import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// "Cast to a TV or speaker": find Chromecasts, DLNA TVs/speakers and AirPlay devices, then send YouTube links
/// or photos, videos and music from this iPhone.
struct CastView: View {
    @State private var targets: [CastTarget] = []
    @State private var scanning = false
    @State private var scanned = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await scan() }
                } label: {
                    HStack {
                        Label(scanning ? "Looking for cast devices…" : scanned ? "Scan again" : "Find cast devices", systemImage: "airplayvideo")
                        Spacer()
                        if scanning { ProgressView() }
                    }
                }
                .disabled(scanning)
            } footer: {
                Text("Finds Chromecasts and Google TVs, DLNA TVs and speakers (including Sonos, music only) and AirPlay devices.")
            }

            if !targets.isEmpty {
                Section("Found") {
                    ForEach(targets) { t in
                        NavigationLink { CastTargetView(target: t) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t.name)
                                HStack(spacing: 6) {
                                    ForEach(t.kinds, id: \.self) { k in
                                        Text(k).font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 7).padding(.vertical, 2)
                                            .background(Theme.gold.opacity(0.18), in: Capsule())
                                            .foregroundStyle(Theme.gold)
                                    }
                                    Text(t.ip).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else if scanned && !scanning {
                ContentUnavailableView("Nothing to cast to", systemImage: "tv.slash", description: Text("No Chromecast, DLNA or AirPlay device answered on this Wi-Fi."))
            }
        }
        .navigationTitle("Cast")
        .task { if !scanned { await scan() } }
    }

    private func scan() async {
        scanning = true
        let r = await CastScan.find()
        withAnimation { targets = r; scanned = true; scanning = false }
        r.isEmpty ? Haptic.error() : Haptic.success()
    }
}

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("cast-" + received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}

