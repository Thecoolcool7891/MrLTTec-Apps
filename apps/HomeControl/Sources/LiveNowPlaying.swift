import SwiftUI
import ActivityKit

/// Keeps the Lock Screen / Dynamic Island now-playing card in step with the TV while the app runs.
/// iOS pauses the app soon after it leaves the screen, so the card keeps the last song, and its progress bar runs on a timer.
@MainActor
enum LiveNowPlaying {
    private static var last: NowPlayingAttributes.ContentState?

    static func update(_ m: AppModel) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let state = content(m) else {
            end()
            return
        }
        if state == last, !Activity<NowPlayingAttributes>.activities.isEmpty { return }
        last = state
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60))
        if let a = Activity<NowPlayingAttributes>.activities.first {
            Task { await a.update(content) }
        } else {
            _ = try? Activity.request(attributes: NowPlayingAttributes(name: "TV"), content: content, pushType: nil)
        }
    }

    static func end() {
        last = nil
        for a in Activity<NowPlayingAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private static func content(_ m: AppModel) -> NowPlayingAttributes.ContentState? {
        guard m.tvOn, m.hasMedia || m.musicControls else { return nil }
        if m.musicControls, let s = m.ms, let t = s.title, !t.isEmpty {
            let playing = s.playing ?? false
            var start: Date? = nil
            var end: Date? = nil
            if let d = s.durationMs, d > 0 {
                // Round to whole seconds so tiny drifts don't count as changes.
                let st = Date(timeIntervalSince1970: (m.msAt.timeIntervalSince1970 - (s.positionMs ?? 0) / 1000).rounded())
                start = st
                end = st.addingTimeInterval(d / 1000)
            }
            return NowPlayingAttributes.ContentState(title: t, artist: s.artist ?? "", app: "MrLTTec Music", playing: playing, start: start, end: end)
        }
        let title = m.npTitle
        return NowPlayingAttributes.ContentState(title: title, artist: m.np?.subtitle ?? "", app: m.npAppLine, playing: m.isPlaying, start: nil, end: nil)
    }
}

/// Opened by the Control Center "Brightness" button (mrlttec-control://brightness).
struct BrightnessSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Brightness").font(.system(size: 26, weight: .bold)).foregroundStyle(Tan.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Tan.muted)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)
            LightSlider(key: "light1", fallback: "Light 1")
            LightSlider(key: "light2", fallback: "Light 2")
            Spacer()
        }
        .padding(.horizontal, 16)
        .background(Tan.bg.ignoresSafeArea())
    }
}

struct LightSlider: View {
    @EnvironmentObject var m: AppModel
    let key: String
    let fallback: String
    @State private var value: Double? = nil

    var body: some View {
        let l = m.light(key)
        let shown = value ?? Double(l?.brightness ?? 100)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: l?.on == true ? "lightbulb.fill" : "lightbulb").foregroundStyle(l?.on == true ? Tan.gold : Tan.faint)
                Text(l?.name ?? fallback).font(.system(size: 16, weight: .semibold)).foregroundStyle(Tan.text)
                Spacer()
                Text(l?.on == true ? "\(Int(shown))%" : "Off").font(.system(size: 14).monospacedDigit()).foregroundStyle(Tan.muted)
                TanSwitch(on: l?.on == true) { m.toggleLight(key) }
            }
            Slider(value: Binding(get: { shown }, set: { value = $0 }), in: 1...100, step: 1,
                   onEditingChanged: { editing in
                       if !editing, let v = value {
                           m.setLight(key, ["on": true, "brightness": Int(v)])
                           value = nil
                       }
                   })
            .tint(Tan.brown)
        }
        .tanCard()
    }
}
