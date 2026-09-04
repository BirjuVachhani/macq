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
import IOKit.pwr_mgt

/// Where MacQ believes the monitor's power is, from MacQ's own actions.
///
/// This tracks intent, not ground truth: `offByMacQ` means "the off button ran
/// and was not contradicted since", and a refresh that reads the panel awake
/// reconciles back to `normal`. A monitor turned off by its own button while
/// the app was not looking still reads as `normal`; the wake button works from
/// there regardless, so the distinction costs nothing.
enum MonitorPowerState: Equatable {
    case normal
    case offByMacQ
    case waking
}

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

    // Auto input detection (VCP 0xF6). Only surfaced when the panel advertises
    // or answers the code; the toggle that drives it lives in Preferences, and
    // DisplayController reconciles the panel to that preference on every bind.
    @Published private(set) var supportsAutoInputDetect = false

    // Monitor power (VCP 0xD6). The off action requires the panel to advertise
    // or answer the code; the wake action deliberately has no such gate because
    // a sleeping panel cannot answer a capability probe.
    @Published private(set) var supportsPowerControl = false
    @Published private(set) var powerState: MonitorPowerState = .normal

    /// Whether the popover shows the power rows at all. True whenever there is
    /// a display to act on now, or one we acted on that may since have dropped
    /// out of the display list (a monitor that is off can de-enumerate, and the
    /// wake row must survive that).
    var showsPowerActions: Bool {
        display != nil || powerState != .normal || lastPowerTargetID != nil
    }

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

    // Recovery after a monitor that is present but not yet talking. See
    // scheduleRecovery.
    private static let recoveryDelays: [TimeInterval] = [1.5, 3, 6]
    /// Bumped by every refresh, so a retry scheduled by an earlier one knows it
    /// has been superseded and drops out instead of stacking up.
    private var refreshGeneration = 0

    /// The display the power actions target. Captured on every successful bind
    /// and at off time, so a wake can still address a panel that de-enumerated
    /// after being turned off. Main-thread confined, like the @Published state.
    private var lastPowerTargetID: CGDirectDisplayID?
    /// Supersession counter for the wake pipeline's timers, mirroring
    /// `refreshGeneration`: a verdict scheduled by an earlier wake drops out.
    private var wakeGeneration = 0

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
        performRefresh(attempt: 0)
    }

    /// `attempt` is this refresh's position in the recovery ladder: 0 for anything
    /// the user or the system asked for, higher only for a retry this class
    /// scheduled itself. Starting again at 0 is what makes "Sync now" a way out
    /// of a monitor that has stopped answering.
    private func performRefresh(attempt: Int) {
        // NSScreen (used by discovery) must be read on the main thread.
        dispatchPrecondition(condition: .onQueue(.main))
        refreshGeneration &+= 1
        let generation = refreshGeneration

        // Snapshot the auto-detect preference here, on the main thread, so the
        // reconcile on the DDC queue below never reads the @Published value off
        // the main thread.
        let preserveAuto = Preferences.shared.preserveAutoInputDetect

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
                    self.supportsAutoInputDetect = false
                    // powerState and lastPowerTargetID survive on purpose: a
                    // panel that is off can drop out of the display list, and
                    // they are what keeps the wake action alive through that.
                    self.supportsPowerControl = false
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
                    self.supportsAutoInputDetect = false
                    self.supportsPowerControl = false
                    self.monitorIsAudioOutput = false
                    self.isBusy = false
                    self.lastSyncText = self.stamp("DDC/CI not responding")
                    MediaKeyDiagnostics.shared.note(
                        "no DDC link for \(chosen.name); every media key passes through")
                    // A monitor MacQ itself turned off is expected to be silent;
                    // polling it back awake would defeat the off button.
                    if self.powerState != .offByMacQ {
                        self.scheduleRecovery(after: attempt, generation: generation)
                    }
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

            // Power mode (0xD6). The read serves two purposes: it infers support
            // when capabilities are unknown, and its value reconciles powerState
            // when the user woke or slept the panel outside MacQ.
            let mayHavePower = self.caps?.supports(VCP.powerMode) ?? true
            let pReading = mayHavePower ? ddc.getVCP(VCP.powerMode) : nil
            let supportsP = (self.caps?.supports(VCP.powerMode) ?? false) || pReading != nil

            // Auto input detection (0xF6). Read it to learn support and, when the
            // panel answers, reconcile it to the user's preference: a manual
            // switch (or another tool) may have left it disabled, and this is
            // where MacQ puts it back. Only write when it actually differs, so a
            // routine refresh does not spend an NVRAM write on every bind.
            let mayHaveAuto = self.caps?.supports(VCP.autoInputSwitch) ?? true
            let autoReading = mayHaveAuto ? ddc.getVCP(VCP.autoInputSwitch) : nil
            let supportsAuto = (self.caps?.supports(VCP.autoInputSwitch) ?? false) || autoReading != nil
            if let autoReading {
                let desired: UInt16 = preserveAuto ? 1 : 0
                if autoReading.current != desired {
                    ddc.setVCP(VCP.autoInputSwitch, value: desired)
                }
            }

            let controllable = (reading != nil) || (bReading != nil) || (vReading != nil) || (self.caps != nil)
            let activeValue = reading.map { UInt8($0.current & 0xFF) }

            // A link that answered nothing at all may be a handle left over from
            // a DisplayPort connection that has since been torn down and rebuilt,
            // which stays non-nil and stays silent. Dropping it costs one
            // IOAVService lookup on the next attempt and is the only thing that
            // distinguishes a retry from repeating the same failed reads.
            if !controllable {
                self.ddc = nil
                self.boundDisplayID = nil
            }
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
                self.supportsAutoInputDetect = supportsAuto
                self.supportsPowerControl = supportsP
                if controllable { self.lastPowerTargetID = chosen.id }
                self.isBusy = false
                self.lastSyncText = self.stamp(controllable ? "Synced" : "DDC/CI not responding")

                // Reconcile power intent with observed reality. The comparison
                // is against the off value MacQ wrote, not against powerOn:
                // the panel's on-state may legitimately read as another of the
                // advertised values, and "no longer in the state we put it in"
                // is the honest test. (Refine once the 0xD6 value semantics
                // are bench-confirmed.) A panel answering while we believe it
                // off means someone woke it by hand; a controllable bind
                // mid-wake means the wake succeeded, and stamping here settles
                // the UI immediately instead of at the verdict deadline.
                if self.powerState == .offByMacQ, let pReading,
                   pReading.current != BenQProfile.powerOff {
                    self.powerState = .normal
                }
                if self.powerState == .waking, controllable,
                   pReading == nil || pReading?.current != BenQProfile.powerOff {
                    self.powerState = .normal
                    self.lastSyncText = self.stamp("Monitor is awake")
                }

                // The same facts as the NSLog above, on a channel that can
                // actually be read back. These three are every precondition a
                // brightness key has to clear apart from where the pointer is,
                // so a log that shows them plus the pointer explains any
                // passthrough without a second round of questions.
                MediaKeyDiagnostics.shared.note(
                    "monitor \(chosen.name) id \(chosen.id): controllable=\(controllable), "
                    + "brightness=\(bReading.map { "\($0.current)/\($0.max)" } ?? "no answer to VCP 0x10"), "
                    + "volume=\(vReading.map { "\($0.current)/\($0.max)" } ?? "no answer to VCP 0x62")")

                if !controllable, self.powerState != .offByMacQ {
                    self.scheduleRecovery(after: attempt, generation: generation)
                }
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
        // Snapshot on the main thread (see performRefresh); decides whether auto
        // detection is turned back on once the switch has settled.
        let preserveAuto = Preferences.shared.preserveAutoInputDetect

        queue.async { [weak self] in
            // ddc is queue-confined; whatever it currently is, is correct here
            // because binding changes are serialized on this same queue.
            guard let self, let ddc = self.ddc else {
                self?.publish { self?.isBusy = false }
                return
            }

            // Stop the panel's auto input detection from racing the selection.
            // It is turned back on after the switch settles when the user wants
            // it preserved (see below); the disable is required either way,
            // because the panel otherwise reverts a manual choice mid-switch.
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

            // Re-enable auto detection now that the switch has settled, so the
            // panel is left the way the user asked. Safe after the settle: the
            // panel only reverts a selection while it is still hunting during
            // the switch. If the switch moved to an input with no live source
            // the DDC link may already be gone and this write is a harmless
            // no-op; the next successful bind reconciles 0xF6 regardless.
            if preserveAuto {
                ddc.setVCP(VCP.autoInputSwitch, value: 1)
            }

            self.publish {
                if let reading { self.activeInputReadValue = UInt8(reading.current & 0xFF) }
                self.isBusy = false
                self.lastSyncText = self.stamp(confirmed
                    ? "Switched to \(self.label(for: source))"
                    : "Could not switch to \(self.label(for: source))")
            }
        }
    }

    // MARK: - Monitor power

    /// Puts the monitor into standby with a VCP 0xD6 write, leaving the Mac and
    /// every other display untouched. Verified by read-back: the panel answering
    /// anything other than "on" counts, and so does the link going silent (an
    /// off state that drops the DisplayPort link takes DDC with it, and the dark
    /// panel is the user-visible truth). Only an unchanged "on" read-back is a
    /// failure, which reverts the state and says so.
    func turnMonitorOff() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard availability.isAvailable, supportsPowerControl, powerState == .normal else { return }
        isBusy = true
        // Set the intent before the write: the reconfiguration storm an off
        // transition can fire must find refresh already knowing it is expected,
        // or the recovery ladder would poll the panel back awake.
        powerState = .offByMacQ
        if let id = display?.id { lastPowerTargetID = id }

        queue.async { [weak self] in
            guard let self, let ddc = self.ddc else {
                self?.publish {
                    self?.powerState = .normal
                    self?.isBusy = false
                }
                return
            }

            var confirmed = false
            for _ in 0..<2 {
                ddc.setVCP(VCP.powerMode, value: BenQProfile.powerOff)
                usleep(1_000_000)
                guard let r = ddc.getVCP(VCP.powerMode) else {
                    confirmed = true // link died with the backlight
                    break
                }
                if r.current != BenQProfile.powerOn {
                    confirmed = true
                    break
                }
            }
            NSLog("MacQ.power: off write 0x%04X confirmed=%@", BenQProfile.powerOff,
                  confirmed ? "true" : "false")

            self.publish {
                self.isBusy = false
                if confirmed {
                    self.lastSyncText = self.stamp("Monitor turned off")
                } else {
                    self.powerState = .normal
                    self.lastSyncText = self.stamp("Monitor did not turn off")
                }
            }
        }
    }

    /// Wakes the monitor through escalating stages:
    ///
    /// W1 declares user activity (public IOKit), which powers macOS-slept
    /// displays back on and re-drives the video signal; a signal transition is
    /// what BenQ panels wake on. W2 re-binds the DDC link by the remembered
    /// display id and writes the 0xD6 "on" value, for off states where the
    /// panel's DDC stays powered. W3 hands over to refresh() and its 1.5/3/6 s
    /// rebuild ladder, the proven remedy for a panel that re-enumerates before
    /// its DDC answers. If the verdict deadline passes without a controllable
    /// bind, W4 soft-replugs the display (disconnect + reconnect), the software
    /// equivalent of pulling the cable. A panel that fully cut its ports can
    /// only be woken by its own button, and the final stamp says so.
    func wakeMonitor() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard powerState != .waking else { return }
        wakeGeneration &+= 1
        let generation = wakeGeneration
        powerState = .waking
        isBusy = true
        lastSyncText = stamp("Waking monitor…")

        // W1: fire and forget; the assertion auto-expires on its own schedule,
        // so the built-in display's normal sleep behavior is untouched.
        var assertionID = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity("MacQ wake monitor" as CFString,
                                         kIOPMUserActiveLocal, &assertionID)

        // Captured on the main thread; the queue block below must not read
        // main-confined state.
        let targetID = display?.id ?? lastPowerTargetID

        // W2, slightly delayed so W1's link re-drive has begun.
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            // Re-resolve a dead link directly by display id. DDCLink.make walks
            // the IORegistry only (no NSScreen), so it is safe on this queue.
            if self.ddc == nil, let id = targetID, let link = DDCLink.make(displayID: id) {
                self.ddc = DDC(link: link)
                self.boundDisplayID = id
            }
            if let ddc = self.ddc {
                for _ in 0..<3 {
                    ddc.setVCP(VCP.powerMode, value: BenQProfile.powerOn)
                    usleep(500_000)
                    if let r = ddc.getVCP(VCP.powerMode), r.current == BenQProfile.powerOn {
                        break
                    }
                }
            }
            // W3: the full refresh re-detects, re-binds and runs the ladder.
            self.publish {
                guard generation == self.wakeGeneration else { return }
                self.refresh()
            }
        }

        // 13 s covers W2's writes plus the whole 1.5/3/6 s ladder.
        scheduleWakeVerdict(generation: generation, deadline: 13.0, isFinal: false)
    }

    /// Checks how a wake attempt ended once its stages have had time to run.
    /// A verdict that finds the panel still unreachable escalates to the replug
    /// (W4) once; the second verdict is final and reports honestly.
    private func scheduleWakeVerdict(generation: Int, deadline: TimeInterval, isFinal: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard let self, generation == self.wakeGeneration else { return }
            // An earlier refresh already settled this wake (or the user acted);
            // nothing left to judge.
            guard self.powerState == .waking else { return }

            if self.availability.isAvailable {
                self.powerState = .normal
                self.lastSyncText = self.stamp("Monitor is awake")
            } else if !isFinal {
                self.performReplugWake(generation: generation)
            } else {
                self.powerState = .normal
                self.lastSyncText = self.stamp("Could not wake the monitor. Try its power button.")
            }
        }
    }

    /// W4: soft-replug via the private CGSConfigureDisplayEnabled call (see
    /// DisplayReplug). Disconnecting and reconnecting renegotiates the link the
    /// way unplugging the cable would, which produces the signal transition a
    /// BenQ panel wakes on even when its DDC is unreachable. Last resort only:
    /// a replug can occasionally leave the mode list degraded until a physical
    /// re-plug, so the DDC path always gets its chance first.
    private func performReplugWake(generation: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard generation == wakeGeneration, powerState == .waking else { return }
        guard let id = display?.id ?? lastPowerTargetID else {
            powerState = .normal
            lastSyncText = stamp("Could not wake the monitor. Try its power button.")
            return
        }

        let isOnline = CGDisplayIsOnline(id) != 0
        NSLog("MacQ.power: replug wake, display %u online=%@", id, isOnline ? "true" : "false")

        if isOnline {
            let disabled = DisplayReplug.setDisplay(id, enabled: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                guard generation == self.wakeGeneration, self.powerState == .waking else {
                    // The wake was superseded mid-replug; never leave a display
                    // disabled behind our own back.
                    if disabled { DisplayReplug.restorePermanentConfiguration() }
                    return
                }
                let enabled = DisplayReplug.setDisplay(id, enabled: true)
                if disabled && !enabled {
                    DisplayReplug.restorePermanentConfiguration()
                }
                self.refresh()
                self.scheduleWakeVerdict(generation: generation, deadline: 10.0, isFinal: true)
            }
        } else {
            // Fully de-enumerated: there is nothing to disable. The enable call
            // revives a soft-disabled display and fails cleanly otherwise.
            _ = DisplayReplug.setDisplay(id, enabled: true)
            refresh()
            scheduleWakeVerdict(generation: generation, deadline: 10.0, isFinal: true)
        }
    }

    // MARK: - Auto input detection

    /// Records the user's auto-input-detection choice and applies it to the
    /// panel right away. The refresh path also reconciles 0xF6 on every bind, so
    /// this exists only so flipping the toggle takes effect without waiting for
    /// the next refresh.
    func setAutoInputDetect(_ on: Bool) {
        Preferences.shared.preserveAutoInputDetect = on
        guard availability.isAvailable else { return }
        queue.async { [weak self] in
            guard let self, let ddc = self.ddc else { return }
            ddc.setVCP(VCP.autoInputSwitch, value: on ? 1 : 0)
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

    /// Asks again, a few times, after a refresh that found the monitor but could
    /// not talk to it.
    ///
    /// A panel coming back from sleep is in the display list and carrying a live
    /// DisplayPort link well before its DDC channel will answer, so the
    /// reconfiguration event that triggers the refresh routinely arrives too
    /// early. Without this, that one badly timed read is final: refresh runs only
    /// on a display change, and the change has already happened. The 3 s poll is
    /// no help, since it runs only while the popover is open and only re-reads
    /// values through a link that is already bound. The visible symptom is a
    /// monitor that looks connected while every media key passes through to the
    /// Mac, until the app is relaunched or Sync is pressed by hand.
    ///
    /// The ladder is short and it stops. A monitor that is genuinely not
    /// DDC-capable must not be polled forever, and any real change to the display
    /// setup starts a fresh refresh anyway.
    private func scheduleRecovery(after attempt: Int, generation: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        // A newer refresh has already started, and its own result decides what
        // happens next. This is the common case during a wake, which emits
        // several reconfiguration callbacks in a burst.
        guard generation == refreshGeneration else { return }

        guard attempt < Self.recoveryDelays.count else {
            MediaKeyDiagnostics.shared.note(
                "monitor still not answering after \(attempt) retries; "
                + "waiting for a display change or a manual sync")
            return
        }

        let delay = Self.recoveryDelays[attempt]
        MediaKeyDiagnostics.shared.note(
            String(format: "monitor not answering; retrying in %.1fs (attempt %d of %d)",
                   delay, attempt + 1, Self.recoveryDelays.count))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.refreshGeneration else { return }
            self.performRefresh(attempt: attempt + 1)
        }
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
