//
//  DisplayController.swift
//  MacQ
//
//  Orchestrates detection, DDC I/O, and published UI state. DDC calls run on a
//  private serial queue (they block and retry); all @Published mutations happen
//  on the main thread.
//

import Foundation
import Combine
import CoreGraphics

final class DisplayController: ObservableObject {
    /// Shared instance used by both the SwiftUI scene and the AppDelegate.
    static let shared = DisplayController()

    // Published state consumed by the UI.
    @Published private(set) var display: ExternalDisplay?
    @Published private(set) var availability: ControlAvailability = .noExternalDisplay
    @Published private(set) var sources: [InputSource] = []
    @Published private(set) var activeInputReadValue: UInt8?
    @Published private(set) var isBusy = false
    @Published private(set) var lastSyncText = "Not synced yet"

    // Brightness (VCP 0x10, 0...max) and Volume (VCP 0x62, 0...max). Each is
    // shown only when the monitor advertises/answers the corresponding code.
    @Published private(set) var supportsBrightness = false
    @Published private(set) var brightness = 0
    @Published private(set) var brightnessMax = 100
    @Published private(set) var supportsVolume = false
    @Published private(set) var volume = 0
    @Published private(set) var volumeMax = 50

    // Audio mute (VCP 0x8D, 0x01 mute / 0x02 unmute). Kept separate from
    // "volume 0" on purpose: a volume-zero mute has nowhere to record the level
    // to restore, and the 3-second value poll would immediately overwrite it.
    @Published private(set) var supportsMute = false
    @Published private(set) var isMuted = false

    /// Whether macOS is currently playing through this monitor.
    ///
    /// This is routing information, not permission. It decides whether the
    /// keyboard's volume keys are aimed at the monitor (see VolumeRouting), and
    /// it is shown in Settings so that rule is legible. It deliberately does not
    /// gate anything in this class: an explicit slider drag is a direct
    /// instruction about the monitor's volume and is always obeyed.
    @Published private(set) var monitorIsAudioOutput = false

    private let aliasStore = AliasStore()
    private let queue = DispatchQueue(label: "dev.birjuvachhani.MacQ.ddc", qos: .userInitiated)

    // Per-display cache (valid while bound to the same display id).
    private var ddc: DDC?
    private var caps: MonitorCapabilities?
    private var boundDisplayID: CGDirectDisplayID?
    /// Queue-confined mirror of `supportsMute`. The value poll runs on this
    /// queue and must not read the main-thread @Published copy.
    private var pollMute = false

    // Slider write coalescing + guards against a sync overwriting an active drag.
    private lazy var brightnessThrottle = Throttle(0.05)
    private lazy var volumeThrottle = Throttle(0.05)
    private var editingBrightness = false
    private var editingVolume = false
    private var editingMute = false
    private var muteSettleGeneration = 0

    private var audioOutputObserver: NSObjectProtocol?

    init() {
        registerReconfigurationCallback()
        // The sound output device can change with no involvement from MacQ, and
        // it decides where the keyboard's volume keys are aimed, so it is
        // tracked rather than sampled only at refresh time.
        audioOutputObserver = NotificationCenter.default.addObserver(
            forName: MonitorAudioBinding.defaultOutputDeviceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refreshAudioOutputState() }
        refresh()
    }

