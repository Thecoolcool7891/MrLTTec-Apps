import SwiftUI

struct Toast: Equatable {
    let id = UUID()
    let text: String
    let bad: Bool
}

struct Track: Identifiable, Hashable {
    let id: String
    let n: Int
    let title: String
    let artist: String
    let art: URL?
    let songId: String   // Jellyfin id ("" = not on the mini PC)
    let match: String    // normalized title, to find the song that's playing
}

struct Playlist: Identifiable {
    var id: String { name }
    let name: String
    let fav: Bool
    let tracks: [Track]
    var short: String {
        if name == "Other songs" { return "Other" }
        return name.replacingOccurrences(of: "MrLTTec ", with: "")
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// nil = still trying, false = can't reach the server (Tailscale off), true = connected
    @Published var connected: Bool? = nil
    @Published var status: RoomStatus?
    @Published var np: NowPlaying?
    @Published var npAt = Date()
    @Published var nowKey = ""
    @Published var rgb = ""                       // "on" / "off" / "" (unknown or PC asleep)
    @Published var pcWaitUntil = Date.distantPast
    @Published var toast: Toast?
    @Published var showMusic = false
    @Published var lists: [Playlist] = []
    @Published var musicLoading = false
    @Published var musicError = ""
    @Published var lastError = ""   // why the last connect failed (shown small on the Connect screen)
    @Published var onWifi = false   // true = talking to 10.0.0.187 on the home Wi-Fi, false = through Tailscale
    // MrLTTec Music's own state (control port 8790): exact song, position, shuffle, repeat, volume
    @Published var ms: MusicState?
    @Published var msAt = Date()
    @Published var queue: [MusicQueue.Item] = []
    @Published var showNowPlaying = false
    // Gaming PC page
    @Published var showPC = false
    @Published var pcStats: PCStats?
    @Published var pcStatsAt = Date.distantPast
    @Published var pcStatsError = ""
    @Published var showBrightness = false
    /// After an optimistic change, ignore polled state for a moment so the screen doesn't jump back.
    var msHold = Date.distantPast

    private var fails = 0
    private var refreshing = false

    // MARK: connection + polling

    /// Runs for as long as the app is open: polls every 5 s when connected, retries every 3 s when not.
    func run() async {
        while !Task.isCancelled {
            if connected == true { await refresh() } else { await connect() }
            let secs: UInt64 = connected == true ? 5 : 3
            try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
        }
    }

    func connect() async {
        do {
            let (h, s) = try await API.find()
            API.host = h
            onWifi = h == API.lanHost
            status = s
            fails = 0
            withAnimation { connected = true }
            lastError = ""
            await refresh()
        } catch {
            lastError = error.localizedDescription
            withAnimation { connected = false }
        }
    }

    func refresh() async {
        if refreshing { return }
        refreshing = true
        defer { refreshing = false }
        do {
            status = try await API.status()
            fails = 0
        } catch {
            // Left home (Wi-Fi gone) or came home: try both addresses before giving up.
            if let found = try? await API.find() {
                API.host = found.0
                onWifi = found.0 == API.lanHost
                status = found.1
                fails = 0
            } else {
                fails += 1
                if fails >= 2 { withAnimation { connected = false } }
                return
            }
        }
        // On Tailscale but maybe back home: switch to Wi-Fi when it answers (faster, works without Tailscale).
        if !onWifi, (try? await API.status(at: API.lanHost, timeout: 1.5)) != nil {
            API.host = API.lanHost
            onWifi = true
        }
        await refreshNowPlaying()
        if musicOpen || ms != nil { await refreshMusic() }
        if status?.pc?.on == true {
            if let r = try? await API.main("/pc?v=rgb", timeout: 8), r == "on" || r == "off" { rgb = r }
        } else {
            rgb = ""
        }
        if lists.isEmpty && !musicLoading { Task { await loadMusic() } }
        LiveNowPlaying.update(self)
    }

    func refreshNowPlaying() async {
        guard let n = try? await API.nowPlaying() else { return }
        np = n
        npAt = Date()
        nowKey = (n.app == musicPackage && !(n.title ?? "").isEmpty) ? Match.title(n.title ?? "") : ""
    }

    func say(_ text: String, bad: Bool = false) {
        let t = Toast(text: text, bad: bad)
        withAnimation(.snappy) { toast = t }
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if toast?.id == t.id { withAnimation(.snappy) { toast = nil } }
        }
    }

