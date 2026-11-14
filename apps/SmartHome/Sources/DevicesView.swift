import SwiftUI

struct DevicesView: View {
    @Binding var tab: AppTab
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var updater: Updater
    @StateObject private var runner = Runner()
    @State private var showAdd = false
    @State private var renaming: Device?
    @State private var newName = ""
    @State private var showOther = false
    @State private var refreshToken = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if updater.available != nil { UpdateBanner(updater: updater).padding(.bottom, 10) }
                    NetworkCard(addrs: store.localAddrs, count: store.here.count)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))

                if store.here.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 34)).foregroundStyle(Theme.gold)
                            Text("Nothing saved on this Wi-Fi yet").font(.headline)
                            Text("Scan this network to find TVs, speakers and lights.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button { tab = .discover } label: { Text("Discover devices").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 10)
                    }
                }

                ForEach(Category.allCases, id: \.self) { cat in
                    let items = store.here.filter { $0.category == cat }
                    if !items.isEmpty {
                        Section(cat.title) {
                            ForEach(items) { d in row(d) }
                        }
                    }
                }

                if !store.elsewhere.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showOther) {
                            ForEach(store.elsewhere) { d in row(d) }
                        } label: {
                            Label("Saved from other networks (\(store.elsewhere.count))", systemImage: "clock.arrow.circlepath")
                        }
                    } footer: {
                        Text("These only answer when you're back on the Wi-Fi where they were found.")
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationDestination(for: Device.self) { DeviceDetailView(device: $0) }
            .refreshable { store.refreshNetwork(); refreshToken += 1 }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("Add device by IP", systemImage: "plus") }
                        if store.here.contains(where: { $0.hasSwitch }) {
                            Divider()
                            Button { allLights(true) } label: { Label("Turn everything on", systemImage: "lightbulb.max.fill") }
                            Button { allLights(false) } label: { Label("Turn everything off", systemImage: "lightbulb.slash") }
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddDeviceSheet() }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { if let r = renaming { store.rename(r, to: newName) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .notes(runner)
        }
    }

    @ViewBuilder private func row(_ d: Device) -> some View {
        NavigationLink(value: d) {
            HStack(spacing: 12) {
                DeviceIcon(device: d)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).lineLimit(1)
                    Text(d.detail.isEmpty ? d.kindName : d.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if d.hasSwitch { PowerSwitch(device: d, runner: runner, token: refreshToken) }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { withAnimation { store.remove(d) } } label: { Label("Remove", systemImage: "trash") }
            Button { newName = d.name; renaming = d } label: { Label("Rename", systemImage: "pencil") }.tint(.indigo)
        }
        .contextMenu {
            Button { newName = d.name; renaming = d } label: { Label("Rename", systemImage: "pencil") }
            Button { UIPasteboard.general.string = d.ip } label: { Label("Copy IP \(d.ip)", systemImage: "doc.on.doc") }
            Button(role: .destructive) { store.remove(d) } label: { Label("Remove", systemImage: "trash") }
        }
    }

    private func allLights(_ on: Bool) {
        let list = store.here.filter { $0.hasSwitch }
        Task {
            await runner.run(on ? "Turned on \(list.count) lights and plugs" : "Turned off \(list.count) lights and plugs") {
                await withTaskGroup(of: Void.self) { g in
                    for d in list { g.addTask { try? await Power.set(d, on) } }
                }
                return ""
            }
            refreshToken += 1
        }
    }
}

/// Wi-Fi summary at the top of the Devices tab.
struct NetworkCard: View {
    let addrs: [String]
    let count: Int
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: addrs.isEmpty ? "wifi.slash" : "wifi")
                .font(.title3).foregroundStyle(addrs.isEmpty ? .orange : Theme.gold)
                .frame(width: 40, height: 40)
                .background(Theme.gold.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(addrs.isEmpty ? "Not on Wi-Fi" : "Connected to Wi-Fi").font(.subheadline.weight(.semibold))
                Text(addrs.isEmpty ? "Join a Wi-Fi network to find devices." : "iPhone \(addrs[0]) · \(count) saved here")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// On/off for lights and plugs, used in the list and on their screens.
enum Power {
    static func get(_ d: Device) async -> Bool? {
        switch d.type {
        case "wemo": return await Wemo.state(d.ip)
        case "wled": return await Wled.state(d.ip)?.on
        case "wiz", "wizplug": return (try? await Wiz.pilot(d.ip))?["state"] as? Bool
        default: return nil
        }
    }
    static func set(_ d: Device, _ on: Bool) async throws {
        switch d.type {
        case "wemo": try await Wemo.run(d.ip, on ? "on" : "off")
        case "wled": try await Wled.run(d.ip, on ? "on" : "off")
        case "wiz", "wizplug": _ = try await Wiz.run(d.ip, on ? "on" : "off", "")
        default: break
        }
    }
}

struct PowerSwitch: View {
    let device: Device
    @ObservedObject var runner: Runner
    var token = 0
    @State private var on = false
    @State private var known = false

    var body: some View {
        Group {
            if known {
                Toggle("", isOn: Binding(get: { on }, set: { v in
                    on = v
                    Task {
                        if await runner.run(nil, { try await Power.set(device, v); return "" }) == nil { on = !v }
                    }
                }))
                .labelsHidden()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: token) {
            if let s = await Power.get(device) { on = s; known = true } else { known = true; on = false }
        }
    }
}

struct AddDeviceSheet: View {
    @EnvironmentObject var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State private var type = "roku"
    @State private var ip = ""
    @State private var name = ""
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $type) {
                    ForEach(Device.types.filter { !["adb", "appletv"].contains($0) }, id: \.self) { t in
                        Text(Device(type: t, ip: "", name: "", detail: "").kindName).tag(t)
                    }
                }
                TextField("IP address, like 192.168.1.50", text: $ip).keyboardType(.decimalPad)
                TextField("Name (optional)", text: $name)
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Add device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let i = ip.trimmingCharacters(in: .whitespaces)
                        guard isPrivateIp(i) else { error = "Type a local IP address, like 192.168.1.50."; return }
                        store.add(type: type, ip: i, name: name)
                        Haptic.success()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