    deinit {
        if let audioOutputObserver {
            NotificationCenter.default.removeObserver(audioOutputObserver)
        }
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Public API (call on main thread)

    /// Re-detects the display and reads its current input (and capabilities on
    /// first bind). Safe to call repeatedly; this is the manual "Sync" action.
    func refresh() {
        // NSScreen (used by discovery) must be read on the main thread.
        let displays = DisplayDiscovery.externalDisplays()
        NSLog("MacQ.refresh: externalDisplays=\(displays.count) names=\(displays.map { $0.name })")
        isBusy = true

        // Everything that touches ddc/caps/boundDisplayID runs on this serial
        // queue, so those fields are never accessed from two threads at once.
        queue.async { [weak self] in
            guard let self else { return }

            guard let chosen = self.pickDisplay(from: displays) else {
                self.ddc = nil
                self.boundDisplayID = nil
                self.caps = nil
                self.pollMute = false
                MonitorAudioBinding.shared.bind(to: nil)
                self.publish {
                    self.display = nil
                    self.availability = .noExternalDisplay
                    self.sources = []
                    self.activeInputReadValue = nil
                    self.supportsBrightness = false
                    self.supportsVolume = false
                    self.supportsMute = false
                    self.monitorIsAudioOutput = false
                    self.isBusy = false
                    self.lastSyncText = self.stamp("No external monitor")
                    MediaKeyDiagnostics.shared.note("no external monitor; every media key passes through")
                }
                return
            }

            self.publish { self.display = chosen }

            // Reads the display's EDID UUID from the IORegistry, which is why it
            // runs here on the DDC queue rather than on the main thread. This is
            // deliberately independent of whether DDC answers: the answer feeds
            // the volume-key routing decision, not DDC itself.
            MonitorAudioBinding.shared.bind(to: chosen)

            if self.boundDisplayID != chosen.id || self.ddc == nil {
                self.ddc = DisplayDiscovery.ddc(for: chosen)
                self.boundDisplayID = (self.ddc != nil) ? chosen.id : nil
                self.caps = nil
            }

            guard let ddc = self.ddc else {
                NSLog("MacQ.refresh: no DDC link for \(chosen.name)")
                self.pollMute = false
                self.publish {
                    self.availability = .ddcUnavailable
                    self.sources = BenQProfile.inputSources(from: nil)
                    self.activeInputReadValue = nil
                    self.supportsBrightness = false
                    self.supportsVolume = false
                    self.supportsMute = false
                    self.monitorIsAudioOutput = false
                    self.isBusy = false
                    self.lastSyncText = self.stamp("DDC/CI not responding")
                    MediaKeyDiagnostics.shared.note(
                        "no DDC link for \(chosen.name); every media key passes through")
                }
                return
            }

            if self.caps == nil, let raw = ddc.readCapabilities() {
                self.caps = CapabilitiesParser.parse(raw)
            }
            let reading = ddc.getVCP(VCP.inputSource)
            let builtSources = BenQProfile.inputSources(from: self.caps)

            // Read brightness/volume when the monitor advertises them (or when
            // capabilities are unknown, in which case we probe and infer support).
            let mayHaveBrightness = self.caps?.supports(VCP.brightness) ?? true
            let mayHaveVolume = self.caps?.supports(VCP.audioVolume) ?? true
            let bReading = mayHaveBrightness ? ddc.getVCP(VCP.brightness) : nil
            let vReading = mayHaveVolume ? ddc.getVCP(VCP.audioVolume) : nil
            let supportsB = (self.caps?.supports(VCP.brightness) ?? false) || bReading != nil
            let supportsV = (self.caps?.supports(VCP.audioVolume) ?? false) || vReading != nil

            // 0x8D is probed whenever the monitor answers for volume at all. It
            // is a read, so it costs one DDC round trip and changes nothing on
            // the panel. Whether MacQ should *write* the panel's audio is a
            // routing question, answered per keypress in VolumeRouting, not here.
            let mReading = supportsV ? ddc.getVCP(VCP.audioMute) : nil
            let supportsM = mReading != nil
            let muted = mReading.map { $0.current == VCPValue.muteOn } ?? false
            self.pollMute = supportsM
            let audioIsOurs = MonitorAudioBinding.shared.isMonitorTheDefaultOutput()

            let controllable = (reading != nil) || (bReading != nil) || (vReading != nil) || (self.caps != nil)
            let activeValue = reading.map { UInt8($0.current & 0xFF) }
            NSLog("MacQ.refresh: display=\(chosen.name) controllable=\(controllable) activeInput=\(activeValue.map { String(format: "0x%02X", $0) } ?? "nil") sources=\(builtSources.count) brightness=\(bReading.map { "\($0.current)/\($0.max)" } ?? "n/a") volume=\(vReading.map { "\($0.current)/\($0.max)" } ?? "n/a") mccs=\(self.caps?.mccsVersion ?? "?")")

            self.publish {
                self.sources = builtSources
                self.activeInputReadValue = activeValue
                self.availability = controllable ? .available : .ddcUnavailable
                self.supportsBrightness = supportsB
                if let bReading {
                    self.brightnessMax = max(1, Int(bReading.max))
                    if !self.editingBrightness { self.brightness = Int(bReading.current) }
                }
                self.supportsVolume = supportsV
                if let vReading {
                    self.volumeMax = max(1, Int(vReading.max))
                    if !self.editingVolume { self.volume = Int(vReading.current) }
                }
                self.monitorIsAudioOutput = audioIsOurs
                self.supportsMute = supportsM
                if supportsM { self.isMuted = muted }
                self.isBusy = false
                self.lastSyncText = self.stamp(controllable ? "Synced" : "DDC/CI not responding")

                // The same facts as the NSLog above, on a channel that can
                // actually be read back. These three are every precondition a
                // brightness key has to clear apart from where the pointer is,
                // so a log that shows them plus the pointer explains any
                // passthrough without a second round of questions.
                MediaKeyDiagnostics.shared.note(
                    "monitor \(chosen.name) id \(chosen.id): controllable=\(controllable), "
                    + "brightness=\(bReading.map { "\($0.current)/\($0.max)" } ?? "no answer to VCP 0x10"), "
                    + "volume=\(vReading.map { "\($0.current)/\($0.max)" } ?? "no answer to VCP 0x62")")
            }
        }
    }

    /// Switches the monitor to the given input and confirms it actually took
    /// effect. BenQ panels can ignore a single write (and their auto input
    /// detection can fight a switch), so we write the value repeatedly and
    /// verify the read-back matches the target before giving up.
    /// Note: switching to an input with no live source can drop the DDC link.
    func selectInput(_ source: InputSource) {
        guard availability.isAvailable else { return }
        isBusy = true

        queue.async { [weak self] in
            // ddc is queue-confined; whatever it currently is, is correct here
            // because binding changes are serialized on this same queue.
            guard let self, let ddc = self.ddc else {
                self?.publish { self?.isBusy = false }
                return
            }

            // Stop the panel's auto input detection from racing the selection.
            ddc.setVCP(VCP.autoInputSwitch, value: 0)
            usleep(300_000)

            // Try each candidate value (primary, then fallbacks). For each, write
            // and give the panel ~1.5s to acquire signal before reading back; a
            // read taken mid-switch lags, so we verify only after the settle, and
            // re-write once before moving on.
            var confirmed = false
            var usedValue = source.writeValue
            outer: for value in source.writeCandidates {
                for _ in 0..<2 {
                    ddc.setVCP(VCP.inputSource, value: UInt16(value))
                    usleep(1_500_000)
                    if let r = ddc.getVCP(VCP.inputSource),
                       source.matches(readValue: UInt8(r.current & 0xFF)) {
                        confirmed = true
                        usedValue = value
                        break outer
                    }
                }
            }
            let reading = ddc.getVCP(VCP.inputSource)
            NSLog("MacQ.selectInput: \(self.label(for: source)) tried=\(source.writeCandidates.map { String(format: "0x%02X", $0) }) used=0x\(String(usedValue, radix: 16)) confirmed=\(confirmed) readBack=\(reading.map { String(format: "0x%02X", UInt8($0.current & 0xFF)) } ?? "nil")")

            self.publish {
                if let reading { self.activeInputReadValue = UInt8(reading.current & 0xFF) }
                self.isBusy = false
                self.lastSyncText = self.stamp(confirmed
                    ? "Switched to \(self.label(for: source))"
                    : "Could not switch to \(self.label(for: source))")
            }
        }
    }

    /// Light poll of just the live values (current input, brightness, volume) on
    /// the already-bound display. No re-detection or capabilities read. Used by
    /// the periodic poll while the popover is open; skips values being dragged.
    func syncValues() {
        queue.async { [weak self] in
            guard let self, let ddc = self.ddc else { return }
            let input = ddc.getVCP(VCP.inputSource)
            let b = (self.caps?.supports(VCP.brightness) ?? true) ? ddc.getVCP(VCP.brightness) : nil
            let v = (self.caps?.supports(VCP.audioVolume) ?? true) ? ddc.getVCP(VCP.audioVolume) : nil
            let m = self.pollMute ? ddc.getVCP(VCP.audioMute) : nil
            self.publish {
                if let input { self.activeInputReadValue = UInt8(input.current & 0xFF) }
                if let b, !self.editingBrightness {
                    self.brightnessMax = max(1, Int(b.max))
                    self.brightness = Int(b.current)
                }
                if let v, !self.editingVolume {
                    self.volumeMax = max(1, Int(v.max))
                    self.volume = Int(v.current)
                }
                if let m, !self.editingMute {
                    self.isMuted = (m.current == VCPValue.muteOn)
                }
            }
        }
    }

    // MARK: - Brightness & volume

    /// Sets brightness (0...brightnessMax). During a drag this is called rapidly;
    /// the UI updates immediately and DDC writes are coalesced to ~20/sec.
    func setBrightness(_ value: Int) {
        let clamped = max(0, min(brightnessMax, value))
        brightness = clamped
        brightnessThrottle.submit { [weak self] in self?.writeVCP(VCP.brightness, UInt16(clamped)) }
    }

    func beginEditingBrightness() { editingBrightness = true }
    func endEditingBrightness() {
        editingBrightness = false
        brightnessThrottle.flush() // guarantee the final value is written
    }

    // MARK: - Audio routing

    /// Re-reads whether macOS is playing through the monitor. Main thread only;
    /// a live CoreAudio read costs roughly 13 us, so a UI tick may call it.
    ///
    /// Purely informational. It feeds the Settings row that explains the volume
    /// key rule, and nothing in this class consults it before writing.
    func refreshAudioOutputState() {
        dispatchPrecondition(condition: .onQueue(.main))
        let isOurs = MonitorAudioBinding.shared.isMonitorTheDefaultOutput()
        guard isOurs != monitorIsAudioOutput else { return }
        monitorIsAudioOutput = isOurs
    }

    /// Sets the monitor's speaker volume (0...volumeMax, VCP 0x62).
    ///
    /// Never gated on the sound output device. Reaching this method means the
    /// user aimed at the monitor's volume specifically, by dragging its slider,
    /// or via a media key that MediaKeyRouter already decided belongs to the
    /// monitor. Re-litigating that here would only make the slider inert.
    func setVolume(_ value: Int) {
        let clamped = max(0, min(volumeMax, value))
        volume = clamped
        // Raising the volume unmutes, the way macOS's own volume keys do, but
        // only after confirming the panel really is muted. See the comment on
        // unmuteIfPanelIsMuted().
        if clamped > 0 { unmuteIfPanelIsMuted() }
        volumeThrottle.submit { [weak self] in self?.writeVCP(VCP.audioVolume, UInt16(clamped)) }
    }

    func beginEditingVolume() { editingVolume = true }
    func endEditingVolume() {
        editingVolume = false
        volumeThrottle.flush()
    }

    /// Clears the panel's mute, but only if a fresh read says it is muted.
    ///
    /// The cached `isMuted` can be arbitrarily old: nothing on the media-key
    /// path refreshes it, and the only writers are refresh() and the 3 s poll
    /// that exists solely while the popover is open. Trusting it meant a volume
    /// step could emit an unrequested 0x8D unmute, which is literally the
    /// command "turn this panel's speakers on". One extra read is far cheaper
    /// than that write.
    private func unmuteIfPanelIsMuted() {
        guard supportsMute, isMuted else { return }
        queue.async { [weak self] in
            guard let self, let ddc = self.ddc else { return }
            guard let reading = ddc.getVCP(VCP.audioMute) else { return }
            guard reading.current == VCPValue.muteOn else {
                // Not actually muted: the cached flag was stale. Correct it and
                // write nothing.
                self.publish { if !self.editingMute { self.isMuted = false } }
                return
            }
            ddc.setVCP(VCP.audioMute, value: VCPValue.muteOff)
            self.publish {
                self.isMuted = false
                self.holdMuteState()
            }
        }
    }

    /// Mutes or unmutes the monitor's own speakers (VCP 0x8D).
    func setMute(_ muted: Bool) {
        guard supportsMute else { return }
        isMuted = muted
        holdMuteState()
        writeVCP(VCP.audioMute, muted ? VCPValue.muteOn : VCPValue.muteOff)
    }

    func toggleMute() { setMute(!isMuted) }

    /// Panels can take a moment to report a new mute state, and a poll landing
    /// in that window would flip the UI back. Holds the local value briefly.
    /// Main thread only.
    private func holdMuteState() {
        editingMute = true
        muteSettleGeneration &+= 1
        let generation = muteSettleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.muteSettleGeneration == generation else { return }
            self.editingMute = false
        }
    }

