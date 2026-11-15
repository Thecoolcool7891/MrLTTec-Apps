import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @EnvironmentObject var updater: Updater
    @AppStorage("serverHost") private var serverHost = ""
    @AppStorage("volumeButtons") private var volumeButtons = true

    private func openHomeApp() {
        guard let u = URL(string: "mrlttechome://open") else { return }
        UIApplication.shared.open(u) { ok in
            if !ok {
                Task { @MainActor in m.say("MrLTTec Home isn't installed. Get it from the MrLTTec source in Flare Store.", bad: true) }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings").font(.system(size: 34, weight: .bold)).foregroundStyle(Tan.text)
                    .padding(.horizontal, 18).padding(.top, 8)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        IconBox(symbol: "server.rack")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("MrLTTec server").font(.system(size: 16, weight: .semibold)).foregroundStyle(Tan.text)
                            HStack(spacing: 5) {
                                Circle().fill(m.connected == true ? Tan.switchOn : Tan.bad).frame(width: 7, height: 7)
                                Text(m.connected != true ? "Not connected"
                                     : (m.onWifi ? "Connected on home Wi-Fi" : "Connected through Tailscale"))
                                    .font(.system(size: 12)).foregroundStyle(Tan.muted)
                            }
                        }
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tailscale address").font(.system(size: 12)).foregroundStyle(Tan.muted)
                        TextField(API.defaultHost, text: $serverHost)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(Tan.text)
                            .padding(10)
                            .background(Tan.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onSubmit { Task { await m.connect() } }
                    }
                    Button {
                        Haptic.tap()
                        Task { await m.connect() }
                    } label: {
                        Text("Reconnect")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Tan.card)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Tan.brown, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .tanCard()
                .padding(.horizontal, 12)

                // Opens the other app (MrLTTec Home) for devices on whatever Wi-Fi the phone is on.
                VStack(alignment: .leading, spacing: 12) {
                    Text("Control the devices on the network").font(.system(size: 16, weight: .semibold)).foregroundStyle(Tan.text)
                    Text("Use this app:").font(.system(size: 12)).foregroundStyle(Tan.muted)
                    HStack(spacing: 12) {
                        BundleIcon(file: "home-app.png", size: 48)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("MrLTTec Home").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text)
                            Text("TVs, speakers and lights on any Wi-Fi").font(.system(size: 12)).foregroundStyle(Tan.muted)
                        }
                        Spacer(minLength: 6)
                        Button {
                            Haptic.tap()
                            openHomeApp()
                        } label: {
                            Text("Open")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Tan.card)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Tan.brown, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .tanCard()
                .padding(.horizontal, 12)

                HStack(spacing: 10) {
                    IconBox(symbol: "speaker.wave.2")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Volume buttons control TV").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text)
                        Text("While MrLTTec Control is open").font(.system(size: 12)).foregroundStyle(Tan.muted)
                    }
                    Spacer(minLength: 6)
                    TanSwitch(on: volumeButtons) {
                        Haptic.tap()
                        volumeButtons.toggle()
                    }
                }
                .tanCard()
                .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        IconBox(symbol: "bolt.horizontal")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Fast TV buttons").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tan.text)
                            Text(m.tvPairing ? "Press OK on the TV..." : m.tvDirect ? "At home, buttons go straight to the TV" : "Buttons go through the mini PC")
                                .font(.system(size: 12)).foregroundStyle(Tan.muted)
                        }
                        Spacer(minLength: 6)
                        if m.tvPairing {
                            ProgressView().tint(Tan.brown)
                        } else {
                            TanSwitch(on: m.tvDirect) { m.setTVDirect(!m.tvDirect) }
                        }
                    }
                    if !m.tvDirect && !m.tvPairing {
                        Text("Turn on at home: the TV asks \"Allow USB debugging?\" once. Tick \"Always allow\" and press OK with the TV remote.")
                            .font(.system(size: 11)).foregroundStyle(Tan.faint)
                    }
                }
                .tanCard()
                .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 10) {
                    UpdateSettingsRow(updater: updater)
                }
                .foregroundStyle(Tan.text)
                .tanCard()
                .padding(.horizontal, 12)

                Text("MrLTTec Control talks to the mini PC on your home Wi-Fi (\(API.lanHost)) or through Tailscale, so it does nothing on a phone that isn't on either one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tan.muted)
                    .padding(.horizontal, 18)
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }
}
