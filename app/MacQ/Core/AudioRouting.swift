//
//  AudioRouting.swift
//  MacQ
//
//  Answers one question: is the external monitor the device macOS is currently
//  playing sound through? That decides whether a volume key should drive the
//  monitor over DDC or pass through to the Mac's own output.
//
//  The join is exact, not a heuristic. A DisplayPort or HDMI audio device's
//  kAudioDevicePropertyDeviceUID is byte-for-byte the display's IORegistry
//  "EDID UUID" string. Verified on a BenQ MA320UP, where both read
//  "09D13581-0000-0000-2E23-0104B5462778".
//
//  What NOT to match on, all tried and rejected:
//    - Transport type. Every DisplayPort monitor reports 'dprt', so it
//      identifies the connection, not the display.
//    - Device name. Cosmetic, localised, and duplicated across identical units.
//    - CGDisplaySerialNumber. macOS synthesises 0x01010101 when the EDID serial
//      is zero, which is exactly what the MA320UP reports.
//

import CoreAudio
import Foundation
import os

// MARK: - Thin CoreAudio helpers

enum CoreAudioHAL {

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The device macOS is currently playing through. Measured at roughly 13 us,
    /// which is cheap enough for the media-key path.
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// A CFString-valued property. These come back +1, so the value must be
    /// consumed with takeRetainedValue or it leaks.
    static func string(_ selector: AudioObjectPropertySelector,
                       from objectID: AudioObjectID) -> String? {
        var address = self.address(selector)
        // AudioObjectIsPropertySettable returns kAudioHardwareUnknownPropertyError
        // and leaves its out-param untouched for absent properties, so presence
        // has to be checked with HasProperty first.
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        string(kAudioDevicePropertyDeviceUID, from: deviceID)
    }

    static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        string(kAudioObjectPropertyName, from: deviceID)
    }
}

// MARK: - Property listeners

/// Wraps AudioObjectAddPropertyListener with a C function pointer.
///
/// The block-based variants (AudioObjectAddPropertyListenerBlock /
/// RemovePropertyListenerBlock) are unusable from Swift: Swift boxes a fresh
/// Objective-C block every time one crosses the C boundary, so Remove compares
/// against a different block object, matches nothing, returns noErr, and the
/// listener keeps firing forever. Verified by counting fires across a
/// "successful" removal: they went 2, then 4.
private final class AudioPropertyListener {

    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let handler: () -> Void
    private var installed = false

    init(objectID: AudioObjectID,
         selector: AudioObjectPropertySelector,
         handler: @escaping () -> Void) {
        self.objectID = objectID
        self.address = CoreAudioHAL.address(selector)
        self.handler = handler
    }

    deinit { remove() }

    func install() {
        guard !installed else { return }
        let client = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(objectID, &address,
                                                    audioPropertyListenerProc, client)
        installed = (status == noErr)
    }

    func remove() {
        guard installed else { return }
        let client = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(objectID, &address,
                                          audioPropertyListenerProc, client)
        installed = false
    }

    fileprivate func fire() { handler() }
}

/// Runs on a CoreAudio worker thread, never on main.
private func audioPropertyListenerProc(objectID: AudioObjectID,
                                       count: UInt32,
                                       addresses: UnsafePointer<AudioObjectPropertyAddress>,
                                       client: UnsafeMutableRawPointer?) -> OSStatus {
    guard let client else { return noErr }
    Unmanaged<AudioPropertyListener>.fromOpaque(client).takeUnretainedValue().fire()
    return noErr
}

// MARK: - Binding

/// Tracks whether the bound monitor is the current default output device.
///
/// `isMonitorTheDefaultOutput()` is safe from the event-tap callback: it costs
/// one small CoreAudio read plus a lock, and only fetches the device UID string
/// when the default device has actually changed.
final class MonitorAudioBinding {

    /// Posted on the main thread, debounced, after the default output device
    /// changes. macOS 26 is known to emit floods of these notifications, so
    /// anything expensive downstream must hang off the debounced post rather
    /// than off the raw HAL callback.
    static let defaultOutputDeviceDidChange =
        Notification.Name("MacQ.MonitorAudioBinding.defaultOutputDeviceDidChange")

    static let shared = MonitorAudioBinding()

    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var monitorUID: String?          // the display's EDID UUID, lowercased
    private var cachedDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var cachedDeviceUID: String?     // lowercased
    /// Bumped by every invalidation. A UID read that started before an
    /// invalidation must not write its result back into the cache afterwards.
    private var cacheGeneration: UInt64 = 0
    /// Main thread only. Coalesces a burst of HAL callbacks into one post.
    private var notifyGeneration = 0

    private var defaultDeviceListener: AudioPropertyListener?
    private var deviceListListener: AudioPropertyListener?

