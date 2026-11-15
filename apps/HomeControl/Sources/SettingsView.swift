import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @EnvironmentObject var updater: Updater
    @AppStorage("serverHost") private var serverHost = ""

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