    /// Fire-and-forget VCP write on the DDC queue (used by the sliders).
    private func writeVCP(_ code: UInt8, _ value: UInt16) {
        queue.async { [weak self] in self?.ddc?.setVCP(code, value: value) }
    }

    // MARK: - Labels & aliases

    func label(for source: InputSource) -> String {
        guard let display else { return source.defaultLabel }
        return aliasStore.displayLabel(for: source, displayKey: display.persistentKey)
    }

    func alias(for source: InputSource) -> String? {
        guard let display else { return nil }
        return aliasStore.alias(displayKey: display.persistentKey, writeValue: source.writeValue)
    }

    func setAlias(_ alias: String?, for source: InputSource) {
        guard let display else { return }
        aliasStore.setAlias(alias, displayKey: display.persistentKey, writeValue: source.writeValue)
        objectWillChange.send() // labels changed; refresh views
    }

    func isActive(_ source: InputSource) -> Bool {
        guard let value = activeInputReadValue else { return false }
        return source.matches(readValue: value)
    }

    // MARK: - Helpers

    private func pickDisplay(from displays: [ExternalDisplay]) -> ExternalDisplay? {
        // Keep the currently bound display if it is still connected.
        if let boundID = boundDisplayID, let same = displays.first(where: { $0.id == boundID }) {
            return same
        }
        return displays.first
    }

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func stamp(_ text: String) -> String {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return "\(text) · \(f.string(from: Date()))"
    }

