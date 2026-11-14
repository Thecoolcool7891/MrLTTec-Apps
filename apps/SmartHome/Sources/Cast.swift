import Foundation
import Network
import Security

// Casting, ported from Tool-App.ps1: Google Cast (CastV2 over TLS on 8009), DLNA players (UPnP AVTransport),
// YouTube over DIAL, and old-style AirPlay (port 7000).

struct CastTarget: Identifiable, Hashable {
    let ip: String
    var name: String
    var avt: String = ""          // DLNA AVTransport control URL
    var dial: String = ""         // DIAL application URL that can launch YouTube
    var cast = false
    var air = false
    var music = false             // Sonos: DLNA is music only
    var id: String { ip }
    var kinds: [String] {
        var k: [String] = []
        if !avt.isEmpty { k.append("DLNA") }
        if cast { k.append("Google Cast") }
        if !dial.isEmpty { k.append("YouTube") }
        if air { k.append("AirPlay") }
        return k
    }
    var methods: [String] {
        var m: [String] = []
        if !avt.isEmpty { m.append("dlna") }
        if cast { m.append("cast") }
        if air { m.append("airplay") }
        return m
    }
}

// MARK: - Google Cast protocol

final class CastSession {
    private let conn: NWConnection
    private let q = DispatchQueue(label: "mrl.cast")
    private var requestId = 0
    static let recv = "urn:x-cast:com.google.cast.receiver"
    static let connNs = "urn:x-cast:com.google.cast.tp.connection"
    static let media = "urn:x-cast:com.google.cast.media"

    init(_ ip: String) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, DispatchQueue.global())
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        conn = NWConnection(host: NWEndpoint.Host(ip), port: 8009, using: NWParameters(tls: tls, tcp: tcp))
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            let finish: (Result<Void, Error>) -> Void = { r in
                if done { return }
                done = true
                c.resume(with: r)
            }
            conn.stateUpdateHandler = { s in
                switch s {
                case .ready: finish(.success(()))
                case .failed(let e): finish(.failure(AppError("Secure connection to the Cast device failed (\(e.localizedDescription)).")))
                case .waiting(let e): finish(.failure(AppError("The device did not answer on the Cast port (\(e.localizedDescription)).")))
                case .cancelled: finish(.failure(AppError("The Cast connection closed.")))
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + 6) { finish(.failure(AppError("The device did not answer on the Cast port (8009)."))) }
        }
        try await send("receiver-0", Self.connNs, "{\"type\":\"CONNECT\"}")
    }

    func close() { conn.cancel() }

    // Protobuf CastMessage: version, source, destination, namespace, payload_type=STRING, payload_utf8.
    private static func pbString(_ field: UInt8, _ s: String) -> [UInt8] {
        let b = [UInt8](s.utf8)
        var out: [UInt8] = [(field << 3) | 2]
        var n = b.count
        while n >= 128 { out.append(UInt8(n & 127) | 128); n >>= 7 }
        out.append(UInt8(n))
        return out + b
    }

    func send(_ dst: String, _ ns: String, _ payload: String) async throws {
        var m: [UInt8] = [8, 0]
        m += Self.pbString(2, "sender-0") + Self.pbString(3, dst) + Self.pbString(4, ns) + [40, 0] + Self.pbString(6, payload)
        let len = UInt32(m.count)
        let frame = Data([UInt8(len >> 24), UInt8((len >> 16) & 255), UInt8((len >> 8) & 255), UInt8(len & 255)] + m)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: frame, completion: .contentProcessed { e in
                if let e { c.resume(throwing: AppError("Cast send failed: \(e.localizedDescription)")) } else { c.resume() }
            })
        }
    }

    func request(_ dst: String, _ ns: String, _ body: [String: Any]) async throws {
        requestId += 1
        var b = body
        b["requestId"] = requestId
        let d = try JSONSerialization.data(withJSONObject: b)
        try await send(dst, ns, String(decoding: d, as: UTF8.self))
    }

    private func readExact(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, err in
                if let data, data.count == n { c.resume(returning: data) }
                else { c.resume(throwing: AppError(err?.localizedDescription ?? "The device closed the connection.")) }
            }
        }
    }

    private func readMessage() async throws -> (src: String, ns: String, payload: String) {
        let h = [UInt8](try await readExact(4))
        let len = Int(h[0]) << 24 | Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
        guard len > 0, len < 1_048_576 else { throw AppError("Unexpected answer from the device.") }
        let b = [UInt8](try await readExact(len))
        var i = 0, src = "", ns = "", payload = ""
        func varint() -> Int {
            var v = 0, shift = 0
            while i < b.count { let x = b[i]; i += 1; v |= Int(x & 127) << shift; shift += 7; if x & 128 == 0 { break } }
            return v
        }
        while i < b.count {
            let tag = varint()
            let wt = tag & 7, fn = tag >> 3
            if wt == 0 { _ = varint() }
            else if wt == 2 {
                let l = varint()
                guard i + l <= b.count else { break }
                let s = String(decoding: b[i..<(i + l)], as: UTF8.self)
                i += l
                if fn == 2 { src = s } else if fn == 4 { ns = s } else if fn == 6 { payload = s }
            } else { break }
        }
        return (src, ns, payload)
    }

    /// Reads messages (answering keep-alive pings) until `test` matches. Gives up after `seconds`.
    func wait(_ seconds: Double, _ test: @escaping ([String: Any]) -> Bool) async -> [String: Any]? {
        let cancelWork = DispatchWorkItem { [conn] in conn.cancel() }
        q.asyncAfter(deadline: .now() + seconds, execute: cancelWork)
        defer { cancelWork.cancel() }
        while true {
            guard let m = try? await readMessage() else { return nil }
            if m.ns.hasSuffix("heartbeat") && m.payload.contains("PING") { try? await send(m.src, m.ns, "{\"type\":\"PONG\"}"); continue }
            if let j = (try? JSONSerialization.jsonObject(with: Data(m.payload.utf8))) as? [String: Any], test(j) { return j }
        }
    }

    func status() async throws -> [String: Any] {
        try await request("receiver-0", Self.recv, ["type": "GET_STATUS"])
        guard let r = await wait(5, { $0["type"] as? String == "RECEIVER_STATUS" }), let s = r["status"] as? [String: Any] else {
            throw AppError("The device didn't report its status.")
        }
        return s
    }
}

