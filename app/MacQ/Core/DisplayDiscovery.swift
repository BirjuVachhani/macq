//
//  DisplayDiscovery.swift
//  MacQ
//
//  Enumerates external displays and binds each to its DDC transport.
//

import Foundation
import CoreGraphics
import AppKit

enum DisplayDiscovery {
    /// Returns all online external displays (built-in panel excluded).
    static func externalDisplays() -> [ExternalDisplay] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        return ids.prefix(Int(count)).compactMap { id -> ExternalDisplay? in
            guard CGDisplayIsBuiltin(id) == 0 else { return nil }
            // Skip mirrored secondaries: control the primary of a mirror set.
            let mirror = CGDisplayMirrorsDisplay(id)
            if mirror != 0 && mirror != id { return nil }

            return ExternalDisplay(
                id: id,
                name: localizedName(for: id) ?? "External Display",
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id)
            )
        }
    }

    /// Resolves the DDC transport for a display, or nil if it has no reachable
    /// external DDC/CI channel.
    static func ddc(for display: ExternalDisplay) -> DDC? {
        guard let link = DDCLink.make(displayID: display.id) else { return nil }
        return DDC(link: link)
    }

    private static func localizedName(for id: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber,
               number.uint32Value == id {
                return screen.localizedName
            }
        }
        return nil
    }
}