    private init() {
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Point the binding at a display. Pass nil to unbind, for instance when the
    /// monitor is disconnected.
    func bind(edidUUID: String?) {
        os_unfair_lock_lock(lock)
        monitorUID = edidUUID?.lowercased()
        // Drop the cache so the next query re-reads rather than trusting a
        // device UID resolved against the previous monitor.
        cachedDeviceID = kAudioObjectUnknown
        cachedDeviceUID = nil
        os_unfair_lock_unlock(lock)

        installListeners()
    }

    /// Convenience for the discovery path.
    func bind(to display: ExternalDisplay?) {
        guard let display else { bind(edidUUID: nil); return }
        bind(edidUUID: DisplayIdentity.edidUUID(displayID: display.id))
    }

    /// True when macOS is playing through the bound monitor right now.
    ///
    /// Safe from the tap callback. Returns false whenever the answer is unknown,
    /// so an unreadable EDID UUID degrades to passing keys through rather than
    /// to driving DDC blindly.
    func isMonitorTheDefaultOutput() -> Bool {
        os_unfair_lock_lock(lock)
        let target = monitorUID
        let generation = cacheGeneration
        os_unfair_lock_unlock(lock)
        guard let target else { return false }

        guard let deviceID = CoreAudioHAL.defaultOutputDeviceID() else { return false }

        os_unfair_lock_lock(lock)
        if cachedDeviceID == deviceID, let cached = cachedDeviceUID {
            os_unfair_lock_unlock(lock)
            return cached == target
        }
        os_unfair_lock_unlock(lock)

        // The device changed, so resolve its UID once and cache it. AudioDeviceIDs
        // are recycled on replug, which is why the device-list listener also
        // invalidates this.
        let uid = CoreAudioHAL.deviceUID(deviceID)?.lowercased()
        os_unfair_lock_lock(lock)
        // Only publish the pair if no invalidation landed while the UID was
        // being read. Writing unconditionally would resurrect a pair the
        // listener had already thrown away, and the next keypress would be
        // answered from it.
        if cacheGeneration == generation {
            cachedDeviceID = deviceID
            cachedDeviceUID = uid
        }
        os_unfair_lock_unlock(lock)

        return uid == target
    }

    /// Name of the current output device, for the Settings explanation row.
    func currentOutputDeviceName() -> String? {
        guard let deviceID = CoreAudioHAL.defaultOutputDeviceID() else { return nil }
        return CoreAudioHAL.deviceName(deviceID)
    }

    private func installListeners() {
        guard defaultDeviceListener == nil else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)

        defaultDeviceListener = AudioPropertyListener(
            objectID: system,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { [weak self] in self?.invalidate() }

        // Device IDs are recycled when a display is unplugged and replugged, so
        // a stale (id, uid) pair could otherwise survive as a false match.
        deviceListListener = AudioPropertyListener(
            objectID: system,
            selector: kAudioHardwarePropertyDevices
        ) { [weak self] in self?.invalidate() }

        defaultDeviceListener?.install()
        deviceListListener?.install()
    }

    /// Called on a CoreAudio worker thread.
    private func invalidate() {
        os_unfair_lock_lock(lock)
        cacheGeneration &+= 1
        cachedDeviceID = kAudioObjectUnknown
        cachedDeviceUID = nil
        os_unfair_lock_unlock(lock)
        scheduleChangeNotification()
    }

    /// Hops to main and collapses a burst into a single post. The 0.3 s window
    /// is long enough to swallow the notification storms macOS 26 produces and
    /// short enough that a real device switch is reflected before the user's
    /// next keypress.
    private func scheduleChangeNotification() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyGeneration &+= 1
            let generation = self.notifyGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.notifyGeneration == generation else { return }
                NotificationCenter.default.post(name: Self.defaultOutputDeviceDidChange,
                                                object: self)
            }
        }
    }
}

// MARK: - The routing decision

enum VolumeRouting {
    /// MacQ writes the monitor's volume over DDC and swallows the key.
    case monitor
    /// The key passes through and macOS handles it as usual.
    case system

    /// - Parameters:
    ///   - monitorIsActive: the monitor holds the focused window.
    ///   - rule: the user's setting.
    ///   - binding: the audio binding to consult under the audio-device rule.
    static func decide(monitorIsActive: Bool,
                       rule: VolumeKeyRule,
                       binding: MonitorAudioBinding) -> VolumeRouting {
        // Non-negotiable precondition for BOTH rules. A volume key that reaches
        // a panel macOS is not playing through is inaudible at best, and at
        // worst wakes that panel's own speakers and its on-screen display while
        // the sound is still coming from the Mac, which reads as the output
        // device having moved.
        guard binding.isMonitorTheDefaultOutput() else { return .system }

        switch rule {
        case .followAudioDevice:
            // Deliberately independent of which display is focused: sound is
            // already coming out of the monitor, so the key belongs to it no
            // matter which screen the user is looking at.
            return .monitor
        case .followActiveDisplay:
            // The stricter rule, for a desk where the monitor is the output but
            // the user often works on the built-in screen and wants the keys
            // back while they do.
            return monitorIsActive ? .monitor : .system
        }
    }
}