enum Cast {
    private static func session(_ ip: String) async throws -> CastSession {
        let s = CastSession(ip)
        try await s.open()
        return s
    }

    static func volume(_ ip: String, _ v: String) async throws {
        let s = try await session(ip); defer { s.close() }
        let st = try await s.status()
        guard let vol = st["volume"] as? [String: Any] else { throw AppError("This device doesn't report a volume.") }
        let lvl = (vol["level"] as? Double) ?? 0.5
        var set: [String: Any] = [:]
        if v == "volup" { set["level"] = min(1, lvl + 0.05) }
        else if v == "voldown" { set["level"] = max(0, lvl - 0.05) }
        else { set["muted"] = !((vol["muted"] as? Bool) ?? false) }
        try await s.request("receiver-0", CastSession.recv, ["type": "SET_VOLUME", "volume": set])
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Plays a URL with the built-in Default Media Receiver (CC1AD845).
    static func load(_ ip: String, url: URL, type: String) async throws {
        let s = try await session(ip); defer { s.close() }
        let st = try await s.status()
        func app(_ status: [String: Any]) -> [String: Any]? {
            (status["applications"] as? [[String: Any]])?.first { $0["appId"] as? String == "CC1AD845" && $0["transportId"] != nil }
        }
        var cur = app(st)
        if cur == nil {
            try await s.request("receiver-0", CastSession.recv, ["type": "LAUNCH", "appId": "CC1AD845"])
            let r = await s.wait(15) { j in j["type"] as? String == "RECEIVER_STATUS" && app((j["status"] as? [String: Any]) ?? [:]) != nil }
            cur = app((r?["status"] as? [String: Any]) ?? [:])
            if cur == nil { throw AppError("The device didn't start its media player.") }
        }
        let tid = cur?["transportId"] as? String ?? ""
        try await s.send(tid, CastSession.connNs, "{\"type\":\"CONNECT\"}")
        try await s.request(tid, CastSession.media, ["type": "LOAD", "sessionId": cur?["sessionId"] as? String ?? "", "autoplay": true, "currentTime": 0,
                                                       "media": ["contentId": url.absoluteString, "contentType": type, "streamType": "BUFFERED"]])
        let r = await s.wait(12) { j in
            let t = j["type"] as? String ?? ""
            return (t == "MEDIA_STATUS" && !((j["status"] as? [Any]) ?? []).isEmpty) || t == "LOAD_FAILED" || t == "INVALID_REQUEST"
        }
        if let r, r["type"] as? String != "MEDIA_STATUS" {
            throw AppError("The device couldn't load that file. It may not support this format (MP4 with H.264 is the safest).")
        }
    }

    static func control(_ ip: String, _ v: String) async throws {
        let s = try await session(ip); defer { s.close() }
        let st = try await s.status()
        guard let cur = (st["applications"] as? [[String: Any]])?.first(where: { $0["transportId"] != nil }) else { throw AppError("Nothing is playing on this device.") }
        if v == "stop" {
            try await s.request("receiver-0", CastSession.recv, ["type": "STOP", "sessionId": cur["sessionId"] as? String ?? ""])
            try? await Task.sleep(nanoseconds: 200_000_000)
            return
        }
        let tid = cur["transportId"] as? String ?? ""
        try await s.send(tid, CastSession.connNs, "{\"type\":\"CONNECT\"}")
        try await s.request(tid, CastSession.media, ["type": "GET_STATUS"])
        guard let r = await s.wait(5, { $0["type"] as? String == "MEDIA_STATUS" && !(($0["status"] as? [Any]) ?? []).isEmpty }),
              let ms = (r["status"] as? [[String: Any]])?.first else { throw AppError("Nothing is playing on this device.") }
        try await s.request(tid, CastSession.media, ["type": v == "pause" ? "PAUSE" : "PLAY", "mediaSessionId": ms["mediaSessionId"] ?? 0])
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    static func probe(_ ip: String) async -> Bool {
        guard let s = try? await session(ip) else { return false }
        defer { s.close() }
        return (try? await s.status()) != nil
    }
}

// MARK: - DLNA, DIAL, AirPlay

enum Dlna {
    static func call(_ avt: String, _ action: String, _ inner: String) async throws {
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID>\(inner)</u:\(action)></s:Body></s:Envelope>"
        _ = try await Http.call(avt, method: "POST", body: Data(body.utf8), contentType: "text/xml; charset=\"utf-8\"",
                                headers: ["SOAPAction": "\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\""], timeout: 8)
    }

    static func play(_ avt: String, url: URL, type: String, title: String) async throws {
        let cls = type.hasPrefix("image/") ? "object.item.imageItem.photo" : type.hasPrefix("audio/") ? "object.item.audioItem.musicTrack" : "object.item.videoItem"
        let u = xmlEscape(url.absoluteString)
        let didl = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"1\" parentID=\"0\" restricted=\"1\"><dc:title>\(xmlEscape(title))</dc:title><upnp:class>\(cls)</upnp:class><res protocolInfo=\"http-get:*:\(type):*\">\(u)</res></item></DIDL-Lite>"
        try await call(avt, "SetAVTransportURI", "<CurrentURI>\(u)</CurrentURI><CurrentURIMetaData>\(xmlEscape(didl))</CurrentURIMetaData>")
        try await call(avt, "Play", "<Speed>1</Speed>")
    }
}

enum AirPlay1 {
    static func run(_ ip: String, _ cmd: String, url: URL? = nil) async throws {
        do {
            switch cmd {
            case "load":
                _ = try await Http.call("http://\(ip):7000/play", method: "POST", body: Data("Content-Location: \(url?.absoluteString ?? "")\nStart-Position: 0\n".utf8), contentType: "text/parameters", timeout: 8)
            case "play": _ = try await Http.call("http://\(ip):7000/rate?value=1", method: "POST", timeout: 5)
            case "pause": _ = try await Http.call("http://\(ip):7000/rate?value=0", method: "POST", timeout: 5)
            case "stop": _ = try await Http.call("http://\(ip):7000/stop", method: "POST", timeout: 5)
            default: throw AppError("Command not allowed.")
            }
        } catch {
            throw AppError("The AirPlay device didn't accept that. Newer AirPlay 2 devices usually need pairing for this.")
        }
    }
}

enum YouTube {
    static func videoId(_ link: String) -> String? {
        if let m = link.firstMatch(of: #/(?:v=|youtu\.be/|shorts/|embed/|live/)([\w-]{11})/#) { return String(m.1) }
        if link.wholeMatch(of: #/[\w-]{11}/#) != nil { return link }
        return nil
    }
    static func play(_ dial: String, link: String) async throws {
        guard let id = videoId(link.trimmed) else { throw AppError("That doesn't look like a YouTube link.") }
        let base = dial.hasSuffix("/") ? String(dial.dropLast()) : dial
        do {
            _ = try await Http.call(base + "/YouTube", method: "POST", body: Data("v=\(id)".utf8), contentType: "text/plain; charset=\"utf-8\"", timeout: 8)
        } catch let e as HttpStatusError where e.status == 201 {
            return
        }
    }
}

// MARK: - Finding cast targets

enum CastScan {
    static func find() async -> [CastTarget] {
        let ips = LowNet.subnetIps()
        if ips.isEmpty { return [] }
        // 1) SSDP (may be blocked by iOS without Apple's multicast permission; then the port scan below still finds most things).
        let search: [String] = ["urn:schemas-upnp-org:device:MediaRenderer:1", "urn:dial-multiscreen-org:service:dial:1"]
        let msgs = search.map { Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \($0)\r\n\r\n".utf8) }
        // Ask the multicast group, and also every address directly (works even when iOS blocks multicast).
        async let ssdp = (try? await blocking { LowNet.udpSweep(["239.255.255.250"] + ips, port: 1900, payloads: msgs, waitMs: 2500, repeats: 2) }) ?? []
        // 2) Port scan for Cast (8008/8009), AirPlay (7000) and Sonos (1400 has a DLNA player).
        let ports: [UInt16] = [7000, 8008, 8009, 1400]
        let sweep = (try? await blocking { LowNet.tcpSweep(ips.flatMap { ip in ports.map { (ip, $0) } }, timeoutMs: 2000) }) ?? LowNet.SweepResult()

        var dlnaLoc: [String: String] = [:], dialLoc: [String: String] = [:]
        for (_, d) in await ssdp {
            let t = String(decoding: d, as: UTF8.self)
            guard let m = t.firstMatch(of: #/(?im)^LOCATION:\s*(http://([\d.]+)[^\r\n]*)/#) else { continue }
            let loc = String(m.1), ip = String(m.2)
            guard isPrivateIp(ip) else { continue }
            if t.range(of: "MediaRenderer", options: .caseInsensitive) != nil { dlnaLoc[ip] = loc }
            else if t.range(of: "dial", options: .caseInsensitive) != nil { dialLoc[ip] = loc }
        }
        var open: [String: Set<UInt16>] = [:]
        for k in sweep.open {
            let p = k.split(separator: ":")
            if p.count == 2, let port = UInt16(p[1]) { open[String(p[0]), default: []].insert(port) }
        }
        for (ip, ps) in open where ps.contains(1400) && dlnaLoc[ip] == nil { dlnaLoc[ip] = "http://\(ip):1400/xml/device_description.xml" }
        for (ip, ps) in open where ps.contains(8008) && dialLoc[ip] == nil { dialLoc[ip] = "http://\(ip):8008/ssdp/device-desc.xml" }

        let all = Set(dlnaLoc.keys).union(dialLoc.keys).union(open.filter { $0.value.contains(8009) || $0.value.contains(7000) }.keys)
        var out: [CastTarget] = []
        await withTaskGroup(of: CastTarget?.self) { g in
            for ip in all {
                g.addTask { await identify(ip, dlna: dlnaLoc[ip], dial: dialLoc[ip], ports: open[ip] ?? []) }
            }
            for await t in g { if let t { out.append(t) } }
        }
        return out.sorted { ipLess($0.ip, $1.ip) }
    }

    private static func identify(_ ip: String, dlna: String?, dial: String?, ports: Set<UInt16>) async -> CastTarget? {
        var t = CastTarget(ip: ip, name: "")
        if let loc = dlna, let x = try? await Http.call(loc, timeout: 2).text {
            t.name = xmlTag(x, "friendlyName") ?? ""
            if let room = xmlTag(x, "roomName") { t.name = room }
            t.music = (xmlTag(x, "manufacturer") ?? "").contains("Sonos")
            if let rx = try? NSRegularExpression(pattern: "<service>(.*?)</service>", options: [.dotMatchesLineSeparators]) {
                for m in rx.matches(in: x, range: NSRange(x.startIndex..., in: x)) {
                    guard let r = Range(m.range(at: 1), in: x) else { continue }
                    let svc = String(x[r])
                    if (xmlTag(svc, "serviceType") ?? "").contains("AVTransport"), let ctl = xmlTag(svc, "controlURL"),
                       let base = URL(string: loc), let u = URL(string: ctl, relativeTo: base) {
                        t.avt = u.absoluteString
                        break
                    }
                }
            }
        }
        if let loc = dial, let r = try? await Http.call(loc, timeout: 2) {
            if t.name.isEmpty { t.name = xmlTag(r.text, "friendlyName") ?? "" }
            if let app = r.header("Application-URL"), let host = URL(string: app)?.host, isPrivateIp(host) {
                let base = app.hasSuffix("/") ? String(app.dropLast()) : app
                if (try? await Http.call(base + "/YouTube", timeout: 2)) != nil { t.dial = app }
            }
        }
        if ports.contains(8009) {
            if let j = try? await Http.json("http://\(ip):8008/setup/eureka_info?params=name", timeout: 2) {
                t.cast = true
                if t.name.isEmpty { t.name = j["name"] as? String ?? "" }
            } else {
                t.cast = await Cast.probe(ip)
            }
        }
        if ports.contains(7000) { t.air = true }
        if t.avt.isEmpty && t.dial.isEmpty && !t.cast && !t.air { return nil }
        if t.name.isEmpty { t.name = ip }
        t.name = cleanName(t.name)
        return t
    }
}
