import Foundation
import CryptoKit

// Building blocks for Apple TV (Companion protocol) pairing: big numbers for SRP-6a, TLV8 and OPACK.

// MARK: - Big unsigned integers (little-endian 32-bit limbs)

struct BigUInt: Equatable {
    var w: [UInt32]

    init(_ words: [UInt32]) { w = words; trim() }
    init(_ v: UInt64) { w = [UInt32(v & 0xFFFFFFFF), UInt32(v >> 32)]; trim() }
    init(bytes: [UInt8]) {
        var out = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (i, b) in bytes.reversed().enumerated() { out[i / 4] |= UInt32(b) << (8 * UInt32(i % 4)) }
        w = out; trim()
    }

    mutating func trim() { while w.count > 1 && w.last == 0 { w.removeLast() }; if w.isEmpty { w = [0] } }

    var isZero: Bool { w.count == 1 && w[0] == 0 }
    var bitCount: Int { (w.count - 1) * 32 + (32 - w.last!.leadingZeroBitCount) }
    func bit(_ i: Int) -> Bool { i / 32 < w.count && (w[i / 32] >> UInt32(i % 32)) & 1 == 1 }

    /// Big-endian bytes; `pad` left-pads with zeros to that length.
    func bytes(pad: Int = 0) -> [UInt8] {
        var out: [UInt8] = []
        for v in w.reversed() { out += [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
        let minimal = Array(out.drop(while: { $0 == 0 }))
        let m = minimal.isEmpty ? [0] : minimal
        return m.count >= pad ? m : [UInt8](repeating: 0, count: pad - m.count) + m
    }

    static func cmp(_ a: BigUInt, _ b: BigUInt) -> Int {
        if a.w.count != b.w.count { return a.w.count < b.w.count ? -1 : 1 }
        for i in stride(from: a.w.count - 1, through: 0, by: -1) where a.w[i] != b.w[i] { return a.w[i] < b.w[i] ? -1 : 1 }
        return 0
    }

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var r = [UInt32](repeating: 0, count: max(a.w.count, b.w.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<r.count {
            let s = UInt64(i < a.w.count ? a.w[i] : 0) + UInt64(i < b.w.count ? b.w[i] : 0) + carry
            r[i] = UInt32(s & 0xFFFFFFFF); carry = s >> 32
        }
        return BigUInt(r)
    }

    /// a - b, requires a >= b
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        var r = a.w
        var borrow: Int64 = 0
        for i in 0..<r.count {
            var s = Int64(r[i]) - Int64(i < b.w.count ? b.w[i] : 0) - borrow
            if s < 0 { s += 1 << 32; borrow = 1 } else { borrow = 0 }
            r[i] = UInt32(s)
        }
        return BigUInt(r)
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        var r = [UInt32](repeating: 0, count: a.w.count + b.w.count)
        for i in 0..<a.w.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.w[i])
            if ai == 0 { continue }
            for j in 0..<b.w.count {
                let t = ai * UInt64(b.w[j]) + UInt64(r[i + j]) + carry
                r[i + j] = UInt32(t & 0xFFFFFFFF); carry = t >> 32
            }
            var k = i + b.w.count
            while carry > 0 { let t = UInt64(r[k]) + carry; r[k] = UInt32(t & 0xFFFFFFFF); carry = t >> 32; k += 1 }
        }
        return BigUInt(r)
    }
}

/// Modular arithmetic for an odd modulus, using Montgomery multiplication.
struct Montgomery {
    let n: [UInt32]
    let k: Int
    let n0inv: UInt32
    let r2: [UInt32]   // R^2 mod n

