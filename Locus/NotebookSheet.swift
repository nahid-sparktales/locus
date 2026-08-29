//  Every stored note in one place. The list is the Notebook's own; the editor
//  beside it is the same one the inspector uses, driving the same store
//  instance, so a note open in both cannot disagree with itself.

import SwiftUI

struct NotebookSheet: View {
    @ObservedObject var notebook: NotebookModel
    @Environment(\.dismiss) private var dismiss

    private static let listWidth: CGFloat = 268

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                list
                    .frame(width: Self.listWidth)
                    .background(LocusTheme.surfaceStructural)
                Rectangle()
                    .fill(LocusTheme.separator)
                    .frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 880, height: 620)
        .background(LocusTheme.panel)
        .onExitCommand { dismiss() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Notebook")
                    .font(.locus(size: 15, weight: .bold))
                // `muted` nominally clears the contrast floor here, but at nine
                // points its antialiased strokes never reach that colour: the
                // pixels this caption actually draws measure 4.4:1 against the
                // panel, under the 4.5:1 minimum. Secondary copy measures about
                // 11.8:1 and is the right weight for prose in any case.
                Text("Every note Locus has kept — one per workspace, one per chat, and one shared by all of them. Edits here are the same document the Notes panel shows.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.locus())
            .accessibilityLabel("Close notebook")
            .accessibilityIdentifier("notebook.close")
        }
        .padding(16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Search notes", text: $notebook.query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
                .accessibilityLabel("Search notes")
                .accessibilityIdentifier("notebook.search")

            if notebook.namingIsIncomplete {
                // Being offline is not the same as these notes being orphans,
                // and the difference is not visible from the rows alone.
                Text("Reconnect the agent to name chat notes.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("notebook.namingNotice")
            }

            if notebook.entries.isEmpty {
                emptyState(
                    symbol: "note.text",
                    title: "No notes yet",
                    detail: "Open the Notes panel with ⌘9 and start writing."
                )
            } else if notebook.filteredEntries.isEmpty {
                emptyState(
                    symbol: "magnifyingglass",
                    title: "Nothing matches",
                    detail: "No note contains “\(notebook.query)”."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(notebook.sections) { section in
                            Text(section.title.uppercased())
                                .font(.locus(size: 8, weight: .semibold))
                                .foregroundStyle(LocusTheme.muted)
                                .padding(.top, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func row(_ entry: NotebookEntry) -> some View {
        let isSelected = notebook.selection?.documentID == entry.documentID
        return Button {
            notebook.select(entry)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: entry.scope.symbol)
                    .font(.locus(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? LocusTheme.accentAction : LocusTheme.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.locus(size: 10, weight: .bold))
                        .foregroundStyle(LocusTheme.textPrimary)
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.characterCount == 0 ? "Empty" : entry.preview)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let modified = entry.modifiedAt {
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .locusCard(radius: 9)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(LocusTheme.accentAction, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.locus())
        .help(entry.abbreviatedPath.isEmpty ? entry.subtitle : entry.abbreviatedPath)
        .accessibilityLabel("\(entry.title), \(entry.subtitle)")
        .accessibilityValue(entry.characterCount == 0 ? "Empty" : entry.preview)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // Keyed by digest prefix, not by path: an accessibility identifier is
        // readable by any process, and is no place for a filesystem path.
        .accessibilityIdentifier("notebook.entry.\(entry.documentID.digest.prefix(8))")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = notebook.selection, let store = notebook.selectedStore {
            NotesDocumentEditor(
                store: store,
                workspaceName: entry.origin?.workspaceName ?? entry.scope.documentTitle,
                workspacePath: entry.origin?.workspacePath ?? "",
                identifierPrefix: "notebook.document"
            )
            // The editor wraps an AppKit text view, so switching documents
            // rebuilds it rather than reconciling one document's undo stack
            // and selection onto another's text.
            .id(entry.documentID)
        } else {
            emptyState(
                symbol: "text.book.closed",
                title: "Select a note",
                detail: notebook.entries.isEmpty
                    ? "Notes you write in the Notes panel will appear here."
                    : "Pick one from the list to read or edit it."
            )
            .accessibilityIdentifier("notebook.noSelection")
        }
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.locus(size: 25))
                .foregroundStyle(LocusTheme.muted)
                // Decorative: the text below says the same thing, and an
                // unhidden symbol reads out as its own SF Symbol name.
                .accessibilityHidden(true)
            Text(title)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.textPrimary)
            Text(detail)
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }
}
