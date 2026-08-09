import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An image that exists only on the pasteboard — no file URL behind it.
struct PastedImage: Equatable {
    let data: Data
    let mimeType: String
}

/// Pure decision table for a paste while the composer is focused. Kept free of
/// AppKit so the rules are unit-testable: file URLs win over everything (a
/// Finder copy also carries the filename as a string), raw image data attaches
/// only when no plain text rides along (copied rich text keeps pasting as
/// text), and anything else passes through to the editor untouched.
enum ChatPasteboardClassifier {
    enum Decision: Equatable {
        case attachFiles([URL])
        case attachImages([PastedImage])
        case passthrough
    }

    static func classify(
        fileURLs: [URL],
        plainText: String?,
        images: [PastedImage]
    ) -> Decision {
        if !fileURLs.isEmpty {
            let local = fileURLs.filter(\.isFileURL)
            return local.isEmpty ? .passthrough : .attachFiles(local)
        }
        if !images.isEmpty, (plainText ?? "").isEmpty {
            return .attachImages(images)
        }
        return .passthrough
    }

    /// The pasteboard's image payload with an honest MIME type, or nothing.
    /// PNG is kept verbatim; everything else goes through the same JPEG
    /// transcode as file attachments so the agent never sees raw TIFF.
    static func imagePayload(pngData: Data?, tiffData: Data?) -> PastedImage? {
        if let pngData, !pngData.isEmpty {
            return PastedImage(data: pngData, mimeType: "image/png")
        }
        guard let tiffData, !tiffData.isEmpty,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpeg = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.88]
              )
        else { return nil }
        return PastedImage(data: jpeg, mimeType: "image/jpeg")
    }

    static func read(from pasteboard: NSPasteboard) -> Decision {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let plainText = pasteboard.string(forType: .string)
        let image = imagePayload(
            pngData: pasteboard.data(forType: .png),
            tiffData: pasteboard.data(forType: .tiff)
        )
        return classify(
            fileURLs: urls.filter(\.isFileURL),
            plainText: plainText,
            images: image.map { [$0] } ?? []
        )
    }
}

/// Routes a classified paste or drop into the model's existing attachment
/// pipeline, which owns scoping, dedupe, caps, and notices.
@MainActor
enum ChatAttachmentIngest {
    static func apply(_ decision: ChatPasteboardClassifier.Decision, to model: AppModel) -> Bool {
        switch decision {
        case .attachFiles(let urls):
            model.loadChatAttachments(from: urls)
            return true
        case .attachImages(let images):
            model.addPastedImages(images.map { (data: $0.data, mimeType: $0.mimeType) })
            return true
        case .passthrough:
            return false
        }
    }

    static func handleDrop(_ providers: [NSItemProvider], model: AppModel) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        if !fileProviders.isEmpty {
            let group = DispatchGroup()
            var dropped: [URL] = []
            let guardQueue = DispatchQueue(label: "locus.attachment-drop")
            for provider in fileProviders {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL {
                        guardQueue.sync { dropped.append(url) }
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let urls = guardQueue.sync { dropped }
                guard !urls.isEmpty else { return }
                Task { @MainActor in
                    model.loadChatAttachments(from: urls)
                }
            }
            return true
        }
        let imageProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !imageProviders.isEmpty else { return false }
        for provider in imageProviders {
            provider.loadDataRepresentation(
                forTypeIdentifier: UTType.image.identifier
            ) { data, _ in
                guard let data,
                      let image = ChatPasteboardClassifier.imagePayload(
                          pngData: data.isPNG ? data : nil,
                          tiffData: data.isPNG ? nil : data
                      )
                else { return }
                Task { @MainActor in
                    model.addPastedImages([(data: image.data, mimeType: image.mimeType)])
                }
            }
        }
        return true
    }
}

extension Data {
    /// The eight-byte PNG signature — enough to route pasted data honestly.
    var isPNG: Bool {
        starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}

/// Accepts Finder files and raw image drags anywhere the modifier is applied,
/// with a visible target highlight while a drag hovers.
struct ChatAttachmentDropTarget: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                ChatAttachmentIngest.handleDrop(providers, model: model)
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(LocusTheme.signal, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(LocusTheme.signal.opacity(0.06))
                        )
                        .overlay {
                            Label("Drop to attach", systemImage: "paperclip")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(LocusTheme.signal)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(LocusTheme.white.opacity(0.92))
                                .clipShape(Capsule())
                        }
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func chatAttachmentDropTarget() -> some View {
        modifier(ChatAttachmentDropTarget())
    }
}

/// Intercepts ⌘V ahead of the Edit menu — but only while the composer's own
/// editor is focused. A key-equivalent monitor is the only hook that reliably
/// runs before the menu's Paste claims the shortcut, and it sees every key
/// window's events, so an unguarded monitor would hijack paste from the
/// commit-message field, the sidebar search, and every sheet. The decision
/// itself stays in the pure classifier; anything that is not an attachment
/// paste falls through to normal handling.
struct ChatPasteInterceptor: ViewModifier {
    /// The monitor closure outlives any one render, so the current focus
    /// value reaches it through a reference box, not a captured struct copy.
    @MainActor
    final class FocusBox {
        var editorFocused = false
    }

    @EnvironmentObject private var model: AppModel
    let editorFocused: Bool
    @State private var box = FocusBox()
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                box.editorFocused = editorFocused
                guard monitor == nil else { return }
                let box = box
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // Plain ⌘V only — ⇧⌘V and friends keep their own meanings,
                    // and Caps Lock or the Fn flag must not defeat the match.
                    guard MainActor.assumeIsolated({ box.editorFocused }),
                          event.modifierFlags.contains(.command),
                          event.modifierFlags.isDisjoint(with: [.shift, .option, .control]),
                          event.charactersIgnoringModifiers?.lowercased() == "v"
                    else { return event }
                    let decision = ChatPasteboardClassifier.read(from: .general)
                    return ChatAttachmentIngest.apply(decision, to: model) ? nil : event
                }
            }
            .onChange(of: editorFocused) {
                box.editorFocused = editorFocused
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                monitor = nil
            }
    }
}

extension View {
    func chatPasteInterceptor(editorFocused: Bool) -> some View {
        modifier(ChatPasteInterceptor(editorFocused: editorFocused))
    }
}
