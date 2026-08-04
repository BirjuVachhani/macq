//
//  DDC.swift
//  MacQ
//
//  DDC/CI framing on top of the raw I2C transport (DDCLink). Packet layouts,
//  checksums, and retry policy were reverse-engineered from BenQ Display Pilot 2
//  and validated live against a BenQ MA320UP. See /docs/benq-ddc-reference.md.
//
//  All methods here block (they usleep between write and read) and must be
//  called off the main thread.
//

import Foundation

/// Standard MCCS VCP codes used by MacQ.
enum VCP {
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12
    static let inputSource: UInt8 = 0x60
    static let audioVolume: UInt8 = 0x62
    static let audioMute: UInt8 = 0x8D
    static let mccsVersion: UInt8 = 0xDF
    /// BenQ auto input detection (F6(00 01)): 0x00 = off, 0x01 = on. Disabling it
    /// before a manual switch stops the panel from racing/overriding the choice.
    static let autoInputSwitch: UInt8 = 0xF6
}

/// A DDC/CI "Get VCP Feature" reply.
struct VCPReading {
    let current: UInt16
    let max: UInt16
}

/// DDC/CI conversation with a single external display.
final class DDC {
    private let link: DDCLink

    /// Frames returned empty on this panel fairly often; retry before giving up.
    private let maxAttempts: Int
    /// Delay between write and read, and between attempts (microseconds).
    private let settleMicros: useconds_t

    init(link: DDCLink, maxAttempts: Int = 12, settleMicros: useconds_t = 40_000) {
        self.link = link
        self.maxAttempts = maxAttempts
        self.settleMicros = settleMicros
    }

    // MARK: Get VCP (read current + max)

    /// Reads a VCP feature, retrying through transient empty/garbled replies.
    /// Returns nil only if every attempt failed.
    func getVCP(_ code: UInt8) -> VCPReading? {
        // Request checksum base is 0x6E only (matches the validated m1ddc path;
        // the 0x51 sub-address is not folded into the read-request checksum).
        var request: [UInt8] = [0x82, 0x01, code, 0]
        request[3] = 0x6E ^ request[0] ^ request[1] ^ request[2]

        for _ in 0..<maxAttempts {
            if link.write(request) != 0 {
                usleep(settleMicros)
                continue
            }
            usleep(settleMicros)

            var reply = [UInt8](repeating: 0, count: 12)
            let rc = reply.withUnsafeMutableBufferPointer { buf in
                link.readI2C(buf.baseAddress!, length: UInt32(buf.count))
            }
            if rc == 0, let reading = Self.parseGetReply(reply, code: code) {
                return reading
            }
            usleep(settleMicros)
        }
        return nil
    }

    /// Validates a Get VCP Feature reply and extracts current/max (big-endian).
    /// Frame: [0]=0x6E src, [2]=0x02 opcode, [3]=result, [4]=code, [6..7]=max, [8..9]=current.
    private static func parseGetReply(_ reply: [UInt8], code: UInt8) -> VCPReading? {
        guard reply.count >= 10 else { return nil }
        guard reply[2] == 0x02, reply[4] == code else { return nil } // wrong/empty frame
        let maxV = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let curV = UInt16(reply[8]) << 8 | UInt16(reply[9])
        if maxV == 0 && curV == 0 { return nil } // treat all-zero as an empty read
        return VCPReading(current: curV, max: maxV)
    }

    // MARK: Set VCP (write a value)

    /// Writes a VCP feature. Returns true if the I2C write reported success.
    /// (DDC/CI Set has no reply; callers should re-read to confirm the effect.)
    @discardableResult
    func setVCP(_ code: UInt8, value: UInt16) -> Bool {
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        var packet: [UInt8] = [0x84, 0x03, code, hi, lo, 0]
        packet[5] = 0x6E ^ 0x51 ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4]
        return link.write(packet) == 0
    }

    // MARK: Capabilities string

    /// Reads the DDC/CI capabilities string by looping 0xF3 requests until the
    /// 0xE3 reply fragments run out. Returns nil if nothing readable came back.
    func readCapabilities() -> String? {
        var out = [UInt8]()
        var offset: UInt16 = 0
        var emptyStreak = 0

        for _ in 0..<512 {
            let ohi = UInt8((offset >> 8) & 0xFF)
            let olo = UInt8(offset & 0xFF)
            var request: [UInt8] = [0x83, 0xF3, ohi, olo, 0]
            request[4] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2] ^ request[3]

            if link.write(request) != 0 { usleep(settleMicros); continue }
            usleep(settleMicros)

            var reply = [UInt8](repeating: 0, count: 64)
            let rc = reply.withUnsafeMutableBufferPointer { buf in
                link.readI2C(buf.baseAddress!, length: UInt32(buf.count))
            }
            if rc != 0 { usleep(settleMicros); continue }
            guard reply[2] == 0xE3 else {
                emptyStreak += 1
                if emptyStreak > 12 { break }
                continue
            }
            let payload = Int(reply[1] & 0x7F) - 3 // minus opcode(1) + echoed offset(2)
            if payload <= 0 { break }              // no more fragments: done
            out.append(contentsOf: reply[5..<min(5 + payload, reply.count)])
            offset += UInt16(payload)
            emptyStreak = 0
        }

        guard !out.isEmpty else { return nil }
        return String(bytes: out, encoding: .ascii)
    }
}

private extension DDCLink {
    /// Convenience: write a byte-array frame, returning the IOReturn code.
    func write(_ bytes: [UInt8]) -> Int32 {
        return bytes.withUnsafeBufferPointer { buf in
            self.writeI2C(buf.baseAddress!, length: UInt32(buf.count))
        }
    }
}
