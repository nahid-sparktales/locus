import AppKit
import CoreGraphics
import SwiftUI

/// Captured ownership for every Companion input and read. The central chat's
/// selection is never used to resolve the destination of an asynchronous result.
struct CompanionConversationScope: Equatable, Hashable {
    let sessionID: String
    let workspace: String
    let profileID: UUID
}

@MainActor
final class CompanionContextSharingModel: ObservableObject {
    @Published private(set) var scope: CompanionConversationScope?
    @Published private(set) var attachments: [ChatAttachment] = []
    @Published private(set) var pending: [ChatAttachment] = []
    @Published private(set) var isPreparing = false
    @Published var notice: String?
    private var revision = UUID()
    private var browserSnapshot: (() async throws -> ChatAttachment)?
    private var applicationSnapshot: (() async throws -> ChatAttachment)?

    func configure(browserSnapshot: @escaping () async throws -> ChatAttachment,
                   applicationSnapshot: @escaping () async throws -> ChatAttachment) {
        self.browserSnapshot = browserSnapshot
        self.applicationSnapshot = applicationSnapshot
    }

    func activate(_ newScope: CompanionConversationScope?) {
        guard scope != newScope else { return }
        revision = UUID()
        scope = newScope
        attachments = []
        pending = []
        notice = nil
        isPreparing = false
    }

    static func textAttachment(_ text: String, name: String) -> ChatAttachment {
        ChatAttachment(url: URL(fileURLWithPath: "/dev/null/companion-\(UUID().uuidString).txt"),
                       kind: .text, textContent: text, overrideName: name)
    }

    func previewText(_ text: String, name: String) {
        guard scope != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { notice = "Enter the text you want to share."; return }
        guard value.utf8.count <= 500_000 else { notice = "Selected text must be smaller than 500 KB."; return }
        pending = [Self.textAttachment(value, name: name)]
        notice = nil
    }

    func chooseFiles() {
        guard scope != nil, !isPreparing else { return }
        let panel = NSOpenPanel()
        panel.title = "Share files with Companion"
        panel.message = "Review the selected contents before attaching. This does not grant folder access."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Preview"
        guard panel.runModal() == .OK else { return }
        let urls = Array(panel.urls.prefix(10))
        prepare {
            let secured = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { secured.forEach { $0.stopAccessingSecurityScopedResource() } }
            return await Task.detached(priority: .userInitiated) {
                ChatAttachmentLoader.readChatAttachments(urls, excluding: [])
            }.value
        }
    }

    func previewBrowser() {
        guard let browserSnapshot else { notice = "Open a browser page in Locus first."; return }
        prepare { .init(attachments: [try await browserSnapshot()], notice: nil) }
    }

    func previewApplication() {
        guard let applicationSnapshot else { notice = "Select an application first."; return }
        prepare { .init(attachments: [try await applicationSnapshot()], notice: nil) }
    }

    func previewRegion() {
        guard !IdentityPrivacyGuard.shared.blocksCapture else {
            notice = ApplicationContextError.privateIdentitySurface.localizedDescription
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            notice = ApplicationContextError.screenRecordingPermission.localizedDescription
            return
        }
        prepare {
            let attachment = try await Task.detached(priority: .userInitiated) { () throws -> ChatAttachment? in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("companion-region-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: url) }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-s", "-x", "-t", "png", url.path]
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else { return nil }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 15_000_000 else { throw ApplicationContextError.screenshotTooLarge }
                return ChatAttachment.pasted(imageData: try Data(contentsOf: url), mimeType: "image/png", nameStem: "Selected region")
            }.value
            guard !IdentityPrivacyGuard.shared.blocksCapture else { throw ApplicationContextError.privateIdentitySurface }
            return .init(attachments: attachment.map { [$0] } ?? [], notice: nil)
        }
    }

    private func prepare(_ operation: @escaping () async throws -> ChatAttachmentLoadResult) {
        guard scope != nil, !isPreparing else { return }
        let captured = revision
        isPreparing = true
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            defer { if revision == captured { isPreparing = false } }
            do {
                let result = try await operation()
                guard revision == captured else { return }
                pending = result.attachments
                notice = result.notice
            } catch {
                guard revision == captured else { return }
                notice = error.localizedDescription
            }
        }
    }

    @discardableResult
    func approvePreview() -> Bool {
        guard scope != nil, !pending.isEmpty else { return false }
        let merged = attachments + pending
        guard merged.count <= 10,
              merged.allSatisfy({ $0.isAvailable && ($0.imageData?.count ?? 0) <= 15_000_000 }),
              merged.reduce(0, { $0 + ($1.imageData?.count ?? 0) }) <= 25_000_000,
              merged.reduce(0, { $0 + ($1.textContent?.utf8.count ?? 0) }) <= 750_000 else {
            notice = "A message allows 10 items, 25 MB of images and 750 KB of text. Remove an item and try again."
            return false
        }
        attachments = merged
        pending = []
        return true
    }

    func cancelPreview() { pending = [] }
    func remove(_ id: UUID) { attachments.removeAll { $0.id == id } }

    /// Only clear the exact inputs accepted by the canonical worker; a newer
    /// draft, cleared chat or replacement Companion keeps its own inputs.
    func consume(_ ids: Set<UUID>, for captured: CompanionConversationScope) {
        guard scope == captured else { return }
        attachments.removeAll { ids.contains($0.id) }
    }
}

