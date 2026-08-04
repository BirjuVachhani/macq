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

    private let aliasStore = AliasStore()
    private let queue = DispatchQueue(label: "dev.birjuvachhani.MacQ.ddc", qos: .userInitiated)

    // Per-display cache (valid while bound to the same display id).
    private var ddc: DDC?
    private var caps: MonitorCapabilities?
    private var boundDisplayID: CGDirectDisplayID?

    // Slider write coalescing + guards against a sync overwriting an active drag.
    private lazy var brightnessThrottle = Throttle(0.05)
    private lazy var volumeThrottle = Throttle(0.05)
    private var editingBrightness = false
    private var editingVolume = false

    init() {
        registerReconfigurationCallback()
        refresh()
    }

    deinit {
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
                self.publish {
                    self.display = nil
                    self.availability = .noExternalDisplay
                    self.sources = []
                    self.activeInputReadValue = nil
                    self.supportsBrightness = false
                    self.supportsVolume = false
                    self.isBusy = false
                    self.lastSyncText = self.stamp("No external monitor")
                }
                return
            }

            self.publish { self.display = chosen }

            if self.boundDisplayID != chosen.id || self.ddc == nil {
                self.ddc = DisplayDiscovery.ddc(for: chosen)
                self.boundDisplayID = (self.ddc != nil) ? chosen.id : nil
                self.caps = nil
            }

            guard let ddc = self.ddc else {
                NSLog("MacQ.refresh: no DDC link for \(chosen.name)")
                self.publish {
                    self.availability = .ddcUnavailable
                    self.sources = BenQProfile.inputSources(from: nil)
                    self.activeInputReadValue = nil
                    self.supportsBrightness = false
                    self.supportsVolume = false
                    self.isBusy = false
                    self.lastSyncText = self.stamp("DDC/CI not responding")
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
                self.isBusy = false
                self.lastSyncText = self.stamp(controllable ? "Synced" : "DDC/CI not responding")
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

    func setVolume(_ value: Int) {
        let clamped = max(0, min(volumeMax, value))
        volume = clamped
        volumeThrottle.submit { [weak self] in self?.writeVCP(VCP.audioVolume, UInt16(clamped)) }
    }

    func beginEditingVolume() { editingVolume = true }
    func endEditingVolume() {
        editingVolume = false
        volumeThrottle.flush()
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