    // MARK: lights and plugs

    func light(_ key: String) -> RoomStatus.LightInfo? { status?.lights?[key] }

    func toggleLight(_ key: String) {
        let on = light(key)?.on ?? false
        setLight(key, ["on": !on])
    }

    func setLight(_ key: String, _ body: [String: Any]) {
        Haptic.tap()
        if let on = body["on"] as? Bool { status?.lights?[key]?.on = on }
        if let b = body["brightness"] as? Int { status?.lights?[key]?.brightness = b }
        Task {
            do { try await API.post("/lights/\(key)", body) } catch { say(error.localizedDescription, bad: true) }
            await refresh()
        }
    }

    func togglePlug(_ which: String) {
        Haptic.tap()
        var on = true
        if which == "monitor" {
            on = !(status?.monitor?.on ?? false)
            status?.monitor?.on = on
        } else {
            on = !(status?.leds?.on ?? false)
            status?.leds?.on = on
        }
        Task {
            do { try await API.post("/\(which)", ["on": on]) } catch { say(error.localizedDescription, bad: true) }
            await refresh()
        }
    }

    // MARK: gaming PC

    var pcWaking: Bool { status?.pc?.on != true && Date() < pcWaitUntil }

    var pcLine: String {
        guard let on = status?.pc?.on else { return "Checking..." }
        if on {
            if rgb == "on" { return "On · RGB lit" }
            if rgb == "off" { return "On · RGB off" }
            return "On"
        }
        return pcWaking ? "Waking up..." : "Asleep"
    }

    func pcPower(_ on: Bool) {
        Haptic.tap()
        if on { pcWaitUntil = Date().addingTimeInterval(60) } else { pcWaitUntil = .distantPast }
        say(on ? "Waking the PC..." : "Putting the PC to sleep...")
        Task {
            do {
                let r = try await API.post("/pc", ["on": on], timeout: 60)
                say((r["message"] as? String) ?? (on ? "Wake signal sent." : "Going to sleep."))
            } catch {
                if on { pcWaitUntil = .distantPast }
                say(error.localizedDescription, bad: true)
            }
            await refresh()
        }
    }

    func toggleRGB() {
        guard status?.pc?.on == true else { return }
        Haptic.tap()
        let prev = rgb
        let on = rgb != "on"
        rgb = on ? "on" : "off"
        Task {
            do {
                let r = try await API.main(on ? "/pc?v=rgb_on" : "/pc?v=rgb_off", timeout: 15)
                if r == "on" || r == "off" { rgb = r }
            } catch {
                rgb = prev
                say(error.localizedDescription, bad: true)
            }
        }
    }

    // MARK: TV

    let musicPackage = "dev.mrlttec.music"
    var tvOn: Bool { np?.power == "on" || status?.tv?.on == true }
    var musicOpen: Bool { np?.power == "on" && np?.app == musicPackage }
    var isPlaying: Bool { np?.state == "playing" }
    var hasMedia: Bool { np?.power == "on" && (np?.state ?? "none") != "none" }

    var npAppLine: String {
        guard let n = np, n.power == "on" else { return "Now playing on the TV" }
        let a = n.appName ?? ""
        return a.isEmpty ? (n.app ?? "Now playing on the TV") : a
    }

    var npTitle: String {
        guard let n = np else { return "Checking the TV..." }
        if n.power != "on" { return "The TV is off" }
        if (n.state ?? "none") == "none" { return "Nothing playing" }
        if let t = n.title, !t.isEmpty { return t }
        return n.state == "playing" ? "Playing" : n.state == "paused" ? "Paused" : "Loading"
    }

