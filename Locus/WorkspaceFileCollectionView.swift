import AppKit
import SwiftUI

struct WorkspaceFileCollectionEntry: Identifiable {
    let id: String
    let path: String
    let runs: [MarkdownInlineRun]
    var reference: WorkspaceArtifactReference? = nil
    var selectionSpan: TranscriptSelectionSpan? = nil
}

/// A file inventory owns one container. Text remains selectable and the
/// original Markdown selection spans keep their original order and content.
struct WorkspaceFileCollectionView: View {
    let entries: [WorkspaceFileCollectionEntry]
    var title: String? = nil
    var workspacePath: String? = nil
    var density: MarkdownRenderDensity = .regular
    var selectionStore: TranscriptSelectionStore? = nil
    var onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)? = nil
    var onShowFiles: (() -> Void)? = nil
    init(entries: [WorkspaceFileCollectionEntry], title: String? = nil, workspacePath: String? = nil,
         density: MarkdownRenderDensity = .regular, selectionStore: TranscriptSelectionStore? = nil,
         onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)? = nil,
         onShowFiles: (() -> Void)? = nil, initiallyCollapsed: Bool = false) {
        self.entries = entries; self.title = title; self.workspacePath = workspacePath; self.density = density
        self.selectionStore = selectionStore; self.onOpenWorkspaceReference = onOpenWorkspaceReference
        self.onShowFiles = onShowFiles
        _isCollapsed = State(initialValue: initiallyCollapsed)
    }
    @State private var isCollapsed = false
    @State private var showsDescriptions = false
    @State private var showsSizes = false
    @State private var isExpanded = false
    @Environment(\.locusAccent) private var accent
    @Environment(\.responseOutputContext) private var outputContext

    private var showFilesAction: (() -> Void)? {
        if let onShowFiles { return onShowFiles }
        guard let workspacePath, !outputContext.sessionID.isEmpty else { return nil }
        return { outputContext.showFiles(workspacePath, nil) }
    }

    private var isSelecting: Bool {
        guard let selectionStore else { return false }
        return entries.contains { entry in
            guard let rowID = entry.selectionSpan?.rowID else { return false }
            return selectionStore.activeRowIDs.contains(rowID)
        }
    }

    private var visibleEntries: [WorkspaceFileCollectionEntry] {
        isExpanded ? entries : Array(entries.prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { collectionHeading; Spacer(minLength: 8); collectionControls.fixedSize() }
                VStack(alignment: .leading, spacing: 8) { collectionHeading; collectionControls }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(LocusTheme.paperDeep.opacity(0.45))
            if !isCollapsed {
            ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                let group = WorkspaceFileCollectionCategory.category(for: entry.path)
                if index == 0 || WorkspaceFileCollectionCategory.category(for: visibleEntries[index - 1].path) != group {
                    Text(group.rawValue)
                        .font(.locusExact(size: 11, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 5)
                        .accessibilityAddTraits(.isHeader)
                }
                Rectangle().fill(LocusTheme.line.opacity(0.65)).frame(height: 1)
                row(entry)
                    .background(index.isMultiple(of: 2) ? Color.clear : LocusTheme.paperDeep.opacity(0.12))
            }
            if entries.count > 20 {
                Button(isExpanded ? "Show fewer files" : "Show all \(entries.count) files") { isExpanded.toggle() }
                    .buttonStyle(.locus())
                    .font(.locusExact(size: 12, weight: .semibold))
                    .foregroundStyle(accent.actionColor)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("message.fileCollection.expand")
                    .disabled(isSelecting)
            }
        }
        }
        .background(LocusTheme.white)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(LocusTheme.line, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title ?? "File collection, \(entries.count) files")
        .accessibilityIdentifier("message.fileCollection")
    }

    private var collectionHeading: some View {
        Button { isCollapsed.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.locusExact(size: 10))
                Text(title ?? "\(entries.count) files").font(.locusExact(size: density.fontSize, weight: .semibold))
            }
        }
        .buttonStyle(.locus()).disabled(isSelecting)
        .accessibilityLabel("\(title ?? "File collection"), \(entries.count) files, \(isCollapsed ? "expand" : "collapse")")
    }

    private var collectionControls: some View {
        HStack(spacing: 8) {
            Toggle("Descriptions", isOn: $showsDescriptions).toggleStyle(.button)
                .accessibilityIdentifier("message.fileCollection.descriptions").disabled(isSelecting)
            Toggle("Sizes", isOn: $showsSizes).toggleStyle(.button)
                .accessibilityIdentifier("message.fileCollection.sizes").disabled(isSelecting)
            if let showFilesAction {
                Button("Show in Files", action: showFilesAction).buttonStyle(.locus())
                    .accessibilityIdentifier("message.fileCollection.showFiles")
            }
        }.font(.locusExact(size: 11))
    }

    private func row(_ entry: WorkspaceFileCollectionEntry) -> some View {
        let reference = entry.reference ?? WorkspaceArtifactReference.classify(entry.path, workspacePath: workspacePath)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: reference?.kind.symbol ?? "doc")
                .font(.locusExact(size: 13))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 18, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                rowText(entry)
                if showsSizes {
                    Text(metadata(for: reference))
                        .font(.locusExact(size: 11))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contextMenu {
            if let reference {
                Button("Open") { open(reference) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([reference.url]) }
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Copy Path")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string)
        }
        .accessibilityAction(named: Text("Reveal in Finder")) {
            if let reference { NSWorkspace.shared.activateFileViewerSelecting([reference.url]) }
        }
    }

    @ViewBuilder
    private func rowText(_ entry: WorkspaceFileCollectionEntry) -> some View {
        // File names already have an icon and action. Remove the extra code
        // pill without changing any characters or their selection offsets.
        let runs = WorkspaceFileCollectionText.runs(for: entry, showsDescriptions: showsDescriptions)
        let attributed = MarkdownNativeText.attributed(
            runs, size: density.fontSize, weight: .regular, color: LocusTheme.inkSoft,
            lineSpacing: density.lineSpacing, inlineCodeSize: density.inlineCodeFontSize,
            workspacePath: workspacePath
        )
        if let selectionStore, let span = entry.selectionSpan {
            ResponseSelectableText(attributedText: attributed, span: span.displaying(attributed.string), store: selectionStore, onOpenURL: openURL)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(AttributedString(attributed))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in openURL(url); return .handled })
        }
    }

    private func metadata(for reference: WorkspaceArtifactReference?) -> String {
        guard let reference else { return "File unavailable" }
        return [reference.kind.label, reference.displaySize].compactMap { $0 }.joined(separator: " · ")
    }

    private func openURL(_ url: URL) {
        if let reference = WorkspaceArtifactReference.fromNavigationURL(url, workspacePath: workspacePath) {
            open(reference)
        } else if let safe = MarkdownLinkPolicy.safeURL(url.absoluteString, workspacePath: workspacePath) {
            NSWorkspace.shared.open(safe)
        }
    }

    private func open(_ reference: WorkspaceArtifactReference) {
        guard WorkspaceArtifactReference.classify(reference.url.path, workspacePath: workspacePath) != nil else { return }
        if let onOpenWorkspaceReference { onOpenWorkspaceReference(reference) }
        else { NSWorkspace.shared.open(reference.url) }
    }
}

