import Foundation

/// Minimal MPEG-2 Transport Stream muxer for one H.264 video stream (what DLNA TVs play as a live "video/mp2t").
struct TSMuxer {
    static let pmtPid: UInt16 = 0x1000
    static let videoPid: UInt16 = 0x0100
    private var cc: [UInt16: UInt8] = [:]

    private mutating func counter(_ pid: UInt16) -> UInt8 {
        let c = cc[pid, default: 0]
        cc[pid] = (c + 1) & 0x0F
        return c
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 24
        for _ in 0..<8 { c = (c & 0x80000000) != 0 ? (c << 1) ^ 0x04C11DB7 : c << 1 }
        return c
    }
    static func crc32(_ d: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = (c << 8) ^ crcTable[Int(((c >> 24) ^ UInt32(b)) & 0xFF)] }
        return c
    }

    private mutating func psiPacket(_ pid: UInt16, _ section: [UInt8]) -> [UInt8] {
        let crc = TSMuxer.crc32(section)
        let body = section + [UInt8(crc >> 24), UInt8((crc >> 16) & 255), UInt8((crc >> 8) & 255), UInt8(crc & 255)]
        var p: [UInt8] = [0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 255), 0x10 | counter(pid), 0x00]
        p += body
        p += [UInt8](repeating: 0xFF, count: 188 - p.count)
        return p
    }

    /// PAT + PMT, sent before every keyframe so a TV can join at any time.
    mutating func tables() -> [UInt8] {
        let pmt = TSMuxer.pmtPid, vid = TSMuxer.videoPid
        let pat: [UInt8] = [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
                            0x00, 0x01, 0xE0 | UInt8(pmt >> 8), UInt8(pmt & 255)]
        let pmtSec: [UInt8] = [0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00,
                               0xE0 | UInt8(vid >> 8), UInt8(vid & 255), 0xF0, 0x00,
                               0x1B, 0xE0 | UInt8(vid >> 8), UInt8(vid & 255), 0xF0, 0x00]
        return psiPacket(0, pat) + psiPacket(pmt, pmtSec)
    }

    private static func ts5(_ marker: UInt8, _ v: UInt64) -> [UInt8] {
        [marker | UInt8((v >> 29) & 0x0E) | 1, UInt8((v >> 22) & 0xFF), UInt8((v >> 14) & 0xFE) | 1,
         UInt8((v >> 7) & 0xFF), UInt8((v << 1) & 0xFE) | 1]
    }

    /// Packs one H.264 access unit (Annex-B) into TS packets. pts is in 90 kHz units.
    mutating func video(_ au: [UInt8], pts: UInt64, key: Bool) -> [UInt8] {
        let pes: [UInt8] = [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05] + TSMuxer.ts5(0x20, pts) + au
        var out: [UInt8] = []
        out.reserveCapacity((pes.count / 184 + 2) * 188)
        let pid = TSMuxer.videoPid
        var i = 0
        var first = true
        while i < pes.count {
            var hasAF = false
            var af: [UInt8] = []          // adaptation field content, after its length byte
            if first {
                // PCR a little behind the PTS; random-access flag on keyframes.
                let pcr = pts > 9000 ? pts - 9000 : 0
                hasAF = true
                af = [key ? 0x50 : 0x10, UInt8((pcr >> 25) & 255), UInt8((pcr >> 17) & 255), UInt8((pcr >> 9) & 255),
                      UInt8((pcr >> 1) & 255), UInt8((pcr & 1) << 7) | 0x7E, 0x00]
            }
            let left = pes.count - i
            let room = 184 - (hasAF ? 1 + af.count : 0)
            if left < room {
                let stuff = room - left
                if hasAF {
                    af += [UInt8](repeating: 0xFF, count: stuff)
                } else {
                    hasAF = true
                    af = stuff == 1 ? [] : [0x00] + [UInt8](repeating: 0xFF, count: stuff - 2)
                }
            }
            let n = min(left, 184 - (hasAF ? 1 + af.count : 0))
            out += [0x47, (first ? 0x40 : 0x00) | UInt8(pid >> 8), UInt8(pid & 255), (hasAF ? 0x30 : 0x10) | counter(pid)]
            if hasAF { out += [UInt8(af.count)] + af }
            out += pes[i..<(i + n)]
            i += n
            first = false
        }
        return out
    }
}
