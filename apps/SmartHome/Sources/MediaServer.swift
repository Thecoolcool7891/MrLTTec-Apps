import Foundation
import Network

/// A tiny web server on the phone so a TV or speaker can pull a photo, video or song from it.
/// Supports Range requests (TVs seek in videos with them). Only serves files you picked.
final class MediaServer {
    static let shared = MediaServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 8796
    private var files: [String: (url: URL, type: String)] = [:]
    private let q = DispatchQueue(label: "mrl.media")

    /// Makes `file` downloadable and returns the URL a device on `ip`'s network should use.
    func publish(_ file: URL, type: String, for ip: String) throws -> URL {
        try start()
        let clean = file.lastPathComponent.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let name = String(UUID().uuidString.prefix(8)) + "-" + clean
        q.sync { files[name] = (file, type) }
        let net = ip.split(separator: ".").prefix(3).joined(separator: ".")
        let addrs = LowNet.localAddrs()
        guard let me = addrs.first(where: { $0.hasPrefix(net + ".") }) ?? addrs.first else {
            throw AppError("This iPhone isn't on Wi-Fi, so the TV can't reach it.")
        }
        guard let u = URL(string: "http://\(me):\(port)/\(name)") else { throw AppError("Couldn't make a link for that file.") }
        return u
    }

    private func start() throws {
        if listener != nil { return }
        var lastError: Error?
        for p in [UInt16(8796), 8797, 8798, 18796] {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: p)!)
                l.newConnectionHandler = { [weak self] c in self?.handle(c) }
                l.start(queue: q)
                listener = l
                port = p
                return
            } catch { lastError = error }
        }
        throw AppError("Couldn't start the file sharing on this iPhone (\(lastError?.localizedDescription ?? "unknown")).")
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: q)
        readHeader(c, Data())
    }

    private func readHeader(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            if let data { b.append(data) }
            if let r = b.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(c, String(decoding: b[..<r.lowerBound], as: UTF8.self))
            } else if done || err != nil || b.count > 32768 {
                c.cancel()
            } else {
                self.readHeader(c, b)
            }
        }
    }

    private func respond(_ c: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { c.cancel(); return }
        let method = String(parts[0])
        let name = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
        guard let f = files[name], let h = try? FileHandle(forReadingFrom: f.url),
              let size = (try? FileManager.default.attributesOfItem(atPath: f.url.path)[.size] as? NSNumber)?.int64Value else {
            send(c, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true)
            return
        }
        var start: Int64 = 0, end: Int64 = size - 1, partial = false
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let m = range.firstMatch(of: #/bytes=(\d*)-(\d*)/#) {
            if let a = Int64(m.1) {
                start = a
                if let b = Int64(m.2) { end = min(b, size - 1) }
            } else if let b = Int64(m.2) {
                start = max(0, size - b)
            }
            partial = true
        }
        if start > end || start >= size {
            send(c, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", close: true)
            try? h.close()
            return
        }
        let len = end - start + 1
        var hdr = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        hdr += "Content-Type: \(f.type)\r\nContent-Length: \(len)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
        hdr += "transferMode.dlna.org: Streaming\r\ncontentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n"
        if partial { hdr += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        hdr += "\r\n"
        c.send(content: Data(hdr.utf8), completion: .contentProcessed { [weak self] e in
            guard e == nil, method != "HEAD" else { try? h.close(); c.cancel(); return }
            try? h.seek(toOffset: UInt64(start))
            self?.pump(c, h, left: len)
        })
    }

    private func pump(_ c: NWConnection, _ h: FileHandle, left: Int64) {
        if left <= 0 { try? h.close(); c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
        let n = Int(min(left, 256 * 1024))
        guard let chunk = try? h.read(upToCount: n), !chunk.isEmpty else { try? h.close(); c.cancel(); return }
        c.send(content: chunk, completion: .contentProcessed { [weak self] e in
            if e != nil { try? h.close(); c.cancel(); return }
            self?.pump(c, h, left: left - Int64(chunk.count))
        })
    }

    private func send(_ c: NWConnection, _ s: String, close: Bool) {
        c.send(content: Data(s.utf8), completion: .contentProcessed { _ in if close { c.cancel() } })
    }
}
