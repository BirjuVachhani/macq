//
//  Preferences.swift
//  MacQ
//
//  UserDefaults-backed settings for the media-key feature. Observable so the
//  Settings UI binds to it directly, and so toggling a switch starts or stops
//  the event tap without any extra plumbing.
//

import Foundation
import Combine

/// How volume keys decide between the monitor and the Mac's own output.
///
/// Both cases require the monitor to be the current sound output device. That
/// is not a policy choice: writing the monitor's audio controls while macOS is
/// playing somewhere else is inaudible at best, and on some panels wakes their
/// own speakers and their on-screen display. The cases differ only in whether
/// the focused window is an ADDITIONAL requirement.
enum VolumeKeyRule: String, CaseIterable, Identifiable {
    /// Drive the monitor whenever macOS is playing through it, whichever screen
    /// the user happens to be looking at. This is the default.
    case followAudioDevice

    /// Drive the monitor only when it is playing the sound AND holds the
    /// focused window. For a desk where the monitor is the speaker but a lot of
    /// work happens on the built-in screen.
    case followActiveDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followAudioDevice: return "Whenever sound is playing through the monitor"
        case .followActiveDisplay: return "Only while the monitor is also the active display"
        }
    }

    var detail: String {
        switch self {
        case .followAudioDevice:
            return "Volume keys change the monitor whenever it is the selected sound output. Otherwise they control the Mac as usual."
        case .followActiveDisplay:
            return "Volume keys change the monitor only when it is the selected sound output and a window on it is focused. Otherwise they control the Mac as usual."
        }
    }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let mediaKeysEnabled = "mediaKeysEnabled"
        static let brightnessKeysEnabled = "brightnessKeysEnabled"
        static let volumeKeysEnabled = "volumeKeysEnabled"
        static let volumeKeyRule = "volumeKeyRule"
        static let showOSD = "showOSD"
    }

    private let defaults: UserDefaults

    /// Master switch. Off by default: the feature needs an Accessibility grant,
    /// so we never install an event tap until the user asks for one.
    @Published var mediaKeysEnabled: Bool {
        didSet { defaults.set(mediaKeysEnabled, forKey: Key.mediaKeysEnabled) }
    }

    @Published var brightnessKeysEnabled: Bool {
        didSet { defaults.set(brightnessKeysEnabled, forKey: Key.brightnessKeysEnabled) }
    }

    @Published var volumeKeysEnabled: Bool {
        didSet { defaults.set(volumeKeysEnabled, forKey: Key.volumeKeysEnabled) }
    }

    @Published var volumeKeyRule: VolumeKeyRule {
        didSet { defaults.set(volumeKeyRule.rawValue, forKey: Key.volumeKeyRule) }
    }

    /// Show MacQ's own level indicator on the monitor when a key changes it.
    /// Swallowing a key also swallows the system HUD, so with this off a
    /// brightness or volume change has no on-screen feedback at all.
    @Published var showOSD: Bool {
        didSet { defaults.set(showOSD, forKey: Key.showOSD) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The sub-toggles default to on so that flipping the master switch is
        // enough to get the expected behaviour; register() only fills in keys
        // the user has never touched.
        defaults.register(defaults: [
            // Registered explicitly so the master switch's default is stated
            // rather than being an implicit false from a missing key.
            Key.mediaKeysEnabled: false,
            Key.brightnessKeysEnabled: true,
            Key.volumeKeysEnabled: true,
            Key.showOSD: true,
        ])
        mediaKeysEnabled = defaults.bool(forKey: Key.mediaKeysEnabled)
        brightnessKeysEnabled = defaults.bool(forKey: Key.brightnessKeysEnabled)
        volumeKeysEnabled = defaults.bool(forKey: Key.volumeKeysEnabled)
        showOSD = defaults.bool(forKey: Key.showOSD)
        volumeKeyRule = defaults.string(forKey: Key.volumeKeyRule)
            .flatMap(VolumeKeyRule.init(rawValue:)) ?? .followAudioDevice
    }
}
