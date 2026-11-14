import Foundation
import Security

/// Android / Fire TV over ADB (port 5555), speaking the adb wire protocol directly (no adb.exe needed).
/// The first time, the TV shows "Allow USB debugging?" for this iPhone's key. Tick "Always allow" and press OK.
final class Adb {
    static let shared = Adb()

    private let q = DispatchQueue(label: "mrl.adb")
    private var stream: LowNet.Stream?
    private var streamIp = ""
    private var nextId: UInt32 = 1

    private static let CNXN: UInt32 = 0x4E584E43, AUTH: UInt32 = 0x48545541, OPEN: UInt32 = 0x4E45504F,
                       OKAY: UInt32 = 0x59414B4F, CLSE: UInt32 = 0x45534C43, WRTE: UInt32 = 0x45545257

    struct Packet { let cmd: UInt32; let a0: UInt32; let a1: UInt32; let data: [UInt8] }

    // MARK: Key (RSA 2048, kept on this iPhone)

    private static func key() throws -> SecKey {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                    kSecAttrKeySizeInBits as String: 2048]
        if let d = UserDefaults.standard.data(forKey: "adbKey"), let k = SecKeyCreateWithData(d as CFData, attrs as CFDictionary, nil) { return k }
        var err: Unmanaged<CFError>?
        guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let d = SecKeyCopyExternalRepresentation(k, &err) as Data? else { throw AppError("Couldn't make the ADB key on this iPhone.") }
        UserDefaults.standard.set(d, forKey: "adbKey")
        return k
    }

    /// Android's own public key format: len, n0inv, n (LE words), rr = R^2 mod n (LE words), e. Base64 + " name".
    private static func androidPublicKey(_ k: SecKey) throws -> [UInt8] {
        guard let pub = SecKeyCopyPublicKey(k), let der = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { throw AppError("Couldn't read the ADB key.") }
        let (nBytes, e) = try parseRSAPublic([UInt8](der))
        let words = 64
        var n = [UInt32](repeating: 0, count: words)   // little-endian 32-bit words
        let be = Array(nBytes.drop(while: { $0 == 0 }).suffix(256))
        for (i, b) in be.reversed().enumerated() { n[i / 4] |= UInt32(b) << (8 * UInt32(i % 4)) }
        // n0inv = -1 / n[0] mod 2^32
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- n[0] &* inv) }
        let n0inv = 0 &- inv
        // rr = 2^4096 mod n, by doubling 4096 times with conditional subtraction
        var r = [UInt32](repeating: 0, count: words + 1)
        r[0] = 1
        for _ in 0..<4096 {
            var carry: UInt32 = 0
            for i in 0...words { let v = r[i]; r[i] = (v << 1) | carry; carry = v >> 31 }
            if geq(r, n) { sub(&r, n) }
        }
        var out: [UInt8] = []
        func put(_ v: UInt32) { out += [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
        put(UInt32(words)); put(n0inv)
        for w in n { put(w) }
        for i in 0..<words { put(r[i]) }
        put(e)
        let line = Data(out).base64EncodedString() + " mrlttec@iphone\0"
        return [UInt8](line.utf8)
    }

    private static func geq(_ a: [UInt32], _ n: [UInt32]) -> Bool {
        if a.count > n.count, a[n.count...].contains(where: { $0 != 0 }) { return true }
        for i in stride(from: n.count - 1, through: 0, by: -1) {
            let x = i < a.count ? a[i] : 0
            if x != n[i] { return x > n[i] }
        }
        return true
    }
    private static func sub(_ a: inout [UInt32], _ n: [UInt32]) {
        var borrow: Int64 = 0
        for i in 0..<a.count {
            let v = Int64(a[i]) - (i < n.count ? Int64(n[i]) : 0) - borrow
            borrow = v < 0 ? 1 : 0
            a[i] = UInt32(truncatingIfNeeded: v < 0 ? v + (1 << 32) : v)
        }
    }

    /// PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }
    private static func parseRSAPublic(_ d: [UInt8]) throws -> ([UInt8], UInt32) {
        var i = 0
        func len() throws -> Int {
            guard i < d.count else { throw AppError("Bad key.") }
            var l = Int(d[i]); i += 1
            if l & 0x80 != 0 { let c = l & 0x7F; l = 0; for _ in 0..<c { l = l << 8 | Int(d[i]); i += 1 } }
            return l
        }
        guard d.first == 0x30 else { throw AppError("Bad key.") }
        i = 1; _ = try len()
        guard d[i] == 0x02 else { throw AppError("Bad key.") }
        i += 1; let nl = try len(); let n = Array(d[i..<(i + nl)]); i += nl
        guard d[i] == 0x02 else { throw AppError("Bad key.") }
        i += 1; let el = try len()
        var e: UInt32 = 0
        for b in d[i..<(i + el)] { e = e << 8 | UInt32(b) }
        return (n, e)
    }

    // MARK: Wire

    private func write(_ s: LowNet.Stream, _ cmd: UInt32, _ a0: UInt32, _ a1: UInt32, _ data: [UInt8] = []) throws {
        var h: [UInt8] = []
        func put(_ v: UInt32) { h += [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
        put(cmd); put(a0); put(a1); put(UInt32(data.count))
        put(data.reduce(UInt32(0)) { $0 &+ UInt32($1) }); put(cmd ^ 0xFFFFFFFF)
        try s.write(h + data)
    }

    private func read(_ s: LowNet.Stream) throws -> Packet {
        let h = try s.read(24)
        func u(_ o: Int) -> UInt32 { UInt32(h[o]) | UInt32(h[o + 1]) << 8 | UInt32(h[o + 2]) << 16 | UInt32(h[o + 3]) << 24 }
        let len = Int(u(12))
        guard len <= 1 << 20 else { throw AppError("The TV sent something unexpected.") }
        var data: [UInt8] = []
        if len > 0 { data = try s.read(len) }
        return Packet(cmd: u(0), a0: u(4), a1: u(8), data: data)
    }

    private func connect(_ ip: String) throws -> LowNet.Stream {
        if let s = stream, streamIp == ip { return s }
        stream = nil
        let s: LowNet.Stream
        do { s = try LowNet.Stream(ip, 5555, connectMs: 3000) }
        catch { throw AppError("The TV didn't answer on the ADB port (5555). Turn on ADB debugging: Settings > My Fire TV (or Device Preferences) > Developer options.") }
        s.setTimeout(5000)
        try write(s, Self.CNXN, 0x01000000, 256 * 1024, [UInt8]("host::\0".utf8))
        let k = try Self.key()
        var sentSig = false
        while true {
            let p = try read(s)
            if p.cmd == Self.CNXN { break }
            guard p.cmd == Self.AUTH, p.a0 == 1 else { continue }
            if !sentSig {
                var err: Unmanaged<CFError>?
                guard let sig = SecKeyCreateSignature(k, .rsaSignatureDigestPKCS1v15SHA1, Data(p.data) as CFData, &err) as Data? else {
                    throw AppError("Couldn't sign the TV's request.")
                }
                try write(s, Self.AUTH, 2, 0, [UInt8](sig))
                sentSig = true
            } else {
                // The TV doesn't know this iPhone yet: send the public key; the TV shows "Allow USB debugging?".
                try write(s, Self.AUTH, 3, 0, try Self.androidPublicKey(k))
                s.setTimeout(45000)
                let p2: Packet
                do { p2 = try read(s) } catch {
                    throw AppError("The TV didn't allow this iPhone. On the TV, tick \"Always allow\" and press OK, then try again.")
                }
                guard p2.cmd == Self.CNXN else { throw AppError("The TV said no to this iPhone.") }
                break
            }
        }
        s.setTimeout(8000)
        stream = s; streamIp = ip
        return s
    }

    private func shellOnce(_ ip: String, _ command: String) throws -> String {
        let s = try connect(ip)
        let local = nextId; nextId &+= 1
        try write(s, Self.OPEN, local, 0, [UInt8]("shell:\(command)\0".utf8))
        var out: [UInt8] = []
        var remote: UInt32 = 0
        while true {
            let p = try read(s)
            switch p.cmd {
            case Self.OKAY: remote = p.a0
            case Self.WRTE:
                out += p.data
                remote = p.a0
                try write(s, Self.OKAY, local, remote)
            case Self.CLSE:
                if p.a1 == local || p.a1 == 0 {
                    try? write(s, Self.CLSE, local, remote)
                    return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            default: continue
            }
        }
    }

    /// Runs `adb shell <command>`, reconnecting once if the old connection went stale.
    func shell(_ ip: String, _ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { c in
            q.async {
                do { c.resume(returning: try self.shellOnce(ip, command)) }
                catch let e as AppError where e.message.contains("ADB port") || e.message.contains("allow") || e.message.contains("said no") {
                    self.stream = nil; c.resume(throwing: e)
                }
                catch {
                    self.stream = nil
                    do { c.resume(returning: try self.shellOnce(ip, command)) } catch { self.stream = nil; c.resume(throwing: error) }
                }
            }
        }
    }

    func forgetKey() { UserDefaults.standard.removeObject(forKey: "adbKey"); q.async { self.stream = nil } }

    // MARK: Commands (same as the PC tool's /adb)

    static let keys: [String: Int] = ["sleep": 223, "wake": 224, "home": 3, "volup": 24, "voldown": 25, "mute": 164,
        "up": 19, "down": 20, "left": 21, "right": 22, "ok": 23, "back": 4, "menu": 82,
        "playpause": 85, "stop": 86, "next": 87, "prev": 88, "rewind": 89, "ffwd": 90,
        "chup": 166, "chdown": 167, "search": 84, "settings": 176, "recents": 187, "guide": 172, "enter": 66, "del": 67,
        "n0": 7, "n1": 8, "n2": 9, "n3": 10, "n4": 11, "n5": 12, "n6": 13, "n7": 14, "n8": 15, "n9": 16]

    static let appNames: [String: String] = ["org.jellyfin.androidtv": "Jellyfin", "org.videolan.vlc": "VLC", "com.amazon.firetv.youtube": "YouTube",
        "com.google.android.youtube.tv": "YouTube", "com.netflix.ninja": "Netflix", "com.amazon.avod": "Prime Video",
        "com.amazon.avod.thirdpartyclient": "Prime Video", "com.disney.disneyplus": "Disney+", "com.hulu.plus": "Hulu",
        "com.spotify.tv.android": "Spotify", "com.plexapp.android": "Plex", "com.wbd.stream": "Max", "tv.twitch.android.app": "Twitch",
        "com.amazon.tv.launcher": "Fire TV Home", "com.amazon.firebat": "Fire TV Home", "com.google.android.apps.tv.launcherx": "Google TV Home"]

    func key(_ ip: String, _ k: String) async throws {
        guard let code = Self.keys[k] else { throw AppError("Command not allowed.") }
        _ = try await shell(ip, "input keyevent \(code)")
    }

    func text(_ ip: String, _ t: String) async throws {
        guard t.wholeMatch(of: #/[A-Za-z0-9 .,@_+=:\/-]{1,100}/#) != nil else {
            throw AppError("Text can only use letters, numbers, spaces and . , @ _ + = : / - (up to 100 characters).")
        }
        _ = try await shell(ip, "input text '\(t.replacingOccurrences(of: " ", with: "%s"))'")
    }

    func launch(_ ip: String, _ pkgs: String) async throws {
        guard pkgs.wholeMatch(of: #/[A-Za-z0-9_.]+(\|[A-Za-z0-9_.]+){0,3}/#) != nil else { throw AppError("App name not allowed.") }
        for p in pkgs.split(separator: "|") {
            for cat in ["android.intent.category.LAUNCHER", "android.intent.category.LEANBACK_LAUNCHER"] {
                if try await shell(ip, "monkey -p \(p) -c \(cat) 1").contains("Events injected: 1") { return }
            }
        }
        throw AppError("Couldn't open that app. It may not be installed on this device.")
    }

    func apps(_ ip: String) async throws -> [String] {
        let r = try await shell(ip, "pm list packages -3")
        return r.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "package:", with: "") }
            .filter { $0.wholeMatch(of: #/[A-Za-z0-9_.]+/#) != nil }.sorted()
    }

    func info(_ ip: String) async throws -> String {
        var lines: [String] = []
        for (label, prop) in [("Model", "ro.product.model"), ("Maker", "ro.product.manufacturer"), ("Android version", "ro.build.version.release"), ("Build", "ro.build.display.id")] {
            let v = try await shell(ip, "getprop \(prop)")
            lines.append("\(label): \(v)")
        }
        let p = try await shell(ip, "dumpsys power | grep mWakefulness=")
        if let m = p.firstMatch(of: #/mWakefulness=(\w+)/#) { lines.append("Screen: " + (["Awake", "Dreaming"].contains(String(m.1)) ? "on" : "off")) }
        return lines.joined(separator: "\n")
    }

    /// Puts a Fire TV into Display Mirroring (Miracast) so an Android phone or Windows PC can mirror to it.
    /// Amazon doesn't document the screen's name, so try the known ones, then fall back to the display settings.
    func startMirroring(_ ip: String) async throws -> String {
        _ = try? await shell(ip, "input keyevent 224")
        let tries = ["am start -n com.amazon.cast.sink/.DisplayMirroringSinkActivity",
                     "am start -a com.amazon.cast.sink.action.START",
                     "am start -n com.amazon.tv.settings.v2/com.amazon.tv.settings.v2.tv.mirroring.DisplayMirroringActivity"]
        for t in tries {
            let r = try await shell(ip, t)
            if r.range(of: "error", options: .caseInsensitive) == nil && r.range(of: "exception", options: .caseInsensitive) == nil {
                return "Display Mirroring is on. On the Android phone or Windows PC, choose Cast or Smart View (Windows: press Windows + K) and pick this TV."
            }
        }
        _ = try await shell(ip, "am start -a android.settings.CAST_SETTINGS")
        return "Opened the TV's mirroring settings. Choose Enable Display Mirroring on the TV."
    }

    /// iPhones can't use Miracast. AirScreen makes a Fire TV accept AirPlay, so Control Center > Screen Mirroring works.
    func mirrorIPhone(_ ip: String) async throws -> String {
        let pkg = "com.ionitech.airscreen"
        let has = try await shell(ip, "pm path \(pkg)")
        if has.contains("package:") {
            try await launch(ip, pkg)
            return "AirScreen is open on the TV. On this iPhone, open Control Center, tap Screen Mirroring and pick the TV."
        }
        _ = try? await shell(ip, "input keyevent 224")
        _ = try await shell(ip, "am start -a android.intent.action.VIEW -d 'amzn://apps/android?p=\(pkg)'")
        return "The TV is showing AirScreen in the app store. Tap Get on the TV, then press this button again."
    }

    func youtube(_ ip: String, _ link: String) async throws {
        guard let id = YouTube.videoId(link.trimmed) else { throw AppError("That doesn't look like a YouTube link.") }
        _ = try? await shell(ip, "input keyevent 224")
        let r = try await shell(ip, "am start -a android.intent.action.VIEW -d 'https://www.youtube.com/watch?v=\(id)'")
        if r.range(of: "error", options: .caseInsensitive) != nil { throw AppError("The TV couldn't open YouTube: \(r)") }
    }
}