    init(_ mod: BigUInt) {
        n = mod.w; k = mod.w.count
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- n[0] &* inv) }
        n0inv = 0 &- inv
        // R^2 mod n with R = 2^(32k): double 1 (64k) times, subtracting n when needed.
        var r = [UInt32](repeating: 0, count: k + 1)
        r[0] = 1
        for _ in 0..<(64 * k) {
            var carry: UInt32 = 0
            for i in 0...k { let v = r[i]; r[i] = (v << 1) | carry; carry = v >> 31 }
            if Montgomery.geq(r, mod.w) { Montgomery.subIn(&r, mod.w) }
        }
        r2 = Array(r.prefix(k))
    }

    static func geq(_ a: [UInt32], _ n: [UInt32]) -> Bool {
        if a.count > n.count, a[n.count...].contains(where: { $0 != 0 }) { return true }
        for i in stride(from: n.count - 1, through: 0, by: -1) where a[i] != n[i] { return a[i] > n[i] }
        return true
    }
    static func subIn(_ a: inout [UInt32], _ n: [UInt32]) {
        var borrow: Int64 = 0
        for i in 0..<a.count {
            var s = Int64(a[i]) - (i < n.count ? Int64(n[i]) : 0) - borrow
            if s < 0 { s += 1 << 32; borrow = 1 } else { borrow = 0 }
            a[i] = UInt32(s)
        }
    }

    private func pad(_ a: BigUInt) -> [UInt32] { a.w.count >= k ? Array(a.w.prefix(k)) : a.w + [UInt32](repeating: 0, count: k - a.w.count) }

    /// a * b * R^-1 mod n (CIOS)
    func mul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var t = [UInt32](repeating: 0, count: k + 2)
        for i in 0..<k {
            var c: UInt64 = 0
            let ai = UInt64(a[i])
            for j in 0..<k {
                let s = UInt64(t[j]) + ai * UInt64(b[j]) + c
                t[j] = UInt32(s & 0xFFFFFFFF); c = s >> 32
            }
            var s = UInt64(t[k]) + c
            t[k] = UInt32(s & 0xFFFFFFFF); t[k + 1] = UInt32(s >> 32)
            let m = UInt64(t[0] &* n0inv)
            s = UInt64(t[0]) + m * UInt64(n[0])
            c = s >> 32
            for j in 1..<k {
                s = UInt64(t[j]) + m * UInt64(n[j]) + c
                t[j - 1] = UInt32(s & 0xFFFFFFFF); c = s >> 32
            }
            s = UInt64(t[k]) + c
            t[k - 1] = UInt32(s & 0xFFFFFFFF)
            t[k] = t[k + 1] &+ UInt32(s >> 32)
        }
        var r = Array(t.prefix(k + 1))
        if Montgomery.geq(r, n) { Montgomery.subIn(&r, n) }
        return Array(r.prefix(k))
    }

    func reduce(_ a: BigUInt) -> BigUInt {
        // a mod n for a < n * R: (a * R^-1) * R^2 * R^-1 ... done in two steps on padded limbs.
        var x = a.w
        if x.count > 2 * k { x = Array(x.prefix(2 * k)) }   // inputs here are always below n^2
        // Split a = hi*R + lo, then a mod n = (hi * R mod n + lo) mod n
        let lo = BigUInt(Array(x.prefix(k)))
        let hi = BigUInt(x.count > k ? Array(x[k...]) : [0])
        let hiR = BigUInt(mul(pad(hi), r2))                    // hi * R^2 * R^-1 = hi * R mod n
        var s = (hiR + lo).w
        while Montgomery.geq(s, n) { Montgomery.subIn(&s, n) }
        return BigUInt(s)
    }

    func mulMod(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        BigUInt(mul(mul(pad(reduce(a)), pad(reduce(b))), r2))
    }

    func pow(_ base: BigUInt, _ e: BigUInt) -> BigUInt {
        let bm = mul(pad(reduce(base)), r2)
        var one = [UInt32](repeating: 0, count: k); one[0] = 1
        var acc = mul(one, r2)            // R mod n (Montgomery 1)
        for i in stride(from: e.bitCount - 1, through: 0, by: -1) {
            acc = mul(acc, acc)
            if e.bit(i) { acc = mul(acc, bm) }
        }
        return BigUInt(mul(acc, one))
    }
}

// MARK: - SRP-6a (3072-bit group, SHA-512), as used by HomeKit / Apple TV pair-setup

