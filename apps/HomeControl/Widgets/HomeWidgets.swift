import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit

// MrLTTec Control's widgets: Now Playing, the 2x2 room buttons, the Lock Screen / Dynamic Island
// now-playing card, and the Control Center light buttons.

enum WTan {
    static let bg = Color(red: 0xEF / 255, green: 0xE2 / 255, blue: 0xD0 / 255)
    static let card = Color(red: 0xFB / 255, green: 0xF5 / 255, blue: 0xEC / 255)
    static let chip = Color(red: 0xE6 / 255, green: 0xD3 / 255, blue: 0xBA / 255)
    static let text = Color(red: 0x3B / 255, green: 0x27 / 255, blue: 0x17 / 255)
    static let muted = Color(red: 0x8A / 255, green: 0x6A / 255, blue: 0x50 / 255)
    static let brown = Color(red: 0x8B / 255, green: 0x5A / 255, blue: 0x35 / 255)
    static let dark = Color(red: 0x3B / 255, green: 0x27 / 255, blue: 0x17 / 255)
    static let gold = Color(red: 0xC9 / 255, green: 0x8A / 255, blue: 0x00 / 255)
}

@main
struct HomeWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        RoomButtonsWidget()
        NowPlayingLiveActivity()
        LightsControl()
        BrightnessControl()
    }
}

// MARK: - Now Playing widget

struct NPEntry: TimelineEntry {
    let date: Date
    let title: String
    let sub: String
    let playing: Bool
    let on: Bool
}

struct NPProvider: TimelineProvider {
    func placeholder(in context: Context) -> NPEntry {
        NPEntry(date: Date(), title: "Inolvidable", sub: "Luis Miguel", playing: true, on: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NPEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NPEntry>) -> Void) {
        Task {
            let e = await load()
            completion(Timeline(entries: [e], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    private func load() async -> NPEntry {
        // MrLTTec Music first (exact song), then the TV's media session.
        if let d = try? await RoomLink.call(8765, "/tvmusic/remote?v=state") {
            let o = RoomLink.json(d)
            if let t = o["title"] as? String, !t.isEmpty {
                return NPEntry(date: Date(), title: t, sub: (o["artist"] as? String) ?? "MrLTTec Music",
                               playing: (o["playing"] as? Bool) ?? false, on: true)
            }
        }
        guard let d = try? await RoomLink.call(8765, "/adb?ip=10.0.0.238&v=nowplaying", method: "POST") else {
            return NPEntry(date: Date(), title: "Can't reach home", sub: "Wi-Fi or Tailscale", playing: false, on: false)
        }
        let o = RoomLink.json(d)
        let on = (o["power"] as? String) == "on"
        let state = (o["state"] as? String) ?? "none"
        let app = (o["appName"] as? String) ?? ""
        if !on { return NPEntry(date: Date(), title: "The TV is off", sub: "", playing: false, on: false) }
        if state == "none" { return NPEntry(date: Date(), title: "Nothing playing", sub: app, playing: false, on: true) }
        let title = (o["title"] as? String) ?? ""
        return NPEntry(date: Date(), title: title.isEmpty ? (state == "playing" ? "Playing" : "Paused") : title,
                       sub: app, playing: state == "playing", on: true)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NPProvider()) { e in
            NPWidgetView(e: e)
                .containerBackground(WTan.card, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("What's playing on the TV, with play/pause and next.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NPWidgetView: View {
    let e: NPEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "music.note.tv")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WTan.card)
                    .frame(width: 26, height: 26)
                    .background(WTan.brown, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Now playing").font(.system(size: 12, weight: .semibold)).foregroundStyle(WTan.muted)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Text(e.title).font(.system(size: family == .systemSmall ? 15 : 17, weight: .bold)).foregroundStyle(WTan.text).lineLimit(2)
            if !e.sub.isEmpty {
                Text(e.sub).font(.system(size: 12)).foregroundStyle(WTan.muted).lineLimit(1)
            }
            HStack(spacing: 8) {
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: e.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(WTan.card)
                        .frame(width: 34, height: 34)
                        .background(WTan.brown, in: Circle())
                }
                .buttonStyle(.plain)
                Button(intent: NextSongIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(WTan.text)
                        .frame(width: 34, height: 34)
                        .background(WTan.chip, in: Circle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .opacity(e.on ? 1 : 0.4)
        }
    }
}

// MARK: - 2x2 room buttons

struct SimpleEntry: TimelineEntry { let date: Date }

struct SimpleProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) { completion(SimpleEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry(date: Date())], policy: .never))
    }
}

struct RoomButtonsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RoomButtons", provider: SimpleProvider()) { _ in
            RoomButtonsView()
                .containerBackground(WTan.card, for: .widget)
        }
        .configurationDisplayName("Room")
        .description("Lights, Movie lights, TV and All off.")
        .supportedFamilies([.systemSmall])
    }
}

