import AppKit
import XCTest

@testable import Locus

@MainActor
final class NotebookModelTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocusNotebookTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func settle(_ notebook: NotebookModel, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil(file: file, line: line) { !notebook.isLoading && !notebook.isSearching }
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Notebook operation did not finish", file: file, line: line)
    }

    /// Writes a document the way the store would, so discovery is tested
    /// against real files rather than against its own bookkeeping.
    @discardableResult
    private func write(
        _ text: String?,
        scope: NotesScope,
        digest: String,
        in support: URL,
        styled: NSAttributedString? = nil
    ) throws -> NotesDocumentID {
        let directory = support
            .appendingPathComponent(AppEdition.current.displayName, isDirectory: true)
            .appendingPathComponent(NotesStore.directoryName(for: scope), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let text {
            try text.write(
                to: directory.appendingPathComponent("\(digest).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        if let styled {
            try NSKeyedArchiver.archivedData(withRootObject: styled, requiringSecureCoding: true)
                .write(to: directory.appendingPathComponent("\(digest).styled"))
        }
        return NotesDocumentID(
            directoryName: NotesStore.directoryName(for: scope),
            digest: digest
        )
    }

    private func workspace(_ path: String) -> WorkspaceProfile {
        WorkspaceProfile(
            path: path,
            lastOpened: Date(timeIntervalSince1970: 10),
            model: "",
            accountID: nil,
            mode: .work,
            previewURL: "",
            contextFiles: [],
            draft: ""
        )
    }

    private func session(_ id: String, title: String, cwd: String?) -> SessionSummary {
        SessionSummary(
            id: id,
            name: "\(id).jsonl",
            preview: title,
            mtime: 20,
            size: 1,
            title: title,
            cwd: cwd
        )
    }

    /// Give each fixture its own store instances as well as its own files.
    private func model(in support: URL) -> NotebookModel {
        NotebookModel(applicationSupport: support) { documentID, scope in
            NotesStore.testingStore(
                documentID: documentID,
                scope: scope,
                applicationSupport: support
            )
        }
    }

    func testEveryStoredDocumentIsListedAcrossAllThreeScopes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let path = "/tmp/locus-notebook-alpha"

        let workspaceNote = NotesStore.documentID(
            workspacePath: path, sessionID: "", scope: .workspace
        )
        let chatNote = NotesStore.documentID(
            workspacePath: path, sessionID: "chat-one", scope: .chat
        )
        try write("Workspace facts", scope: .workspace, digest: workspaceNote.digest, in: support)
        try write("Chat facts", scope: .chat, digest: chatNote.digest, in: support)
        try write("Shared facts", scope: .global, digest: NotesStore.globalDocumentID.digest, in: support)

        let notebook = model(in: support)
        notebook.refresh(
            workspaces: [workspace(path)],
            sessions: [session("chat-one", title: "Ship the release", cwd: path)]
        )
        await settle(notebook)

        XCTAssertEqual(notebook.entries.count, 3)
        XCTAssertEqual(
            Set(notebook.entries.map(\.scope)),
            [.workspace, .chat, .global]
        )
        let chat = try XCTUnwrap(notebook.entries.first { $0.documentID == chatNote })
        XCTAssertEqual(chat.title, "Ship the release")
        XCTAssertEqual(chat.preview, "Chat facts")
        XCTAssertFalse(chat.isUnlinked)
        XCTAssertEqual(
            notebook.entries.first { $0.documentID == workspaceNote }?.title,
            "locus-notebook-alpha"
        )
    }

    func testStyledOnlyAndEmptyNotesEachAppearExactlyOnce() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)

        // A document whose plain mirror was lost still has its text, and both
        // of its files describe one note rather than two.
        let styledOnly = try write(
            nil,
            scope: .workspace,
            digest: String(repeating: "a", count: 64),
            in: support,
            styled: NotesTextStyle.plain("Release on Friday")
        )
        let paired = try write(
            "Paired",
            scope: .workspace,
            digest: String(repeating: "b", count: 64),
            in: support,
            styled: NotesTextStyle.plain("Paired")
        )
        let empty = try write(
            "", scope: .workspace, digest: String(repeating: "c", count: 64), in: support
        )

        let notebook = model(in: support)
        notebook.refresh(workspaces: [], sessions: [])
        await settle(notebook)

        XCTAssertEqual(notebook.entries.count, 3)
        XCTAssertEqual(
            notebook.entries.first { $0.documentID == styledOnly }?.preview,
            "Release on Friday"
        )
        XCTAssertEqual(notebook.entries.filter { $0.documentID == paired }.count, 1)
        // An empty note is a real document: hiding it would leave the reader no
        // way to see it exists.
        XCTAssertEqual(notebook.entries.first { $0.documentID == empty }?.characterCount, 0)
    }

    func testUnknownDigestsStayListedAndDistinguishableAsUnlinked() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let first = try write(
            "Notes from a deleted chat",
            scope: .chat,
            digest: String(repeating: "d", count: 64),
            in: support
        )
        let second = try write(
            "Notes from another deleted chat",
            scope: .chat,
            digest: String(repeating: "e", count: 64),
            in: support
        )

        let notebook = model(in: support)
        notebook.refresh(workspaces: [], sessions: [])
        await settle(notebook)

        let entries = notebook.entries.filter { [first, second].contains($0.documentID) }
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy(\.isUnlinked))
        XCTAssertEqual(Set(entries.map(\.title)).count, 1, "both fall back to the scope name")
        XCTAssertEqual(
            Set(entries.map(\.subtitle)).count, 2,
            "two unlinked notes in one scope have to be tellable apart"
        )
        XCTAssertEqual(notebook.sections.last?.title, "Unlinked")
    }

    func testANameSurvivesTheChatThatProducedItDisappearing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let path = "/tmp/locus-notebook-beta"
        let chatNote = NotesStore.documentID(
            workspacePath: path, sessionID: "chat-gone", scope: .chat
        )
        try write("Kept", scope: .chat, digest: chatNote.digest, in: support)

        let notebook = model(in: support)
        notebook.refresh(
            workspaces: [workspace(path)],
            sessions: [session("chat-gone", title: "Notary follow-up", cwd: path)]
        )
        await settle(notebook)
        XCTAssertEqual(notebook.entries.first { $0.documentID == chatNote }?.title,
                       "Notary follow-up")

        // The session list is where a chat's title lives, and SHA-256 cannot be
        // reversed, so without the recorded name this row loses its identity.
        notebook.refresh(workspaces: [workspace(path)], sessions: [])
        await settle(notebook)
        let entry = try XCTUnwrap(notebook.entries.first { $0.documentID == chatNote })
        XCTAssertEqual(entry.title, "Notary follow-up")
        XCTAssertFalse(entry.isUnlinked)
    }

    func testAnOfflineSessionListIsReportedRatherThanShownAsOrphans() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        try write("Unknown", scope: .chat, digest: String(repeating: "f", count: 64), in: support)

        let notebook = model(in: support)
        notebook.refresh(workspaces: [], sessions: [])
        await settle(notebook)
        XCTAssertTrue(notebook.namingIsIncomplete)

        notebook.refresh(
            workspaces: [],
            sessions: [session("any", title: "Any", cwd: "/tmp/locus-notebook-gamma")]
        )
        await settle(notebook)
        XCTAssertFalse(notebook.namingIsIncomplete)
    }

    func testANoteWrittenBeforeItsChatHadAnIDIsNamedForItsWorkspace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let path = "/tmp/locus-notebook-delta"
        let pending = NotesStore.documentID(workspacePath: path, sessionID: "", scope: .chat)
        try write("Draft", scope: .chat, digest: pending.digest, in: support)

        let notebook = model(in: support)
        notebook.refresh(workspaces: [workspace(path)], sessions: [])
        await settle(notebook)

        let entry = try XCTUnwrap(notebook.entries.first { $0.documentID == pending })
        XCTAssertEqual(entry.title, "Unsaved chat")
        XCTAssertFalse(entry.isUnlinked)
    }

    func testOnlyTheDocumentsThisAppWritesAreEnumerated() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        try write("Real", scope: .workspace, digest: String(repeating: "1", count: 64), in: support)

        let locus = support.appendingPathComponent(AppEdition.current.displayName, isDirectory: true)
        // An abandoned notes format left this folder behind; nothing reads it.
        let legacy = locus.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try #"{"notes":[]}"#.write(
            to: legacy.appendingPathComponent("\(String(repeating: "1", count: 64)).json"),
            atomically: true,
            encoding: .utf8
        )
        let workspaceDirectory = locus
            .appendingPathComponent(NotesStore.directoryName(for: .workspace), isDirectory: true)
        for name in ["notes.txt", "README.md", "\(String(repeating: "z", count: 63)).txt"] {
            try "stray".write(
                to: workspaceDirectory.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        let notebook = model(in: support)
        notebook.refresh(workspaces: [], sessions: [])
        await settle(notebook)
        XCTAssertEqual(notebook.entries.count, 1)
    }

    func testSearchMatchesTitleWorkspaceAndBodyAndSurvivesRefresh() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let path = "/tmp/locus-notebook-epsilon"
        let workspaceNote = NotesStore.documentID(
            workspacePath: path, sessionID: "", scope: .workspace
        )
        let chatNote = NotesStore.documentID(
            workspacePath: path, sessionID: "chat", scope: .chat
        )
        try write(
            "- [ ] tag the build",
            scope: .workspace,
            digest: workspaceNote.digest,
            in: support
        )
        try write("nothing relevant", scope: .chat, digest: chatNote.digest, in: support)

        let notebook = model(in: support)
        notebook.refresh(
            workspaces: [workspace(path)],
            sessions: [session("chat", title: "Notary follow-up", cwd: path)]
        )
        await settle(notebook)

        // A checklist previews as its words, not as its markers.
        XCTAssertEqual(
            notebook.entries.first { $0.documentID == workspaceNote }?.preview,
            "tag the build"
        )
        notebook.query = "tag the build"
        XCTAssertEqual(notebook.filteredEntries.map(\.documentID), [workspaceNote])
        notebook.query = "notary"
        XCTAssertEqual(notebook.filteredEntries.map(\.documentID), [chatNote])
        notebook.query = "epsilon"
        XCTAssertEqual(notebook.filteredEntries.count, 2, "both name their workspace")
        notebook.query = "nothing here matches"
        XCTAssertTrue(notebook.filteredEntries.isEmpty)
        XCTAssertTrue(notebook.sections.isEmpty)
    }

    func testSelectingOpensTheDocumentAndKeepsPointingAtItAcrossARefresh() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let documentID = try write(
            "Original",
            scope: .workspace,
            digest: String(repeating: "9", count: 64),
            in: support
        )

        let notebook = model(in: support)
        notebook.refresh(workspaces: [], sessions: [])
        await settle(notebook)
        notebook.select(try XCTUnwrap(notebook.entries.first))
        XCTAssertEqual(notebook.selectedStore?.text, "Original")
        XCTAssertEqual(notebook.selection?.documentID, documentID)

        try write("Rewritten", scope: .workspace, digest: documentID.digest, in: support)
        notebook.refresh(workspaces: [], sessions: [])
        await settle(notebook)
        XCTAssertEqual(
            notebook.selection?.documentID, documentID,
            "a refresh must not silently drop the open document"
        )
        XCTAssertEqual(notebook.entries.first?.preview, "Rewritten")
    }

    func testCreatePersistsBlankStandaloneAndSelectsItWithoutContext() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = model(in: root)
        notebook.query = "a previous search"
        notebook.showingTrash = true
        let entry = try XCTUnwrap(notebook.createNote())
        let store = try XCTUnwrap(notebook.selectedStore)

        XCTAssertTrue(entry.isStandalone)
        XCTAssertFalse(entry.isUnlinked)
        XCTAssertEqual(entry.documentID.directoryName, "Notebook Notes")
        XCTAssertEqual(entry.title, "Untitled Note")
        XCTAssertEqual(notebook.selection?.id, entry.id)
        XCTAssertNotNil(notebook.createdSelectionToken)
        XCTAssertFalse(notebook.showingTrash)
        XCTAssertEqual(notebook.query, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "")
        XCTAssertEqual(notebook.sections.map(\.title), ["My Notes"])

        let reloaded = model(in: root)
        reloaded.refresh(workspaces: [], sessions: [])
        await settle(reloaded)
        XCTAssertEqual(reloaded.entries.map(\.id), [entry.id])
        XCTAssertEqual(reloaded.entries.first?.title, "Untitled Note")
        for scope in NotesScope.allCases {
            let directory = root.appendingPathComponent(AppEdition.current.displayName)
                .appendingPathComponent(NotesStore.directoryName(for: scope))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testRenameOverridesInferredTitleAndDuplicateUsesLatestRichText() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/tmp/locus-notebook-rename"
        let id = NotesStore.documentID(workspacePath: path, sessionID: "source", scope: .chat)
        try write("Saved original", scope: .chat, digest: id.digest, in: root)
        let notebook = model(in: root)
        notebook.refresh(workspaces: [workspace(path)], sessions: [session("source", title: "Chat title", cwd: path)])
        await settle(notebook)
        let originalEntry = try XCTUnwrap(notebook.entries.first)
        notebook.select(originalEntry)
        let source = try XCTUnwrap(notebook.selectedStore)
        let formatted = NSMutableAttributedString(attributedString: NotesTextStyle.plain("Latest unsaved contents"))
        formatted.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18),
                               range: NSRange(location: 0, length: formatted.length))
        source.updateAttributed(formatted)
        notebook.rename(originalEntry, title: "My release checklist")
        notebook.select(originalEntry)
        XCTAssertEqual(notebook.selection?.title, "My release checklist", "a captured row cannot restore an old title")
        let copy = try XCTUnwrap(notebook.duplicate(originalEntry))
        XCTAssertEqual(copy.title, "My release checklist copy", "a title edit must apply before duplication")
        XCTAssertTrue(copy.isStandalone)
        XCTAssertNotEqual(copy.id, originalEntry.id)
        XCTAssertEqual(notebook.selectedStore?.text, formatted.string)
        let copiedFont = notebook.selectedStore?.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(copiedFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
        XCTAssertEqual(notebook.entries.first { $0.id == id }?.title, "My release checklist")
        XCTAssertEqual(source.documentID, id, "renaming never changes a contextual document's digest")
        try source.flush()

        let reloaded = model(in: root)
        reloaded.refresh(workspaces: [], sessions: [])
        await settle(reloaded)
        XCTAssertEqual(reloaded.entries.first { $0.id == id }?.title, "My release checklist")
        XCTAssertFalse(try XCTUnwrap(reloaded.entries.first { $0.id == id }).isUnlinked)
    }

    func testPinAndSortPersistWithoutDuplicatingRows() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = model(in: root)
        let zulu = try XCTUnwrap(notebook.createNote())
        notebook.rename(zulu, title: "Zulu")
        let alpha = try XCTUnwrap(notebook.createNote())
        notebook.rename(alpha, title: "Alpha")
        notebook.togglePin(zulu)
        notebook.sortOrder = .titleAscending
        XCTAssertEqual(notebook.sections.map(\.title), ["Pinned", "My Notes"])
        XCTAssertEqual(notebook.sections.flatMap(\.entries).map(\.id), [zulu.id, alpha.id])
        XCTAssertEqual(Set(notebook.sections.flatMap(\.entries).map(\.id)).count, 2)

        let reloaded = model(in: root)
        reloaded.refresh(workspaces: [], sessions: [])
        await settle(reloaded)
        XCTAssertEqual(reloaded.sortOrder, .titleAscending)
        XCTAssertEqual(reloaded.entries.map(\.title), ["Alpha", "Zulu"])
        XCTAssertTrue(try XCTUnwrap(reloaded.entries.first { $0.id == zulu.id }).isPinned)
    }

    func testTrashPreservesLatestTextAndRestorePreservesIdentity() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = model(in: root)
        let entry = try XCTUnwrap(notebook.createNote())
        let store = try XCTUnwrap(notebook.selectedStore)
        store.update("The final keystroke")
        notebook.trash(entry)
        XCTAssertTrue(notebook.entries.isEmpty)
        XCTAssertNil(notebook.selection)
        let deleted = try XCTUnwrap(notebook.recentlyDeleted.first)
        XCTAssertTrue(deleted.canRestore)
        XCTAssertTrue(deleted.isTrashed)
        XCTAssertFalse(store.isEditable)
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "The final keystroke")
        notebook.showingTrash = true
        // A row action can retain the value it captured before deletion. The
        // current collection, rather than that snapshot's lifecycle, decides
        // whether the same document can be selected.
        notebook.select(entry)
        await Task.yield()
        XCTAssertEqual(notebook.selection?.id, entry.id)
        XCTAssertTrue(notebook.selection?.isTrashed == true)
        XCTAssertTrue(notebook.selectedStore === store)
        XCTAssertEqual(notebook.selectedStore?.text, "The final keystroke")
        notebook.select(deleted)
        XCTAssertEqual(notebook.selection?.id, deleted.id)
        XCTAssertTrue(notebook.selection?.isTrashed == true)
        XCTAssertTrue(notebook.selectedStore === store)
        XCTAssertEqual(notebook.selectedStore?.text, "The final keystroke")
        notebook.restore(deleted)
        XCTAssertTrue(notebook.recentlyDeleted.isEmpty)
        XCTAssertEqual(notebook.entries.map(\.id), [entry.id])
        XCTAssertTrue(store.isEditable)
        notebook.showingTrash = false
        notebook.select(try XCTUnwrap(notebook.entries.first))
        XCTAssertTrue(notebook.selectedStore === store)
        XCTAssertEqual(store.text, "The final keystroke")
    }

    func testFailedPurgeStaysVisibleAfterReloadAndRetryFinishesDeletion() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = model(in: root)
        let entry = try XCTUnwrap(notebook.createNote())
        let store = try XCTUnwrap(notebook.selectedStore)
        store.update("Retained until deletion succeeds")
        notebook.trash(entry)
        try FileManager.default.removeItem(at: store.styledFileURL)
        try FileManager.default.createDirectory(at: store.styledFileURL, withIntermediateDirectories: false)
        notebook.deletePermanently(try XCTUnwrap(notebook.recentlyDeleted.first))
        XCTAssertNotNil(notebook.errorMessage)
        let pending = try XCTUnwrap(notebook.recentlyDeleted.first)
        XCTAssertTrue(pending.isPurgePending)
        XCTAssertFalse(pending.canRestore)
        XCTAssertEqual(pending.preview, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        let reloaded = model(in: root)
        reloaded.refresh(workspaces: [], sessions: [])
        await settle(reloaded)
        XCTAssertTrue(try XCTUnwrap(reloaded.recentlyDeleted.first).isPurgePending)
        XCTAssertTrue(reloaded.entries.isEmpty)
        try FileManager.default.removeItem(at: store.styledFileURL)
        notebook.retry()
        XCTAssertNil(notebook.errorMessage)
        XCTAssertTrue(notebook.recentlyDeleted.isEmpty)
        reloaded.refresh(workspaces: [], sessions: [])
        await settle(reloaded)
        XCTAssertTrue(reloaded.recentlyDeleted.isEmpty)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    func testEmptyTrashReportsFailureAndRetryCompletesRemainingDocuments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = model(in: root)
        let first = try XCTUnwrap(notebook.createNote())
        let blockedStore = try XCTUnwrap(notebook.selectedStore)
        notebook.trash(first)
        let second = try XCTUnwrap(notebook.createNote())
        notebook.trash(second)
        try FileManager.default.removeItem(at: blockedStore.styledFileURL)
        try FileManager.default.createDirectory(at: blockedStore.styledFileURL, withIntermediateDirectories: false)
        notebook.emptyTrash()
        XCTAssertNotNil(notebook.errorMessage)
        XCTAssertTrue(notebook.recentlyDeleted.contains { $0.id == first.id && $0.isPurgePending })
        try FileManager.default.removeItem(at: blockedStore.styledFileURL)
        notebook.retry()
        XCTAssertNil(notebook.errorMessage)
        XCTAssertTrue(notebook.recentlyDeleted.isEmpty)
        XCTAssertTrue(notebook.entries.isEmpty)
    }

    func testFullTextSearchUsesLatestDiskContentDespitePreviouslyOpenedStore() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try write("An old body", scope: .workspace,
                           digest: String(repeating: "6", count: 64), in: root)
        let notebook = model(in: root)
        notebook.refresh(workspaces: [], sessions: [])
        await settle(notebook)
        notebook.select(try XCTUnwrap(notebook.entries.first))
        let store = try XCTUnwrap(notebook.selectedStore)
        let replacement = String(repeating: "intro ", count: 600) + "hidden-search-needle"
        try write(replacement, scope: .workspace, digest: id.digest, in: root)
        notebook.refresh(workspaces: [], sessions: [])
        await settle(notebook)
        XCTAssertFalse(try XCTUnwrap(notebook.entries.first).preview.contains("hidden-search-needle"))
        notebook.query = "hidden-search-needle"
        XCTAssertTrue(notebook.isSearching)
        await settle(notebook)
        XCTAssertEqual(notebook.filteredEntries.map(\.id), [id])
        XCTAssertTrue(notebook.selectedStore === store)
        notebook.select(try XCTUnwrap(notebook.entries.first))
        XCTAssertEqual(store.text, replacement, "clicking the same note refreshes its clean editor")
        notebook.query = "An old body"
        await settle(notebook)
        XCTAssertTrue(notebook.filteredEntries.isEmpty)
    }

    func testSearchCancelsSupersededQueriesAndUsesWholeStyledDocument() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write(nil, scope: .workspace, digest: String(repeating: "7", count: 64), in: root,
            styled: NotesTextStyle.plain(String(repeating: "body ", count: 600) + "first-needle"))
        let second = try write("second-needle", scope: .workspace,
                               digest: String(repeating: "8", count: 64), in: root)
        let notebook = model(in: root)
        notebook.refresh(workspaces: [], sessions: [])
        await settle(notebook)
        notebook.query = "first-needle"
        await settle(notebook)
        XCTAssertEqual(notebook.filteredEntries.map(\.id), [first])
        notebook.query = "no match"
        notebook.query = "first-needle"
        notebook.query = "second-needle"
        await settle(notebook)
        XCTAssertEqual(notebook.filteredEntries.map(\.id), [second])
        notebook.query = "first-needle"
        notebook.query = ""
        await settle(notebook)
        XCTAssertFalse(notebook.isSearching)
        XCTAssertEqual(notebook.filteredEntries.count, 2)
        notebook.query = "second-needle"
        notebook.showingTrash = true
        await settle(notebook)
        XCTAssertTrue(notebook.filteredEntries.isEmpty)
    }

    func testLivePreviewAndBackgroundSaveKeepTheSameSelectedStore() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = model(in: root)
        let selected = try XCTUnwrap(notebook.createNote())
        let selectedStore = try XCTUnwrap(notebook.selectedStore)
        selectedStore.update("Live unsaved words")
        await waitUntil { notebook.entries.first { $0.id == selected.id }?.preview == "Live unsaved words" }
        XCTAssertTrue(notebook.selectedStore === selectedStore)
        let external = NotesStore.testingStore(workspacePath: "/tmp/notebook-external",
            sessionID: "external", scope: .chat, applicationSupport: root)
        external.update("Saved by another notes surface")
        try external.flush()
        await waitUntil { notebook.entries.contains { $0.id == external.documentID } }
        XCTAssertEqual(notebook.entries.first { $0.id == external.documentID }?.preview, "Saved by another notes surface")
        XCTAssertEqual(notebook.selection?.id, selected.id)
        XCTAssertTrue(notebook.selectedStore === selectedStore)
        try selectedStore.flush()
    }

    func testCreateAndDuplicateDuringRefreshKeepTheirCapturedPreviews() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = model(in: root)
        let original = try XCTUnwrap(notebook.createNote())
        let source = try XCTUnwrap(notebook.selectedStore)
        source.update("Content captured while discovery is running")
        try source.flush()
        for _ in 0..<5 {
            notebook.refresh(workspaces: [], sessions: [])
            let copy = try XCTUnwrap(notebook.duplicate(original))
            let blank = try XCTUnwrap(notebook.createNote())
            await settle(notebook)
            XCTAssertEqual(notebook.entries.first { $0.id == copy.id }?.preview, source.text)
            XCTAssertTrue(notebook.entries.contains { $0.id == blank.id })
            XCTAssertEqual(notebook.selection?.id, blank.id)
        }
        XCTAssertEqual(notebook.entries.count, 11)
    }

    func testMetadataFailureIsVisibleAndRetryPerformsOriginalRename() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = model(in: root)
        let entry = try XCTUnwrap(notebook.createNote())
        let catalogURL = NotebookCatalog.fileURL(in: root)
        let original = try Data(contentsOf: catalogURL)
        try Data("damaged catalog".utf8).write(to: catalogURL)
        notebook.rename(entry, title: "Retry this title")
        XCTAssertNotNil(notebook.errorMessage)
        XCTAssertEqual(notebook.entries.first?.title, "Untitled Note")
        try original.write(to: catalogURL)
        notebook.retry()
        XCTAssertNil(notebook.errorMessage)
        XCTAssertEqual(notebook.entries.first?.title, "Retry this title")
    }
}
