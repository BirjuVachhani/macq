//
//  Capabilities.swift
//  MacQ
//
//  Minimal parser for the DDC/CI capabilities string, e.g.
//  (prot(monitor)type(LCD)model(MA320UP)...vcp(... 60(0F 11 12 15) 62 ...)...)
//  We only need the model, the MCCS version, and the discrete values for the
//  codes we care about (input source 0x60 in particular).
//

import Foundation

struct MonitorCapabilities {
    let model: String?
    let mccsVersion: String?
    /// Every VCP code the monitor advertises.
    let supportedCodes: Set<UInt8>
    /// Discrete values advertised for a code, when it lists them, e.g. 0x60 -> [0x0F, 0x11, 0x12, 0x15].
    let discreteValues: [UInt8: [UInt8]]

    func supports(_ code: UInt8) -> Bool { supportedCodes.contains(code) }
    func values(for code: UInt8) -> [UInt8] { discreteValues[code] ?? [] }
}

enum CapabilitiesParser {
    /// Parses a raw capabilities string. Tolerant of spacing/casing.
    static func parse(_ raw: String) -> MonitorCapabilities {
        let model = extractGroup("model", from: raw)
        let mccs = extractGroup("mccs_ver", from: raw)

        var codes = Set<UInt8>()
        var discrete = [UInt8: [UInt8]]()

        if let vcp = extractGroup("vcp", from: raw) {
            var i = vcp.startIndex
            let end = vcp.endIndex
            while i < end {
                // Read a 2-hex-digit code token.
                while i < end, vcp[i] == " " { i = vcp.index(after: i) }
                guard i < end else { break }
                var token = ""
                while i < end, vcp[i].isHexDigit, token.count < 2 {
                    token.append(vcp[i]); i = vcp.index(after: i)
                }
                guard let code = UInt8(token, radix: 16) else {
                    // Not a code token; skip one char to make progress.
                    if i < end { i = vcp.index(after: i) }
                    continue
                }
                codes.insert(code)

                // Optional parenthesized value list immediately after the code.
                if i < end, vcp[i] == "(" {
                    i = vcp.index(after: i)
                    var inner = ""
                    var depth = 1
                    while i < end, depth > 0 {
                        let c = vcp[i]
                        if c == "(" { depth += 1 }
                        else if c == ")" { depth -= 1; if depth == 0 { break } }
                        inner.append(c)
                        i = vcp.index(after: i)
                    }
                    if i < end, vcp[i] == ")" { i = vcp.index(after: i) }
                    let values = inner.split(whereSeparator: { $0 == " " })
                        .compactMap { UInt8($0, radix: 16) }
                    if !values.isEmpty { discrete[code] = values }
                }
            }
        }

        return MonitorCapabilities(model: model, mccsVersion: mccs,
                                   supportedCodes: codes, discreteValues: discrete)
    }

    /// Extracts the contents of a `name(...)` group, honoring nested parentheses.
    private static func extractGroup(_ name: String, from raw: String) -> String? {
        guard let r = raw.range(of: name + "(") else { return nil }
        var i = r.upperBound
        var depth = 1
        var out = ""
        while i < raw.endIndex, depth > 0 {
            let c = raw[i]
            if c == "(" { depth += 1 }
            else if c == ")" { depth -= 1; if depth == 0 { break } }
            out.append(c)
            i = raw.index(after: i)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