    func npSub(at date: Date) -> String {
        guard let n = np, n.power == "on" else { return "" }
        if (n.state ?? "none") == "none" {
            let a = n.appName ?? ""
            return a.isEmpty ? "" : "\(a) is open"
        }
        var parts: [String] = []
        if let s = n.subtitle, !s.isEmpty { parts.append(s) }
        parts.append(n.state == "playing" ? "Playing" : n.state == "paused" ? "Paused" : "Loading")
        if let p = n.positionMs {
            var ms = Double(p)
            if n.state == "playing" { ms += date.timeIntervalSince(npAt) * 1000 }
            let s = max(0, Int(ms / 1000))
            parts.append(String(format: "%d:%02d", s / 60, s % 60))
        }
        return parts.joined(separator: " · ")
    }

    var npArt: URL? {
        if musicOpen, let a = ms?.art, !a.isEmpty { return API.fixHost(a) }
        guard !nowKey.isEmpty else { return nil }
        for l in lists {
            if let t = l.tracks.first(where: { $0.match == nowKey && $0.art != nil }) { return t.art }
        }
        return nil
    }

    func isNow(_ t: Track) -> Bool {
        guard musicOpen else { return false }
        if let id = ms?.id, !id.isEmpty, !t.songId.isEmpty { return t.songId == id }
        return !nowKey.isEmpty && t.match == nowKey
    }

    func key(_ k: String) {
        Haptic.tap()
        if k == "playpause", let st = np?.state, st == "playing" || st == "paused" {
            np?.state = st == "playing" ? "paused" : "playing"
        }
        Task {
            do {
                try await API.key(k)
                try? await Task.sleep(nanoseconds: 900_000_000)
                await refreshNowPlaying()
            } catch { say(error.localizedDescription, bad: true) }
        }
    }

    func tvPower(_ on: Bool) {
        Haptic.tap()
        status?.tv?.on = on
        np?.power = on ? "on" : "off"
        Task {
            do { try await API.post("/tv/power", ["on": on], timeout: 30); say(on ? "TV on." : "TV off.") }
            catch { say(error.localizedDescription, bad: true) }
            await refresh()
        }
    }

    func scene(_ name: String, _ label: String) {
        Haptic.tap()
        say("\(label)...")
        Task {
            do {
                let r = try await API.post("/scene/\(name)", [:], timeout: 60)
                say((r["message"] as? String) ?? "\(label) done.")
            } catch { say(error.localizedDescription, bad: true) }
            await refresh()
        }
    }

    // MARK: MrLTTec Music

    func loadMusic() async {
        if musicLoading { return }
        musicLoading = true
        defer { musicLoading = false }
        do {
            let d = try await API.songs()
            let built = Match.build(d)
            lists = built
            musicError = built.isEmpty ? "No songs yet." : ""
        } catch {
            musicError = error.localizedDescription
        }
    }

    func play(_ t: Track, fav: Bool) {
        guard !t.songId.isEmpty else { return }
        Haptic.tap()
        let arg = fav ? "\(t.songId):\(t.n - 1)" : t.songId
        // Show it right away; the TV catches up.
        var s = ms ?? MusicState()
        s.id = t.songId; s.title = t.title; s.artist = t.artist; s.playing = true; s.positionMs = 0
        s.art = t.art?.absoluteString ?? s.art
        ms = s; msAt = Date(); msHold = Date().addingTimeInterval(2.5)
        np?.app = musicPackage; np?.power = "on"; np?.state = "playing"; np?.title = t.title
        nowKey = t.match
        Task {
            do {
                try await API.playSong(arg)
            } catch { say(error.localizedDescription, bad: true) }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await refreshNowPlaying()
            await refreshMusic()
        }
    }
}

/// Matches the Apple playlists to the Jellyfin songs, the same way the web page and the sync dashboard do.
enum Match {
    static func rx(_ s: String, _ pattern: String, _ with: String = "") -> String {
        s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
    }

