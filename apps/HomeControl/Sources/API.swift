import Foundation

/// Talks to the MrLTTec server on the mini PC. It is only reachable through Tailscale
/// (or the home Wi-Fi), so anyone else who installs the app just sees "Connect to Tailscale".
///  - port 8768: the room API (status, lights, monitor, LEDs, TV, PC, scenes) - see TV-API-Guide.md on the server
///  - port 8765: the main app (what's playing on the TV, the PC's RGB fan, MrLTTec Music)
struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum API {
    /// The mini PC's Tailscale address. Can be changed in Settings.
    static let defaultHost = "100.67.247.123"
    static let tvIp = "10.0.0.238"

    static var host: String {
        let h = (UserDefaults.standard.string(forKey: "serverHost") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? defaultHost : h
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func request(_ port: Int, _ path: String, method: String = "GET", json: [String: Any]? = nil,
                        timeout: TimeInterval = 20) async throws -> Data {
        guard let u = URL(string: "http://\(host):\(port)\(path)") else { throw APIError(message: "The server address is not valid.") }
        var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = method
        if let json = json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code < 200 || code >= 300 { throw APIError(message: errorText(data, code)) }
        return data
    }

    static func errorText(_ d: Data, _ code: Int) -> String {
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let e = o["error"] as? String, !e.isEmpty { return e }
        let t = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && t.count < 300 && !t.hasPrefix("<") { return t }
        return "The server answered \(code)."
    }

    // MARK: room API (8768)

    static func status(timeout: TimeInterval = 8) async throws -> RoomStatus {
        let d = try await request(8768, "/status", timeout: timeout)
        return try JSONDecoder().decode(RoomStatus.self, from: d)
    }

    @discardableResult
    static func post(_ path: String, _ body: [String: Any] = [:], timeout: TimeInterval = 20) async throws -> [String: Any] {
        let d = try await request(8768, path, method: "POST", json: body, timeout: timeout)
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    static func key(_ k: String) async throws {
        try await post("/tv/key", ["key": k])
    }

    // MARK: main app (8765)

    /// POST to the main app; it answers with plain text.
    static func main(_ path: String, timeout: TimeInterval = 20) async throws -> String {
        let d = try await request(8765, path, method: "POST", timeout: timeout)
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nowPlaying() async throws -> NowPlaying {
        let d = try await request(8765, "/adb?ip=\(tvIp)&v=nowplaying", method: "POST", timeout: 15)
        return try JSONDecoder().decode(NowPlaying.self, from: d)
    }

    static func songs() async throws -> Data {
        try await request(8765, "/tvmusic/songs", timeout: 30)
    }

    /// `t` is a Jellyfin id, or "id:index" for a song from the Favorites list.
    static func playSong(_ t: String) async throws {
        _ = try await main("/adb?ip=\(tvIp)&v=musicplay&t=\(t)", timeout: 30)
    }
}

// MARK: - Replies

struct RoomStatus: Decodable {
    struct LightInfo: Decodable {
        var name: String?
        var online: Bool?
        var on: Bool?
        var brightness: Int?
        var mode: String?
        var white: Int?
        var hex: String?
    }
    struct Plug: Decodable {
        var name: String?
        var online: Bool?
        var on: Bool?
        var brightness: Int?
    }
    struct PCInfo: Decodable { var on: Bool? }

    var lights: [String: LightInfo]?
    var monitor: Plug?
    var tv: Plug?
    var pc: PCInfo?
    var leds: Plug?
}

struct NowPlaying: Decodable, Equatable {
    var power: String?
    var app: String?
    var appName: String?
    var state: String?
    var title: String?
    var subtitle: String?
    var positionMs: Int?
}
