import Foundation
import CryptoKit

/// AirPlay 2 with pairing (HAP over HTTP on port 7000), so Apple TVs and AirPlay TVs accept videos, music and photos.
/// Pair once with the PIN the TV shows. After pair-verify the connection is encrypted (ChaCha20-Poly1305, HAP framing).
/// The TV stops playing when the connection closes, so it's kept open while the app is running.
final class AirPlay2 {
    static let shared = AirPlay2()

    struct Creds: Codable { var ltsk: Data; var pairingId: String }

    private let q = DispatchQueue(label: "mrl.airplay")
    private var stream: LowNet.Stream?
    private var ip = ""
    private var writeKey: SymmetricKey?
    private var readKey: SymmetricKey?
    private var writeCount: UInt64 = 0
    private var readCount: UInt64 = 0
    private var readBuf: [UInt8] = []
    private var srp: SRPClient?
    private var salt: [UInt8] = []
    private var serverB: [UInt8] = []

    static func creds(_ ip: String) -> Creds? {
        guard let d = UserDefaults.standard.data(forKey: "ap.\(ip)") else { return nil }
        return try? JSONDecoder().decode(Creds.self, from: d)
    }
    static func save(_ ip: String, _ c: Creds?) {
        if let c, let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: "ap.\(ip)") }
        else { UserDefaults.standard.removeObject(forKey: "ap.\(ip)") }
    }
    static func isPaired(_ ip: String) -> Bool { creds(ip) != nil }

    // MARK: Plain / encrypted byte transport

    private func close() {
        stream = nil; ip = ""; writeKey = nil; readKey = nil; writeCount = 0; readCount = 0; readBuf = []
    }

    private func connect(_ to: String) throws {
        close()
        do { stream = try LowNet.Stream(to, 7000, connectMs: 3000) }
        catch { throw AppError("The device didn't answer on the AirPlay port (7000). Is it on?") }
        stream?.setTimeout(10000)
        ip = to
    }

    private static func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var b = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { b[4 + i] = UInt8((n >> (8 * UInt64(i))) & 255) }
        return try ChaChaPoly.Nonce(data: b)
    }

    private func send(_ bytes: [UInt8]) throws {
        guard let s = stream else { throw AppError("Not connected.") }
        guard let k = writeKey else { try s.write(bytes); return }
        var i = 0
        var out: [UInt8] = []
        while i < bytes.count {
            let n = min(1024, bytes.count - i)
            let aad: [UInt8] = [UInt8(n & 255), UInt8(n >> 8)]
            let box = try ChaChaPoly.seal(Data(bytes[i..<(i + n)]), using: k, nonce: AirPlay2.nonce(writeCount), authenticating: Data(aad))
            writeCount += 1
            out += aad + [UInt8](box.ciphertext) + [UInt8](box.tag)
            i += n
        }
        try s.write(out)
    }

    /// Reads at least one more chunk of plaintext into readBuf.
    private func fill() throws {
        guard let s = stream else { throw AppError("Not connected.") }
        guard let k = readKey else { readBuf += try s.read(1); return }
        let lb = try s.read(2)
        let n = Int(lb[0]) | Int(lb[1]) << 8
        let body = try s.read(n + 16)
        let box = try ChaChaPoly.SealedBox(nonce: AirPlay2.nonce(readCount), ciphertext: body.prefix(n), tag: body.suffix(16))
        readCount += 1
        readBuf += [UInt8](try ChaChaPoly.open(box, using: k, authenticating: Data(lb)))
    }

    // MARK: HTTP over that transport

    struct Response { let status: Int; let headers: [String: String]; let body: [UInt8] }

    private func request(_ method: String, _ path: String, body: [UInt8] = [], type: String? = nil, extra: [String: String] = [:]) throws -> Response {
        var h = "\(method) \(path) HTTP/1.1\r\nUser-Agent: AirPlay/550.10\r\nContent-Length: \(body.count)\r\n"
        if let type { h += "Content-Type: \(type)\r\n" }
        for (k, v) in extra { h += "\(k): \(v)\r\n" }
        h += "\r\n"
        try send(Array(h.utf8) + body)
        // read headers
        while true {
            if let r = readBuf.firstRange(of: [13, 10, 13, 10]) {
                let head = String(decoding: readBuf[..<r.lowerBound], as: UTF8.self)
                readBuf.removeSubrange(..<r.upperBound)
                let lines = head.components(separatedBy: "\r\n")
                let status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
                var headers: [String: String] = [:]
                for l in lines.dropFirst() {
                    if let c = l.firstIndex(of: ":") { headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) }
                }
                let len = Int(headers["content-length"] ?? "0") ?? 0
                while readBuf.count < len { try fill() }
                let b = Array(readBuf.prefix(len))
                readBuf.removeFirst(len)
                return Response(status: status, headers: headers, body: b)
            }
            try fill()
        }
    }

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            q.async {
                do { c.resume(returning: try work()) }
                catch { self.close(); c.resume(throwing: error) }
            }
        }
    }

    private static func hkdf(_ ikm: [UInt8], _ salt: String, _ info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
    }
    private static func seal(_ pt: [UInt8], _ key: SymmetricKey, _ label: String) throws -> [UInt8] {
        let b = try ChaChaPoly.seal(Data(pt), using: key, nonce: ChaChaPoly.Nonce(data: [0, 0, 0, 0] + Array(label.utf8)))
        return [UInt8](b.ciphertext) + [UInt8](b.tag)
    }
    private static func open(_ ct: [UInt8], _ key: SymmetricKey, _ label: String) throws -> [UInt8] {
        guard ct.count >= 16 else { throw AppError("Bad encrypted data from the device.") }
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: [0, 0, 0, 0] + Array(label.utf8)), ciphertext: ct.dropLast(16), tag: ct.suffix(16))
        return [UInt8](try ChaChaPoly.open(box, using: key))
    }

    private func tlvRequest(_ path: String, _ items: [(UInt8, [UInt8])]) throws -> [UInt8: [UInt8]] {
        let r = try request("POST", path, body: TLV8.encode(items), type: "application/octet-stream", extra: ["X-Apple-HKP": "3"])
        guard r.status == 200 else {
            if r.status == 470 || r.status == 403 { throw AppError("The device asked for a PIN. Tap Start pairing first.") }
            throw AppError("The device answered \(r.status) during pairing.")
        }
        let t = TLV8.decode(r.body)
        if let e = t[0x07]?.first {
            throw AppError(e == 2 ? "Wrong PIN. Start pairing again and type the new PIN." : "The device refused pairing (error \(e)).")
        }
        return t
    }

    // MARK: Pairing

    func startPairing(_ to: String) async throws {
        try await onQueue {
            try self.connect(to)
            _ = try? self.request("POST", "/pair-pin-start")
            let m2 = try self.tlvRequest("/pair-setup", [(0x00, [0x00]), (0x06, [0x01])])
            guard let s = m2[0x02], let b = m2[0x03] else { throw AppError("The device didn't start pairing.") }
            self.salt = s; self.serverB = b
            self.srp = SRPClient()
        }
    }

    func finishPairing(_ to: String, pin: String) async throws {
        try await onQueue {
            guard let srp = self.srp, self.ip == to else { throw AppError("Tap Start pairing first so the TV shows a PIN.") }
            self.srp = nil
            let r = try srp.respond(salt: self.salt, B: self.serverB, pin: pin)
            let m4 = try self.tlvRequest("/pair-setup", [(0x06, [0x03]), (0x03, r.a), (0x04, r.m1)])
            guard m4[0x04] == srp.serverProof(m1: r.m1, k: r.k) else { throw AppError("Wrong PIN. Start pairing again and type the new PIN.") }
            let signing = Curve25519.Signing.PrivateKey()
            let ltpk = [UInt8](signing.publicKey.rawRepresentation)
            let pid = UUID().uuidString.uppercased()
            let x = AirPlay2.hkdf(r.k, "Pair-Setup-Controller-Sign-Salt", "Pair-Setup-Controller-Sign-Info").withUnsafeBytes { [UInt8]($0) }
            let enc = AirPlay2.hkdf(r.k, "Pair-Setup-Encrypt-Salt", "Pair-Setup-Encrypt-Info")
            let sig = [UInt8](try signing.signature(for: Data(x + Array(pid.utf8) + ltpk)))
            let inner = TLV8.encode([(0x01, Array(pid.utf8)), (0x03, ltpk), (0x0A, sig)])
            let m6 = try self.tlvRequest("/pair-setup", [(0x06, [0x05]), (0x05, try AirPlay2.seal(inner, enc, "PS-Msg05"))])
            if let e6 = m6[0x05] { _ = try AirPlay2.open(e6, enc, "PS-Msg06") }
            AirPlay2.save(to, Creds(ltsk: signing.rawRepresentation, pairingId: pid))
            self.close()
        }
    }

    private func verify(_ to: String) throws {
        guard let cr = AirPlay2.creds(to) else { throw AppError("Pair with this device first.") }
        try connect(to)
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = [UInt8](eph.publicKey.rawRepresentation)
        let m2 = try tlvRequest("/pair-verify", [(0x06, [0x01]), (0x03, ephPub)])
        guard let spub = m2[0x03], let enc2 = m2[0x05] else { throw AppError("The device didn't answer the secure check.") }
        let shared = try eph.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: spub)).withUnsafeBytes { [UInt8]($0) }
        let sess = AirPlay2.hkdf(shared, "Pair-Verify-Encrypt-Salt", "Pair-Verify-Encrypt-Info")
        _ = try AirPlay2.open(enc2, sess, "PV-Msg02")
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: cr.ltsk)
        let sig = [UInt8](try signing.signature(for: Data(ephPub + Array(cr.pairingId.utf8) + spub)))
        let enc3 = try AirPlay2.seal(TLV8.encode([(0x01, Array(cr.pairingId.utf8)), (0x0A, sig)]), sess, "PV-Msg03")
        do { _ = try tlvRequest("/pair-verify", [(0x06, [0x03]), (0x05, enc3)]) }
        catch {
            AirPlay2.save(to, nil)
            throw AppError("The device no longer knows this iPhone. Pair again.")
        }
        writeKey = AirPlay2.hkdf(shared, "Control-Salt", "Control-Write-Encryption-Key")
        readKey = AirPlay2.hkdf(shared, "Control-Salt", "Control-Read-Encryption-Key")
        writeCount = 0; readCount = 0; readBuf = []
    }

    private func ensure(_ to: String) throws {
        if stream != nil, ip == to, writeKey != nil { return }
        try verify(to)
    }

    func forget(_ to: String) { AirPlay2.save(to, nil); q.async { if self.ip == to { self.close() } } }

    // MARK: Media

    func playURL(_ to: String, _ url: URL) async throws {
        try await onQueue {
            try self.ensure(to)
            let plist: [String: Any] = ["Content-Location": url.absoluteString, "Start-Position": 0.0, "Start-Position Seconds": 0.0,
                                        "uuid": UUID().uuidString.uppercased(), "streamType": 1, "mediaType": "file", "volume": 1.0, "rate": 1.0,
                                        "clientBundleID": "com.mrlttec.smarthome", "clientProcName": "MrLTTec Home", "model": "iPhone17,1",
                                        "playbackRestrictions": 0, "mightSupportStorePastisKeyRequests": false]
            let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            let r = try self.request("POST", "/play", body: [UInt8](body), type: "application/x-apple-binary-plist")
            guard (200...299).contains(r.status) else { throw AppError("The device didn't accept the video (HTTP \(r.status)).") }
        }
    }

    func showPhoto(_ to: String, jpeg: Data) async throws {
        try await onQueue {
            try self.ensure(to)
            let r = try self.request("PUT", "/photo", body: [UInt8](jpeg), type: "image/jpeg",
                                     extra: ["X-Apple-AssetKey": UUID().uuidString, "X-Apple-Transition": "Dissolve"])
            guard (200...299).contains(r.status) else { throw AppError("The device didn't accept the photo (HTTP \(r.status)).") }
        }
    }

    func control(_ to: String, _ cmd: String) async throws {
        try await onQueue {
            try self.ensure(to)
            let path: String
            switch cmd {
            case "play": path = "/rate?value=1.000000"
            case "pause": path = "/rate?value=0.000000"
            case "stop": path = "/stop"
            default: throw AppError("Command not allowed.")
            }
            let r = try self.request("POST", path)
            guard (200...299).contains(r.status) else { throw AppError("The device answered \(r.status).") }
            if cmd == "stop" { self.close() }
        }
    }
}
