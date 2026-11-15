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
    /// The mini PC on the home Wi-Fi. Always tried first, so at home it works without Tailscale.
    static let lanHost = "10.0.0.187"
    static let tvIp = "10.0.0.238"

    /// The Tailscale address (or the one typed in Settings).
    static var tailscaleHost: String {
        let h = (UserDefaults.standard.string(forKey: "serverHost") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? defaultHost : h
    }

    /// The address that answered last (set by find()); every request goes here.
    static var host: String = defaultHost

    /// Tries the home Wi-Fi address and Tailscale at the same time. Wi-Fi wins if it answers.
    /// Returns the address that worked and its status, or throws the Tailscale error.
    static func find() async throws -> (String, RoomStatus) {
        let ts = tailscaleHost
        let lanAddr = lanHost
        async let lan: Result<RoomStatus, Error> = result { try await API.status(at: lanAddr, timeout: 2.5) }
        async let tail: Result<RoomStatus, Error> = result { try await API.status(at: ts, timeout: 6) }
        if case .success(let s) = await lan { return (lanAddr, s) }
        switch await tail {
        case .success(let s): return (ts, s)
        case .failure(let e): throw e
        }
    }

    static func result<T>(_ f: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    static func status(at h: String, timeout: TimeInterval) async throws -> RoomStatus {
        let d = try await request(8768, "/status", timeout: timeout, at: h)
        return try JSONDecoder().decode(RoomStatus.self, from: d)
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func request(_ port: Int, _ path: String, method: String = "GET", json: [String: Any]? = nil,
                        timeout: TimeInterval = 20, at: String? = nil) async throws -> Data {
        guard let u = URL(string: "http://\(at ?? host):\(port)\(path)") else { throw APIError(message: "The server address is not valid.") }
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

    static func enc(_ s: String) -> String {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? ""
    }

    /// A TV command through the main app's adb route: a key ("input", "home"...) or "app" / "text" with an argument.
    static func adb(_ v: String, _ t: String = "", timeout: TimeInterval = 20) async throws {
        var path = "/adb?ip=\(tvIp)&v=\(enc(v))"
        if !t.isEmpty { path += "&t=\(enc(t))" }
        _ = try await main(path, timeout: timeout)
    }

    // MARK: MrLTTec Music control port (TV :8790)

    /// MrLTTec Music's control port. At home the phone talks to the TV directly (fastest); otherwise the
    /// mini PC passes it through (/tvmusic/remote). GET for state/queue, POST for commands.
    static func music(_ v: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 6) async throws -> Data {
        let get = v == "state" || v == "queue"
        if host == lanHost {
            if let d = try? await direct(v, body, get: get) { return d }
        }
        return try await request(8765, "/tvmusic/remote?v=\(v)", method: get ? "GET" : "POST",
                                 json: get ? nil : (body ?? [:]), timeout: timeout)
    }

    private static func direct(_ v: String, _ body: [String: Any]?, get: Bool) async throws -> Data {
        guard let u = URL(string: "http://\(tvIp):8790/\(v)") else { throw APIError(message: "bad url") }
        var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        r.httpMethod = get ? "GET" : "POST"
        if !get {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        }
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code < 200 || code >= 300 { throw APIError(message: errorText(d, code)) }
        return d
    }

    static func musicState() async throws -> MusicState {
        try JSONDecoder().decode(MusicState.self, from: try await music("state", timeout: 6))
    }

    static func musicQueue() async throws -> MusicQueue {
        try JSONDecoder().decode(MusicQueue.self, from: try await music("queue", timeout: 8))
    }

    // MARK: Gaming PC helper (through the main app's /pc route)

    static func pcStats() async throws -> PCStats {
        let d = try await request(8765, "/pc?v=stats", method: "POST", timeout: 12)
        return try JSONDecoder().decode(PCStats.self, from: d)
    }

    static func pcLaunch(_ id: String) async throws {
        _ = try await main("/pc?v=launch&a=\(enc(id))", timeout: 15)
    }
}

/// MrLTTec Music's GET /state.
struct MusicState: Decodable, Equatable {
    var playing: Bool?
    var id: String?
    var title: String?
    var artist: String?
    var album: String?
    var art: String?
    var positionMs: Double?
    var durationMs: Double?
    var list: String?
    var index: Int?
    var queueLength: Int?
    var shuffle: Bool?
    var repeatOn: Bool?
    var volume: Double?

    enum CodingKeys: String, CodingKey {
        case playing, id, title, artist, album, art, positionMs, durationMs, list, index, queueLength, shuffle, volume
        case repeatOn = "repeat"
    }
}

struct MusicQueue: Decodable {
    struct Item: Decodable, Identifiable, Hashable {
        var id: String
        var title: String?
        var artist: String?
    }
    var list: String?
    var index: Int?
    var items: [Item]?
}

/// The gaming PC helper's GET /stats (see PROMPT-pc-helper-stats.md on the mini PC). Every value may be missing.
struct PCStats: Decodable {
    struct Chip: Decodable { var name: String?; var tempC: Double?; var loadPct: Double? }
    struct Ram: Decodable { var usedGB: Double?; var totalGB: Double? }
    struct Net: Decodable { var name: String?; var downMbps: Double?; var upMbps: Double? }
    struct Drive: Decodable, Identifiable {
        var name: String?
        var label: String?
        var freeGB: Double?
        var totalGB: Double?
        var id: String { (name ?? "") + "|" + (label ?? "") }
    }
    var cpu: Chip?
    var gpu: Chip?
    var ram: Ram?
    var net: Net?
    var drives: [Drive]?
    var uptimeSec: Double?
    var running: [String]?
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