    static func norm(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive], locale: nil).lowercased()
        t = rx(t, "\\(.*?\\)|\\[.*?\\]")
        t = rx(t, "\\s+-\\s+.*$")
        t = rx(t, ":\\s.*$")
        t = rx(t, "[^a-z0-9]")
        return t
    }

    static func artists(_ s: String) -> [String] {
        let split = rx(s.lowercased(), ",|&|/|;|\\bfeat\\.?|\\bft\\.?|\\bfeaturing\\b|\\bwith\\b|\\bx\\b", "\u{1}")
        return split.components(separatedBy: "\u{1}").map { norm(rx($0, "^\\s*the\\s+")) }.filter { !$0.isEmpty }
    }

    static func title(_ s: String) -> String { norm(rx(s, "^\\s*\\d{1,3}\\.\\s+")) }

    static func same(_ x: String, _ y: String) -> Bool {
        x == y || (min(x.count, y.count) >= 4 && (x.contains(y) || y.contains(x)))
    }

    static func str(_ v: Any?) -> String { (v as? String) ?? "" }

    static func artURL(_ s: String) -> URL? {
        if s.isEmpty { return nil }
        let u = s.replacingOccurrences(of: "{w}", with: "200").replacingOccurrences(of: "{h}", with: "200").replacingOccurrences(of: "{f}", with: "jpg")
        return URL(string: u)
    }

    static func build(_ data: Data) -> [Playlist] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var lib: [[String: Any]] = []
        if let a = root["library"] as? [[String: Any]] {
            lib = a
        } else if let o = root["library"] as? [String: Any], let a = o["items"] as? [[String: Any]] {
            lib = a
        }
        var byTitle: [String: [[String: Any]]] = [:]
        for it in lib { byTitle[title(str(it["title"])), default: []].append(it) }

        var used = Set<String>()
        var out: [Playlist] = []
        let pls = ((root["playlist"] as? [String: Any])?["playlists"] as? [[String: Any]]) ?? []
        for (pi, p) in pls.enumerated() {
            let name = str(p["name"])
            var tracks: [Track] = []
            let raw = (p["tracks"] as? [[String: Any]]) ?? []
            for (i, tr) in raw.enumerated() {
                let tTitle = str(tr["title"])
                let tArtist = str(tr["artist"])
                let key = title(tTitle)
                let want = artists(tArtist)
                let cands = byTitle[key] ?? []
                let hit = cands.first { it in
                    let have = artists(str(it["artist"]))
                    return want.isEmpty || have.isEmpty || want.contains { a in have.contains { b in same(a, b) } }
                }
                var sid = ""
                if let h = hit { sid = str(h["id"]) }
                if !sid.isEmpty { used.insert(sid) }
                tracks.append(Track(id: "\(pi)-\(i)", n: i + 1, title: tTitle, artist: tArtist,
                                    art: artURL(str(tr["art"])), songId: sid, match: key))
            }
            out.append(Playlist(name: name, fav: name.lowercased().contains("favorites"), tracks: tracks))
        }

        // "All songs": every song on the mini PC (Jellyfin), A to Z, with the playlist cover when there is one.
        var artBy: [String: URL] = [:]
        for p in out {
            for t in p.tracks where !t.songId.isEmpty {
                if let a = t.art, artBy[t.songId] == nil { artBy[t.songId] = a }
            }
        }
        var all: [[String]] = []
        for it in lib {
            let sid = str(it["id"])
            if sid.isEmpty { continue }
            all.append([rx(str(it["title"]), "^\\s*\\d{1,3}\\.\\s+"), str(it["artist"]), sid])
        }
        all.sort { $0[0].localizedCaseInsensitiveCompare($1[0]) == .orderedAscending }
        var everything: [Track] = []
        for (i, a) in all.enumerated() {
            let art = artBy[a[2]] ?? URL(string: "http://\(API.host):8096/Items/\(a[2])/Images/Primary?maxHeight=200")
            everything.append(Track(id: "a-\(i)", n: i + 1, title: a[0], artist: a[1], art: art, songId: a[2], match: title(a[0])))
        }
        _ = used
        if !everything.isEmpty { out.append(Playlist(name: "All songs", fav: false, tracks: everything)) }
        return out
    }
}
