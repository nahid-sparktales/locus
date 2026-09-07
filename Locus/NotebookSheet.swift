// The Notebook owns its list; the editor shares the inspector's document store.
import AppKit
import SwiftUI

struct NotebookSheet: View {
    @ObservedObject var notebook: NotebookModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var titleDraft = ""
    @State private var titleEntry: NotebookEntry?
    @State private var pendingPermanentDelete: NotebookEntry?
    @State private var confirmsEmptyTrash = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = notebook.errorMessage { errorBanner(error) }
            HStack(spacing: 0) {
                noteList
                    .frame(minWidth: 220, idealWidth: 268, maxWidth: 268)
                    .background(LocusTheme.surfaceStructural)
                Rectangle().fill(LocusTheme.separator).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, idealWidth: 880, maxWidth: 880, minHeight: 480, idealHeight: 620, maxHeight: 620)
        .background(LocusTheme.panel)
        .focusedSceneValue(\.notebookModel, notebook)
        .focusedSceneValue(\.notebookCreateNote, createNote)
        .onChange(of: notebook.selection?.documentID, initial: true) { _, _ in
            _ = commitTitle()
            titleFocused = false
            synchronizeTitle()
        }
        .onChange(of: notebook.selection?.title) { _, _ in
            if !titleFocused { synchronizeTitle() }
            else if titleEntry?.documentID == notebook.selection?.documentID { titleEntry = notebook.selection }
        }
        .onChange(of: notebook.createdSelectionToken) { _, token in
            if token != nil { focusTitle() }
        }
        .onChange(of: titleFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused { _ = commitTitle() }
        }
        .onDisappear { _ = commitTitle() }
        .onExitCommand {
            if titleFocused {
                titleDraft = titleEntry?.title ?? ""
                titleFocused = false
            } else {
                if commitTitle() { dismiss() }
            }
        }
        .alert("Delete this note permanently?", isPresented: Binding(
            get: { pendingPermanentDelete != nil },
            set: { if !$0 { pendingPermanentDelete = nil } }
        ), presenting: pendingPermanentDelete) { entry in
            Button("Cancel", role: .cancel) { pendingPermanentDelete = nil }
            Button("Delete Permanently", role: .destructive) {
                notebook.deletePermanently(entry)
                pendingPermanentDelete = nil
            }
            .accessibilityIdentifier("notebook.confirmPermanentDelete")
        } message: { entry in
            Text("“\(entry.title)” and its contents will be removed from this Mac. This cannot be undone.")
        }
        .alert("Empty Recently Deleted?", isPresented: $confirmsEmptyTrash) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All Permanently", role: .destructive) { notebook.emptyTrash() }
                .accessibilityIdentifier("notebook.confirmEmptyTrash")
        } message: {
            Text("Permanently delete \(notebook.recentlyDeleted.count) notes from this Mac? This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Notebook").font(.locus(size: 17, weight: .bold))
                Text("Your notes, alongside the notes from your chats and workspaces.")
                    .font(.locus(size: 10))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(action: createNote) {
                Label("New Note", systemImage: "square.and.pencil")
                    .font(.locus(size: 11, weight: .semibold))
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .foregroundStyle(LocusTheme.brandInk)
                    .background(LocusTheme.accentFill, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.locus(.primary))
            .fixedSize()
            .help("Create a note (⌘N)")
            .accessibilityIdentifier("notebook.newNote")
            Button { if commitTitle() { dismiss() } } label: { Image(systemName: "xmark") }
                .buttonStyle(.locus())
                .accessibilityLabel("Close notebook")
                .accessibilityIdentifier("notebook.close")
        }
        .padding(16)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            Text(error).font(.locus(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry") { notebook.retry() }
                .accessibilityIdentifier("notebook.retry")
            Button { notebook.clearError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.locus(.icon)).accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .foregroundStyle(LocusTheme.textPrimary)
        .background(LocusTheme.accentAction.opacity(0.08))
        .accessibilityIdentifier("notebook.error")
    }

    private var noteList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Search notes", text: $notebook.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search notes")
                    .accessibilityIdentifier("notebook.search")
                if notebook.isSearching || notebook.isLoading {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(notebook.isLoading ? "Loading notes" : "Searching notes")
                        .accessibilityIdentifier("notebook.searching")
                }
            }
            .padding(10)
            VStack(spacing: 3) {
                collectionButton("All Notes", symbol: "note.text", count: notebook.entries.count, trash: false)
                collectionButton("Recently Deleted", symbol: "trash", count: notebook.recentlyDeleted.count, trash: true)
            }
            .padding(.horizontal, 10).padding(.bottom, 9)
            HStack {
                Text(notebook.showingTrash ? "RECENTLY DELETED" : "NOTES")
                    .font(.locus(size: 8, weight: .semibold)).foregroundStyle(LocusTheme.textSecondary)
                Spacer()
                Menu {
                    Picker("Sort notes", selection: $notebook.sortOrder) {
                        Text("Date Updated").tag(NotebookSortOrder.modifiedNewest)
                        Text("Date Created").tag(NotebookSortOrder.createdNewest)
                        Text("Title").tag(NotebookSortOrder.titleAscending)
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Sort notes").accessibilityIdentifier("notebook.sort")
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            if notebook.namingIsIncomplete && !notebook.showingTrash {
                Text("Reconnect the agent to name chat notes.")
                    .font(.locus(size: 9)).foregroundStyle(LocusTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .accessibilityIdentifier("notebook.namingNotice")
            }
            listContents
            if notebook.showingTrash && !notebook.recentlyDeleted.isEmpty {
                Button("Empty Recently Deleted…", role: .destructive) { confirmsEmptyTrash = true }
                    .font(.locus(size: 10)).padding(12)
                    .accessibilityIdentifier("notebook.emptyTrash")
            }
        }
    }

    private func collectionButton(_ title: String, symbol: String, count: Int, trash: Bool) -> some View {
        Button {
            guard commitTitle() else { return }
            titleFocused = false
            notebook.showingTrash = trash
            listFocused = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 15)
                Text(title)
                Spacer(minLength: 3)
                Text(count.formatted()).monospacedDigit().foregroundStyle(LocusTheme.textSecondary)
            }
            .font(.locus(size: 11, weight: notebook.showingTrash == trash ? .semibold : .regular))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(notebook.showingTrash == trash ? LocusTheme.accentAction.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityLabel(title).accessibilityValue("\(count) notes")
        .accessibilityAddTraits(notebook.showingTrash == trash ? [.isSelected] : [])
        .accessibilityIdentifier(trash ? "notebook.recentlyDeleted" : "notebook.allNotes")
    }

    @ViewBuilder private var listContents: some View {
        if notebook.isLoading && notebook.filteredEntries.isEmpty {
            emptyState(symbol: "note.text", title: "Loading notes", message: "Your notebook will be ready shortly.")
        } else if notebook.filteredEntries.isEmpty {
            if !notebook.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState(symbol: "magnifyingglass", title: notebook.isSearching ? "Searching…" : "Nothing matches",
                           message: "Search the title or contents of a note.")
                    .accessibilityIdentifier("notebook.searchEmpty")
            } else if notebook.showingTrash {
                emptyState(symbol: "trash", title: "No deleted notes", message: "Deleted notes stay here until you restore or permanently delete them.")
                    .accessibilityIdentifier("notebook.trashEmpty")
            } else {
                emptyState(symbol: "note.text", title: "Your first note", message: "Keep an idea, a plan, or anything you want to come back to.", create: true)
                    .accessibilityIdentifier("notebook.empty")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(notebook.sections) { section in
                        if !notebook.showingTrash {
                            Text(section.title.uppercased())
                                .font(.locus(size: 8, weight: .semibold)).foregroundStyle(LocusTheme.textSecondary)
                                .padding(.top, 4).accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.entries) { entry in row(entry) }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
            .focusable().focused($listFocused)
            .onDeleteCommand(perform: deleteSelectedFromList)
            .accessibilityIdentifier("notebook.list")
        }
    }

    private func row(_ entry: NotebookEntry) -> some View {
        let isSelected = notebook.selection?.documentID == entry.documentID
        return Button {
            guard commitTitle() else { return }
            titleFocused = false
            notebook.select(entry)
            listFocused = true
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: entry.isPinned ? "pin.fill" : entry.isStandalone ? "note.text" : entry.scope.symbol)
                    .font(.locus(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? LocusTheme.accentAction : LocusTheme.muted).frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(.locus(size: 11, weight: .semibold)).foregroundStyle(LocusTheme.textPrimary).lineLimit(1)
                    Text(entry.subtitle).font(.locus(size: 9)).foregroundStyle(LocusTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Text(entry.isPurgePending ? "Deletion incomplete · Retry to finish" : entry.characterCount == 0 ? "Empty note" : entry.preview)
                        .font(.locus(size: 10)).foregroundStyle(LocusTheme.textSecondary)
                        .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if let modified = entry.modifiedAt {
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                            .font(.locus(size: 9)).foregroundStyle(LocusTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .locusCard(radius: 9)
            .overlay {
                if isSelected { RoundedRectangle(cornerRadius: 9).stroke(LocusTheme.accentAction, lineWidth: 1.5) }
            }
        }
        .buttonStyle(.locus())
        .contextMenu { noteActions(entry) }
        .help(entry.abbreviatedPath.isEmpty ? entry.subtitle : entry.abbreviatedPath)
        .accessibilityLabel("\(entry.title), \(entry.subtitle)")
        .accessibilityValue(entry.isPurgePending ? "Deletion incomplete" : entry.characterCount == 0 ? "Empty" : entry.preview)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // Identifiers must never expose a filesystem path.
        .accessibilityIdentifier("notebook.entry.\(entry.documentID.digest.prefix(8))")
    }

    @ViewBuilder private var detail: some View {
        if let entry = notebook.selection {
            VStack(spacing: 0) {
                detailHeader(entry)
                if entry.isPurgePending {
                    VStack(spacing: 12) {
                        emptyState(symbol: "exclamationmark.triangle", title: "Deletion needs another try",
                                   message: "Some files could not be removed. Retry to finish permanently deleting this note.")
                        Button("Retry Delete") { notebook.deletePermanently(entry) }
                            .accessibilityIdentifier("notebook.retryDelete").padding(.bottom, 24)
                    }
                } else if let store = notebook.selectedStore {
                    if entry.isTrashed {
                        HStack(spacing: 8) {
                            Label("Recently Deleted · Read only", systemImage: "trash")
                                .font(.locus(size: 10)).foregroundStyle(LocusTheme.textSecondary)
                            Spacer(minLength: 0)
                            Button("Restore") { notebook.restore(entry) }
                                .disabled(!entry.canRestore).accessibilityIdentifier("notebook.restore")
                        }
                        .padding(12).background(LocusTheme.surfaceStructural)
                    }
                    NotesDocumentEditor(
                        store: store,
                        workspaceName: entry.origin?.workspaceName ?? entry.scope.documentTitle,
                        workspacePath: entry.origin?.workspacePath ?? "",
                        identifierPrefix: "notebook.document",
                        readOnly: entry.isTrashed
                    )
                    .id(entry.documentID)
                }
            }
        } else {
            emptyState(symbol: "text.book.closed", title: "Select a note",
                       message: notebook.showingTrash ? "Select a deleted note to preview or restore it." : "Choose a note from the list, or start a new one.")
                .accessibilityIdentifier("notebook.noSelection")
        }
    }

    private func detailHeader(_ entry: NotebookEntry) -> some View {
        HStack(spacing: 12) {
            if entry.isTrashed {
                Text(entry.title).font(.locus(size: 16, weight: .semibold)).lineLimit(2)
                    .accessibilityIdentifier("notebook.deletedTitle")
            } else {
                TextField("Untitled Note", text: $titleDraft)
                    .textFieldStyle(.plain).font(.locus(size: 16, weight: .semibold))
                    .focused($titleFocused)
                    .onSubmit { if commitTitle() { titleFocused = false } }
                    .accessibilityLabel("Note title").accessibilityIdentifier("notebook.title")
            }
            Spacer(minLength: 0)
            Menu { noteActions(entry) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Note actions").accessibilityIdentifier("notebook.noteActions")
        }
        .padding(16)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.separator).frame(height: 1) }
    }

    @ViewBuilder private func noteActions(_ entry: NotebookEntry) -> some View {
        if entry.isTrashed {
            if entry.canRestore {
                Button("Restore", systemImage: "arrow.uturn.backward") { notebook.restore(entry) }
                    .accessibilityIdentifier("notebook.action.restore")
            }
            Button(entry.isPurgePending ? "Retry Delete" : "Delete Permanently…", systemImage: "trash", role: .destructive) {
                if entry.isPurgePending { notebook.deletePermanently(entry) }
                else { pendingPermanentDelete = entry }
            }
            .accessibilityIdentifier("notebook.action.deletePermanently")
        } else {
            Button("Rename", systemImage: "pencil") {
                guard commitTitle() else { return }
                notebook.select(entry)
                focusTitle()
            }
                .accessibilityIdentifier("notebook.action.rename")
            Button("Duplicate", systemImage: "plus.square.on.square") {
                guard commitTitle() else { return }
                if notebook.duplicate(entry) != nil { focusTitle() }
            }
            .accessibilityIdentifier("notebook.action.duplicate")
            Button(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin") {
                if commitTitle() { notebook.togglePin(entry) }
            }
                .accessibilityIdentifier("notebook.action.pin")
            Divider()
            Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) {
                if commitTitle() { notebook.trash(entry) }
            }
                .accessibilityIdentifier("notebook.action.trash")
        }
    }

    private func createNote() {
        guard commitTitle() else { return }
        if notebook.createNote() != nil { focusTitle() }
    }

    private func focusTitle() {
        synchronizeTitle()
        listFocused = false
        Task { @MainActor in
            await Task.yield()
            guard notebook.selection?.isTrashed == false else { return }
            titleFocused = true
        }
    }

    private func synchronizeTitle() {
        titleEntry = notebook.selection
        titleDraft = notebook.selection?.title ?? ""
    }

    @discardableResult private func commitTitle() -> Bool {
        guard let entry = titleEntry, !entry.isTrashed else { return true }
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if title != entry.title, !notebook.rename(entry, title: title) {
            // Keep the typed title and the original operation available for
            // correction/retry instead of replacing the note after a failed save.
            Task { @MainActor in
                await Task.yield()
                titleFocused = true
            }
            return false
        }
        if notebook.selection?.documentID == entry.documentID { titleEntry = notebook.selection }
        return true
    }

    private func deleteSelectedFromList() {
        // AppKit's editor can own focus while SwiftUI's last list focus lingers.
        // Text deletion must always stay with the native text view or title field.
        guard listFocused, !titleFocused,
              !(NSApp.keyWindow?.firstResponder is NSTextView),
              !(NSApp.keyWindow?.firstResponder is NSTextField),
              let entry = notebook.selection else { return }
        guard commitTitle() else { return }
        if entry.isTrashed { pendingPermanentDelete = entry }
        else { notebook.trash(entry) }
    }

    private func emptyState(symbol: String, title: String, message: String, create: Bool = false) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.locus(size: 27)).foregroundStyle(LocusTheme.muted).accessibilityHidden(true)
            Text(title).font(.locus(size: 12, weight: .semibold)).foregroundStyle(LocusTheme.textPrimary)
            Text(message).font(.locus(size: 10)).foregroundStyle(LocusTheme.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if create {
                Button("Create a Note", action: createNote).padding(.top, 4)
                    .accessibilityIdentifier("notebook.emptyNewNote")
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
