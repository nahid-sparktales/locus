import AppKit
import Combine
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ResponseWritingDrafts {
    static func documentID(workspace: String, sessionID: String, itemID: String, part: ResponsePart) -> NotesDocumentID {
        let provenance = ResponseIdentity.key(workspace: workspace, sessionID: sessionID, itemID: itemID, partID: part.id)
        // An authoritative replacement/regeneration cannot overwrite edits to
        // an earlier version, even if a provider reuses its item identifier.
        return NotesDocumentID(directoryName: NotesDocumentID.standaloneDirectoryName,
            digest: NotesStore.digest(of: "response-writing\u{0}" + provenance + "\u{0}" + part.originalWriting))
    }

    static func existing(id: NotesDocumentID, root: URL) -> NotesStore? {
        let store = NotesStore.shared(documentID: id, scope: .global, applicationSupport: root)
        return (FileManager.default.fileExists(atPath: store.fileURL.path) || FileManager.default.fileExists(atPath: store.styledFileURL.path)) || store.lifecycle != .active ? store : nil
    }

    static func edit(id: NotesDocumentID, part: ResponsePart, root: URL) throws -> NotesStore {
        let attributed = importMarkdown(part.originalWriting)
        return try NotesStore.create(title: String(part.writingTitle.prefix(200)), attributed: attributed,
            documentID: id, applicationSupport: root)
    }

    static func selectionSpan(text: String, rootPath: [Int], rowID: String) -> TranscriptSelectionSpan {
        TranscriptSelectionSpan(treePath: rootPath + [0], displayedText: text,
            separatorBefore: "\n\n", copyPrefix: "", rowID: rowID)
    }
    /// The same Markdown tree used by the response renderer supplies the
    /// editor. Code blocks keep their literal body and line breaks.
    static func importMarkdown(_ source: String) -> NSAttributedString {
        func inline(_ runs: [MarkdownInlineRun], heading: Bool = false) -> NSAttributedString {
            let output = NSMutableAttributedString()
            for run in runs {
                var font = run.style.contains(.code)
                    ? NSFont.monospacedSystemFont(ofSize: NotesTextStyle.defaultFontSize, weight: .regular)
                    : NotesTextStyle.defaultFont
                if heading || run.style.contains(.strong) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if run.style.contains(.emphasis) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NotesTextStyle.defaultColor]
                if run.style.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let destination = run.destination, let url = MarkdownLinkPolicy.safeURL(destination, workspacePath: nil) { attributes[.link] = url }
                output.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            return output
        }
        func blocks(_ values: [MarkdownRenderBlock]) -> NSAttributedString {
            let output = NSMutableAttributedString()
            for (index, block) in values.enumerated() {
                if index > 0 { output.append(NotesTextStyle.plain("\n\n")) }
                switch block {
                case .paragraph(let runs): output.append(inline(runs))
                case .heading(_, let runs): output.append(inline(runs, heading: true))
                case .code(_, let body):
                    output.append(NSAttributedString(string: body, attributes: [.font: NSFont.monospacedSystemFont(ofSize: NotesTextStyle.defaultFontSize, weight: .regular), .foregroundColor: NotesTextStyle.defaultColor]))
                case .unordered(let items), .ordered(_, let items):
                    for (offset, item) in items.enumerated() {
                        if offset > 0 { output.append(NotesTextStyle.plain("\n")) }
                        let marker: String
                        if let checked = item.checked { marker = checked ? "☑ " : "☐ " }
                        else if case .ordered(let start, _) = block { marker = "\(start + offset). " }
                        else { marker = "• " }
                        output.append(NotesTextStyle.plain(marker)); output.append(blocks(item.blocks))
                    }
                case .quote(let nested): output.append(blocks(nested))
                case .table(let headers, _, let rows):
                    output.append(NotesTextStyle.plain(MarkdownTableExport.render(headers: headers, rows: rows, format: .tsv)))
                case .rule: output.append(NotesTextStyle.plain("—"))
                case .rawText(let text): output.append(NotesTextStyle.plain(text))
                }
            }
            return output
        }
        return blocks(MarkdownDocumentParser.parse(source))
    }

}

