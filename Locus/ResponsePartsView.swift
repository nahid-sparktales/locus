import AppKit
import SwiftUI

struct ResponseOutputContext {
    var sessionID = ""
    var notesRoot = NotesStore.applicationSupportDirectory
    var allowsEditing = true
    var outputs: OutputsLibraryModel? = nil
    var showFiles: (String, Bool?) -> Void = { _, _ in }
    var openVersion: (String, String, String) -> Void = { _, _, _ in }
    /// Attaches a workspace image to the composer for `edit_image`.
    var attachImage: (WorkspaceArtifactReference) -> Void = { _ in }
    var allowsImageEditing = false
    var interactiveAnswersEnabled = true
}

private struct ResponseOutputContextKey: EnvironmentKey {
    static let defaultValue = ResponseOutputContext()
}

extension EnvironmentValues {
    var responseOutputContext: ResponseOutputContext {
        get { self[ResponseOutputContextKey.self] }
        set { self[ResponseOutputContextKey.self] = newValue }
    }
}

/// Both the lazy-row selection provider and rendered leaves use this exact
/// projection, so a selected part survives scrolling its native view away.
@MainActor
enum ResponseSelectionProjection {
    static func spans(document: ResponseDocument, rowID: String, workspacePath: String? = nil,
                      sessionID: String? = nil, itemID: String? = nil,
                      notesRoot: URL = NotesStore.applicationSupportDirectory) -> [TranscriptSelectionSpan] {
        document.parts.enumerated().flatMap { index, part -> [TranscriptSelectionSpan] in
            if part.type == "file_collection" {
                if part.collapsed == true { return [] }
                return orderedEntries(part).enumerated().map { offset, entry in
                    fileSpan(entry: entry, partIndex: index, entryIndex: offset, rowID: rowID)
                }
            }
            if part.type == "writing", let workspacePath, let sessionID, let itemID {
                let id = ResponseWritingDrafts.documentID(workspace: workspacePath, sessionID: sessionID, itemID: itemID, part: part)
                if let draft = ResponseWritingDrafts.existing(id: id, root: notesRoot) {
                    let text = draft.lifecycle == .active ? draft.text
                        : "This draft is in Notebook Trash or was deleted. The original answer is still available."
                    return [ResponseWritingDrafts.selectionSpan(text: text, rootPath: [0, index], rowID: rowID)]
                }
            }
            return Array(MarkdownSelectionProjection.spans(
                for: FinishedMarkdownCache.blocks(for: part.type == "sources" ? sourceMarkdown(document: document, part: part) : markdown(for: part)),
                rootPath: [0, index], firstSeparator: "\n\n", rowID: rowID
            ).values)
        }
    }

    static func orderedEntries(_ part: ResponsePart) -> [ResponseFileEntry] {
        let categories = WorkspaceFileCollectionCategory.allCases
        return (part.entries ?? []).enumerated().sorted { lhs, rhs in
            let left = categories.firstIndex(of: .category(for: lhs.element.path)) ?? categories.count
            let right = categories.firstIndex(of: .category(for: rhs.element.path)) ?? categories.count
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    static func sourceMarkdown(document: ResponseDocument, part: ResponsePart) -> String {
        guard document.parts.first(where: { $0.type == "sources" })?.id == part.id else { return "" }
        return document.sources.map { source in
            "[\(source.label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]"))](<\(source.destination?.absoluteString ?? "")>)" +
                (source.document?.location.map { " — " + $0.label } ?? "")
        }.joined(separator: "\n\n")
    }

    static func fileSpan(entry: ResponseFileEntry, partIndex: Int, entryIndex: Int, rowID: String) -> TranscriptSelectionSpan {
        TranscriptSelectionSpan(treePath: [0, partIndex, entryIndex],
            displayedText: entry.path,
            separatorBefore: "\n", copyPrefix: "", rowID: rowID)
    }

    static func markdown(for part: ResponsePart) -> String {
        switch part.type {
        case "markdown": return part.text ?? ""
        case "writing": return part.originalWriting
        case "artifact": return [part.title ?? part.path, part.description].compactMap { $0 }.joined(separator: "\n\n")
        case "sources": return (part.references ?? []).map { "[\($0.label)](\($0.destination?.absoluteString ?? ""))" }.joined(separator: "\n\n")
        case "image": return [part.title ?? part.alt ?? part.path, part.prompt].compactMap { $0 }.joined(separator: "\n\n")
        case "interactive": return "### \(part.interactiveTitle)\n\n\(part.summary ?? "")"
        default: return ""
        }
    }
}

