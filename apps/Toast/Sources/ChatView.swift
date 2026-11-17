import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Text Toast, with photos, camera shots, PDFs and text files.
struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var attachProblem: String?
    @FocusState private var focused: Bool

    private let chips = ["what's due", "my grades", "what tests do i have", "quiz me", "what should i do first"]
    private let maxFiles = 4

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let p = attachProblem {
                Text(p).font(.caption).foregroundStyle(Tan.bad).padding(.horizontal, 14).padding(.vertical, 4)
            }
            if text.isEmpty && attachments.isEmpty && !focused {
                chipRow
            }
            if !attachments.isEmpty {
                attachmentRow
            }
            inputBar
        }
        .background(Tan.bg.ignoresSafeArea())
        .navigationTitle("Toast")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.loadHistory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: maxFiles, matching: .images)
        .onChange(of: photoItems) { _, items in
            if items.isEmpty { return }
            let picked = items
            photoItems = []
            Task { await addPhotos(picked) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .plainText, .commaSeparatedText, .json],
                      allowsMultipleSelection: true) { result in
            addFiles(result)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image = image { addImage(image, name: "photo.jpg") }
                showCamera = false
            }
            .ignoresSafeArea()
        }
    }

    // MARK: pieces

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let e = model.chatError, model.messages.isEmpty {
                        Note(text: e, bad: true).padding(.top, 30)
                    } else if model.messages.isEmpty && model.historyLoaded {
                        Note(text: "Say hi to Toast 🍞").padding(.top, 30)
                    }
                    ForEach(model.messages) { m in
                        Bubble(msg: m)
                            .id(m.id)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = m.text
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                Button(role: .destructive) {
                                    Task { await model.delete(m) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    if model.sending {
                        TypingRow().id("typing")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.sending) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: focused) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { c in
                    Button {
                        Haptic.tap()
                        Task { await model.send(text: c, files: []) }
                    } label: {
                        Text(c)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Tan.chipText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Tan.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    AttachmentChip(item: a) {
                        attachments.removeAll { $0.id == a.id }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button {
                    showPhotos = true
                } label: {
                    Label("Photo library", systemImage: "photo.on.rectangle")
                }
                Button {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCamera = true
                    } else {
                        attachProblem = "No camera on this device."
                    }
                } label: {
                    Label("Take a photo", systemImage: "camera")
                }
                Button {
                    showFiles = true
                } label: {
                    Label("File (PDF or text)", systemImage: "doc")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Tan.brown)
            }
            TextField("Text Toast", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .foregroundStyle(Tan.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Tan.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Tan.line, lineWidth: 0.5))
            Button {
                sendNow()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? Tan.brown : Tan.faint)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Tan.bar)
    }

    private var canSend: Bool {
        if model.sending { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    // MARK: actions

    private func sendNow() {
        if !canSend { return }
        let t = text
        let files = attachments
        text = ""
        attachments = []
        attachProblem = nil
        Haptic.tap()
        Task { await model.send(text: t, files: files) }
    }

    private func room() -> Bool {
        if attachments.count >= maxFiles {
            attachProblem = "Up to \(maxFiles) files per message."
            return false
        }
        return true
    }

    private func addImage(_ image: UIImage, name: String) {
        if !room() { return }
        guard let data = Shrink.jpeg(image) else {
            attachProblem = "Couldn't read that photo."
            return
        }
        attachments.append(Attachment(name: name, type: "image/jpeg", data: data, thumb: Shrink.thumb(image)))
        attachProblem = nil
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        var n = attachments.count
        for item in items {
            let data = try? await item.loadTransferable(type: Data.self)
            if let data = data, let image = UIImage(data: data) {
                n += 1
                addImage(image, name: "photo\(n).jpg")
            } else {
                attachProblem = "Couldn't load one of the photos."
            }
        }
    }

    private func addFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            attachProblem = "Couldn't open that file."
            return
        }
        for url in urls {
            if !room() { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? Data(contentsOf: url) else {
                attachProblem = "Couldn't read " + url.lastPathComponent
                continue
            }
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                if data.count > 20_000_000 {
                    attachProblem = name + " is too big (max 20 MB)."
                    continue
                }
                attachments.append(Attachment(name: name, type: "application/pdf", data: data))
            } else if ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(ext), let image = UIImage(data: data) {
                addImage(image, name: name.replacingOccurrences(of: "." + url.pathExtension, with: ".jpg"))
            } else {
                if data.count > 200_000 {
                    attachProblem = name + " is too long for Toast to read."
                    continue
                }
                attachments.append(Attachment(name: name, type: "text/plain", data: data))
            }
        }
    }
}

/// Makes photos small enough to send (Toast's limit is 5 MB per image).
enum Shrink {
    static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        if longest <= 0 { return image }
        let scale = min(1, maxSide / longest)
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func jpeg(_ image: UIImage) -> Data? {
        resized(image, maxSide: 1800).jpegData(compressionQuality: 0.75)
    }

    static func thumb(_ image: UIImage) -> UIImage {
        resized(image, maxSide: 160)
    }
}

struct AttachmentChip: View {
    let item: Attachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let thumb = item.thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: item.type == "application/pdf" ? "doc.richtext.fill" : "doc.text.fill")
                    .foregroundStyle(Tan.brown)
                    .frame(width: 34, height: 34)
            }
            Text(item.name).font(.caption).foregroundStyle(Tan.text).lineLimit(1).frame(maxWidth: 110)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Tan.faint)
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(Tan.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tan.line, lineWidth: 0.5))
    }
}

struct Bubble: View {
    let msg: ChatMsg

    private var mine: Bool { msg.role == "user" }

    private var noteLabel: String? {
        if msg.kind != "note" { return nil }
        switch msg.source {
        case "reminder": return "⏰ Reminder"
        case "brief": return "☀️ Brief"
        case "system": return "⚙️ Toast"
        default: return "🔔 Alert"
        }
    }

    var body: some View {
        if msg.role == "info" {
            Text(msg.text)
                .font(.caption)
                .foregroundStyle(Tan.bad)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        } else {
            HStack {
                if mine { Spacer(minLength: 44) }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    if let label = noteLabel {
                        Text(label).font(.caption2.weight(.bold)).foregroundStyle(Tan.muted)
                    }
                    Text(msg.text)
                        .font(.body)
                        .foregroundStyle(mine ? Color.white : Tan.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(mine ? Tan.brown : (msg.kind == "note" ? Tan.bar : Tan.card),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(mine ? Color.clear : Tan.line, lineWidth: 0.5)
                        )
                    let stamp = Stamp.label(msg.date)
                    if !stamp.isEmpty {
                        Text(stamp).font(.system(size: 10)).foregroundStyle(Tan.faint)
                    }
                }
                if !mine { Spacer(minLength: 44) }
            }
        }
    }
}

struct TypingRow: View {
    @State private var on = false

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Tan.muted)
                        .frame(width: 7, height: 7)
                        .opacity(on ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Tan.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Toast is typing").font(.caption).foregroundStyle(Tan.faint)
            Spacer()
        }
        .onAppear { on = true }
    }
}

/// The system camera, for snapping homework.
struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void

        init(done: @escaping (UIImage?) -> Void) {
            self.done = done
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            done(nil)
        }
    }
}