enum WorkspaceFileCollectionCategory: String, CaseIterable {
    case documents = "Documents", scripts = "Scripts", tests = "Tests", setup = "Setup", other = "Other"

    static func category(for path: String) -> Self {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if name.hasPrefix("test_") || name.hasSuffix("tests.swift") || name.contains(".test.") || name.contains(".spec.")
            || path.lowercased().split(separator: "/").contains(where: { ["test", "tests", "__tests__"].contains(String($0)) }) { return .tests }
        if ["agents.md", "readme.md", "requirements.txt", "package.json", "package-lock.json", "pyproject.toml", "makefile", "dockerfile", "license", "license.md", ".gitignore"].contains(name)
            || ["toml", "yaml", "yml", "ini", "cfg", "lock"].contains(ext) { return .setup }
        if ["pdf", "doc", "docx", "rtf", "md", "txt", "pages", "odt", "ppt", "pptx", "key", "xlsx", "xls", "csv", "tsv"].contains(ext) { return .documents }
        if ["py", "swift", "js", "jsx", "ts", "tsx", "sh", "zsh", "bash", "rb", "go", "rs", "c", "cpp", "h", "java", "sql"].contains(ext) { return .scripts }
        return .other
    }
}

enum WorkspaceFileCollectionText {
    static func runs(for entry: WorkspaceFileCollectionEntry, showsDescriptions: Bool) -> [MarkdownInlineRun] {
        guard var first = entry.runs.first else { return [.init(text: entry.path, destination: entry.path)] }
        first.style.remove(.code)
        first.style.insert(.strong)
        first.destination = first.destination ?? entry.path
        guard showsDescriptions, entry.runs.count > 1 else { return [first] }
        var suffix = Array(entry.runs.dropFirst())
        // Separate annotation visually; original runs remain the source for
        // full-response copy/export and reappear unchanged when requested.
        if !suffix.isEmpty {
            var annotation = suffix[0].text.trimmingCharacters(in: .whitespaces)
            if let marker = annotation.first, "—–-:".contains(marker) {
                annotation = String(annotation.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            suffix[0] = MarkdownInlineRun(text: "\n" + annotation, style: suffix[0].style,
                                          destination: suffix[0].destination, isImage: suffix[0].isImage)
        }
        return [first] + suffix
    }
}

enum MarkdownFileCollectionDetector {
    static func references(
        in items: [MarkdownRenderListItem],
        resolve: (String?) -> WorkspaceArtifactReference?
    ) -> [WorkspaceArtifactReference]? {
        guard items.count >= 2 else { return nil }
        var references: [WorkspaceArtifactReference] = []
        for item in items {
            guard item.checked == nil, item.blocks.count == 1,
                  case .paragraph(let runs) = item.blocks[0], let first = runs.first,
                  !first.isImage,
                  let reference = resolve(MarkdownArtifactPromotion.candidate(in: first)),
                  runs.dropFirst().allSatisfy({ resolve(MarkdownArtifactPromotion.candidate(in: $0)) == nil && !$0.isImage })
            else { return nil }
            let annotation = runs.dropFirst().map(\.text).joined()
            if !annotation.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = annotation.trimmingCharacters(in: .whitespaces)
                guard ["—", "–", "-", ":"].contains(where: trimmed.hasPrefix), !annotation.contains("\n") else { return nil }
            }
            references.append(reference)
        }
        return references
    }
}