struct ResponsePartsView: View {
    let document: ResponseDocument
    let block: ChatBlock
    let workspacePath: String
    var selectionStore: TranscriptSelectionStore? = nil
    var selectionRowID = ""
    var onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)? = nil
    @Environment(\.responseOutputContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(document.parts.enumerated()), id: \.element.id) { index, part in
                switch part.type {
                case "markdown": markdown(part, index: index)
                case "file_collection": fileCollection(part, index: index)
                case "writing":
                    ResponseWritingView(part: part, sourceItemID: block.sourceItemID,
                        workspacePath: workspacePath, original: { markdown(part, index: index) },
                        selectionStore: selectionStore, selectionRootPath: [0, index], selectionRowID: selectionRowID)
                        .id(writingViewIdentity(part))
                case "artifact":
                    if let outputs = context.outputs {
                        ResponseArtifactView(part: part, block: block, workspacePath: workspacePath,
                            outputs: outputs, onOpenCurrent: openCurrent,
                            original: { markdown(part, index: index) })
                    } else { markdown(part, index: index) }
                case "sources": sourceList(part, index: index)
                case "image":
                    ResponseImageView(part: part, workspacePath: workspacePath,
                        onOpenWorkspaceReference: onOpenWorkspaceReference,
                        original: { markdown(part, index: index) })
                case "interactive":
                    InteractiveAnswerView(title: part.interactiveTitle, summary: part.summary ?? "",
                        html: part.html ?? "", height: part.interactiveHeight,
                        isEnabled: context.interactiveAnswersEnabled,
                        identity: interactiveViewIdentity(part),
                        original: { markdown(part, index: index) })
                default: EmptyView()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .environment(\.responseRegisteredSources, document.sources)
        .accessibilityIdentifier("message.structuredResponse")
    }

    /// The sealed web view is keyed by durable provider identity plus the
    /// fragment itself, so a regenerated answer with different HTML restarts
    /// its host instead of showing the old page under a new title.
    private func interactiveViewIdentity(_ part: ResponsePart) -> String {
        ResponseIdentity.key(workspace: workspacePath, sessionID: context.sessionID,
            itemID: block.sourceItemID ?? "", partID: part.id)
            + "|" + String((part.html ?? "").hashValue)
    }

    private func writingViewIdentity(_ part: ResponsePart) -> String {
        let id = ResponseWritingDrafts.documentID(workspace: workspacePath, sessionID: context.sessionID,
            itemID: block.sourceItemID ?? "", part: part)
        return context.notesRoot.standardizedFileURL.path + "|" + id.identity
    }

    private func markdown(_ part: ResponsePart, index: Int) -> some View {
        MarkdownBodyView(text: ResponseSelectionProjection.markdown(for: part), workspacePath: workspacePath,
            selectionStore: selectionStore, selectionRootPath: [0, index], selectionRowID: selectionRowID,
            onOpenWorkspaceReference: onOpenWorkspaceReference)
    }

    private func fileCollection(_ part: ResponsePart, index: Int) -> some View {
        let sameWorkspace = part.workspace.map { OutputsLibraryStore.canonical($0) == OutputsLibraryStore.canonical(workspacePath) } == true
        let entries = ResponseSelectionProjection.orderedEntries(part).enumerated().map { offset, entry in
            let resolved = sameWorkspace ? WorkspaceArtifactReference.classify(entry.path, workspacePath: workspacePath) : nil
            let reference = resolved.map { WorkspaceArtifactReference(url: $0.url, relativePath: $0.relativePath,
                kind: $0.kind, byteCount: entry.size, sourceLocation: $0.sourceLocation) }
            var runs = [MarkdownInlineRun(text: entry.path, destination: reference?.navigationURL.absoluteString)]
            if let description = entry.description { runs.append(MarkdownInlineRun(text: " — " + description)) }
            return WorkspaceFileCollectionEntry(id: entry.path, path: entry.path, runs: runs, reference: reference,
                selectionSpan: ResponseSelectionProjection.fileSpan(entry: entry, partIndex: index, entryIndex: offset, rowID: selectionRowID))
        }
        return VStack(alignment: .leading, spacing: 6) {
            WorkspaceFileCollectionView(entries: entries, title: part.title, workspacePath: sameWorkspace ? workspacePath : nil,
                selectionStore: selectionStore, onOpenWorkspaceReference: onOpenWorkspaceReference,
                onShowFiles: sameWorkspace ? { context.showFiles(workspacePath, part.showHidden ?? false) } : nil, initiallyCollapsed: part.collapsed == true)
            if part.complete != true {
                Text(part.totalCount.map { "Showing \(entries.count) of \($0) files" } ?? "Partial listing · \(entries.count) files shown")
                    .font(.locus(size: 11)).foregroundStyle(LocusTheme.muted)
            }
        }
    }

    private func sourceList(_ part: ResponsePart, index: Int) -> some View {
        let text = ResponseSelectionProjection.sourceMarkdown(document: document, part: part)
        return Group {
            if !text.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Sources").font(.locus(size: 11, weight: .semibold)).foregroundStyle(LocusTheme.muted)
                        .accessibilityAddTraits(.isHeader)
                    MarkdownBodyView(text: text, workspacePath: workspacePath,
                        selectionStore: selectionStore, selectionRootPath: [0, index], selectionRowID: selectionRowID,
                        onOpenWorkspaceReference: onOpenWorkspaceReference)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("message.responseSources")
            }
        }
    }

    private func openCurrent(_ path: String) {
        guard let reference = WorkspaceArtifactReference.classify(path, workspacePath: workspacePath) else { return }
        onOpenWorkspaceReference?(reference)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ResponseArtifactView<Original: View>: View {
    let part: ResponsePart
    let block: ChatBlock
    let workspacePath: String
    @ObservedObject var outputs: OutputsLibraryModel
    let onOpenCurrent: (String) -> Void
    @ViewBuilder let original: () -> Original
    @Environment(\.responseOutputContext) private var context
    @State private var binding: ResponseArtifactBinding?
    @State private var status = "Saving version…"
    @State private var available = false
    @State private var requestGeneration = UUID()

    private var identity: String {
        let origin = ResponseIdentity.key(workspace: workspacePath, sessionID: context.sessionID,
            itemID: block.sourceItemID ?? "", partID: part.id)
        return origin + [block.runID ?? "", part.path ?? "", part.workspace.map(OutputsLibraryStore.canonical) ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    private var isCurrentWorkspace: Bool {
        part.workspace.map { OutputsLibraryStore.canonical($0) == OutputsLibraryStore.canonical(workspacePath) } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            original()
            Text([part.path, status].compactMap { $0 }.joined(separator: " · "))
                .font(.locus(size: 11)).foregroundStyle(LocusTheme.muted)
                .textSelection(.enabled)
            HStack {
                Button("Open saved version") {
                    guard let binding, isCurrentWorkspace else { return }
                    context.openVersion(binding.outputID, binding.versionID, workspacePath)
                }
                .disabled(!available || !isCurrentWorkspace)
                if let path = part.path {
                    Button("Current file") { onOpenCurrent(path) }.disabled(!isCurrentWorkspace)
                }
            }
            .buttonStyle(.locus()).font(.locus(size: 11))
        }
        .padding(14).locusCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.deliveredArtifact")
        .task(id: "\(identity)|\(outputs.responseRevision)") { await loadBinding() }
    }

    private func loadBinding() async {
        let request = UUID(), key = identity
        requestGeneration = request
        binding = nil; available = false; status = "Saving version…"
        guard let itemID = block.sourceItemID, !itemID.isEmpty,
              let runID = block.runID, !context.sessionID.isEmpty,
              let path = part.path, isCurrentWorkspace
        else { status = "Current file reference"; return }
        if outputs.isCapturingResponse(sessionID: context.sessionID, runID: runID) { return }
        do {
            let result = try await outputs.responseBinding(key: key, workspace: workspacePath,
                path: path, sessionID: context.sessionID, runID: runID)
            let isAvailable: Bool
            if let result { isAvailable = try await outputs.store.responseVersionAvailable(result, workspace: workspacePath) }
            else { isAvailable = false }
            guard !Task.isCancelled, requestGeneration == request, identity == key else { return }
            binding = result; available = isAvailable
            status = result.map { $0.unavailableReason ?? (isAvailable ? "Saved version" : "Saved version unavailable") }
                ?? "Version not saved"
        } catch {
            guard !Task.isCancelled, requestGeneration == request, identity == key else { return }
            status = "Version not saved: \(error.localizedDescription)"
        }
    }
}
