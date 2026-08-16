//
//  MediaKeyRouter.swift
//  MacQ
//
//  The decision layer between the raw key stream and DDC. It owns the event tap
//  and answers one question per keypress: does this key belong to the external
//  monitor, or to the Mac?
//
//  Brightness follows the display under the pointer, because brightness is a
//  property of the screen you are looking at and pointing at it is how you say
//  which one that is. Volume always requires the monitor to be the device macOS
//  is playing through: changing a panel's volume while sound comes out of the
//  Mac's speakers is silent at best, and on some panels wakes their own
//  speakers. The user's rule only decides whether the active display is an
//  additional requirement on top of that.
//
//  Both rules are the ones BenQ's Display Pilot 2 ships, which is the behaviour
//  this was asked to match: brightness by cursor position, volume by selected
//  audio output.
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

        // Logged unconditionally, before the first sync: the starting state is
        // usually `.off`, and setStatus only records transitions, so without this
        // the commonest failure ("the feature is simply switched off in this
        // build's preference domain") would leave no trace at all. The bundle id
        // is here because it *is* the preference domain: a build signed with a
        // different identifier reads a different set of settings.
        MediaKeyDiagnostics.shared.note(
            "start: bundle \(Bundle.main.bundleIdentifier ?? "unknown"), "
            + "media keys enabled=\(prefs.mediaKeysEnabled), "
            + "accessibility trusted=\(MediaKeyTap.isAccessibilityTrusted)")

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
            setStatus(.off)
            return
        }

        guard MediaKeyTap.isAccessibilityTrusted else {
            tap.stop()
            setStatus(.needsAccessibility)
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
            setStatus(.running)
        } catch {
            setStatus(.failed("\(error)"))
            NSLog("MacQ.MediaKeyRouter: tap start failed: \(error)")
        }
    }

    /// Every transition is logged, including the ones that mean "no key will ever
    /// arrive". A silent `.off` is the single most confusing state this feature
    /// has: nothing happens, nothing is written, and nothing says why. Only real
    /// changes are recorded, since syncTapState is idempotent and called often.
    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        MediaKeyDiagnostics.shared.note("tap status: \(new.summary)")
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

        switch route(press) {
        case .monitor:
            // Auto-repeat would otherwise flood the log and push the interesting
            // first press of a hold off the top of it.
            if !press.isRepeat { MediaKeyDiagnostics.shared.record("    to the monitor") }
            ownedKeys.insert(press.key)
            apply(press)
            return true
        case .passthrough(let reason):
            ownedKeys.remove(press.key)
            if !press.isRepeat { MediaKeyDiagnostics.shared.record("    to macOS: \(reason)") }
            return false
        }
    }

    func mediaKeyTap(_ tap: MediaKeyTap, wasDisabledBy reason: MediaKeyTap.DisableReason) {
        NSLog("MacQ.MediaKeyRouter: tap disabled by \(reason.rawValue) and re-enabled")
        MediaKeyDiagnostics.shared.note("tap disabled by \(reason.rawValue), re-enabled")
    }

    // MARK: - Routing

    /// Where one key-down goes, with the reason attached. The reason is only ever
    /// read by the diagnostics log, but carrying it forces every declining branch
    /// to say something specific instead of returning a bare false.
    private enum Routing {
        case monitor
        case passthrough(String)
    }

    /// Whether this key belongs to the monitor. Every `.passthrough` here means
    /// "let macOS have it", so any uncertainty degrades to normal system
    /// behaviour rather than to a key that appears dead.
    private func route(_ press: MediaKeyPress) -> Routing {
        guard prefs.mediaKeysEnabled else { return .passthrough("media keys are off") }
        guard controller.availability.isAvailable else {
            return .passthrough("monitor not controllable: \(controller.availability.reason ?? "unavailable")")
        }
        guard let display = controller.display else { return .passthrough("no external monitor bound") }

        if press.key.isBrightness {
            guard prefs.brightnessKeysEnabled else { return .passthrough("brightness keys are off") }
            guard controller.supportsBrightness else {
                return .passthrough("monitor did not answer brightness (VCP 0x10)")
            }
            // Brightness belongs to the screen being pointed at, full stop.
            // There is no audio-style ambiguity to resolve.
            guard ActiveDisplay.shared.isActive(display.id) else {
                return .passthrough("pointer is not on monitor \(display.id); \(ActiveDisplay.shared.diagnostics())")
            }
            return .monitor
        }

        guard prefs.volumeKeysEnabled else { return .passthrough("volume keys are off") }
        guard controller.supportsVolume else {
            return .passthrough("monitor did not answer volume (VCP 0x62)")
        }
        if press.key == .mute && !controller.supportsMute {
            return .passthrough("monitor did not answer mute (VCP 0x8D)")
        }

        // Both rules require the monitor to be the current sound output device;
        // see VolumeRouting.decide. Anything else passes the key through, so a
        // wrong answer costs a normal macOS volume change rather than a DDC
        // write to a panel nobody is listening to.
        let monitorIsActive = ActiveDisplay.shared.isActive(display.id)
        let routing = VolumeRouting.decide(monitorIsActive: monitorIsActive,
                                           rule: prefs.volumeKeyRule,
                                           binding: MonitorAudioBinding.shared)
        guard routing == .monitor else {
            let owns = MonitorAudioBinding.shared.isMonitorTheDefaultOutput()
            return .passthrough("rule \"\(prefs.volumeKeyRule.title)\" not met; monitor owns sound=\(owns), monitor is active display=\(monitorIsActive)")
        }
        return .monitor
    }

    // MARK: - Applying

    private func apply(_ press: MediaKeyPress) {
        switch press.key {
        case .brightnessUp, .brightnessDown:
            brightnessStepper.handle(press)
            guard press.isDown else { return }
            if !press.isRepeat {
                MediaKeyDiagnostics.shared.record(
                    "    brightness \(controller.brightness)/\(controller.brightnessMax), writing VCP 0x10")
            }
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

    /// The monitor's name is the indicator's title. The indicator hangs under
    /// MacQ's menu-bar icon rather than on the panel it just changed, so naming
    /// the monitor is what keeps it from being an unattributed bar on a screen
    /// that did not move.
    private func showHUD(_ glyph: MediaKeyHUD.Glyph, value: Int, maximum: Int) {
        guard prefs.showOSD, let display = controller.display else { return }
        MediaKeyHUD.shared.show(glyph, title: display.name,
                                value: value, maximum: maximum, on: display.id)
    }
}
