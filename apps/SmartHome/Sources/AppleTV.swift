import Foundation
import Network
import CryptoKit

/// Apple TV remote over Apple's Companion protocol (what the iPhone's own Apple TV Remote uses).
/// Pair once with the PIN the TV shows; after that every connection is verified and encrypted.
/// Protocol details follow the open-source pyatv project.
actor AppleTV {
    static let shared = AppleTV()

    struct Creds: Codable { var ltsk: Data; var pairingId: String; var atvId: String; var atvLtpk: Data }

    private var conn: NWConnection?
    private var connIp = ""
    private var outKey: SymmetricKey?
    private var inKey: SymmetricKey?
    private var outCounter: UInt64 = 0
    private var inCounter: UInt64 = 0
    private var xid = Int.random(in: 1000...60000)
    private var srp: SRPClient?
    private var pendingPin = false
    private let q = DispatchQueue(label: "mrl.atv")

    // MARK: Saved pairings

    static func creds(_ ip: String) -> Creds? {
        guard let d = UserDefaults.standard.data(forKey: "atv.\(ip)") else { return nil }
        return try? JSONDecoder().decode(Creds.self, from: d)
    }
    static func save(_ ip: String, _ c: Creds?) {
        if let c, let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: "atv.\(ip)") }
        else { UserDefaults.standard.removeObject(forKey: "atv.\(ip)") }
    }
    static func isPaired(_ ip: String) -> Bool { creds(ip) != nil }

    // MARK: Finding the Companion port (it changes, so ask Bonjour)

    struct Found: Hashable { let name: String; let ip: String; let port: UInt16 }

    static func browse(seconds: Double = 3) async -> [Found] {
        let browser = NWBrowser(for: .bonjour(type: "_companion-link._tcp", domain: nil), using: .tcp)
        let q = DispatchQueue(label: "mrl.atv.browse")
        let results: Set<NWBrowser.Result> = await withCheckedContinuation { c in
            var done = false
            var latest = Set<NWBrowser.Result>()
            browser.browseResultsChangedHandler = { r, _ in latest = r }
            browser.start(queue: q)
            q.asyncAfter(deadline: .now() + seconds) {
                if done { return }
                done = true
                browser.cancel()
                c.resume(returning: latest)
            }
        }
        var out: [Found] = []
        await withTaskGroup(of: Found?.self) { g in
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint else { continue }
                g.addTask { await resolve(r.endpoint, name: name) }
            }
            for await f in g { if let f, isPrivateIp(f.ip) { out.append(f) } }
        }
        return out
    }

    private static func resolve(_ ep: NWEndpoint, name: String) async -> Found? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: ep, using: params)
        let q = DispatchQueue(label: "mrl.atv.resolve")
        return await withCheckedContinuation { cont in
            var done = false
            let finish: (Found?) -> Void = { f in if !done { done = true; c.cancel(); cont.resume(returning: f) } }
            c.stateUpdateHandler = { s in
                switch s {
                case .ready:
                    if case .hostPort(let host, let port) = c.currentPath?.remoteEndpoint {
                        var ip = "\(host)"
                        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
                        finish(Found(name: name, ip: ip, port: port.rawValue))
                    } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }

    private func port(for ip: String) async throws -> UInt16 {
        if let p = UInt16(Store.get("atvPort", ip)), LowNet.tcpOpen(ip, p, timeoutMs: 800) { return p }
        for f in await AppleTV.browse() { Store.set("atvPort", f.ip, "\(f.port)") }
        if let p = UInt16(Store.get("atvPort", ip)) { return p }
        // Fallback: tvOS usually listens on 49153.
        if LowNet.tcpOpen(ip, 49153, timeoutMs: 800) { return 49153 }
        throw AppError("Couldn't find the Apple TV's remote service. Is it awake and on this Wi-Fi?")
    }

    // MARK: Connection and frames

    private func disconnect() {
        conn?.cancel(); conn = nil; connIp = ""
        outKey = nil; inKey = nil; outCounter = 0; inCounter = 0
    }

    private func open(_ ip: String) async throws {
        disconnect()
        let p = try await port(for: ip)
        let c = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: p)!, using: .tcp)
        let q = self.q
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            let finish: (Error?) -> Void = { e in if done { return }; done = true; if let e { cont.resume(throwing: e) } else { cont.resume() } }
            c.stateUpdateHandler = { s in
                switch s {
                case .ready: finish(nil)
                case .failed, .waiting: finish(AppError("Couldn't connect to the Apple TV. Is it awake?"))
                case .cancelled: finish(AppError("The Apple TV connection closed."))
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + 5) { finish(AppError("The Apple TV didn't answer.")) }
        }
        conn = c; connIp = ip
    }

    private func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var b = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { b[i] = UInt8((n >> (8 * UInt64(i))) & 255) }
        return try ChaChaPoly.Nonce(data: b)
    }

    private func sendFrame(_ type: UInt8, _ payload: [UInt8]) async throws {
        guard let c = conn else { throw AppError("Not connected to the Apple TV.") }
        var body = payload
        var header: [UInt8]
        if let k = outKey, type == 8 {
            let len = payload.count + 16
            header = [type, UInt8((len >> 16) & 255), UInt8((len >> 8) & 255), UInt8(len & 255)]
            let box = try ChaChaPoly.seal(Data(payload), using: k, nonce: nonce(outCounter), authenticating: Data(header))
            outCounter += 1
            body = [UInt8](box.ciphertext) + [UInt8](box.tag)
        } else {
            let len = payload.count
            header = [type, UInt8((len >> 16) & 255), UInt8((len >> 8) & 255), UInt8(len & 255)]
        }
        let frame = Data(header + body)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: frame, completion: .contentProcessed { e in
                if e != nil { cont.resume(throwing: AppError("Lost the connection to the Apple TV.")) } else { cont.resume() }
            })
        }
    }

    private func readExact(_ c: NWConnection, _ n: Int) async throws -> [UInt8] {
        if n == 0 { return [] }
        return try await withCheckedThrowingContinuation { cont in
            c.receive(minimumIncompleteLength: n, maximumLength: n) { d, _, _, e in
                if let d, d.count == n { cont.resume(returning: [UInt8](d)) }
                else { cont.resume(throwing: AppError(e == nil ? "The Apple TV closed the connection." : "Lost the connection to the Apple TV.")) }
            }
        }
    }

    /// Reads one frame (type, decrypted payload). Gives up after `seconds` by closing the connection.
    private func readFrame(_ seconds: Double = 8) async throws -> (UInt8, [UInt8]) {
        guard let c = conn else { throw AppError("Not connected to the Apple TV.") }
        let w = DispatchWorkItem { c.cancel() }
        q.asyncAfter(deadline: .now() + seconds, execute: w)
        defer { w.cancel() }
        let h = try await readExact(c, 4)
        let len = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
        var body = try await readExact(c, len)
        if let k = inKey, h[0] == 8, body.count >= 16 {
            let box = try ChaChaPoly.SealedBox(nonce: nonce(inCounter), ciphertext: body.dropLast(16), tag: body.suffix(16))
            body = [UInt8](try ChaChaPoly.open(box, using: k, authenticating: Data(h)))
            inCounter += 1
        }
        return (h[0], body)
    }

    private func readPd(_ seconds: Double = 10) async throws -> [UInt8: [UInt8]] {
        let (_, body) = try await readFrame(seconds)
        guard let m = OPACK.unpack(body) as? [String: Any], let pd = m["_pd"] as? [UInt8] else {
            throw AppError("The Apple TV sent an answer this app doesn't understand.")
        }
        let t = TLV8.decode(pd)
        if let err = t[0x07], let code = err.first {
            switch code {
            case 2: throw AppError("Wrong PIN. Start pairing again and type the new PIN.")
            case 3: throw AppError("The Apple TV is busy. Wait a minute and try again.")
            case 6: throw AppError("The Apple TV is already pairing with something. Try again in a moment.")
            default: throw AppError("The Apple TV refused (error \(code)).")
            }
        }
        return t
    }

    private static func hkdf(_ ikm: [UInt8], _ salt: String, _ info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
    }

    private static func seal(_ pt: [UInt8], _ key: SymmetricKey, _ label: String) throws -> [UInt8] {
        let n = try ChaChaPoly.Nonce(data: [0, 0, 0, 0] + Array(label.utf8))
        let b = try ChaChaPoly.seal(Data(pt), using: key, nonce: n)
        return [UInt8](b.ciphertext) + [UInt8](b.tag)
    }

    private static func open(_ ct: [UInt8], _ key: SymmetricKey, _ label: String) throws -> [UInt8] {
        guard ct.count >= 16 else { throw AppError("Bad encrypted data from the Apple TV.") }
        let n = try ChaChaPoly.Nonce(data: [0, 0, 0, 0] + Array(label.utf8))
        let box = try ChaChaPoly.SealedBox(nonce: n, ciphertext: ct.dropLast(16), tag: ct.suffix(16))
        return [UInt8](try ChaChaPoly.open(box, using: key))
    }

    // MARK: Pairing (shows a PIN on the TV)

    func startPairing(_ ip: String) async throws {
        try await open(ip)
        let m1 = TLV8.encode([(0x00, [0x00]), (0x06, [0x01])])
        try await sendFrame(3, OPACK.pack(["_pd": m1, "_pwTy": 1] as [String: Any]))
        let m2 = try await readPd(15)
        guard m2[0x02] != nil, m2[0x03] != nil else { throw AppError("The Apple TV didn't start pairing.") }
        pairSalt = m2[0x02]!; pairB = m2[0x03]!
        srp = SRPClient()
        pendingPin = true
    }
    private var pairSalt: [UInt8] = []
    private var pairB: [UInt8] = []

    func finishPairing(_ ip: String, pin: String) async throws {
        guard pendingPin, let srp, connIp == ip else { throw AppError("Tap Start pairing first so the TV shows a PIN.") }
        pendingPin = false
        let r = try srp.respond(salt: pairSalt, B: pairB, pin: pin)
        try await sendFrame(4, OPACK.pack(["_pd": TLV8.encode([(0x06, [0x03]), (0x03, r.a), (0x04, r.m1)])] as [String: Any]))
        let m4 = try await readPd(15)
        guard m4[0x04] == srp.serverProof(m1: r.m1, k: r.k) else { throw AppError("Wrong PIN. Start pairing again and type the new PIN.") }

        let signing = Curve25519.Signing.PrivateKey()
        let ltpk = [UInt8](signing.publicKey.rawRepresentation)
        let pid = UUID().uuidString.uppercased()
        let iosX = AppleTV.hkdf(r.k, "Pair-Setup-Controller-Sign-Salt", "Pair-Setup-Controller-Sign-Info").withUnsafeBytes { [UInt8]($0) }
        let encKey = AppleTV.hkdf(r.k, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info")
        let sig = [UInt8](try signing.signature(for: Data(iosX + Array(pid.utf8) + ltpk)))
        let inner = TLV8.encode([(0x01, Array(pid.utf8)), (0x03, ltpk), (0x0A, sig)])
        let enc = try AppleTV.seal(inner, encKey, "PS-Msg05")
        try await sendFrame(4, OPACK.pack(["_pd": TLV8.encode([(0x06, [0x05]), (0x05, enc)])] as [String: Any]))
        let m6 = try await readPd(15)
        guard let e6 = m6[0x05] else { throw AppError("The Apple TV didn't finish pairing.") }
        let t6 = TLV8.decode(try AppleTV.open(e6, encKey, "PS-Msg06"))
        let creds = Creds(ltsk: signing.rawRepresentation, pairingId: pid,
                          atvId: String(decoding: t6[0x01] ?? [], as: UTF8.self), atvLtpk: Data(t6[0x03] ?? []))
        AppleTV.save(ip, creds)
        self.srp = nil
        disconnect()
    }

    // MARK: Verified session

    private func verify(_ ip: String) async throws {
        guard let cr = AppleTV.creds(ip) else { throw AppError("Pair with this Apple TV first.") }
        try await open(ip)
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = [UInt8](eph.publicKey.rawRepresentation)
        try await sendFrame(5, OPACK.pack(["_pd": TLV8.encode([(0x06, [0x01]), (0x03, ephPub)]), "_auTy": 4] as [String: Any]))
        let m2 = try await readPd()
        guard let spub = m2[0x03], let enc2 = m2[0x05] else { throw AppError("The Apple TV didn't answer the secure check.") }
        let shared = try eph.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: spub))
        let sharedBytes = shared.withUnsafeBytes { [UInt8]($0) }
        let sess = AppleTV.hkdf(sharedBytes, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info")
        _ = try AppleTV.open(enc2, sess, "PV-Msg02")
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: cr.ltsk)
        let sig = [UInt8](try signing.signature(for: Data(ephPub + Array(cr.pairingId.utf8) + spub)))
        let inner = TLV8.encode([(0x01, Array(cr.pairingId.utf8)), (0x0A, sig)])
        let enc3 = try AppleTV.seal(inner, sess, "PV-Msg03")
        try await sendFrame(6, OPACK.pack(["_pd": TLV8.encode([(0x06, [0x03]), (0x05, enc3)])] as [String: Any]))
        do { _ = try await readPd() } catch let e as AppError where e.message.contains("refused") {
            AppleTV.save(ip, nil)
            throw AppError("The Apple TV no longer knows this iPhone. Pair again.")
        }
        outKey = AppleTV.hkdf(sharedBytes, "", "ClientEncrypt-main")
        inKey = AppleTV.hkdf(sharedBytes, "", "ServerEncrypt-main")
        outCounter = 0; inCounter = 0

        _ = try? await request("_systemInfo", ["_bf": 0, "_cf": 512, "_clFl": 128, "_i": "cafecafecafe", "_idsID": cr.pairingId,
                                                "_pubID": "aa:bb:cc:dd:ee:ff", "_sf": 256, "_sv": "170.18", "model": "iPhone17,1", "name": "MrLTTec Home"])
        _ = try? await request("_sessionStart", ["_srvT": "com.apple.tvremoteservices", "_sid": Int.random(in: 1...0x7FFFFFFF)])
        _ = try? await request("_touchStart", ["_height": 1000.0, "_tFl": 0, "_width": 1000.0])
    }

    private func ensure(_ ip: String) async throws {
        if conn != nil, connIp == ip, outKey != nil, conn?.state == .ready { return }
        try await verify(ip)
    }

    @discardableResult
    private func request(_ id: String, _ content: [String: Any], wait: Bool = true) async throws -> [String: Any] {
        xid += 1
        let me = xid
        try await sendFrame(8, OPACK.pack(["_i": id, "_x": me, "_t": 2, "_c": content] as [String: Any]))
        if !wait { return [:] }
        let end = Date().addingTimeInterval(6)
        while Date() < end {
            let (t, body) = try await readFrame(6)
            guard t == 8, let m = OPACK.unpack(body) as? [String: Any] else { continue }
            if (m["_x"] as? Int) == me {
                if let em = m["_em"] as? String { throw AppError("The Apple TV said: \(em)") }
                return m["_c"] as? [String: Any] ?? [:]
            }
        }
        throw AppError("The Apple TV didn't answer.")
    }

    /// Runs a command; if the old connection went stale, verifies again and retries once.
    private func run<T>(_ ip: String, _ op: () async throws -> T) async throws -> T {
        do { try await ensure(ip); return try await op() }
        catch let e as AppError where e.message.contains("Pair") || e.message.contains("PIN") { disconnect(); throw e }
        catch {
            disconnect()
            try await ensure(ip)
            return try await op()
        }
    }

    // MARK: Commands

    static let buttons: [String: Int] = ["up": 1, "down": 2, "left": 3, "right": 4, "menu": 5, "ok": 6, "home": 7,
                                         "volup": 8, "voldown": 9, "siri": 10, "screensaver": 11, "sleep": 12, "wake": 13,
                                         "playpause": 14, "chup": 15, "chdown": 16, "guide": 17, "pageup": 18, "pagedown": 19]

    func press(_ ip: String, _ name: String) async throws {
        guard let code = AppleTV.buttons[name] else { throw AppError("Unknown button.") }
        try await run(ip) {
            try await self.request("_hidC", ["_hBtS": 1, "_hidC": code], wait: false)
            try await self.request("_hidC", ["_hBtS": 2, "_hidC": code], wait: false)
        }
    }

    static let media: [String: Int] = ["play": 1, "pause": 2, "next": 3, "previous": 4]

    func mediaCommand(_ ip: String, _ name: String) async throws {
        guard let c = AppleTV.media[name] else { throw AppError("Unknown command.") }
        try await run(ip) { try await self.request("_mcc", ["_mcc": c], wait: false) }
    }

    func launch(_ ip: String, _ bundle: String) async throws {
        try await run(ip) { try await self.request("_launchApp", ["_bundleID": bundle]) }
    }

    func apps(_ ip: String) async throws -> [(id: String, name: String)] {
        let c = try await run(ip) { try await self.request("_appList", [:]) }
        return c.compactMap { k, v in (v as? String).map { (id: k, name: $0) } }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func forget(_ ip: String) { AppleTV.save(ip, nil); disconnect() }
}
