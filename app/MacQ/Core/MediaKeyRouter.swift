//
//  MediaKeyRouter.swift
//  MacQ
//
//  The decision layer between the raw key stream and DDC. It owns the event tap
//  and answers one question per keypress: does this key belong to the external
//  monitor, or to the Mac?
//
//  Brightness follows the active display, because brightness is a property of
//  the screen you are looking at. Volume always requires the monitor to be the
//  device macOS is playing through: changing a panel's volume while sound comes
//  out of the Mac's speakers is silent at best, and on some panels wakes their
//  own speakers. The user's rule only decides whether the focused window is an
//  additional requirement on top of that.
//
//  Main thread only. The tap's run-loop source lives on the main run loop, so
//  every delegate callback arrives here on main and may touch DisplayController
//  and AppKit directly.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class MediaKeyRouter: ObservableObject, MediaKeyTapDelegate {

    static let shared = MediaKeyRouter()

    /// Why the feature is or is not currently intercepting keys. Drives the
    /// status row in Settings.
    enum Status: Equatable {
        case off
        case needsAccessibility
        case running
        case failed(String)

        var summary: String {
            switch self {
            case .off: return "Off"
            case .needsAccessibility: return "Waiting for Accessibility permission"
            case .running: return "Active"
            case .failed(let reason): return "Not running: \(reason)"
            }
        }
    }

    @Published private(set) var status: Status = .off

    private let controller: DisplayController
    private let prefs: Preferences
    private let tap = MediaKeyTap()

    /// Keys whose key-down MacQ swallowed, so the matching key-up is swallowed
    /// too. Re-deciding on the up could route the two halves differently (the
    /// sound output device can change in between) and hand macOS an unmatched
    /// release.
    private var ownedKeys: Set<MediaKey> = []

    private var cancellables: Set<AnyCancellable> = []
    private var trustPollGeneration = 0
    private var started = false

    private init(controller: DisplayController = .shared,
                 prefs: Preferences = .shared) {
        self.controller = controller
        self.prefs = prefs
        tap.delegate = self
    }

    // MARK: - Steppers

    private lazy var brightnessStepper = MediaKeyStepper(
        current: { [controller] in controller.brightness },
        maximum: { [controller] in controller.brightnessMax },
        apply: { [controller] in controller.setBrightness($0) },
        begin: { [controller] in controller.beginEditingBrightness() },
        end: { [controller] in controller.endEditingBrightness() })

    private lazy var volumeStepper = MediaKeyStepper(
        current: { [controller] in controller.volume },
        maximum: { [controller] in controller.volumeMax },
        apply: { [controller] in controller.setVolume($0) },
        begin: { [controller] in controller.beginEditingVolume() },
        end: { [controller] in controller.endEditingVolume() })

    // MARK: - Lifecycle

    /// Starts observing preferences and brings the tap up if it should be up.
    /// Call once from applicationDidFinishLaunching.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true

        // receive(on:) defers to the next run-loop turn, so by the time
        // syncTapState reads the preference the @Published property has already
        // been assigned. Reading it inside the sink would see the old value.
        prefs.$mediaKeysEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncTapState() }
            .store(in: &cancellables)

        syncTapState()
    }

    /// Brings the tap up or takes it down to match the current preference and
    /// permission state. Idempotent.
    func syncTapState() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard prefs.mediaKeysEnabled else {
            tap.stop()
            ActiveDisplay.shared.stop()
            MediaKeyHUD.shared.hide()
            ownedKeys.removeAll()
            trustPollGeneration &+= 1 // cancels any pending permission poll
            status = .off
            return
        }

        guard MediaKeyTap.isAccessibilityTrusted else {
            tap.stop()
            status = .needsAccessibility
            pollForTrust()
            return
        }

        // Only started once the feature is genuinely on: it installs an
        // AXObserver on the frontmost app and re-arms it on every app switch,
        // which is not work an idle menu-bar app should be doing.
        ActiveDisplay.shared.start()
        ActiveDisplay.shared.prewarm()

        do {
            try tap.start()
            status = .running
        } catch {
            status = .failed("\(error)")
            NSLog("MacQ.MediaKeyRouter: tap start failed: \(error)")
        }
    }

    /// Full stop and restart. The tap dies across sleep/wake, screen lock and
    /// fast user switching, and a dead tap reports nothing, so the lifecycle
    /// notifications rebuild it rather than trusting it survived.
    func restart() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard prefs.mediaKeysEnabled else { return }
        tap.stop()
        syncTapState()
    }

    /// Opens the system prompt, then Settings. Called from the Settings button.
    func requestAccessibility() {
        dispatchPrecondition(condition: .onQueue(.main))
        // macOS shows this alert at most once per app version and silently
        // returns false thereafter, so the pane is opened regardless.
        MediaKeyTap.promptForAccessibility()
        MediaKeyTap.openAccessibilitySettings()
        pollForTrust()
    }

    /// There is no notification for "the user granted Accessibility", so the
    /// only way to notice is to look. Runs only while the feature is switched on
    /// and the grant is missing, and stops the moment either changes.
    private func pollForTrust() {
        trustPollGeneration &+= 1
        let generation = trustPollGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.trustPollGeneration == generation else { return }
            guard self.prefs.mediaKeysEnabled else { return }
            if MediaKeyTap.isAccessibilityTrusted {
                self.syncTapState()
            } else {
                self.pollForTrust()
            }
        }
    }

    // MARK: - MediaKeyTapDelegate

    func mediaKeyTap(_ tap: MediaKeyTap, shouldSwallow press: MediaKeyPress) -> Bool {
        if !press.isDown {
            guard ownedKeys.remove(press.key) != nil else { return false }
            apply(press) // ends the hold and flushes the final DDC write
            return true
        }

        guard shouldOwn(press) else {
            ownedKeys.remove(press.key)
            return false
        }
        ownedKeys.insert(press.key)
        apply(press)
        return true
    }

    func mediaKeyTap(_ tap: MediaKeyTap, wasDisabledBy reason: MediaKeyTap.DisableReason) {
        NSLog("MacQ.MediaKeyRouter: tap disabled by \(reason.rawValue) and re-enabled")
    }

    // MARK: - Routing

    /// Whether this key belongs to the monitor. Every early return here means
    /// "pass it through", so any uncertainty degrades to normal macOS behaviour
    /// rather than to a key that appears dead.
    private func shouldOwn(_ press: MediaKeyPress) -> Bool {
        guard prefs.mediaKeysEnabled,
              controller.availability.isAvailable,
              let display = controller.display else { return false }

        if press.key.isBrightness {
            guard prefs.brightnessKeysEnabled, controller.supportsBrightness else { return false }
            // Brightness belongs to the screen being looked at, full stop. There
            // is no audio-style ambiguity to resolve.
            return ActiveDisplay.shared.isActive(display.id)
        }

        guard prefs.volumeKeysEnabled, controller.supportsVolume else { return false }
        if press.key == .mute && !controller.supportsMute { return false }

        // Both rules require the monitor to be the current sound output device;
        // see VolumeRouting.decide. Anything else passes the key through, so a
        // wrong answer costs a normal macOS volume change rather than a DDC
        // write to a panel nobody is listening to.
        let routing = VolumeRouting.decide(monitorIsActive: ActiveDisplay.shared.isActive(display.id),
                                           rule: prefs.volumeKeyRule,
                                           binding: MonitorAudioBinding.shared)
        return routing == .monitor
    }

    // MARK: - Applying

    private func apply(_ press: MediaKeyPress) {
        switch press.key {
        case .brightnessUp, .brightnessDown:
            brightnessStepper.handle(press)
            guard press.isDown else { return }
            showHUD(.brightness, value: controller.brightness, maximum: controller.brightnessMax)

        case .volumeUp, .volumeDown:
            volumeStepper.handle(press)
            guard press.isDown else { return }
            // Raising the volume unmutes, so the glyph is read after the step.
            showHUD(controller.isMuted ? .muted : .volume,
                    value: controller.isMuted ? 0 : controller.volume,
                    maximum: controller.volumeMax)

        case .mute:
            // Mute is a toggle, so auto-repeat would flap it. Only the first
            // key-down acts; the repeats and the key-up are still swallowed.
            guard press.isDown, !press.isRepeat else { return }
            controller.toggleMute()
            showHUD(controller.isMuted ? .muted : .volume,
                    value: controller.isMuted ? 0 : controller.volume,
                    maximum: controller.volumeMax)
        }
    }

    private func showHUD(_ glyph: MediaKeyHUD.Glyph, value: Int, maximum: Int) {
        guard prefs.showOSD, let id = controller.display?.id else { return }
        MediaKeyHUD.shared.show(glyph, value: value, maximum: maximum, on: id)
    }
}