struct SRPClient {
    static let N = BigUInt(bytes: hex("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"))
    static let g = BigUInt(5)
    static let mont = Montgomery(N)

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }
    static func H(_ parts: [UInt8]...) -> [UInt8] {
        var h = SHA512()
        for p in parts { h.update(data: p) }
        return Array(h.finalize())
    }

    let a: BigUInt
    let A: BigUInt

    init() {
        var r = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &r)
        a = BigUInt(bytes: r)
        A = SRPClient.mont.pow(SRPClient.g, a)
    }

    /// Returns (M1 proof, session key K) for the server's salt and public value B.
    func respond(salt: [UInt8], B Bbytes: [UInt8], pin: String) throws -> (m1: [UInt8], k: [UInt8], a: [UInt8]) {
        let N = SRPClient.N, mont = SRPClient.mont
        let B = BigUInt(bytes: Bbytes)
        guard !mont.reduce(B).isZero else { throw AppError("The Apple TV sent a bad pairing value.") }
        let padLen = N.bytes().count
        let k = BigUInt(bytes: SRPClient.H(N.bytes(), SRPClient.g.bytes(pad: padLen)))
        let x = BigUInt(bytes: SRPClient.H(salt, SRPClient.H(Array("Pair-Setup:\(pin)".utf8))))
        let u = BigUInt(bytes: SRPClient.H(A.bytes(pad: padLen), B.bytes(pad: padLen)))
        let v = mont.pow(SRPClient.g, x)
        let kv = mont.mulMod(k, v)
        let Bm = mont.reduce(B)
        let base = BigUInt.cmp(Bm, kv) >= 0 ? Bm - kv : (Bm + N) - kv
        let S = mont.pow(base, a + u * x)
        let K = SRPClient.H(S.bytes())
        let hN = SRPClient.H(N.bytes()), hg = SRPClient.H(SRPClient.g.bytes())
        let x1 = zip(hN, hg).map { $0 ^ $1 }
        let m1 = SRPClient.H(x1, SRPClient.H(Array("Pair-Setup".utf8)), salt, A.bytes(), B.bytes(), K)
        return (m1, K, A.bytes())
    }

    func serverProof(m1: [UInt8], k: [UInt8]) -> [UInt8] { SRPClient.H(A.bytes(), m1, k) }
}

// MARK: - TLV8

