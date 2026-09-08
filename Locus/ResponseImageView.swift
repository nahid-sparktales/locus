import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A first-class `image` answer part: the workspace picture, its caption as
/// native selectable prose, and the actions a reader expects from a generated
/// image. The file is re-contained at render time and must belong to the
/// current workspace; anything else degrades to the caption and a notice.
struct ResponseImageView<Original: View>: View {
    let part: ResponsePart
    let workspacePath: String
    var onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)? = nil
    @ViewBuilder let original: () -> Original
    @Environment(\.responseOutputContext) private var context
    @State private var saveError: String?

    private var isCurrentWorkspace: Bool {
        part.workspace.map { OutputsLibraryStore.canonical($0) == OutputsLibraryStore.canonical(workspacePath) } == true
    }

    private var reference: WorkspaceArtifactReference? {
        guard isCurrentWorkspace,
              let resolved = WorkspaceArtifactReference.classify(part.path, workspacePath: workspacePath),
              resolved.kind == .image else { return nil }
        return resolved
    }

    private var dimensions: (width: Int, height: Int)? {
        guard let width = part.width, let height = part.height, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private var metadata: String {
        [part.path, dimensions.map { "\($0.width)×\($0.height)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        let base = "Generated image, \(part.imageTitle)"
        guard let dimensions else { return base }
        return base + ", \(dimensions.width) by \(dimensions.height)"
    }

    private var unavailableMessage: String {
        let path = part.path ?? ""
        return isCurrentWorkspace ? "This image is no longer at \(path)" : "This image belongs to another workspace: \(path)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            original()
            if let reference {
                AsyncWorkspaceImageArtifactView(
                    reference: reference, caption: "", selectionStore: nil, selectionSpan: nil,
                    onOpen: { onOpenWorkspaceReference?(reference) },
                    additionalActions: WorkspaceImageAction.responseActions(
                        for: reference, context: context, onError: { saveError = $0 }
                    ),
                    accessibilityIdentifierPrefix: "message.generatedImage"
                )
            } else {
                Label(unavailableMessage, systemImage: "photo")
                    .font(.locus(size: 11))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .padding(12)
                    .frame(maxWidth: 620, alignment: .leading)
                    .background(LocusTheme.paperDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityIdentifier("message.generatedImage.unavailable")
            }
            Text(metadata)
                .font(.locus(size: 11))
                .foregroundStyle(LocusTheme.textSecondary)
                .textSelection(.enabled)
            if let saveError {
                Text(saveError)
                    .font(.locus(size: 11))
                    .foregroundStyle(LocusTheme.coral)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("message.generatedImage.error")
            }
        }
        .padding(14).locusCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier("message.generatedImage")
    }

}

extension WorkspaceImageAction {
    /// The controls every workspace image in an answer offers — the generated
    /// image card and a picture the prose references alike: Edit in chat when
    /// the host allows editing, and a More menu with Copy Image and Save As….
    /// `onError` receives a message when a copy or save fails, nil once one
    /// succeeds.
    @MainActor
    static func responseActions(
        for reference: WorkspaceArtifactReference,
        context: ResponseOutputContext,
        onError: @escaping (String?) -> Void = { _ in }
    ) -> [WorkspaceImageAction] {
        var result: [WorkspaceImageAction] = []
        if context.allowsImageEditing {
            result.append(WorkspaceImageAction(id: "edit", title: "Edit in chat", symbol: "wand.and.stars") {
                context.attachImage(reference)
            })
        }
        result.append(WorkspaceImageAction(id: "more", title: "More", symbol: "ellipsis", items: [
            WorkspaceImageAction(id: "copy", title: "Copy Image", symbol: "doc.on.doc") {
                copyImage(at: reference.url, onError: onError)
            },
            WorkspaceImageAction(id: "save", title: "Save As…", symbol: "square.and.arrow.down") {
                saveImage(at: reference.url, onError: onError)
            },
        ]))
        return result
    }

    @MainActor
    private static func copyImage(at url: URL, onError: (String?) -> Void) {
        guard let image = NSImage(contentsOf: url) else {
            onError("Could not read \(url.lastPathComponent)")
            return
        }
        onError(nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @MainActor
    private static func saveImage(at url: URL, onError: (String?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: url.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: url, to: destination)
            onError(nil)
        } catch {
            onError("Could not save the image: \(error.localizedDescription)")
        }
    }
}
