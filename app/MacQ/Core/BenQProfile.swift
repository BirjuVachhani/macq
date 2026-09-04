//
//  BenQProfile.swift
//  MacQ
//
//  Input-source model for the BenQ MA-series (MA320UP). Maps each real input to
//  its VCP 0x60 write value, the values it reads back as, and a label.
//  See /docs/benq-ddc-reference.md.
//

import Foundation

enum BenQProfile {
    struct KnownInput {
        let writeValue: UInt8
        let fallback: [UInt8]
        let readValues: Set<UInt8>
        let label: String
    }

    /// The real, switchable inputs on the MA320UP, in display order.
    ///
    /// The monitor's capabilities advertise `60(0F 11 12 15)`, but both `0x0F`
    /// (a DisplayPort slot this model does not expose) and `0x15` (Thunderbolt3,
    /// disabled in firmware) are phantoms, so neither is shown. The real USB-C
    /// input is selected by `0x13` (the OEM's own code, absent from the caps
    /// string), with `0x15` kept only as a fallback write value; it reads back as
    /// `0x13`. HDMI 1/2 are the standard MCCS `0x11`/`0x12`.
    ///
    /// This is intentionally a fixed list (not derived from capabilities) so the
    /// phantoms never appear and USB-C uses the value that actually switches.
    static let knownInputs: [KnownInput] = [
        KnownInput(writeValue: 0x13, fallback: [0x15], readValues: [0x13], label: "USB-C"),
        KnownInput(writeValue: 0x11, fallback: [], readValues: [0x11], label: "HDMI 1"),
        KnownInput(writeValue: 0x12, fallback: [], readValues: [0x12], label: "HDMI 2"),
    ]

    /// Builds the selectable input list. `caps` is accepted for signature
    /// compatibility but the MA-series input set is fixed (see above).
    static func inputSources(from caps: MonitorCapabilities?) -> [InputSource] {
        knownInputs.map {
            InputSource(writeValue: $0.writeValue,
                        readValues: $0.readValues,
                        defaultLabel: $0.label,
                        fallbackWriteValues: $0.fallback)
        }
    }

    // MARK: Power mode (VCP 0xD6)

    /// The panel's "on" value. This is the only 0xD6 reading ever observed live:
    /// Display Pilot 2 read 0x60 while the panel was on and driving the Mac
    /// (research/logs/ddc-vcp-evidence.txt). Writing it back restores the exact
    /// observed on-state.
    static let powerOn: UInt16 = 0x60

    /// PROVISIONAL until the 0xD6 bench experiment runs against the panel (it
    /// was not connected at implementation time). The advertised set is
    /// `D6(50 60 90 A0)` with 0x60 confirmed as "on"; the remaining candidates
    /// are 0x50, 0x90 and 0xA0, and their DPMS mapping is unidentified. 0x90 is
    /// the working hypothesis for "standby that keeps DDC alive": the values
    /// pair up as 0x40-group (0x50, 0x60) and 0x80-group (0x90, 0xA0), with the
    /// low nibble matching the OSD Deep Sleep flag pair (OffFlag 0x10 /
    /// OnFlag 0x20 in Display Pilot 2's model config), which reads as
    /// on/standby x deep-sleep-off/on. If the panel ignores the write, the off
    /// action reports failure and reverts (see DisplayController.turnMonitorOff).
    static let powerOff: UInt16 = 0x90
}
