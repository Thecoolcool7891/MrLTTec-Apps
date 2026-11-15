import SwiftUI

/// The big Now Playing page. Opens from the Home "Now playing" card and the Music mini player.
/// With MrLTTec Music open on the TV it uses the app's own controls (seek, shuffle, repeat, volume, Up Next);
/// for any other app it falls back to the TV remote keys.
struct NowPlayingView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var dragPos: Double? = nil
    @State private var dragVol: Double? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Tan.muted)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                    Spacer()
                    VStack(spacing: 1) {
                        Text("PLAYING ON THE TV").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(Tan.faint)
                        Text(m.musicOpen ? "MrLTTec Music" : m.npAppLine).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tan.text).lineLimit(1)
                    }
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.top, 14)

                ArtBox(url: m.npArt, size: 300)
                    .shadow(color: Tan.dark.opacity(0.25), radius: 18, y: 10)
                    .padding(.top, 6)

                VStack(spacing: 4) {
                    Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Tan.text).lineLimit(2).multilineTextAlignment(.center)
                    Text(artist).font(.system(size: 16)).foregroundStyle(Tan.muted).lineLimit(1)
                }
                .padding(.horizontal, 20)

                progress

                HStack(spacing: 0) {
                    smallToggle("shuffle", on: m.ms?.shuffle == true) { m.setShuffle(!(m.ms?.shuffle ?? false)) }
                    Spacer()
                    bigKey("backward.fill", 30) { m.previousSong() }
                    Spacer()
                    Button { m.togglePlay() } label: {
                        Image(systemName: m.musicPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Tan.card)
                            .frame(width: 72, height: 72)
                            .background(Tan.brown, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    bigKey("forward.fill", 30) { m.nextSong() }
                    Spacer()
                    smallToggle("repeat", on: m.ms?.repeatOn == true) { m.setRepeat(!(m.ms?.repeatOn ?? false)) }
                }
                .padding(.horizontal, 6)
                .disabled(!m.tvOn)
                .opacity(m.tvOn ? 1 : 0.4)

                volume

                if m.musicControls && !upNext.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Up Next").font(.system(size: 17, weight: .bold)).foregroundStyle(Tan.text).padding(.bottom, 6)
                        ForEach(Array(upNext.enumerated()), id: \.offset) { pair in
                            let it = pair.element
                            HStack(spacing: 10) {
                                ArtBox(url: art(for: it.id), size: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(it.title ?? "").font(.system(size: 14, weight: .medium)).foregroundStyle(Tan.text).lineLimit(1)
                                    Text(it.artist ?? "").font(.system(size: 12)).foregroundStyle(Tan.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tanCard()
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Tan.bg.ignoresSafeArea())
        .task {
            // Poll faster while this page is open.
            await m.loadQueue()
            var n = 0
            while !Task.isCancelled {
                await m.refreshMusic()
                n += 1
                if n % 5 == 0 { await m.loadQueue() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var title: String {
        if m.musicOpen, let t = m.ms?.title, !t.isEmpty { return t }
        return m.npTitle
    }

    private var artist: String {
        if m.musicOpen, let a = m.ms?.artist, !a.isEmpty { return a }
        return m.np?.subtitle ?? ""
    }

    private var upNext: [MusicQueue.Item] {
        guard let i = m.ms?.index, !m.queue.isEmpty else { return Array(m.queue.prefix(8)) }
        let start = i + 1
        if start >= m.queue.count { return [] }
        return Array(m.queue[start..<min(m.queue.count, start + 8)])
    }

    private func art(for id: String) -> URL? {
        for l in m.lists {
            if let t = l.tracks.first(where: { $0.songId == id && $0.art != nil }) { return t.art }
        }
        return URL(string: "http://\(API.host):8096/Items/\(id)/Images/Primary?maxHeight=120")
    }

    @ViewBuilder private var progress: some View {
        if m.musicControls && m.durationMs > 0 {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let pos = dragPos ?? m.positionMs(at: ctx.date)
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { pos }, set: { dragPos = $0 }), in: 0...m.durationMs,
                           onEditingChanged: { editing in
                               if !editing, let p = dragPos {
                                   m.seek(p)
                                   dragPos = nil
                               }
                           })
                    .tint(Tan.brown)
                    HStack {
                        Text(AppModel.clock(pos))
                        Spacer()
                        Text("-" + AppModel.clock(m.durationMs - pos))
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Tan.muted)
                }
            }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(m.npSub(at: ctx.date)).font(.system(size: 13)).foregroundStyle(Tan.muted).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var volume: some View {
        if m.musicControls {
            let v = dragVol ?? (m.ms?.volume ?? 100)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(Tan.faint)
                Slider(value: Binding(get: { v }, set: { dragVol = $0 }), in: 0...100,
                       onEditingChanged: { editing in
                           if !editing, let d = dragVol {
                               m.setMusicVolume(d)
                               dragVol = nil
                           }
                       })
                .tint(Tan.brown)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(Tan.faint)
            }
            .font(.system(size: 13))
        } else {
            HStack(spacing: 40) {
                bigKey("speaker.minus", 22) { m.key("voldown") }
                bigKey("speaker.slash", 22) { m.key("mute") }
                bigKey("speaker.plus", 22) { m.key("volup") }
            }
        }
    }

    private func bigKey(_ symbol: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(Tan.chipText)
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func smallToggle(_ symbol: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? Tan.card : Tan.chipText)
                .frame(width: 40, height: 40)
                .background(on ? Tan.brown : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!m.musicControls)
        .opacity(m.musicControls ? 1 : 0.35)
    }
}
