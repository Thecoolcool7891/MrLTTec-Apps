import SwiftUI

struct HomeView: View {
    @EnvironmentObject var m: AppModel
    @EnvironmentObject var updater: Updater
    @State private var filter = "All"

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 12 { return "Good morning, Landon" }
        if h < 17 { return "Good afternoon, Landon" }
        return "Good evening, Landon"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                UpdateBanner(updater: updater).padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting).font(.system(size: 14)).foregroundStyle(Tan.muted)
                    Text("Home").font(.system(size: 34, weight: .bold)).foregroundStyle(Tan.text)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 4)

                HStack(spacing: 6) {
                    ForEach(["All", "Lights", "Media"], id: \.self) { f in
                        Button {
                            Haptic.tap()
                            withAnimation(.snappy) { filter = f }
                        } label: {
                            Text(f)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(filter == f ? Tan.card : Tan.chipText)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 6)
                                .background(filter == f ? Tan.brown : Tan.chip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

                if filter != "Lights" {
                    NowPlayingCard().padding(.horizontal, 12)
                    PCCard().padding(.horizontal, 12)
                }
                if filter != "Media" {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        LightTile(key: "light1", fallback: "Light 1")
                        LightTile(key: "light2", fallback: "Light 2")
                        PlugTile(which: "monitor")
                        PlugTile(which: "leds")
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .refreshable { await m.refresh() }
    }
}

struct NowPlayingCard: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconBox(symbol: "tv")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Now playing").font(.system(size: 16, weight: .semibold)).foregroundStyle(Tan.text)
                    Text(m.npAppLine).font(.system(size: 12)).foregroundStyle(Tan.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button {
                    Haptic.tap()
                    m.showMusic = true
                } label: {
                    Pill(text: "Music", icon: "music.note",
                         bg: m.musicOpen ? Tan.greenBg : Tan.chip, fg: m.musicOpen ? Tan.greenFg : Tan.chipText)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                ArtBox(url: m.npArt, size: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.npTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(m.npSub(at: ctx.date)).font(.system(size: 12)).foregroundStyle(Tan.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 40) {
                NPKey(symbol: "backward.fill", key: "rewind")
                NPKey(symbol: m.musicPlaying ? "pause.fill" : "play.fill", key: "playpause")
                NPKey(symbol: "forward.fill", key: "ffwd")
            }
            .frame(maxWidth: .infinity)
            .disabled(!m.tvOn)
            .opacity(m.tvOn ? 1 : 0.4)
        }
        .tanCard()
        .contentShape(Rectangle())
        .onTapGesture {
            Haptic.tap()
            m.showNowPlaying = true
        }
    }
}

struct NPKey: View {
    @EnvironmentObject var m: AppModel
    let symbol: String
    let key: String
    var body: some View {
        Button {
            switch key {
            case "playpause": m.togglePlay()
            case "rewind": m.previousSong()
            case "ffwd": m.nextSong()
            default: m.key(key)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(Tan.chipText)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Gaming PC: a bit smaller than the other cards, with the spinning rainbow fan and a smaller switch.
struct PCCard: View {
    @EnvironmentObject var m: AppModel
    @State private var confirmSleep = false

    var body: some View {
        let on = m.status?.pc?.on == true
        HStack(spacing: 10) {
            IconBox(symbol: "desktopcomputer", size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Gaming PC").font(.system(size: 17, weight: .semibold)).foregroundStyle(Tan.text)
                Text(m.pcLine).font(.system(size: 13)).foregroundStyle(Tan.muted)
            }
            Spacer(minLength: 6)
            FanButton(size: 42)
            TanSwitch(on: on || m.pcWaking, scale: 1.05) {
                if on { confirmSleep = true } else { m.pcPower(true) }
            }
            .padding(.leading, 4)
        }
        .tanCard(padding: 15)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptic.tap()
            m.showPC = true
        }
        .confirmationDialog("Put the Gaming PC to sleep?", isPresented: $confirmSleep, titleVisibility: .visible) {
            Button("Sleep", role: .destructive) { m.pcPower(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It might be in a game.")
        }
    }
}

/// The CPU cooler's RGB light. Spins whenever the PC is on; gray when the RGB is off; faded and not pressable while asleep.
struct FanButton: View {
    @EnvironmentObject var m: AppModel
    var size: CGFloat = 30

    var body: some View {
        let enabled = m.status?.pc?.on == true
        let lit = m.rgb == "on"
        Button { m.toggleRGB() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Tan.dark)
                TimelineView(.animation(minimumInterval: nil, paused: !enabled)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    RainbowFan()
                        .rotationEffect(.degrees(enabled ? t.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360 : 0))
                }
                .frame(width: size * 0.76, height: size * 0.76)
                .grayscale(lit ? 0 : 1)
                .brightness(lit ? 0 : -0.15)
            }
            .frame(width: size, height: size)
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(lit ? "Turn the PC's RGB off" : "Turn the PC's RGB on")
    }
}

struct Tile: View {
    let symbol: String
    let tint: Color
    let name: String
    let sub: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(tint).frame(height: 26)
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text).padding(.top, 4)
                Text(sub).font(.system(size: 12)).foregroundStyle(Tan.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tanCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LightTile: View {
    @EnvironmentObject var m: AppModel
    let key: String
    let fallback: String

    var body: some View {
        let l = m.light(key)
        let on = l?.on == true
        let offline = l?.online == false
        var sub = "Checking..."
        if offline { sub = "Offline" } else if let o = l?.on { sub = o ? "On · \(l?.brightness ?? 100)%" : "Off" } else if l != nil { sub = "Unknown" }
        var tint = Tan.faint
        if on {
            if l?.mode == "color", let hx = l?.hex, let c = Color(hexString: hx) { tint = c } else { tint = Tan.gold }
        }
        return Tile(symbol: on ? "lightbulb.fill" : "lightbulb", tint: tint, name: l?.name ?? fallback, sub: sub) {
            m.toggleLight(key)
        }
        .disabled(offline)
        .opacity(offline ? 0.5 : 1)
        .contextMenu {
            Button { m.setLight(key, ["on": true, "white": 92]) } label: { Label("Warm white", systemImage: "sun.max") }
            Button { m.setLight(key, ["on": true, "color": "purple"]) } label: { Label("Purple", systemImage: "circle.fill") }
            Button { m.setLight(key, ["on": true, "color": "green"]) } label: { Label("Green", systemImage: "circle.fill") }
            Button { m.setLight(key, ["on": true, "color": "blue"]) } label: { Label("Blue", systemImage: "circle.fill") }
            Button { m.setLight(key, ["on": true, "color": "red"]) } label: { Label("Red", systemImage: "circle.fill") }
            Divider()
            Button { m.setLight(key, ["on": true, "brightness": 100]) } label: { Label("100% bright", systemImage: "sun.max.fill") }
            Button { m.setLight(key, ["on": true, "brightness": 50]) } label: { Label("50% bright", systemImage: "sun.min") }
            Button { m.setLight(key, ["on": true, "brightness": 15]) } label: { Label("15% bright", systemImage: "moon") }
        }
    }
}

struct PlugTile: View {
    @EnvironmentObject var m: AppModel
    let which: String   // "monitor" or "leds"

    var body: some View {
        let p = which == "monitor" ? m.status?.monitor : m.status?.leds
        let on = p?.on == true
        let offline = p?.online == false
        var sub = "Checking..."
        if offline { sub = "Offline" } else if let o = p?.on {
            if o { sub = which == "leds" ? "On · \(p?.brightness ?? 100)%" : "On" } else { sub = "Off" }
        } else if p != nil { sub = "Unknown" }
        let name = which == "monitor" ? "Monitor" : "Monitor LEDs"
        let symbol = which == "monitor" ? (on ? "powerplug.fill" : "powerplug") : "sparkles"
        return Tile(symbol: symbol, tint: on ? Tan.gold : Tan.faint, name: name, sub: sub) {
            m.togglePlug(which)
        }
        .disabled(offline)
        .opacity(offline ? 0.5 : 1)
    }
}