struct RoomButtonsView: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                cell(ToggleLightsIntent(), "lightbulb.fill", "Lights", WTan.gold)
                cell(ToggleMovieIntent(), "film", "Movie", WTan.brown)
            }
            HStack(spacing: 8) {
                cell(ToggleTVIntent(), "tv", "TV", WTan.brown)
                cell(AllOffIntent(), "moon.fill", "Off", WTan.dark)
            }
        }
    }

    private func cell<I: AppIntent>(_ intent: I, _ symbol: String, _ name: String, _ tint: Color) -> some View {
        Button(intent: intent) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
                Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(WTan.text)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WTan.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Lock Screen + Dynamic Island

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { ctx in
            LockScreenNP(s: ctx.state)
                .activityBackgroundTint(WTan.card)
                .activitySystemActionForegroundColor(WTan.brown)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(WTan.gold)
                        .frame(width: 40, height: 40)
                        .background(WTan.brown, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ctx.state.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(ctx.state.artist.isEmpty ? ctx.state.app : ctx.state.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: ctx.state.playing ? "pause.fill" : "play.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .tint(WTan.gold)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let a = ctx.state.start, let b = ctx.state.end, b > a, ctx.state.playing {
                        ProgressView(timerInterval: a...b, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                            .tint(WTan.gold)
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note").foregroundStyle(WTan.gold)
            } compactTrailing: {
                Image(systemName: ctx.state.playing ? "waveform" : "pause.fill").foregroundStyle(WTan.gold)
            } minimal: {
                Image(systemName: "music.note").foregroundStyle(WTan.gold)
            }
        }
    }
}

struct LockScreenNP: View {
    let s: NowPlayingAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(WTan.card)
                    .frame(width: 50, height: 50)
                    .background(WTan.brown, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.app.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(WTan.muted)
                    Text(s.title).font(.system(size: 16, weight: .bold)).foregroundStyle(WTan.text).lineLimit(1)
                    if !s.artist.isEmpty {
                        Text(s.artist).font(.system(size: 13)).foregroundStyle(WTan.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Button(intent: PlayPauseIntent()) {
                    Image(systemName: s.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(WTan.card)
                        .frame(width: 42, height: 42)
                        .background(WTan.brown, in: Circle())
                }
                .buttonStyle(.plain)
                Button(intent: NextSongIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(WTan.text)
                        .frame(width: 42, height: 42)
                        .background(WTan.chip, in: Circle())
                }
                .buttonStyle(.plain)
            }
            if let a = s.start, let b = s.end, b > a, s.playing {
                ProgressView(timerInterval: a...b, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(WTan.brown)
            }
        }
        .padding(14)
    }
}

// MARK: - Control Center

/// Tap: both lights on/off.
struct LightsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.mrlttec.homecontrol.lights") {
            ControlWidgetButton(action: ToggleLightsIntent()) {
                Label("Lights", systemImage: "lightbulb.2.fill")
            }
        }
        .displayName("Room lights")
        .description("Turns both lights on or off.")
    }
}

/// Opens MrLTTec Control on the brightness sliders (Control Center buttons can't show a slider themselves).
struct BrightnessControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.mrlttec.homecontrol.brightness") {
            ControlWidgetButton(action: OpenBrightnessIntent()) {
                Label("Brightness", systemImage: "sun.max.fill")
            }
        }
        .displayName("Light brightness")
        .description("Opens the brightness sliders in MrLTTec Control.")
    }
}

struct OpenBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource = "Light brightness"
    static var openAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "mrlttec-control://brightness")!))
    }
}
