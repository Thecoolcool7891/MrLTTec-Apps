import SwiftUI

/// TV tab: power, a remote and the room scenes.
struct RemoteView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("TV").font(.system(size: 34, weight: .bold)).foregroundStyle(Tan.text)
                    .padding(.horizontal, 18).padding(.top, 8)

                HStack(spacing: 10) {
                    IconBox(symbol: "tv")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Fire TV").font(.system(size: 16, weight: .semibold)).foregroundStyle(Tan.text)
                        Text(m.tvOn ? "On" : "Off or asleep").font(.system(size: 12)).foregroundStyle(Tan.muted)
                    }
                    Spacer()
                    TanSwitch(on: m.tvOn) { m.tvPower(!m.tvOn) }
                }
                .tanCard()
                .padding(.horizontal, 12)

                VStack(spacing: 18) {
                    HStack(spacing: 18) {
                        RemoteKey(symbol: "arrow.uturn.backward", key: "back")
                        RemoteKey(symbol: "house", key: "home")
                        RemoteKey(symbol: "line.3.horizontal", key: "menu")
                    }
                    DPad()
                    HStack(spacing: 18) {
                        RemoteKey(symbol: "backward.fill", key: "rewind")
                        RemoteKey(symbol: "playpause.fill", key: "playpause")
                        RemoteKey(symbol: "forward.fill", key: "ffwd")
                    }
                    HStack(spacing: 18) {
                        RemoteKey(symbol: "speaker.minus", key: "voldown")
                        RemoteKey(symbol: "speaker.slash", key: "mute")
                        RemoteKey(symbol: "speaker.plus", key: "volup")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .tanCard()
                .padding(.horizontal, 12)

                Text("Scenes").font(.system(size: 18, weight: .bold)).foregroundStyle(Tan.text)
                    .padding(.horizontal, 18).padding(.top, 6)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    SceneTile(symbol: "house", name: "Normal", scene: "normal")
                    SceneTile(symbol: "chevron.left.forwardslash.chevron.right", name: "Matrix", scene: "matrix")
                    SceneTile(symbol: "pawprint", name: "Snoopy", scene: "snoopy")
                    SceneTile(symbol: "film", name: "Movie lights", scene: "")
                    SceneTile(symbol: "bolt", name: "All on", scene: "room-on")
                    SceneTile(symbol: "moon", name: "All off", scene: "room-off")
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
    }
}

struct RemoteKey: View {
    @EnvironmentObject var m: AppModel
    let symbol: String
    let key: String
    var body: some View {
        Button { m.key(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Tan.chipText)
                .frame(width: 58, height: 58)
                .background(Tan.chip, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct DPad: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        ZStack {
            Circle().fill(Tan.chip).frame(width: 200, height: 200)
            VStack {
                arrow("chevron.up", "up")
                Spacer()
                arrow("chevron.down", "down")
            }
            .frame(height: 190)
            HStack {
                arrow("chevron.left", "left")
                Spacer()
                arrow("chevron.right", "right")
            }
            .frame(width: 190)
            Button { m.key("select") } label: {
                Text("OK")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Tan.card)
                    .frame(width: 78, height: 78)
                    .background(Tan.brown, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 200, height: 200)
    }

    private func arrow(_ symbol: String, _ key: String) -> some View {
        Button { m.key(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Tan.chipText)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A scene button. "Movie lights" (empty scene name) is the movie-mode switch instead.
struct SceneTile: View {
    @EnvironmentObject var m: AppModel
    let symbol: String
    let name: String
    let scene: String
    @State private var movieOn: Bool? = nil

    var body: some View {
        Tile(symbol: symbol, tint: movieOn == true ? Tan.gold : Tan.brown, name: name, sub: subText) {
            if scene.isEmpty { toggleMovie() } else { m.scene(scene, name) }
        }
        .task { if scene.isEmpty { await loadMovie() } }
    }

    private var subText: String {
        if !scene.isEmpty { return "Tap to run" }
        guard let on = movieOn else { return "Checking..." }
        return on ? "On · dims for videos" : "Off"
    }

    private func loadMovie() async {
        if let d = try? await API.request(8768, "/movie", timeout: 8),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            movieOn = o["on"] as? Bool
        }
    }

    private func toggleMovie() {
        Haptic.tap()
        let on = !(movieOn ?? false)
        movieOn = on
        Task {
            do {
                try await API.post("/movie", ["on": on])
                m.say(on ? "Movie lights on: the lights dim while a video plays." : "Movie lights off.")
            } catch {
                movieOn = !on
                m.say(error.localizedDescription, bad: true)
            }
        }
    }
}
