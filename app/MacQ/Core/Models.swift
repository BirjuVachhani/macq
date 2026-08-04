//
//  Models.swift
//  MacQ
//

import Foundation
import CoreGraphics

/// An external (non built-in) display MacQ can talk to.
struct ExternalDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    /// Stable key for persisting per-monitor settings (aliases) across reconnects.
    var persistentKey: String { "\(vendor):\(model):\(serial)" }

    static func == (lhs: ExternalDisplay, rhs: ExternalDisplay) -> Bool {
        lhs.id == rhs.id && lhs.persistentKey == rhs.persistentKey
    }
}

/// One selectable video input on the monitor (VCP 0x60 discrete value).
///
/// `writeValue` is what we send with `setVCP 0x60` to select the input.
/// `readValues` are the values `getVCP 0x60` may report while this input is the
/// active one. They can differ, and on BenQ the read value is not always in the
/// monitor's own advertised settable list. See /docs/benq-ddc-reference.md.
struct InputSource: Identifiable, Equatable {
    let writeValue: UInt8
    let readValues: Set<UInt8>
    let defaultLabel: String
    /// Additional 0x60 values to try if `writeValue` does not take effect (BenQ
    /// codes vary; USB-C uses 0x13 with 0x15 as a fallback).
    var fallbackWriteValues: [UInt8] = []

    var id: UInt8 { writeValue }

    /// Every 0x60 value we may write to select this input, primary first.
    var writeCandidates: [UInt8] { [writeValue] + fallbackWriteValues }

    /// True if a value read from VCP 0x60 indicates this input is active.
    func matches(readValue: UInt8) -> Bool {
        readValues.contains(readValue)
    }
}

/// Whether the controls should be enabled, and why not if disabled.
enum ControlAvailability: Equatable {
    case available
    case noExternalDisplay
    case ddcUnavailable   // display present but not answering DDC/CI

    var isAvailable: Bool { self == .available }

    var reason: String? {
        switch self {
        case .available: return nil
        case .noExternalDisplay: return "No external monitor connected"
        case .ddcUnavailable: return "Monitor not responding to DDC/CI. Enable it in the monitor OSD (System > DDC/CI)."
        }
    }
}
