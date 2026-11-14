import SwiftUI

struct ToolsView: View {
    @EnvironmentObject var store: DeviceStore
    @StateObject private var runner = Runner()
    @State private var pingIp = ""
    @State private var portIp = ""
    @State private var port = ""
    @State private var mac = ""
    @State private var output = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("This network") {
                    if store.localAddrs.isEmpty {
                        Label("Not connected to Wi-Fi", systemImage: "wifi.slash").foregroundStyle(.orange)
                    } else {
                        let ip = store.localAddrs[0]
                        let net = ip.split(separator: ".").prefix(3).joined(separator: ".")
                        LabeledContent("iPhone IP", value: ip)
                        LabeledContent("Network", value: "\(net).0/24")
                        LabeledContent("Router (usually)", value: "\(net).1")
                    }
                    NavigationLink { HostListView() } label: {
                        Label("Every device on this network", systemImage: "list.bullet.rectangle")
                    }
                }

                Section {
                    NavigationLink { CastView() } label: {
                        Label("Cast to a TV or speaker", systemImage: "airplayvideo")
                    }
                    NavigationLink { BrowserMirrorView() } label: {
                        Label("Watch my screen in a web browser", systemImage: "safari")
                    }
                } footer: {
                    Text("Send YouTube links, photos, videos, music or your whole screen to Chromecasts, DLNA TVs and speakers, and AirPlay devices, or show your screen in any web browser.")
                }

                Section("Ping") {
                    TextField("IP address", text: $pingIp).keyboardType(.decimalPad)
                    Button("Ping 4 times") { go { try await NetTools.run("ping", pingIp.trimmed, "") } }
                }

                Section("Port check") {
                    TextField("IP address", text: $portIp).keyboardType(.decimalPad)
                    TextField("Port, like 80", text: $port).keyboardType(.numberPad)
                    HStack {
                        Button("Check this port") { go { try await NetTools.run("port", portIp.trimmed, port.trimmed) } }
                        Spacer()
                        Button("Common ports") { go { try await NetTools.run("common", portIp.trimmed, "") } }
                    }
                    .buttonStyle(.borderless)
                }

                Section {
                    TextField("MAC address, like AA:BB:CC:DD:EE:FF", text: $mac).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Send wake signal") { go { try await NetTools.run("wol", "", mac.trimmed) } }
                } header: {
                    Text("Wake-on-LAN")
                } footer: {
                    Text("Wakes a PC or TV that supports it. Some networks block it.")
                }

                if !output.isEmpty {
                    Section("Result") { InfoText(text: output) }
                }
            }
            .navigationTitle("Tools")
            .notes(runner)
        }
    }

    private func go(_ op: @escaping () async throws -> String) {
        Task {
            if let r = await runner.run(nil, op) { output = r; runner.note = nil }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Lists everything that answers on this network, with ping time and host name.
struct HostListView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var hosts: [NetTools.Host] = []
    @State private var loading = false
    @State private var filter = ""

    var body: some View {
        List {
            if loading && hosts.isEmpty {
                HStack { ProgressView(); Text("Checking 254 addresses…").foregroundStyle(.secondary) }
            }
            ForEach(shown) { h in
                NavigationLink { HostDetailView(host: h) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.ip).font(.body.monospacedDigit())
                            Text(label(h)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let p = h.ping { Text("\(Int(p.rounded())) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter by IP or name")
        .navigationTitle(hosts.isEmpty ? "Devices" : "\(hosts.count) devices")
        .refreshable { await load() }
        .task { if hosts.isEmpty { await load() } }
        .overlay { if !loading && hosts.isEmpty { ContentUnavailableView("Nothing answered", systemImage: "wifi.exclamationmark", description: Text("Pull down to try again.")) } }
    }

    private var shown: [NetTools.Host] {
        filter.isEmpty ? hosts : hosts.filter { $0.ip.contains(filter) || label($0).localizedCaseInsensitiveContains(filter) }
    }

    private func label(_ h: NetTools.Host) -> String {
        if let d = store.visible.first(where: { $0.ip == h.ip }) { return "\(d.name) (\(d.kindName))" }
        return h.name.isEmpty ? "No name" : h.name
    }

    private func load() async {
        loading = true
        let r = await NetTools.hosts()
        withAnimation { hosts = r }
        loading = false
    }
}

struct HostDetailView: View {
    let host: NetTools.Host
    @StateObject private var runner = Runner()
    var body: some View {
        Form {
            Section {
                LabeledContent("IP address", value: host.ip)
                if !host.name.isEmpty { LabeledContent("Name", value: host.name) }
                if let p = host.ping { LabeledContent("Ping", value: "\(Int(p.rounded())) ms") }
            }
            NetworkChecks(ip: host.ip, runner: runner)
        }
        .navigationTitle(host.name.isEmpty ? host.ip : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .notes(runner)
    }
}
