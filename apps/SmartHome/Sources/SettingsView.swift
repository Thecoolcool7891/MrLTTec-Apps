import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: DeviceStore
    @EnvironmentObject var updater: Updater
    @AppStorage("appearance") private var appearance = "dark"
    @AppStorage("haptics") private var haptics = true
    @State private var confirmClear = false
    @State private var confirmPairings = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Look and feel") {
                    Picker("Appearance", selection: $appearance) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                        Text("Match iPhone").tag("system")
                    }
                    Toggle("Vibrate on taps", isOn: $haptics)
                }

                Section {
                    LabeledContent("Saved devices", value: "\(store.visible.count)")
                    Button("Forget TV pairings and IDs") { confirmPairings = true }
                    Button("Clear all saved devices", role: .destructive) { confirmClear = true }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Everything stays on this iPhone. Nothing is sent anywhere except to the devices you control.")
                }

                Section("Updates") {
                    UpdateSettingsRow(updater: updater)
                }

                Section("About") {
                    LabeledContent("Made by", value: "MrLTTec")
                    Text("Controls Sonos, Roku, Samsung TVs, Wemo, WLED, WiZ and Xbox on any Wi-Fi. No account or internet needed.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Remove every saved device?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear all", role: .destructive) { store.clearAll(); Haptic.success() }
            }
            .confirmationDialog("Forget Samsung and Fire TV pairings, MAC addresses and Xbox Live IDs?", isPresented: $confirmPairings, titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    for k in ["samsungTokens", "samsungMacs", "xbox", "firetv"] { UserDefaults.standard.removeObject(forKey: k) }
                    Haptic.success()
                }
            }
        }
    }
}
