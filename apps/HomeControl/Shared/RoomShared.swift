import Foundation
import AppIntents
#if canImport(ActivityKit)
import ActivityKit
#endif

// Shared by the app and the widget extension (widgets, Live Activity, Control Center button).

/// The Lock Screen / Dynamic Island now-playing card.
struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var app: String
        var playing: Bool
        /// When the song started (now - position) and when it ends; nil when unknown.
        var start: Date?
        var end: Date?
    }
    var name: String
}

/// Small server client for the widget extension (it can't see the app's settings): home Wi-Fi first, then Tailscale.
enum RoomLink {
    static let lan = "10.0.0.187"
    static let tailscale = "100.67.247.123"

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func call(_ port: Int, _ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> Data {
        var last: Error = URLError(.cannotConnectToHost)
        for (host, wait) in [(lan, 1.5), (tailscale, 6.0)] {
            guard let u = URL(string: "http://\(host):\(port)\(path)") else { continue }
            var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: wait)
            r.httpMethod = method
            if let json = json {
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try? JSONSerialization.data(withJSONObject: json)
            } else if method == "POST" {
                r.httpBody = Data()
            }
            do {
                let (d, resp) = try await session.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code >= 200 && code < 300 { return d }
                last = URLError(.badServerResponse)
            } catch { last = error }
        }
        throw last
    }

    static func json(_ d: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:]
    }

    static func status() async throws -> [String: Any] { json(try await call(8768, "/status")) }

    /// Both lights: off if either is on, otherwise on.
    static func toggleLights() async throws {
        let s = try await status()
        let lights = (s["lights"] as? [String: Any]) ?? [:]
        let anyOn = lights.values.contains { (($0 as? [String: Any])?["on"] as? Bool) == true }
        for key in ["light1", "light2"] {
            _ = try? await call(8768, "/lights/\(key)", method: "POST", json: ["on": !anyOn])
        }
    }

    static func toggleTV() async throws {
        let s = try await status()
        let on = ((s["tv"] as? [String: Any])?["on"] as? Bool) ?? false
        _ = try await call(8768, "/tv/power", method: "POST", json: ["on": !on])
    }

    static func toggleMovie() async throws {
        let o = json(try await call(8768, "/movie"))
        let on = (o["on"] as? Bool) ?? false
        _ = try await call(8768, "/movie", method: "POST", json: ["on": !on])
    }

    static func allOff() async throws {
        _ = try await call(8768, "/scene/room-off", method: "POST", json: [:])
    }

    /// Play/pause: MrLTTec Music's own toggle when it answers, otherwise the TV key.
    static func playPause() async throws {
        if (try? await call(8765, "/tvmusic/remote?v=toggle", method: "POST", json: [:])) != nil { return }
        _ = try await call(8768, "/tv/key", method: "POST", json: ["key": "playpause"])
    }

    static func next() async throws {
        if (try? await call(8765, "/tvmusic/remote?v=next", method: "POST", json: [:])) != nil { return }
        _ = try await call(8768, "/tv/key", method: "POST", json: ["key": "ffwd"])
    }
}

struct ToggleLightsIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle the lights"
    static var description = IntentDescription("Turns Light 1 and Light 2 on or off together.")
    func perform() async throws -> some IntentResult {
        try await RoomLink.toggleLights()
        return .result()
    }
}

struct ToggleTVIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle the TV"
    func perform() async throws -> some IntentResult {
        try await RoomLink.toggleTV()
        return .result()
    }
}

struct ToggleMovieIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle movie lights"
    func perform() async throws -> some IntentResult {
        try await RoomLink.toggleMovie()
        return .result()
    }
}

struct AllOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn the room off"
    func perform() async throws -> some IntentResult {
        try await RoomLink.allOff()
        return .result()
    }
}

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or pause the TV"
    func perform() async throws -> some IntentResult {
        try await RoomLink.playPause()
        return .result()
    }
}

struct NextSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Next song on the TV"
    func perform() async throws -> some IntentResult {
        try await RoomLink.next()
        return .result()
    }
}