    fileprivate func handleReconfiguration(flags: CGDisplayChangeSummaryFlags) {
        let relevant: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .enabledFlag, .disabledFlag, .setModeFlag]
        guard !flags.intersection(relevant).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func registerReconfigurationCallback() {
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())
    }
}

/// C callback for display hotplug / mode changes.
private func displayReconfigCallback(_ display: CGDirectDisplayID,
                                     _ flags: CGDisplayChangeSummaryFlags,
                                     _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let controller = Unmanaged<DisplayController>.fromOpaque(userInfo).takeUnretainedValue()
    controller.handleReconfiguration(flags: flags)
}

/// Leading + trailing throttle: runs the latest submitted action at most once
/// per interval. Main-thread only (matches how the sliders call it).
private final class Throttle {
    private let interval: TimeInterval
    private var scheduled = false
    private var pending: (() -> Void)?
    private var lastFire = Date.distantPast

    init(_ interval: TimeInterval) { self.interval = interval }

    func submit(_ action: @escaping () -> Void) {
        pending = action
        guard !scheduled else { return }
        let elapsed = Date().timeIntervalSince(lastFire)
        if elapsed >= interval {
            fire()
        } else {
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (interval - elapsed)) { [weak self] in
                guard let self else { return }
                self.scheduled = false
                if self.pending != nil { self.fire() }
            }
        }
    }

    /// Runs any pending action immediately (used on drag-end).
    func flush() { if pending != nil { fire() } }

    private func fire() {
        lastFire = Date()
        let action = pending
        pending = nil
        action?()
    }
}
