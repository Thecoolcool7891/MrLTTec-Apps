import SwiftUI

/// The Gaming PC page (tap the Gaming PC card on Home): power, fan RGB, temps and load, RAM, network,
/// storage, what's running, and buttons that open games on the PC. The numbers come from the PC helper
/// (port 8901 on the PC, through the mini PC); until the helper has its stats update, the page says so.
struct PCStatsView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSleep = false

    private var on: Bool { m.status?.pc?.on == true }
    private var s: PCStats? { m.pcStats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Gaming PC").font(.system(size: 28, weight: .bold)).foregroundStyle(Tan.text)
                        Text(m.pcLine).font(.system(size: 13)).foregroundStyle(Tan.muted)
                    }
                    Spacer()
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
                .padding(.horizontal, 6)
                .padding(.top, 20)
                .padding(.bottom, 4)

                HStack(spacing: 10) {
                    // Power
                    HStack(spacing: 10) {
                        Image(systemName: "power")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(on ? Tan.greenFg : Tan.iconFg)
                            .frame(width: 36, height: 36)
                            .background(on ? Tan.greenBg : Tan.chip, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Power").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text)
                            Text(on ? "On" : (m.pcWaking ? "Waking..." : "Asleep")).font(.system(size: 12)).foregroundStyle(Tan.muted)
                        }
                        Spacer(minLength: 4)
                        TanSwitch(on: on || m.pcWaking) {
                            if on { confirmSleep = true } else { m.pcPower(true) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .tanCard(padding: 12)

                    // Fan RGB
                    HStack(spacing: 10) {
                        FanButton(size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Fan RGB").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text)
                            Text(!on ? "PC asleep" : (m.rgb == "on" ? "Lit" : m.rgb == "off" ? "Off" : "Checking...")).font(.system(size: 12)).foregroundStyle(Tan.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .tanCard(padding: 12)
                }

                if !on {
                    note("moon.zzz", "The PC is asleep. Turn it on to see its stats and open games.")
                } else if s == nil {
                    if m.pcStatsError.isEmpty {
                        HStack { Spacer(); ProgressView().tint(Tan.brown); Spacer() }.padding(.vertical, 20)
                    } else {
                        note("wrench.and.screwdriver", m.pcStatsError)
                    }
                }

                if on, let s = s {
                    HStack(spacing: 10) {
                        chip("cpu", "CPU", s.cpu)
                        chip("rectangle.3.group", "GPU", s.gpu)
                    }
                    HStack(spacing: 10) {
                        stat("memorychip", "RAM", ramText(s.ram), ramSub(s.ram))
                        stat("network", s.net?.name ?? "Network", netText(s.net), "down · up")
                    }

                    if let drives = s.drives, !drives.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Storage left").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text)
                            ForEach(drives) { d in
                                driveRow(d)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tanCard()
                    }

                    HStack(alignment: .top, spacing: 10) {
                        IconBox(symbol: "bolt.horizontal")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Running now").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text)
                            Text((s.running ?? []).isEmpty ? "Nothing from the list" : (s.running ?? []).joined(separator: ", "))
                                .font(.system(size: 12)).foregroundStyle(Tan.muted)
                        }
                        Spacer(minLength: 6)
                        if let up = s.uptimeSec {
                            Text("PC on \(uptime(up))").font(.system(size: 12, weight: .medium)).foregroundStyle(Tan.chipText)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Tan.chip, in: Capsule())
                        }
                    }
                    .tanCard()
                }

                Text("Launch on PC").font(.system(size: 18, weight: .bold)).foregroundStyle(Tan.text)
                    .padding(.horizontal, 6).padding(.top, 8)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    launch("pc-steam.png", "Steam", "steam")
                    launch("pc-fortnite.png", "Fortnite", "fortnite")
                    launch("pc-minecraft.png", "Minecraft", "minecraft")
                    launch("pc-discord.png", "Discord", "discord")
                }
                .tanCard()
                .opacity(on ? 1 : 0.5)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Tan.bg.ignoresSafeArea())
        .task {
            while !Task.isCancelled {
                await m.loadPCStats()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .confirmationDialog("Put the Gaming PC to sleep?", isPresented: $confirmSleep, titleVisibility: .visible) {
            Button("Sleep", role: .destructive) { m.pcPower(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It might be in a game.")
        }
    }

    // MARK: pieces

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            IconBox(symbol: symbol)
            Text(text).font(.system(size: 13)).foregroundStyle(Tan.muted)
            Spacer(minLength: 0)
        }
        .tanCard()
    }

    private func chip(_ symbol: String, _ name: String, _ c: PCStats.Chip?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconBox(symbol: symbol, size: 30)
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(c?.tempC.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(tempColor(c?.tempC))
                Text("C").font(.system(size: 12)).foregroundStyle(Tan.muted)
                Spacer(minLength: 0)
                Text(c?.loadPct.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.chipText)
            }
            bar((c?.loadPct ?? 0) / 100)
            if let n = c?.name, !n.isEmpty {
                Text(n).font(.system(size: 10)).foregroundStyle(Tan.faint).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tanCard(padding: 12)
    }

    private func stat(_ symbol: String, _ name: String, _ big: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconBox(symbol: symbol, size: 30)
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(big).font(.system(size: 18, weight: .bold)).foregroundStyle(Tan.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 11)).foregroundStyle(Tan.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tanCard(padding: 12)
    }

    private func driveRow(_ d: PCStats.Drive) -> some View {
        let total = d.totalGB ?? 0
        let free = d.freeGB ?? 0
        let used = total > 0 ? (total - free) / total : 0
        let label = [d.name ?? "", d.label ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Tan.text)
                Spacer()
                Text("\(gb(free)) free of \(gb(total))").font(.system(size: 12)).foregroundStyle(Tan.muted)
            }
            bar(used, color: used > 0.9 ? Tan.bad : Tan.brown)
        }
    }

    private func bar(_ frac: Double, color: Color = Tan.brown) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Tan.row)
                Capsule().fill(color).frame(width: g.size.width * min(1, max(0, frac)))
            }
        }
        .frame(height: 6)
    }

    private func launch(_ icon: String, _ name: String, _ id: String) -> some View {
        Button { m.launchOnPC(id, name) } label: {
            VStack(spacing: 5) {
                BundleIcon(file: icon, size: 56)
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(Tan.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!on)
    }

    private func tempColor(_ t: Double?) -> Color {
        guard let t = t else { return Tan.text }
        if t >= 85 { return Tan.bad }
        if t >= 70 { return Tan.gold }
        return Tan.greenFg
    }

    private func gb(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1f TB", v / 1000) : "\(Int(v.rounded())) GB"
    }

    private func ramText(_ r: PCStats.Ram?) -> String {
        guard let u = r?.usedGB, let t = r?.totalGB else { return "—" }
        return String(format: "%.1f / %.0f GB", u, t)
    }

    private func ramSub(_ r: PCStats.Ram?) -> String {
        guard let u = r?.usedGB, let t = r?.totalGB, t > 0 else { return "in use" }
        return "\(Int((u / t * 100).rounded()))% in use"
    }

    private func netText(_ n: PCStats.Net?) -> String {
        guard let n = n else { return "—" }
        let d = n.downMbps.map { String(format: "↓ %.1f", $0) } ?? "↓ —"
        let u = n.upMbps.map { String(format: "↑ %.1f", $0) } ?? "↑ —"
        return "\(d)  \(u) Mb/s"
    }

    private func uptime(_ secs: Double) -> String {
        let m = Int(secs) / 60
        if m < 60 { return "\(m) m" }
        let h = m / 60
        if h < 48 { return "\(h) h \(m % 60) m" }
        return "\(h / 24) d \(h % 24) h"
    }
}
