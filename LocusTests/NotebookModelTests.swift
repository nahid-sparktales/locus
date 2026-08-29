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
            .appendingPathComponent("Locus", isDirectory: true)
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

    /// A model whose stores are confined to the fixture directory. The default
    /// provider reaches the process-wide cache, which is the real Application
    /// Support folder.
    private func model(in support: URL) -> NotebookModel {
        NotebookModel(applicationSupport: support) { documentID, scope in
            NotesStore.testingStore(
                documentID: documentID,
                scope: scope,
                applicationSupport: support
            )
        }
    }

    func testEveryStoredDocumentIsListedAcrossAllThreeScopes() throws {
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

    func testStyledOnlyAndEmptyNotesEachAppearExactlyOnce() throws {
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

    func testUnknownDigestsStayListedAndDistinguishableAsUnlinked() throws {
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

    func testANameSurvivesTheChatThatProducedItDisappearing() throws {
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
        XCTAssertEqual(notebook.entries.first { $0.documentID == chatNote }?.title,
                       "Notary follow-up")

        // The session list is where a chat's title lives, and SHA-256 cannot be
        // reversed, so without the recorded name this row loses its identity.
        notebook.refresh(workspaces: [workspace(path)], sessions: [])
        let entry = try XCTUnwrap(notebook.entries.first { $0.documentID == chatNote })
        XCTAssertEqual(entry.title, "Notary follow-up")
        XCTAssertFalse(entry.isUnlinked)
    }

    func testAnOfflineSessionListIsReportedRatherThanShownAsOrphans() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        try write("Unknown", scope: .chat, digest: String(repeating: "f", count: 64), in: support)

        let notebook = model(in: support)
        notebook.refresh(workspaces: [], sessions: [])
        XCTAssertTrue(notebook.namingIsIncomplete)

        notebook.refresh(
            workspaces: [],
            sessions: [session("any", title: "Any", cwd: "/tmp/locus-notebook-gamma")]
        )
        XCTAssertFalse(notebook.namingIsIncomplete)
    }

    func testANoteWrittenBeforeItsChatHadAnIDIsNamedForItsWorkspace() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let path = "/tmp/locus-notebook-delta"
        let pending = NotesStore.documentID(workspacePath: path, sessionID: "", scope: .chat)
        try write("Draft", scope: .chat, digest: pending.digest, in: support)

        let notebook = model(in: support)
        notebook.refresh(workspaces: [workspace(path)], sessions: [])

        let entry = try XCTUnwrap(notebook.entries.first { $0.documentID == pending })
        XCTAssertEqual(entry.title, "Unsaved chat")
        XCTAssertFalse(entry.isUnlinked)
    }

    func testOnlyTheDocumentsThisAppWritesAreEnumerated() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        try write("Real", scope: .workspace, digest: String(repeating: "1", count: 64), in: support)

        let locus = support.appendingPathComponent("Locus", isDirectory: true)
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
        XCTAssertEqual(notebook.entries.count, 1)
    }

    func testSearchMatchesTitleWorkspaceAndBodyAndSurvivesRefresh() throws {
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

    func testSelectingOpensTheDocumentAndKeepsPointingAtItAcrossARefresh() throws {
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
        notebook.select(try XCTUnwrap(notebook.entries.first))
        XCTAssertEqual(notebook.selectedStore?.text, "Original")
        XCTAssertEqual(notebook.selection?.documentID, documentID)

        try write("Rewritten", scope: .workspace, digest: documentID.digest, in: support)
        notebook.refresh(workspaces: [], sessions: [])
        XCTAssertEqual(
            notebook.selection?.documentID, documentID,
            "a refresh must not silently drop the open document"
        )
        XCTAssertEqual(notebook.entries.first?.preview, "Rewritten")
    }
}