struct ResponseWritingView<Original: View>: View {
    let part: ResponsePart
    let sourceItemID: String?
    let workspacePath: String
    @ViewBuilder let original: () -> Original
    var selectionStore: TranscriptSelectionStore? = nil
    var selectionRootPath: [Int] = []
    var selectionRowID = ""
    @Environment(\.responseOutputContext) private var context
    @State private var draft: NotesStore?
    @State private var editing = false
    @State private var showsOriginal = false
    @State private var error: String?
    @State private var copied = false
    @State private var selectedRows: Set<String> = []

    private var identity: NotesDocumentID? {
        guard context.allowsEditing, !context.sessionID.isEmpty,
              let sourceItemID, !sourceItemID.isEmpty else { return nil }
        return ResponseWritingDrafts.documentID(workspace: workspacePath, sessionID: context.sessionID,
            itemID: sourceItemID, part: part)
    }

    private var isSelecting: Bool { selectedRows.contains(selectionRowID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(part.writingTitle).font(.locus(size: 13, weight: .semibold))
                if draft != nil && !showsOriginal {
                    Text("Edited").font(.locus(size: 11)).foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button(copied ? "Copied" : "Copy") { copyVisible() }
                    .accessibilityIdentifier("message.writing.copy")
                Button(editing ? "Done" : "Edit") {
                    if editing { finishEditing() } else { edit() }
                }
                .disabled(identity == nil || isSelecting)
                .accessibilityIdentifier("message.writing.edit")
                Menu {
                    if draft != nil {
                        Button(showsOriginal ? "View edited draft" : "View original") {
                            finishEditing(); showsOriginal.toggle(); reconcileSelection()
                        }
                        .disabled(isSelecting)
                    }
                    Button("Copy original") { copy(MarkdownPlainTextRenderer.render(part.originalWriting)) }
                    Button("Copy original Markdown") { copy(part.originalWriting) }
                    Divider()
                    Button("Export as Text…") { export(rich: false) }
                    Button("Export as Rich Text…") { export(rich: true) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Writing actions")
            }
            .buttonStyle(.locus()).font(.locus(size: 11))
            if let draft, !showsOriginal {
                ResponseWritingDraftContent(store: draft, editing: editing,
                    selectionStore: selectionStore, selectionRootPath: selectionRootPath, selectionRowID: selectionRowID)
            } else { original() }
            if let error {
                HStack {
                    Text(error).foregroundStyle(LocusTheme.coral).textSelection(.enabled)
                    Button("Retry") { edit() }
                }
                .font(.locus(size: 11))
                .accessibilityIdentifier("message.writing.error")
            }
        }
        .padding(14).locusCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(part.writingTitle), writing block")
        .accessibilityIdentifier("message.writing")
        .task(id: identity?.identity) {
            loadDraft()
        }
        .onReceive(selectionStore?.$selectedRowIDs.eraseToAnyPublisher() ?? Just(Set<String>()).eraseToAnyPublisher()) {
            selectedRows = $0
        }
        .onChange(of: isSelecting) { _, selected in if !selected { loadDraft(); reconcileSelection() } }
        .onDisappear { if editing { finishEditing() } }
    }

    private func loadDraft() {
        guard !isSelecting else { return }
        guard let identity else { draft = nil; editing = false; showsOriginal = false; return }
        if draft == nil { draft = ResponseWritingDrafts.existing(id: identity, root: context.notesRoot) }
        reconcileSelection()
    }

    private func reconcileSelection() {
        guard let selectionStore else { return }
        let ids: Set<String>
        if let draft, !showsOriginal {
            ids = editing || draft.lifecycle != .active ? [] : [ResponseWritingDrafts.selectionSpan(
                text: draft.text, rootPath: selectionRootPath, rowID: selectionRowID).id]
        } else {
            ids = Set(MarkdownSelectionProjection.spans(for: FinishedMarkdownCache.blocks(for: part.originalWriting),
                rootPath: selectionRootPath, firstSeparator: "\n\n", rowID: selectionRowID).values.map(\.id))
        }
        selectionStore.retainSpanIDs(in: selectionRowID, under: selectionRootPath, keeping: ids)
    }

    private func edit() {
        guard let identity, !isSelecting else { return }
        do {
            draft = try ResponseWritingDrafts.edit(id: identity, part: part, root: context.notesRoot)
            showsOriginal = false
            editing = draft?.isEditable == true
            error = nil
            reconcileSelection()
        } catch { self.error = "Could not save this draft: \(error.localizedDescription)" }
    }

    private func finishEditing() {
        do { try draft?.flush(); editing = false; error = nil; reconcileSelection() }
        catch { self.error = "Draft not saved: \(error.localizedDescription)" }
    }

    private func copyVisible() {
        copy(!showsOriginal ? draft?.text ?? MarkdownPlainTextRenderer.render(part.originalWriting)
            : MarkdownPlainTextRenderer.render(part.originalWriting))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }

    private func export(rich: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [rich ? .rtf : .plainText]
        panel.nameFieldStringValue = ChatTranscriptBuilder.safeFilename(part.writingTitle) + (rich ? ".rtf" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let draft, !showsOriginal {
                if rich { try draft.exportRichText(to: url) } else { try draft.exportPlainText(to: url) }
            } else {
                let plain = MarkdownPlainTextRenderer.render(part.originalWriting)
                if rich {
                    let text = ResponseWritingDrafts.importMarkdown(part.originalWriting)
                    let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                    try data.write(to: url, options: .atomic)
                } else { try plain.write(to: url, atomically: true, encoding: .utf8) }
            }
        } catch { self.error = "Could not export: \(error.localizedDescription)" }
    }
}

private struct ResponseWritingDraftContent: View {
    @ObservedObject var store: NotesStore
    let editing: Bool
    var selectionStore: TranscriptSelectionStore?
    var selectionRootPath: [Int]
    var selectionRowID: String
    @StateObject private var proxy = NotesEditorProxy()
    @State private var selectionSnapshot: NSAttributedString?

    private var displayedDraft: NSAttributedString { selectionSnapshot ?? store.attributedText }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing && store.isEditable {
                HStack {
                    Button { proxy.toggleBold() } label: { Image(systemName: "bold") }
                        .accessibilityLabel("Bold")
                    Button { proxy.toggleItalic() } label: { Image(systemName: "italic") }
                        .accessibilityLabel("Italic")
                    Button { proxy.toggleUnderline() } label: { Image(systemName: "underline") }
                        .accessibilityLabel("Underline")
                    Spacer()
                    Text(store.hasUnsavedChanges ? "Saving…" : "Saved").foregroundStyle(LocusTheme.muted)
                }
                .buttonStyle(.locus()).font(.locus(size: 11))
                RichNotesEditor(store: store, proxy: proxy, accessibilityLabel: "Edit writing draft", identifierPrefix: "message.writing.draft")
                    .frame(height: min(420, max(160, CGFloat(store.text.components(separatedBy: "\n").count) * 20 + 40)))
            } else if store.lifecycle == .active {
                if let selectionStore {
                    ResponseSelectableText(attributedText: displayedDraft,
                        span: ResponseWritingDrafts.selectionSpan(text: displayedDraft.string, rootPath: selectionRootPath, rowID: selectionRowID),
                        store: selectionStore)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(AttributedString(store.attributedText)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("This draft is in Notebook Trash or was deleted. The original answer is still available.")
                    .font(.locus(size: 11)).foregroundStyle(LocusTheme.muted)
            }
            if let error = store.saveError {
                HStack {
                    Text(error).foregroundStyle(LocusTheme.coral)
                    Button("Retry save") { try? store.flush() }
                }.font(.locus(size: 11))
            }
        }
        .onReceive(selectionStore?.$selectedRowIDs.eraseToAnyPublisher() ?? Just(Set<String>()).eraseToAnyPublisher()) { rows in
            if rows.contains(selectionRowID) {
                if selectionSnapshot == nil { selectionSnapshot = NSAttributedString(attributedString: store.attributedText) }
            } else { selectionSnapshot = nil }
        }
    }
}
