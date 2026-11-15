import SwiftUI

/// MrLTTec Music: the playlists on the phone; tapping a song plays it in the TV app.
/// Used as the sheet from the Now Playing card's Music button and as the Music tab.
struct MusicView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss
    let inSheet: Bool
    @State private var tab = 0
    @State private var find = ""

    private var list: Playlist? { tab < m.lists.count ? m.lists[tab] : nil }

    private var shown: [Track] {
        guard let l = list else { return [] }
        let q = find.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return l.tracks }
        return l.tracks.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MrLTTec Music").font(.system(size: 24, weight: .bold)).foregroundStyle(Tan.text)
                Spacer()
                if inSheet {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Tan.muted)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, inSheet ? 22 : 10)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tan.faint)
                TextField("Search songs", text: $find)
                    .foregroundStyle(Tan.text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !find.isEmpty {
                    Button { find = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Tan.faint) }
                        .buttonStyle(.plain)
                }
            }
            .font(.system(size: 15))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Tan.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Tan.line, lineWidth: 0.5))
            .padding(.horizontal, 14)

            if !m.lists.isEmpty {
                HStack(spacing: 0) {
                    ForEach(0..<m.lists.count, id: \.self) { i in
                        Button {
                            Haptic.tap()
                            tab = i
                        } label: {
                            Text(m.lists[i].short)
                                .font(.system(size: 13, weight: tab == i ? .semibold : .regular))
                                .foregroundStyle(Tan.text)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(tab == i ? Tan.card : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Tan.row, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }

            if m.lists.isEmpty {
                Spacer()
                if m.musicLoading || m.musicError.isEmpty {
                    ProgressView("Loading your songs...").tint(Tan.brown).foregroundStyle(Tan.muted)
                } else {
                    VStack(spacing: 12) {
                        Text(m.musicError).font(.system(size: 14)).foregroundStyle(Tan.muted).multilineTextAlignment(.center)
                        Button("Try again") { Task { await m.loadMusic() } }.foregroundStyle(Tan.brown)
                    }
                    .padding(.horizontal, 30)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { t in
                            SongRow(track: t, fav: list?.fav ?? false)
                        }
                        if shown.isEmpty {
                            Text("No songs match.").font(.system(size: 14)).foregroundStyle(Tan.muted).padding(.top, 30)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }

            if m.hasMedia {
                MiniPlayer()
            }
        }
        .background(Tan.bg.ignoresSafeArea())
        .task { if m.lists.isEmpty { await m.loadMusic() } }
    }
}

struct SongRow: View {
    @EnvironmentObject var m: AppModel
    let track: Track
    let fav: Bool

    var body: some View {
        let now = m.isNow(track)
        let ok = !track.songId.isEmpty
        Button {
            if now { m.key("playpause") } else { m.play(track, fav: fav) }
        } label: {
            if now {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 14)).frame(width: 24, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text("Now playing on TV").font(.system(size: 12)).foregroundStyle(Tan.greenSub)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: m.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 18))
                }
                .foregroundStyle(Tan.greenFg)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .background(Tan.greenBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, -10)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 10) {
                    Text("\(track.n)").font(.system(size: 12)).foregroundStyle(Tan.muted).frame(width: 24, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.system(size: 15)).foregroundStyle(Tan.text).lineLimit(1)
                        Text(track.artist).font(.system(size: 12)).foregroundStyle(Tan.muted).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if ok {
                        Image(systemName: "play").font(.system(size: 18, weight: .medium)).foregroundStyle(Tan.brown)
                    } else {
                        Text("Not on server").font(.system(size: 11)).foregroundStyle(Tan.faint)
                    }
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) { Rectangle().fill(Tan.row).frame(height: 0.5) }
                .opacity(ok ? 1 : 0.55)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .disabled(!ok && !now)
    }
}

/// Small player pinned to the bottom of the music list.
struct MiniPlayer: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        HStack(spacing: 10) {
            ArtBox(url: m.npArt, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.npTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tan.text).lineLimit(1)
                Text(m.musicOpen ? "MrLTTec Music on the TV" : m.npAppLine).font(.system(size: 11)).foregroundStyle(Tan.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                NPKey(symbol: m.isPlaying ? "pause.fill" : "play.fill", key: "playpause")
                NPKey(symbol: "forward.fill", key: "ffwd")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Tan.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Tan.line, lineWidth: 0.5))
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}