struct CompanionContextSharingView: View {
    @ObservedObject var model: CompanionContextSharingModel
    var compact = false
    @State private var textEntry = false
    @State private var ownsPreview = false
    @State private var selectedText = ""
    @State private var textKind = "Selected text"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                Button("Selected text or error…") {
                    model.cancelPreview(); ownsPreview = true; textEntry = true
                }
                Button("File…") { beginPreview { model.chooseFiles() } }
                Button("Current browser page") { beginPreview { model.previewBrowser() } }
                Button("Last active application") { beginPreview { model.previewApplication() } }
                Button("Screenshot region…") { beginPreview { model.previewRegion() } }
            } label: { Label(model.isPreparing ? "Preparing context…" : "Look at this", systemImage: "paperclip") }
                .font(compact ? .locus(size: 10, weight: .medium) : .body)
                .frame(height: compact ? 30 : nil)
                .disabled(model.scope == nil || model.isPreparing)
                .accessibilityIdentifier("companion.context.add")
            if !compact { CompanionContextSharingAttachmentsView(model: model) }
        }
        // Entry and review occupy one sheet. Two sibling sheets can dismiss
        // each other's data during the presentation handoff. Only the surface
        // that initiated a share presents it; the center and inspector may
        // both observe the same canonical attachments.
        .sheet(isPresented: Binding(get: { ownsPreview && (textEntry || !model.pending.isEmpty) },
                                    set: { if !$0 { dismissPreview() } })) {
            if textEntry { textEntryForm } else { previewForm }
        }
        .onChange(of: model.scope) { _, _ in
            textEntry = false; ownsPreview = false; selectedText = ""
        }
    }

    private func beginPreview(_ action: () -> Void) {
        model.cancelPreview()
        ownsPreview = true
        action()
        if !model.isPreparing && model.pending.isEmpty { ownsPreview = false }
    }

    private func dismissPreview() {
        textEntry = false
        ownsPreview = false
        model.cancelPreview()
    }

    private var textEntryForm: some View {
        VStack(alignment: .leading, spacing: 12) {
                Text("Share selected text").font(.headline)
                Text("Paste only the text or error you want your Companion to receive.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Context type", selection: $textKind) {
                    Text("Selected text").tag("Selected text")
                    Text("Error").tag("Error")
                }.pickerStyle(.segmented)
                TextEditor(text: $selectedText).frame(minHeight: 160)
                    .accessibilityIdentifier("companion.context.text")
                HStack {
                    Button("Cancel") { dismissPreview() }
                    Spacer()
                    Button("Review") {
                        model.previewText(selectedText, name: textKind)
                        if !model.pending.isEmpty { textEntry = false; selectedText = "" }
                    }.disabled(selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("companion.context.review")
                }
        }.padding(20).frame(width: 460)
    }

    private var previewForm: some View {
        VStack(alignment: .leading, spacing: 12) {
                Text("Review shared context").font(.headline)
                Text("Only these contents will accompany your next Companion message. No folder or application control is granted.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.pending) { item in
                            Text(item.name).font(.headline)
                            if let data = item.imageData, let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                            }
                            if let text = item.textContent ?? item.applicationContext?.accessibilityText {
                                Text(text).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 400)
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") { dismissPreview() }
                    Spacer()
                    Button("Attach to Companion") {
                        if model.approvePreview() { ownsPreview = false }
                    }
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("companion.context.confirm")
                }
        }.padding(20).frame(width: 480)
    }
}

struct CompanionContextSharingAttachmentsView: View {
    @ObservedObject var model: CompanionContextSharingModel

    var body: some View {
        if !model.attachments.isEmpty || model.notice != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.attachments) { item in
                    HStack {
                        Label(item.name, systemImage: item.kind == .text ? "doc.text" : "photo")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button { model.remove(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.locus(.icon)).accessibilityLabel("Remove \(item.name)")
                    }.font(.caption)
                }
                if !model.attachments.isEmpty {
                    Text("Shared with your next Companion message · This conversation only")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
