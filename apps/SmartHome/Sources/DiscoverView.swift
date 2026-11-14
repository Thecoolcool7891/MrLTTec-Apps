import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var scanning = false
    @State private var found: [Device] = []
    @State private var scanned = false
    @State private var started = Date()
    @State private var seconds = 0.0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        Radar(active: scanning)
                            .onTapGesture { if !scanning { Task { await scan() } } }
                        Text(scanning ? "Scanning this network…" : scanned ? "Found \(found.count) device\(found.count == 1 ? "" : "s") in \(Int(seconds)) s" : "Find what's on this Wi-Fi")
                            .font(.headline)
                        Text(store.localAddrs.isEmpty ? "Connect to Wi-Fi first." : "Checks all 254 addresses on \(store.localAddrs[0].split(separator: ".").prefix(3).joined(separator: ".")).x for TVs, speakers, lights and consoles.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button {
                            Task { await scan() }
                        } label: {
                            Label(scanning ? "Scanning" : scanned ? "Scan again" : "Start scan", systemImage: "dot.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(scanning || store.localAddrs.isEmpty)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                if !found.isEmpty {
                    Section {
                        ForEach(found) { d in
                            NavigationLink(value: d) {
                                HStack(spacing: 12) {
                                    DeviceIcon(device: d)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(d.name).lineLimit(1)
                                        Text("\(d.kindName) · \(d.ip)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if store.isSaved(d.type, d.ip) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else {
                                        Button { store.add(type: d.type, ip: d.ip, name: d.name, detail: d.detail); Haptic.success() } label: {
                                            Image(systemName: "plus.circle.fill").font(.title3)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Found")
                    } footer: {
                        Text("Found devices are saved to Devices automatically. Devices you removed stay removed unless you tap +.")
                    }
                }
            }
            .navigationTitle("Discover")
            .navigationDestination(for: Device.self) { DeviceDetailView(device: $0) }
            .onAppear { store.refreshNetwork() }
        }
    }

    private func scan() async {
        store.refreshNetwork()
        guard !store.localAddrs.isEmpty else { return }
        Haptic.tap(.medium)
        withAnimation { scanning = true; found = [] }
        started = Date()
        let raw = await Discovery.findDevices()
        store.addFound(raw)
        var seen = Set<String>()
        let list: [Device] = raw.compactMap { f in
            let d = Device(type: f["type"] ?? "", ip: f["ip"] ?? "", name: cleanName(f["name"] ?? ""), detail: cleanName(f["detail"] ?? ""))
            guard Device.types.contains(d.type), !seen.contains(d.id) else { return nil }
            seen.insert(d.id)
            return d
        }
        seconds = Date().timeIntervalSince(started)
        withAnimation(.snappy) { found = list; scanning = false; scanned = true }
        list.isEmpty ? Haptic.error() : Haptic.success()
    }
}

/// Pulsing radar rings shown while scanning.
struct Radar: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(Theme.gold.opacity(active ? 0.5 : 0.25), lineWidth: 1.5)
                    .frame(width: 70 + CGFloat(i) * 40, height: 70 + CGFloat(i) * 40)
                    .scaleEffect(active && pulse ? 1.15 : 1)
                    .opacity(active && pulse ? 0.2 : 1)
                    .animation(active ? .easeInOut(duration: 1.1).repeatForever().delay(Double(i) * 0.25) : .default, value: pulse)
            }
            Circle().fill(Theme.gold).frame(width: 64, height: 64)
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.brown)
                .symbolEffect(.variableColor.iterative, isActive: active)
        }
        .frame(height: 170)
        .onChange(of: active) { _, a in pulse = a }
    }
}
