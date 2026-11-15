import SwiftUI

/// MrLTTec Music: the playlists on the phone; tapping a song plays it in the TV app.
/// Used as the Music tab and as the sheet from the Home card's Music button.
struct MusicView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss
    let inSheet: Bool
    @State private var tab = 0
    @State private var find = ""

    private var list: Playlist? { tab < m.lists.count ? m.lists[tab] : nil }
    private var allList: Playlist? { m.lists.first(where: { $0.name == "All songs" }) }
    private var query: String { find.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Typing searches every song; otherwise the chosen list.
    private var source: Playlist? { query.isEmpty ? list : (allList ?? list) }

    private var shown: [Track] {
        guard let l = source else { return [] }
        let q = query
        if q.isEmpty { return l.tracks }
        return l.tracks.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(inSheet ? "MrLTTec Music" : "Music")
                        .font(.system(size: inSheet ? 26 : 34, weight: .bold)).foregroundStyle(Tan.text)
                    Text(m.musicOpen ? "Playing on the TV" : "Tap a song to play it on the TV")
                        .font(.system(size: 13)).foregroundStyle(Tan.muted)
                }
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
            .padding(.top, inSheet ? 22 : 8)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tan.faint)
                TextField((allList?.tracks.count ?? 0) > 0 ? "Search \(allList?.tracks.count ?? 0) songs" : "Search songs", text: $find)
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
            .background(Tan.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tan.line, lineWidth: 0.5))
            .padding(.horizontal, 14)

            if !m.lists.isEmpty {
                if query.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(0..<m.lists.count, id: \.self) { i in
                                Button {
                                    Haptic.tap()
                                    withAnimation(.snappy) { tab = i }
                                } label: {
                                    Text(m.lists[i].name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(tab == i ? Tan.card : Tan.chipText)
                                        .lineLimit(1)
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 7)
                                        .background(tab == i ? Tan.brown : Tan.chip, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.top, 12)
                }

                HStack {
                    Text(query.isEmpty ? "\(shown.count) songs" : "\(shown.count) found")
                        .font(.system(size: 13)).foregroundStyle(Tan.muted)
                    Spacer()
                    Button {
                        if let l = list { m.shufflePlay(l) }
                    } label: {
                        Pill(text: "Shuffle", icon: "shuffle", bg: Tan.dark, fg: Tan.card)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 4)
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
                            SongRow(track: t, fav: source?.fav ?? false)
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

            if m.hasMedia || m.musicControls {
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
            if now { m.togglePlay() } else { m.play(track, fav: fav) }
        } label: {
            HStack(spacing: 11) {
                ArtBox(url: track.art, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 15, weight: now ? .semibold : .regular))
                        .foregroundStyle(now ? Tan.greenFg : Tan.text).lineLimit(1)
                    Text(now ? "Now playing on the TV" : track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(now ? Tan.greenSub : Tan.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                if now {
                    Image(systemName: m.musicPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Tan.card)
                        .frame(width: 36, height: 36)
                        .background(Tan.greenFg, in: Circle())
                } else if ok {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Tan.card)
                        .frame(width: 36, height: 36)
                        .background(Tan.brown, in: Circle())
                } else {
                    Text("Not on server").font(.system(size: 11)).foregroundStyle(Tan.faint)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, now ? 10 : 0)
            .background(now ? Tan.greenBg : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, now ? -10 : 0)
            .padding(.vertical, now ? 3 : 0)
            .opacity(ok || now ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!ok && !now)
    }
}

/// The dark player pinned under the music list. Tap it to open the big Now Playing page.
struct MiniPlayer: View {
    @EnvironmentObject var m: AppModel

    private var title: String {
        if m.musicOpen, let t = m.ms?.title, !t.isEmpty { return t }
        return m.npTitle
    }

    private var sub: String {
        if m.musicOpen, let a = m.ms?.artist, !a.isEmpty { return a }
        return m.npAppLine
    }

    var body: some View {
        HStack(spacing: 10) {
            ArtBox(url: m.npArt, size: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tan.card).lineLimit(1)
                Text("\(sub) · tap to open").font(.system(size: 11)).foregroundStyle(Tan.card.opacity(0.65)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { m.togglePlay() } label: {
                Image(systemName: m.musicPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20)).foregroundStyle(Tan.card)
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { m.nextSong() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20)).foregroundStyle(Tan.card)
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Tan.dark, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            Haptic.tap()
            m.showNowPlaying = true
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}