enum TLV8 {
    static func encode(_ items: [(UInt8, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        for (t, v) in items {
            if v.isEmpty { out += [t, 0]; continue }
            var i = 0
            while i < v.count {
                let n = min(255, v.count - i)
                out += [t, UInt8(n)] + v[i..<(i + n)]
                i += n
            }
        }
        return out
    }
    static func decode(_ d: [UInt8]) -> [UInt8: [UInt8]] {
        var out: [UInt8: [UInt8]] = [:]
        var i = 0, last: UInt8 = 255
        while i + 2 <= d.count {
            let t = d[i], l = Int(d[i + 1]); i += 2
            guard i + l <= d.count else { break }
            let v = Array(d[i..<(i + l)]); i += l
            if t == last, out[t] != nil { out[t]! += v } else { out[t] = v }
            last = t
        }
        return out
    }
}

// MARK: - OPACK (Apple's compact binary plist)

enum OPACK {
    static func pack(_ v: Any) -> [UInt8] {
        switch v {
        case let b as Bool: return [b ? 0x01 : 0x02]
        case let i as Int: return packInt(UInt64(max(0, i)))
        case let i as UInt64: return packInt(i)
        case let d as Double: var x = d.bitPattern.littleEndian; return [0x36] + withUnsafeBytes(of: &x) { Array($0) }
        case let s as String:
            let b = [UInt8](s.utf8)
            if b.count <= 0x20 { return [UInt8(0x40 + b.count)] + b }
            if b.count <= 0xFF { return [0x61, UInt8(b.count)] + b }
            return [0x62, UInt8(b.count & 255), UInt8(b.count >> 8)] + b
        case let d as [UInt8]:
            if d.count <= 0x20 { return [UInt8(0x70 + d.count)] + d }
            if d.count <= 0xFF { return [0x91, UInt8(d.count)] + d }
            return [0x92, UInt8(d.count & 255), UInt8((d.count >> 8) & 255)] + d
        case let d as Data: return pack([UInt8](d))
        case let a as [Any]:
            var out: [UInt8] = [UInt8(0xD0 + min(a.count, 0xF))]
            for x in a { out += pack(x) }
            if a.count >= 0xF { out.append(0x03) }
            return out
        case let m as [String: Any]:
            var out: [UInt8] = [UInt8(0xE0 + min(m.count, 0xF))]
            for (k, x) in m { out += pack(k) + pack(x) }
            if m.count >= 0xF { out.append(0x03) }
            return out
        default: return [0x04]
        }
    }

    private static func packInt(_ i: UInt64) -> [UInt8] {
        if i <= 0x27 { return [UInt8(0x08 + i)] }
        if i <= 0xFF { return [0x30, UInt8(i)] }
        if i <= 0xFFFF { return [0x31, UInt8(i & 255), UInt8(i >> 8)] }
        if i <= 0xFFFFFFFF { return [0x32] + (0..<4).map { UInt8((i >> (8 * $0)) & 255) } }
        return [0x33] + (0..<8).map { UInt8((i >> (8 * UInt64($0))) & 255) }
    }

    static func unpack(_ d: [UInt8]) -> Any? {
        var i = 0
        var objects: [Any] = []
        return try? value(d, &i, &objects)
    }

    private static func le(_ d: [UInt8], _ i: Int, _ n: Int) throws -> UInt64 {
        guard i + n <= d.count else { throw AppError("short") }
        var v: UInt64 = 0
        for j in 0..<n { v |= UInt64(d[i + j]) << (8 * UInt64(j)) }
        return v
    }

    private static func value(_ d: [UInt8], _ i: inout Int, _ objects: inout [Any]) throws -> Any {
        guard i < d.count else { throw AppError("short") }
        let t = d[i]; i += 1
        var add = true
        var result: Any
        switch t {
        case 0x01: result = true; add = false
        case 0x02: result = false; add = false
        case 0x03: throw AppError("end")
        case 0x04: result = NSNull(); add = false
        case 0x05: guard i + 16 <= d.count else { throw AppError("short") }; result = Array(d[i..<(i + 16)]); i += 16
        case 0x06: result = try le(d, i, 8); i += 8
        case 0x08...0x2F: result = Int(t - 0x08); add = false
        case 0x30: result = Int(try le(d, i, 1)); i += 1
        case 0x31: result = Int(try le(d, i, 2)); i += 2
        case 0x32: result = Int(try le(d, i, 4)); i += 4
        case 0x33: result = Int(truncatingIfNeeded: try le(d, i, 8)); i += 8
        case 0x35: result = Double(Float(bitPattern: UInt32(try le(d, i, 4)))); i += 4
        case 0x36: result = Double(bitPattern: try le(d, i, 8)); i += 8
        case 0x40...0x60:
            let n = Int(t - 0x40); guard i + n <= d.count else { throw AppError("short") }
            result = String(decoding: d[i..<(i + n)], as: UTF8.self); i += n
        case 0x61...0x64:
            let ln = Int(t - 0x60); let n = Int(try le(d, i, ln)); i += ln
            guard i + n <= d.count else { throw AppError("short") }
            result = String(decoding: d[i..<(i + n)], as: UTF8.self); i += n
        case 0x70...0x90:
            let n = Int(t - 0x70); guard i + n <= d.count else { throw AppError("short") }
            result = Array(d[i..<(i + n)]); i += n
        case 0x91...0x94:
            let ln = [1, 2, 4, 8][Int(t - 0x91)]; let n = Int(try le(d, i, ln)); i += ln
            guard i + n <= d.count else { throw AppError("short") }
            result = Array(d[i..<(i + n)]); i += n
        case 0xA0...0xC0:
            let idx = Int(t - 0xA0)
            guard idx < objects.count else { throw AppError("bad ref") }
            return objects[idx]
        case 0xD0...0xDF:
            var arr: [Any] = []
            if t == 0xDF {
                while i < d.count && d[i] != 0x03 { arr.append(try value(d, &i, &objects)) }
                i += 1
            } else {
                for _ in 0..<Int(t - 0xD0) { arr.append(try value(d, &i, &objects)) }
            }
            result = arr; add = false
        case 0xE0...0xEF:
            var m: [String: Any] = [:]
            if t == 0xEF {
                while i < d.count && d[i] != 0x03 {
                    let k = try value(d, &i, &objects); let v = try value(d, &i, &objects)
                    m["\(k)"] = v
                }
                i += 1
            } else {
                for _ in 0..<Int(t - 0xE0) {
                    let k = try value(d, &i, &objects); let v = try value(d, &i, &objects)
                    m["\(k)"] = v
                }
            }
            result = m; add = false
        default: throw AppError("Unknown OPACK type \(t)")
        }
        if add { objects.append(result) }
        return result
    }
}