struct CastTargetView: View {
    let target: CastTarget
    @StateObject private var runner = Runner()
    @State private var link = ""
    @State private var method = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var importing = false
    @State private var nowSending = ""
    @State private var apPaired = false
    @State private var apPinShown = false
    @State private var apPin = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("IP address", value: target.ip)
                LabeledContent("Works with", value: target.kinds.joined(separator: ", "))
            }

            if !target.dial.isEmpty {
                Section {
                    TextField("Paste a YouTube link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("Paste") { link = UIPasteboard.general.string ?? link }
                        Spacer()
                        Button("Play on TV") { let l = link; runner.fire("Sent to YouTube on the TV") { try await YouTube.play(target.dial, link: l) } }
                            .buttonStyle(.borderedProminent)
                    }
                    .buttonStyle(.borderless)
                } header: { Text("YouTube") }
            }

            if !target.avt.isEmpty && !target.music {
                MirrorSection(target: target, runner: runner)
            }

            if target.air {
                Section {
                    if apPaired {
                        Label("Paired: photos, videos and music work", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Pair again", role: .destructive) { AirPlay2.shared.forget(target.ip); apPaired = false }
                    } else if !apPinShown {
                        Button {
                            Task {
                                if await runner.run("Check the TV for the PIN", { try await AirPlay2.shared.startPairing(target.ip); return "" }) != nil {
                                    withAnimation { apPinShown = true }
                                }
                            }
                        } label: { Label("Start AirPlay pairing", systemImage: "lock.open.display") }
                    } else {
                        HStack {
                            TextField("PIN on the TV", text: $apPin).keyboardType(.numberPad)
                            Button("Pair") {
                                let p = apPin.trimmed
                                Task {
                                    if await runner.run("Paired", { try await AirPlay2.shared.finishPairing(target.ip, pin: p); return "" }) != nil {
                                        withAnimation { apPaired = true }; Haptic.success()
                                    }
                                    apPinShown = false; apPin = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } header: {
                    Text("AirPlay")
                } footer: {
                    Text(apPaired ? "" : "Apple TVs and newer AirPlay TVs need a one-time pairing. The TV shows a PIN.")
                }
            }

            if !target.methods.isEmpty {
                Section {
                    if target.methods.count > 1 {
                        Picker("Send using", selection: $method) {
                            ForEach(target.methods, id: \.self) { m in Text(label(m)).tag(m) }
                        }
                    }
                    PhotosPicker(selection: $photoItem, matching: target.music ? PHPickerFilter.images : PHPickerFilter.any(of: [.images, .videos])) {
                        Label(target.music ? "Pick a photo" : "Pick a photo or video", systemImage: "photo.on.rectangle")
                    }
                    .disabled(target.music)
                    Button { importing = true } label: { Label("Pick a music or video file", systemImage: "music.note") }
                    if !nowSending.isEmpty { Text(nowSending).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("From this iPhone")
                } footer: {
                    Text(target.music ? "Sonos plays music files (MP3, M4A, FLAC, WAV)." : "MP4 video and JPEG photos work on almost everything. Keep the app open while it plays.")
                }

                Section("Controls") {
                    HStack {
                        Spacer()
                        RemoteKey(icon: "play.fill", size: 52) { ctl("play") }
                        Spacer()
                        RemoteKey(icon: "pause.fill", size: 52) { ctl("pause") }
                        Spacer()
                        RemoteKey(icon: "stop.fill", size: 52) { ctl("stop") }
                        Spacer()
                    }
                    if target.cast {
                        HStack {
                            Spacer()
                            RemoteKey(icon: "speaker.minus.fill", size: 46, repeats: true) { vol("voldown") }
                            Spacer()
                            RemoteKey(icon: "speaker.slash.fill", size: 46) { vol("mute") }
                            Spacer()
                            RemoteKey(icon: "speaker.plus.fill", size: 46, repeats: true) { vol("volup") }
                            Spacer()
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }

            NetworkChecks(ip: target.ip, runner: runner)
        }
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .notes(runner)
        .onAppear {
            if method.isEmpty { method = target.methods.first ?? "" }
            apPaired = AirPlay2.isPaired(target.ip)
            if apPaired && target.air && !target.cast { method = "airplay" }
        }
        .onChange(of: photoItem) { _, item in if let item { Task { await sendPhotoItem(item) } } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie, .image]) { r in
            if case .success(let u) = r { Task { await sendFile(u) } }
        }
    }

    private func label(_ m: String) -> String { ["dlna": "DLNA", "cast": "Google Cast", "airplay": "AirPlay"][m] ?? m }

    private func sendPhotoItem(_ item: PhotosPickerItem) async {
        nowSending = "Getting it ready…"
        defer { photoItem = nil }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let m = try? await item.loadTransferable(type: PickedMovie.self) else { runner.show("Couldn't open that video.", error: true); nowSending = ""; return }
            await send(m.url, type: "video/mp4")
        } else {
            guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.9) else {
                runner.show("Couldn't open that photo.", error: true); nowSending = ""; return
            }
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("cast-\(UUID().uuidString.prefix(6)).jpg")
            try? jpg.write(to: f)
            await send(f, type: "image/jpeg")
        }
    }

    private func sendFile(_ u: URL) async {
        let ok = u.startAccessingSecurityScopedResource()
        defer { if ok { u.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("cast-" + u.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.copyItem(at: u, to: dst) } catch { runner.show("Couldn't open that file.", error: true); return }
        var type = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var file = dst
        if type.hasPrefix("image/") && type != "image/jpeg", let img = UIImage(contentsOfFile: dst.path), let jpg = img.jpegData(compressionQuality: 0.9) {
            file = dst.deletingPathExtension().appendingPathExtension("jpg")
            try? jpg.write(to: file)
            type = "image/jpeg"
        }
        await send(file, type: type)
    }

    private func send(_ file: URL, type: String) async {
        nowSending = "Sending \(file.lastPathComponent.replacingOccurrences(of: "cast-", with: ""))…"
        let m = method.isEmpty ? (target.methods.first ?? "dlna") : method
        await runner.run("Playing on \(target.name)") {
            let url = try MediaServer.shared.publish(file, type: type, for: target.ip)
            switch m {
            case "cast": try await Cast.load(target.ip, url: url, type: type)
            case "airplay":
                if AirPlay2.isPaired(target.ip) {
                    if type.hasPrefix("image/") { try await AirPlay2.shared.showPhoto(target.ip, jpeg: try Data(contentsOf: file)) }
                    else { try await AirPlay2.shared.playURL(target.ip, url) }
                } else {
                    if type.hasPrefix("image/") { throw AppError("Photos over AirPlay need pairing. Tap Start AirPlay pairing above.") }
                    try await AirPlay1.run(target.ip, "load", url: url)
                }
            default: try await Dlna.play(target.avt, url: url, type: type, title: file.lastPathComponent)
            }
            return ""
        }
        nowSending = ""
    }

    private func ctl(_ v: String) {
        let m = method.isEmpty ? (target.methods.first ?? "dlna") : method
        runner.fire {
            switch m {
            case "cast": try await Cast.control(target.ip, v)
            case "airplay":
                if AirPlay2.isPaired(target.ip) { try await AirPlay2.shared.control(target.ip, v) }
                else { try await AirPlay1.run(target.ip, v) }
            default:
                if v == "stop" { try await Dlna.call(target.avt, "Stop", "") }
                else if v == "pause" { try await Dlna.call(target.avt, "Pause", "") }
                else { try await Dlna.call(target.avt, "Play", "<Speed>1</Speed>") }
            }
        }
    }

    private func vol(_ v: String) { runner.fire { try await Cast.volume(target.ip, v) } }
}
