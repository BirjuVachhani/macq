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
}
