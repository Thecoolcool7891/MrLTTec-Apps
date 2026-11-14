import SwiftUI

struct SonosView: View {
    let device: Device
    @StateObject private var runner = Runner()
    @State private var now = Sonos.NowPlaying()
    @State private var volume = 0.0
    @State private var dragging = false
    @State private var advanced = false
    @State private var info = Sonos.Info()
    @State private var eq = Sonos.EQ()
    @State private var members: [Sonos.Member] = []
    @State private var favorites: [Sonos.Favorite] = []
    @State private var sleepLeft = ""
    @State private var loaded = false

    private var me: Sonos.Member? { members.first { $0.ip == device.ip } }
    /// Play/pause/next go to the group leader when this speaker is grouped.
    private var leaderIp: String {
        guard let me, let lead = members.first(where: { $0.uuid == me.coordinator }), !lead.ip.isEmpty else { return device.ip }
        return lead.ip
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                art
                VStack(spacing: 4) {
                    Text(now.title.isEmpty ? (loaded ? "Nothing playing" : " ") : now.title)
                        .font(.title3.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                    Text(now.artist.isEmpty ? device.detail : now.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if !now.source.isEmpty || leaderIp != device.ip {
                        Text(leaderIp != device.ip ? "Grouped with \(members.first { $0.ip == leaderIp }?.name ?? "another speaker")" : now.source)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Theme.gold.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.gold)
                    }
                }
                .padding(.horizontal)

                HStack(spacing: 36) {
                    RemoteKey(icon: "backward.fill", size: 58, tint: .clear) { cmd { try await Sonos.previous(leaderIp) } }
                    RemoteKey(icon: now.isPlaying ? "pause.fill" : "play.fill", size: 76, tint: Theme.gold, fg: Theme.brown) {
                        let playing = now.isPlaying
                        now.state = playing ? "PAUSED_PLAYBACK" : "PLAYING"
                        cmd { if playing { try await Sonos.pause(leaderIp) } else { try await Sonos.play(leaderIp) } }
                    }
                    RemoteKey(icon: "forward.fill", size: 58, tint: .clear) { cmd { try await Sonos.next(leaderIp) } }
                }

                HStack(spacing: 12) {
                    Button {
                        now.muted.toggle()
                        let m = now.muted
                        cmd { try await Sonos.setMute(device.ip, m) }
                    } label: {
                        Image(systemName: now.muted ? "speaker.slash.fill" : "speaker.fill").frame(width: 28)
                    }
                    .foregroundStyle(now.muted ? .orange : .secondary)
                    Slider(value: $volume, in: 0...100, step: 1, onEditingChanged: { editing in
                        dragging = editing
                        if !editing { let v = Int(volume); cmd(haptic: false) { try await Sonos.setVolume(device.ip, v) } }
                    })
                    Text("\(Int(volume))").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34)
                }
                .padding(.horizontal, 24)

                advancedSection
            }
            .padding(.vertical)
        }
        .notes(runner)
        .task {
            if let i = try? await Sonos.info(device.ip) { info = i }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private var art: some View {
        Group {
            if let u = now.art {
                AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { artPlaceholder }
            } else {
                artPlaceholder
            }
        }
        .frame(width: 270, height: 270)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .scaleEffect(now.isPlaying || !loaded ? 1 : 0.92)
        .animation(.spring(duration: 0.4), value: now.isPlaying)
    }

    private var artPlaceholder: some View {
        ZStack {
            Theme.gold.opacity(0.15)
            Image(systemName: "hifispeaker.fill").font(.system(size: 64)).foregroundStyle(Theme.gold)
        }
    }

    @ViewBuilder private var advancedSection: some View {
        VStack(spacing: 14) {
            Button {
                withAnimation(.snappy) { advanced.toggle() }; Haptic.tap()
                if advanced { Task { await loadAdvanced() } }
            } label: {
                HStack {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(advanced ? 180 : 0))
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .foregroundStyle(.primary)

            if advanced {
                Card("Sound") {
                    eqSlider("Bass", value: Binding(get: { Double(eq.bass) }, set: { eq.bass = Int($0) })) { v in try await Sonos.setBass(device.ip, v) }
                    eqSlider("Treble", value: Binding(get: { Double(eq.treble) }, set: { eq.treble = Int($0) })) { v in try await Sonos.setTreble(device.ip, v) }
                    Toggle("Loudness", isOn: Binding(get: { eq.loudness }, set: { v in eq.loudness = v; cmd { try await Sonos.setLoudness(device.ip, v) } }))
                }

                let others = members.filter { $0.ip != device.ip }
                if !others.isEmpty {
                    Card("Group with other speakers") {
                        ForEach(others) { m in
                            let together = m.coordinator == me?.coordinator
                            Toggle(m.name, isOn: Binding(get: { together }, set: { v in
                                guard let me else { return }
                                cmd(done: v ? "\(m.name) joined" : "\(m.name) left") {
                                    if v { try await Sonos.join(m.ip, coordinatorUUID: me.coordinator) } else { try await Sonos.leave(m.ip) }
                                }
                                Task { try? await Task.sleep(nanoseconds: 800_000_000); members = (try? await Sonos.topology(device.ip)) ?? members }
                            }))
                        }
                        if leaderIp != device.ip {
                            Button("Leave the group") { cmd(done: "Playing on its own now") { try await Sonos.leave(device.ip) } }
                        }
                    }
                }

                Card("Source") {
                    HStack {
                        Button { cmd(done: "Switched to TV") { try await Sonos.playTV(device.ip, uuid: info.uuid) } } label: { Label("TV", systemImage: "tv") }
                        Button { cmd(done: "Switched to line-in") { try await Sonos.playLineIn(device.ip, uuid: info.uuid) } } label: { Label("Line-in", systemImage: "cable.connector") }
                    }
                    .buttonStyle(.bordered)
                    Text("TV works on soundbars, line-in on speakers that have the jack.").font(.caption).foregroundStyle(.secondary)
                }

                Card("Favorites") {
                    if favorites.isEmpty {
                        Button("Load Sonos favorites") {
                            Task {
                                if let f = try? await Sonos.favorites(device.ip), !f.isEmpty { favorites = f }
                                else { runner.show("No Sonos favorites found on this system.", error: true) }
                            }
                        }
                    } else {
                        ForEach(favorites) { f in
                            Button {
                                cmd(done: "Playing \(f.title)") { try await Sonos.playFavorite(leaderIp, f, uuid: members.first { $0.ip == leaderIp }?.uuid ?? info.uuid) }
                            } label: {
                                HStack(spacing: 10) {
                                    AsyncImage(url: f.art) { $0.resizable().scaledToFill() } placeholder: { Color(.tertiarySystemFill) }
                                        .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(f.title).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "play.circle").foregroundStyle(Theme.gold)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Card("Sleep timer") {
                    HStack {
                        Text(sleepLeft.isEmpty ? "Off" : "Stops in \(sleepLeft)").foregroundStyle(.secondary)
                        Spacer()
                        Menu("Set") {
                            ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                                Button("\(m) minutes") { cmd(done: "Sleep timer: \(m) min") { try await Sonos.setSleep(leaderIp, minutes: m) }; delayedSleepCheck() }
                            }
                            Button("Turn off", role: .destructive) { cmd(done: "Sleep timer off") { try await Sonos.setSleep(leaderIp, minutes: 0) }; delayedSleepCheck() }
                        }
                    }
                }

                Card("Speaker") {
                    if !info.lines.isEmpty { InfoText(text: info.lines.joined(separator: "\n") + "\nIP: \(device.ip)") }
                    PingRow(ip: device.ip, runner: runner)
                }
            }
        }
        .padding(.horizontal)
    }

    private func eqSlider(_ name: String, value: Binding<Double>, set: @escaping (Int) async throws -> Void) -> some View {
        HStack {
            Text(name).frame(width: 56, alignment: .leading)
            Slider(value: value, in: -10...10, step: 1, onEditingChanged: { editing in
                if !editing { let v = Int(value.wrappedValue); cmd(haptic: false) { try await set(v) } }
            })
            Text("\(Int(value.wrappedValue))").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30)
        }
    }

    private func cmd(done: String? = nil, haptic: Bool = true, _ op: @escaping () async throws -> Void) {
        Task {
            await runner.run(done, haptic: haptic) { try await op(); return "" }
            await refresh()
        }
    }

    private func refresh() async {
        let lead = leaderIp
        let n = await Sonos.now(lead)
        var v = n
        if lead != device.ip { v = await Sonos.now(device.ip) }
        var merged = n
        merged.volume = v.volume
        merged.muted = v.muted
        if merged != now || !loaded {
            withAnimation(.snappy) { now = merged }
        }
        if !dragging { volume = Double(merged.volume) }
        if !loaded {
            loaded = true
            members = (try? await Sonos.topology(device.ip)) ?? []
        }
    }

    private func loadAdvanced() async {
        eq = await Sonos.eq(device.ip)
        members = (try? await Sonos.topology(device.ip)) ?? members
        sleepLeft = await Sonos.sleepRemaining(leaderIp)
    }

    private func delayedSleepCheck() {
        Task { try? await Task.sleep(nanoseconds: 1_000_000_000); sleepLeft = await Sonos.sleepRemaining(leaderIp) }
    }
}
