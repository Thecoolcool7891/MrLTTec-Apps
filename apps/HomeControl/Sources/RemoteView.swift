import SwiftUI
import UIKit

/// TV tab: one full remote tile (power, input, D-pad, keys), the TV apps, typing, and the room scenes.
struct RemoteView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("TV").font(.system(size: 34, weight: .bold)).foregroundStyle(Tan.text)
                    .padding(.horizontal, 18).padding(.top, 8)

                RemoteCard().padding(.horizontal, 12)

                Text("Apps").font(.system(size: 18, weight: .bold)).foregroundStyle(Tan.text)
                    .padding(.horizontal, 18).padding(.top, 6)
                TVAppsRow().padding(.horizontal, 12)

                TypeOnTV().padding(.horizontal, 12)

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
        .scrollDismissesKeyboard(.immediately)
    }
}

/// The whole remote in one tile.
struct RemoteCard: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Button { m.tvPower(!m.tvOn) } label: {
                    Image(systemName: "power")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(Color(hex: 0xD9342B), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(m.tvOn ? "Turn the TV off" : "Turn the TV on")
                Spacer()
                VStack(spacing: 1) {
                    Text("Living room TV").font(.system(size: 16, weight: .semibold)).foregroundStyle(Tan.text)
                    HStack(spacing: 5) {
                        Circle().fill(m.tvOn ? Tan.switchOn : Tan.faint).frame(width: 7, height: 7)
                        Text(m.tvOn ? "On" : "Off").font(.system(size: 12)).foregroundStyle(Tan.muted)
                    }
                }
                Spacer()
                Button { m.key("input") } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Tan.chipText)
                        .frame(width: 50, height: 50)
                        .background(Tan.chip, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Input")
            }

            DPad()

            HStack(spacing: 14) {
                RemoteKey(symbol: "arrow.uturn.backward", key: "back")
                RemoteKey(symbol: "house", key: "home")
                RemoteKey(symbol: "line.3.horizontal", key: "menu")
                RemoteKey(symbol: "playpause.fill", key: "playpause")
            }

            HStack(spacing: 0) {
                volKey("speaker.minus", "voldown")
                Rectangle().fill(Tan.line).frame(width: 0.5, height: 22)
                volKey("speaker.slash", "mute")
                Rectangle().fill(Tan.line).frame(width: 0.5, height: 22)
                volKey("speaker.plus", "volup")
            }
            .background(Tan.chip, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .tanCard()
    }

    private func volKey(_ symbol: String, _ key: String) -> some View {
        Button { m.key(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Tan.chipText)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RemoteKey: View {
    @EnvironmentObject var m: AppModel
    let symbol: String
    let key: String
    var body: some View {
        Button {
            if key == "playpause" { m.togglePlay() } else { m.key(key) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Tan.chipText)
                .frame(width: 56, height: 56)
                .background(Tan.chip, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct DPad: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        ZStack {
            Circle().fill(Tan.chip).frame(width: 210, height: 210)
            VStack {
                arrow("chevron.up", "up")
                Spacer()
                arrow("chevron.down", "down")
            }
            .frame(height: 200)
            HStack {
                arrow("chevron.left", "left")
                Spacer()
                arrow("chevron.right", "right")
            }
            .frame(width: 200)
            Button { m.key("select") } label: {
                Text("OK")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Tan.card)
                    .frame(width: 82, height: 82)
                    .background(Tan.brown, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 210, height: 210)
    }

    private func arrow(_ symbol: String, _ key: String) -> some View {
        Button { m.key(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Tan.chipText)
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// YouTube, MrLTTec Music, MrLTTec Live TV and MovieBox, with Landon's own icons.
struct TVAppsRow: View {
    @EnvironmentObject var m: AppModel
    private let apps: [[String]] = [
        ["app-youtube.png", "YouTube", "com.amazon.firetv.youtube"],
        ["app-music.webp", "MrLTTec Music", "dev.mrlttec.music"],
        ["app-livetv.webp", "MrLTTec Live TV", "dev.mrlttec.livetv"],
        ["app-moviebox.webp", "MovieBox", "com.community.mbox.tv"],
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(apps, id: \.self) { a in
                Button { m.openApp(a[2], a[1]) } label: {
                    VStack(spacing: 6) {
                        BundleIcon(file: a[0], size: 62)
                        Text(a[1]).font(.system(size: 11, weight: .medium)).foregroundStyle(Tan.text)
                            .multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .tanCard()
    }
}

/// Types text into whatever box is focused on the TV (search fields, sign-ins).
struct TypeOnTV: View {
    @EnvironmentObject var m: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard").foregroundStyle(Tan.faint)
            TextField("Type on TV…", text: $text)
                .foregroundStyle(Tan.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Tan.card)
                    .frame(width: 32, height: 32)
                    .background(text.isEmpty ? Tan.faint : Tan.brown, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
        }
        .font(.system(size: 15))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Tan.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Tan.line, lineWidth: 0.5))
    }

    private func send() {
        if m.typeOnTV(text) { text = "" }
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
