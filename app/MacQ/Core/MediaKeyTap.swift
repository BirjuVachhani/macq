//
//  MediaKeyTap.swift
//  MacQ
//
//  An active (swallowing) CGEventTap over the NX_SYSDEFINED media-key stream,
//  so F1/F2 and F10/F11/F12 can drive the external monitor over DDC instead of
//  the Mac's own display and speakers.
//
//  Main-thread confined: the run-loop source is installed on the main run loop,
//  so start/stop and every delegate callback happen on the main thread and the
//  delegate may touch DisplayController directly.
//
//  The callback runs synchronously inside the system's event stream. It must
//  return fast: anything slower than a second makes macOS disable the tap. DDC
//  reads (up to ~1s with retries) must never happen here; DDC writes are fine
//  because they are dispatched to a background queue.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Raw constants

/// Constants from `IOKit/hidsystem/IOLLEvent.h` and `IOKit/hidsystem/ev_keymap.h`,
/// spelled out here so the bit layout is visible at the point of use.
enum NX {
    /// `NX_SYSDEFINED`. Same number as `NSEvent.EventType.systemDefined`.
    static let sysDefined: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`, the systemDefined subtype carrying media
    /// keys. Subtype 1 is the power key, 7 is aux mouse buttons.
    static let subtypeAuxControlButtons: Int16 = 8

    // ev_keymap.h special-key codes.
    static let keyTypeSoundUp = 0
    static let keyTypeSoundDown = 1
    static let keyTypeBrightnessUp = 2
    static let keyTypeBrightnessDown = 3
    static let keyTypeMute = 7

    /// `data1` layout for subtype 8:
    ///   bits 31..16  keyCode  (an NX_KEYTYPE_* value)
    ///   bits 15..8   keyState (0x0A down, 0x0B up)
    ///   bits  7..1   reserved
    ///   bit      0   keyRepeat (1 when this down is a hardware auto-repeat)
    static let keyCodeShift: Int64 = 16
    static let keyCodeMask: Int64 = 0xFFFF_0000
    static let keyFlagsMask: Int64 = 0x0000_FFFF
    static let keyStateShift: Int64 = 8
    static let keyStateMask: Int64 = 0x0000_FF00
    static let keyStateDown: Int64 = 0x0A
    static let keyRepeatMask: Int64 = 0x1
}

// MARK: - Decoded model

/// The five keys MacQ cares about. Everything else on this stream (play/pause,
/// eject, and crucially the keyboard-backlight keys NX_KEYTYPE_ILLUMINATION_UP
/// 21 / _DOWN 22 / _TOGGLE 23) decodes to nil and passes straight through.
enum MediaKey: Equatable {
    case brightnessUp
    case brightnessDown
    case volumeUp
    case volumeDown
    case mute

    init?(nxKeyType code: Int) {
        switch code {
        case NX.keyTypeBrightnessUp: self = .brightnessUp
        case NX.keyTypeBrightnessDown: self = .brightnessDown
        case NX.keyTypeSoundUp: self = .volumeUp
        case NX.keyTypeSoundDown: self = .volumeDown
        case NX.keyTypeMute: self = .mute
        default: return nil
        }
    }

    var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }

    /// +1 raise, -1 lower, 0 for mute.
    var sign: Int {
        switch self {
        case .brightnessUp, .volumeUp: return 1
        case .brightnessDown, .volumeDown: return -1
        case .mute: return 0
        }
    }
}

/// One decoded press. `isRepeat` is the hardware auto-repeat bit, not a guess.
struct MediaKeyPress {
    let key: MediaKey
    let isDown: Bool
    let isRepeat: Bool
    let modifiers: NSEvent.ModifierFlags

    /// Shift+Option held, macOS's own quarter-step gesture.
    var isFineStep: Bool { modifiers.contains(.shift) && modifiers.contains(.option) }
}

// MARK: - Delegate

protocol MediaKeyTapDelegate: AnyObject {
    /// Return true to SWALLOW the event (MacQ handled it and drove DDC), false to
    /// pass it through so macOS does its normal thing: built-in display
    /// brightness, system volume, and the system HUD.
    ///
    /// Called on the main thread, synchronously, inside the tap callback.
    func mediaKeyTap(_ tap: MediaKeyTap, shouldSwallow press: MediaKeyPress) -> Bool

    /// The system disabled the tap and MacQ re-enabled it. Informational; a burst
    /// of these means the main thread is stalling.
    func mediaKeyTap(_ tap: MediaKeyTap, wasDisabledBy reason: MediaKeyTap.DisableReason)
}

extension MediaKeyTapDelegate {
    func mediaKeyTap(_ tap: MediaKeyTap, wasDisabledBy reason: MediaKeyTap.DisableReason) {}
}

// MARK: - The tap

final class MediaKeyTap {
    enum DisableReason: String { case timeout, userInput }

    enum StartError: Error, CustomStringConvertible {
        case notTrusted
        case tapCreationFailed
        case runLoopSourceCreationFailed

        var description: String {
            switch self {
            case .notTrusted:
                return "Accessibility permission is not granted, so a swallowing event tap cannot be created."
            case .tapCreationFailed:
                return "CGEvent.tapCreate returned nil. Accessibility was most likely revoked by a re-signed build."
            case .runLoopSourceCreationFailed:
                return "CFMachPortCreateRunLoopSource returned nil."
            }
        }
    }

    weak var delegate: MediaKeyTapDelegate?

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isRunning = false

    init(delegate: MediaKeyTapDelegate? = nil) {
        self.delegate = delegate
    }

    deinit {
        // Must run before self dies: the C callback holds an unretained pointer
        // to us through refcon, so an outliving tap would use freed memory.
        teardown()
    }

    // MARK: Permission

    /// Non-prompting trust check. Safe to poll; it never shows UI.
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the one-time system prompt. Only call from an explicit user action:
    /// macOS shows the alert at most once per app version, then silently returns
    /// false forever.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        // String literal instead of kAXTrustedCheckOptionPrompt, whose imported
        // symbol is a global var that newer Swift rejects as non-Sendable. The
        // key's string value is stable API.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Lifecycle

    /// Creates and arms the tap. Idempotent. Main thread only.
    func start() throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning else { return }

        // An active tap needs Accessibility. Check first so the failure is
        // reportable instead of an opaque nil out of tapCreate.
        guard Self.isAccessibilityTrusted else { throw StartError.notTrusted }

        // systemDefined only, deliberately.
        //
        // These events exist only while the top row is in media-key mode. With
        // "Use F1, F2, etc. keys as standard function keys" on, plain F1 emits
        // an ordinary keyDown and no systemDefined event, but macOS does not
        // change brightness either, so passing it through is exactly right. The
        // fn/Globe modifier inverts the mode per keystroke, so fn+F1 still
        // arrives here and still works.
        //
        // The cost of this choice: some third-party keyboards report brightness
        // as raw keyDown keycodes 144/145 instead, and MacQ will not see those.
        // Catching them would mean masking kCGEventKeyDown, which routes every
        // keystroke on the system synchronously through this process. That is
        // not a trade a monitor utility should make by default.
        let mask = CGEventMask(1) << CGEventMask(NX.sysDefined)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap, // .listenOnly cannot swallow
                                          eventsOfInterest: mask,
                                          callback: mediaKeyTapCallback,
                                          userInfo: refcon) else {
            throw StartError.tapCreationFailed
        }

        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw StartError.runLoopSourceCreationFailed
        }

        // commonModes, not defaultMode, so the keys keep working while a menu is
        // tracking or a window is being resized.
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        port = tap
        source = src
        isRunning = true
        NSLog("MacQ.MediaKeyTap: started")
        MediaKeyDiagnostics.shared.note(
            String(format: "tap armed: session tap, head insert, mask 0x%llX (systemDefined)", mask))
    }

    /// Disarms and fully disposes the tap. Idempotent, so a Settings toggle can
    /// stop and start repeatedly without leaking a mach port.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRunning else { return }
        teardown()
        NSLog("MacQ.MediaKeyTap: stopped")
    }

    /// Order matters: disable, remove the source, invalidate the source,
    /// invalidate the port, then drop the references. Removing before
    /// invalidating avoids a callback firing into a half-dead port; invalidating
    /// the CFMachPort is what actually releases the underlying mach port. ARC
    /// releases the CF objects when the properties go nil, so no CFRelease.
    private func teardown() {
        if let tap = port { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            CFRunLoopSourceInvalidate(src)
        }
        if let tap = port { CFMachPortInvalidate(tap) }
        source = nil
        port = nil
        isRunning = false
    }

    /// Re-arm after the system disabled us. Called from the C callback.
    fileprivate func handleDisabled(_ reason: DisableReason) {
        if let tap = port { CGEvent.tapEnable(tap: tap, enable: true) }
        NSLog("MacQ.MediaKeyTap: re-enabled after \(reason.rawValue)")
        delegate?.mediaKeyTap(self, wasDisabledBy: reason)
    }

    fileprivate func askDelegate(_ press: MediaKeyPress) -> Bool {
        delegate?.mediaKeyTap(self, shouldSwallow: press) ?? false
    }

    // MARK: Decode

    /// Decodes a systemDefined CGEvent into a media-key press, or nil if it is
    /// not one of the five keys MacQ handles.
    static func decode(_ cgEvent: CGEvent) -> MediaKeyPress? {
        // This check must precede every NSEvent.subtype / .data1 access. Those
        // accessors raise NSInternalInconsistencyException on any event that is
        // not compound (appKitDefined, systemDefined, applicationDefined or
        // periodic). That is an Objective-C exception, uncatchable from Swift,
        // so it aborts the process rather than throwing.
        guard cgEvent.type.rawValue == NX.sysDefined else { return nil }
        guard let event = NSEvent(cgEvent: cgEvent) else { return nil }

        // Subtype 8 is not media-key exclusive. The kernel packs CAPS_LOCK,
        // HELP, POWER, NUM_LOCK, CONTRAST, EJECT, PLAY/NEXT/PREVIOUS and the
        // keyboard-illumination keys through the same path, so the real filter
        // is the keyCode below, not the subtype.
        guard event.subtype.rawValue == NX.subtypeAuxControlButtons else { return nil }

        let data1 = Int64(event.data1)
        let keyCode = Int((data1 & NX.keyCodeMask) >> NX.keyCodeShift)
        let keyFlags = data1 & NX.keyFlagsMask
        let keyState = (keyFlags & NX.keyStateMask) >> NX.keyStateShift

        guard let key = MediaKey(nxKeyType: keyCode) else { return nil }
        return MediaKeyPress(key: key,
                             isDown: keyState == NX.keyStateDown,
                             isRepeat: (keyFlags & NX.keyRepeatMask) == NX.keyRepeatMask,
                             modifiers: event.modifierFlags)
    }

    /// Records the raw shape of a systemDefined event, including every one that
    /// `decode` rejects.
    ///
    /// Deliberately placed before the decode filter: without it, "no brightness
    /// event ever reached the tap" and "a brightness event reached the tap and
    /// was passed through on purpose" produce exactly the same silence.
    /// Costs nothing while diagnostics are off.
    fileprivate static func diagnose(_ cgEvent: CGEvent) {
        guard MediaKeyDiagnostics.shared.isRecording else { return }
        let log = MediaKeyDiagnostics.shared

        // Same precondition as decode: subtype/data1 on a non-compound event
        // raises an uncatchable Objective-C exception.
        guard cgEvent.type.rawValue == NX.sysDefined else { return }
        guard let event = NSEvent(cgEvent: cgEvent) else {
            log.record("systemDefined event that will not convert to NSEvent")
            return
        }

        let subtype = event.subtype.rawValue
        guard subtype == NX.subtypeAuxControlButtons else {
            log.recordFirst(subtype: Int(subtype),
                            "systemDefined subtype \(subtype), not an aux-control key (logged once)")
            return
        }

        let data1 = Int64(event.data1)
        let keyCode = Int((data1 & NX.keyCodeMask) >> NX.keyCodeShift)
        let keyFlags = data1 & NX.keyFlagsMask
        let down = ((keyFlags & NX.keyStateMask) >> NX.keyStateShift) == NX.keyStateDown
        let isRepeat = (keyFlags & NX.keyRepeatMask) == NX.keyRepeatMask

        let name = MediaKey(nxKeyType: keyCode).map { "\($0)" } ?? "NX keyCode \(keyCode), not handled"
        log.record("\(name) \(down ? "down" : "up")\(isRepeat ? " (repeat)" : "")")
    }
}

// MARK: - C callback

/// Top-level, non-capturing C function pointer. Recovers the owning tap from
/// `refcon`, an unretained pointer kept valid by `MediaKeyTap.deinit`.
///
/// The source lives on the main run loop, so this already runs on the main
/// thread and needs no dispatch hop.
private func mediaKeyTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)
    guard let refcon else { return passthrough }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()

    // These two arrive regardless of the event mask, so they are handled before
    // any type filtering. Returning early on "unexpected" types instead would
    // swallow the notification and leave the tap permanently dead with no error
    // reported anywhere.
    switch type {
    case .tapDisabledByTimeout:
        tap.handleDisabled(.timeout)
        return passthrough
    case .tapDisabledByUserInput:
        tap.handleDisabled(.userInput)
        return passthrough
    default:
        break
    }

    guard type.rawValue == NX.sysDefined else { return passthrough }
    MediaKeyTap.diagnose(event)
    guard let press = MediaKeyTap.decode(event) else { return passthrough }
    return tap.askDelegate(press) ? nil : passthrough
}

// MARK: - Repeat-aware stepper

/// Turns the raw press stream into DDC-sized steps.
///
/// Holding a media key produces repeated key-down events with the repeat bit
/// set: one immediate press, a ~500 ms pause, then roughly 30 events per second
/// (`HIDInitialKeyRepeat` / `HIDKeyRepeat`, both user-tunable to more than
/// double that). Acting on every repeat would sweep a 0...50 volume range in
/// half a second, so repeats are rate-gated here. The DDC write throttle in
/// DisplayController protects the I2C bus but does nothing about the value
/// itself ramping too fast.
///
/// Main-thread only, matching DisplayController's own contract.
final class MediaKeyStepper {
    /// macOS moves brightness and volume by 1/16 of the range per press.
    private static let coarseDivisor = 16
    /// Shift+Option quarter-step.
    private static let fineDivisor = 64

    /// Minimum spacing between applied repeat steps. 60 ms is about 16 steps per
    /// second, so a full sweep takes ~1s whatever the user's repeat rate is.
    var minimumRepeatInterval: TimeInterval = 0.06
    /// Idle gap after which a hold is considered finished, which ends the edit
    /// session and flushes the final DDC write. Key-up is not reliably delivered
    /// for every media key on every keyboard, so this cannot depend on it.
    var holdIdleTimeout: TimeInterval = 0.35

    private let current: () -> Int
    private let maximum: () -> Int
    private let apply: (Int) -> Void
    private let begin: () -> Void
    private let end: () -> Void

    private var lastStepAt: TimeInterval = 0
    private var editing = false
    private var idleGeneration = 0

    init(current: @escaping () -> Int,
         maximum: @escaping () -> Int,
         apply: @escaping (Int) -> Void,
         begin: @escaping () -> Void = {},
         end: @escaping () -> Void = {}) {
        self.current = current
        self.maximum = maximum
        self.apply = apply
        self.begin = begin
        self.end = end
    }

    private func step(range: Int, fine: Bool) -> Int {
        let divisor = fine ? Self.fineDivisor : Self.coarseDivisor
        return max(1, Int((Double(range) / Double(divisor)).rounded()))
    }

    /// Applies one step for `press`. A rate-gated repeat is still consumed, it
    /// just does not move the value.
    func handle(_ press: MediaKeyPress) {
        guard press.isDown else { finishHold(); return }

        let now = CFAbsoluteTimeGetCurrent()
        if press.isRepeat, now - lastStepAt < minimumRepeatInterval {
            armIdleTimer()
            return
        }
        lastStepAt = now

        if !editing {
            editing = true
            begin()
        }
        armIdleTimer()

        let range = max(1, maximum())
        let delta = press.key.sign * step(range: range, fine: press.isFineStep)
        guard delta != 0 else { return }
        apply(max(0, min(range, current() + delta)))
    }

    /// Bumps a generation counter and schedules a main-queue check; any newer
    /// keystroke invalidates the pending one. Avoids retaining a Timer.
    private func armIdleTimer() {
        idleGeneration &+= 1
        let generation = idleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + holdIdleTimeout) { [weak self] in
            guard let self, self.idleGeneration == generation else { return }
            self.finishHold()
        }
    }

    private func finishHold() {
        guard editing else { return }
        editing = false
        end()
    }
}
