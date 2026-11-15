import SwiftUI

extension API {
    /// The TV app gives art links on 10.0.0.187 (Jellyfin). Away from home, point them at the address that works.
    static func fixHost(_ s: String) -> URL? {
        URL(string: s.replacingOccurrences(of: "//\(lanHost):", with: "//\(host):"))
    }
}

/// Music controls, the big Now Playing page, the Gaming PC page and the TV extras.
extension AppModel {

    // MARK: MrLTTec Music (control port)

    func refreshMusic() async {
        do {
            let s = try await API.musicState()
            if Date() >= msHold {
                ms = s
                msAt = Date()
            }
        } catch {
            if !musicOpen { ms = nil }
        }
    }

    func loadQueue() async {
        if let q = try? await API.musicQueue() { queue = q.items ?? [] }
    }

    /// True when the phone can use the TV app's own controls (seek, shuffle, repeat, volume, Up Next).
    var musicControls: Bool { musicOpen && ms != nil }

    var musicPlaying: Bool { musicControls ? (ms?.playing ?? false) : isPlaying }

    var durationMs: Double { max(0, ms?.durationMs ?? 0) }

    /// Where the song is now, counting the time since the last poll while it plays.
    func positionMs(at date: Date) -> Double {
        guard let s = ms else { return 0 }
        var p = s.positionMs ?? 0
        if s.playing == true { p += date.timeIntervalSince(msAt) * 1000 }
        let d = durationMs
        return d > 0 ? min(max(0, p), d) : max(0, p)
    }

    static func clock(_ ms: Double) -> String {
        let s = max(0, Int(ms / 1000))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Sends a command to MrLTTec Music. The screen changes first; the TV follows.
    func musicCmd(_ v: String, _ body: [String: Any] = [:], change: ((inout MusicState) -> Void)? = nil) {
        Haptic.tap()
        if let change = change, var s = ms {
            // keep the position honest before changing play state
            s.positionMs = positionMs(at: Date())
            msAt = Date()
            change(&s)
            ms = s
            msHold = Date().addingTimeInterval(2)
        }
        Task {
            do {
                _ = try await API.music(v, body)
            } catch {
                msHold = .distantPast
                say(error.localizedDescription, bad: true)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            msHold = .distantPast
            await refreshMusic()
            if v == "next" || v == "previous" || v == "shuffle" { await loadQueue() }
        }
    }

    func togglePlay() {
        if musicControls {
            musicCmd("toggle") { $0.playing = !($0.playing ?? false) }
        } else {
            key("playpause")
        }
    }

    func nextSong() {
        if musicControls { musicCmd("next") { $0.positionMs = 0 } } else { key("ffwd") }
    }

    func previousSong() {
        if musicControls { musicCmd("previous") { $0.positionMs = 0 } } else { key("rewind") }
    }

    func seek(_ to: Double) {
        let ms = Int(max(0, to))
        musicCmd("seek", ["ms": ms]) { $0.positionMs = Double(ms) }
    }

    func setMusicVolume(_ v: Double) {
        let value = Int(min(100, max(0, v)))
        musicCmd("volume", ["value": value]) { $0.volume = Double(value) }
    }

    func setShuffle(_ on: Bool) {
        musicCmd("shuffle", ["on": on]) { $0.shuffle = on }
    }

    func setRepeat(_ on: Bool) {
        musicCmd("repeat", ["on": on]) { $0.repeatOn = on }
    }

    /// Plays a random song from the list and turns shuffle on.
    func shufflePlay(_ list: Playlist) {
        let ok = list.tracks.filter { !$0.songId.isEmpty }
        guard let t = ok.randomElement() else { return }
        play(t, fav: list.fav)
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            _ = try? await API.music("shuffle", ["on": true])
            await refreshMusic()
        }
    }

    // MARK: Fire TV direct (ADB from the phone, home Wi-Fi only)

    /// Runs `work` straight on the TV when paired and on the home Wi-Fi. False = use the mini PC instead.
    func viaTV(_ work: () async throws -> Void) async -> Bool {
        guard tvDirect, onWifi else { return false }
        do {
            try await work()
            return true
        } catch {
            return false
        }
    }

    /// One time: the TV asks "Allow USB debugging?" for this iPhone.
    func pairTV() {
        guard onWifi else {
            say("Join the home Wi-Fi first, then pair.", bad: true)
            return
        }
        Haptic.tap()
        tvPairing = true
        TVAdb.shared.allowPairing = true
        say("Look at the TV: tick \"Always allow\" and press OK.")
        Task {
            do {
                _ = try await TVAdb.shared.shell(API.tvIp, "echo ok")
                UserDefaults.standard.set(true, forKey: "tvDirect")
                tvDirect = true
                say("Paired. At home, buttons now go straight to the TV.")
            } catch {
                say(error.localizedDescription, bad: true)
            }
            TVAdb.shared.allowPairing = false
            tvPairing = false
        }
    }

    func setTVDirect(_ on: Bool) {
        Haptic.tap()
        if on {
            pairTV()
        } else {
            UserDefaults.standard.set(false, forKey: "tvDirect")
            tvDirect = false
        }
    }

    // MARK: TV extras

    func openApp(_ package: String, _ name: String) {
        Haptic.tap()
        say("Opening \(name)...")
        if !tvOn { np?.power = "on" }
        Task {
            do {
                let direct = await viaTV({ try await TVAdb.shared.launch(API.tvIp, package) })
                if !direct { try await API.adb("app", package, timeout: 30) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await refreshNowPlaying()
            } catch { say(error.localizedDescription, bad: true) }
        }
    }

    /// Types on the TV. The server only accepts letters, numbers, spaces and . , @ _ + = : / -
    func typeOnTV(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,@_+=:/-")
        let t = String(text.unicodeScalars.filter { allowed.contains($0) }.map(Character.init)).prefix(100)
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else {
            say("Only letters, numbers and simple symbols can be typed.", bad: true)
            return false
        }
        Haptic.tap()
        let s = String(t)
        Task {
            do {
                let direct = await viaTV({ try await TVAdb.shared.text(API.tvIp, s) })
                if !direct { try await API.adb("text", s, timeout: 20) }
                say("Typed on the TV.")
            } catch { say(error.localizedDescription, bad: true) }
        }
        return true
    }

    // MARK: Gaming PC page

    func loadPCStats() async {
        guard status?.pc?.on == true else {
            pcStats = nil
            pcStatsError = ""
            return
        }
        do {
            pcStats = try await API.pcStats()
            pcStatsAt = Date()
            pcStatsError = ""
        } catch {
            pcStatsError = error.localizedDescription
        }
    }

    func launchOnPC(_ id: String, _ name: String) {
        guard status?.pc?.on == true else {
            say("Wake the PC first.", bad: true)
            return
        }
        Haptic.tap()
        say("Opening \(name) on the PC...")
        Task {
            do {
                try await API.pcLaunch(id)
                say("\(name) is opening on the PC.")
            } catch { say(error.localizedDescription, bad: true) }
        }
    }
}
