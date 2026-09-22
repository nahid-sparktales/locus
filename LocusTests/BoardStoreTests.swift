import XCTest
@testable import Locus

@MainActor
final class BoardStoreTests: XCTestCase {
    private let atlas = BoardAuthor(kind: .agent, name: "Atlas", agentID: "atlas", sessionID: "session-1")

    /// A temporary Application Support root and a workspace folder whose name
    /// gives the key prefix `LOC`.
    private func makeStore() throws -> (store: BoardStore, workspace: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoardStoreTests-\(UUID().uuidString)", isDirectory: true)
        let workspace = base.appendingPathComponent("locus-board", isDirectory: true)
        let root = base.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (BoardStore.testingStore(workspacePath: workspace.path, applicationSupport: root), workspace, root)
    }

    private func reopened(_ store: BoardStore, root: URL) -> BoardStore {
        BoardStore.testingStore(workspacePath: store.workspacePath, applicationSupport: root)
    }

    /// Writes a board file directly, for states too large to build card by card.
    private func writeDocument(for store: BoardStore, cardCount: Int, columnID: String = "todo") throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let cards = (0..<cardCount).map { index in
            BoardCard(
                id: UUID(), number: index + 1, title: "Card \(index + 1)", details: "",
                columnID: columnID, priority: BoardPriority.none, labels: [], assignee: nil,
                createdAt: date, updatedAt: date, createdBy: .user, timeline: []
            )
        }
        let document = BoardDocument(
            version: 1, workspacePath: store.workspacePath, keyPrefix: store.keyPrefix,
            nextNumber: cardCount + 1, columns: BoardStore.defaultColumns, cards: cards, updatedAt: date
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try NotebookFileIO.write(try encoder.encode(document), to: try XCTUnwrap(store.fileURL))
        store.reload()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.cards.count, cardCount)
    }

    private func assertError(
        _ expected: BoardStoreError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? BoardStoreError, expected, file: file, line: line)
        }
    }

    func testAgentTagsPersistAndPartialEditsPreserveOtherChanges() throws {
        let (store, _, root) = try makeStore()
        let first = UUID(), second = UUID()
        let card = try store.createCard(title: "Tagged card", agentIDs: [first, first])
        XCTAssertEqual(reopened(store, root: root).cards.first?.agentIDs, [first])
        var edits = BoardCardEdits(); edits.load(card)
        edits.draft.agentIDs = [second]
        try store.updateCard(card.id, title: "Agent updated the title")
        try edits.saveFields(of: card.id, in: store)
        XCTAssertEqual(store.cards.first?.title, "Agent updated the title")
        XCTAssertEqual(store.cards.first?.agentIDs, [second])
        let response = store.perform(tool: "board_update_card", arguments: ["card_id": store.key(for: card), "agent_ids": [String]()], author: atlas)
        XCTAssertNil(response["error"])
        XCTAssertEqual(reopened(store, root: root).cards.first?.agentIDs, [])
        let invalid = store.perform(tool: "board_update_card", arguments: ["card_id": store.key(for: card), "agent_ids": ["invalid"]], author: atlas)
        XCTAssertNotNil(invalid["error"])
        XCTAssertEqual(store.cards.first?.agentIDs, [])
    }

    // MARK: - Persistence

    func testBoardPersistsAsOneJSONFilePerWorkspaceAndReloads() throws {
        let (store, workspace, root) = try makeStore()
        let canonical = SessionSummary.canonicalWorkspacePath(workspace.path)
        XCTAssertEqual(store.workspacePath, canonical)
        XCTAssertEqual(store.columns, BoardStore.defaultColumns)
        XCTAssertEqual(BoardStore.defaultColumns.map(\.id), ["backlog", "todo", "in-progress", "review", "done"])
        XCTAssertEqual(
            store.fileURL,
            root.appendingPathComponent(AppEdition.current.displayName, isDirectory: true)
                .appendingPathComponent("Workspace Boards", isDirectory: true)
                .appendingPathComponent("\(NotesStore.digest(of: canonical)).json")
        )
        let fileURL = try XCTUnwrap(store.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "opening a board writes nothing")

        let first = try store.createCard(title: "Plan launch", details: "Line one\nLine two",
                                         priority: .high, labels: ["release"], assignee: "Atlas")
        try store.addComment(to: first.id, text: "Kickoff is Monday.", author: atlas)
        try store.createCard(title: "Write docs", columnID: "review")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["workspacePath"] as? String, canonical)
        XCTAssertEqual(json["keyPrefix"] as? String, "LOC")
        XCTAssertEqual(json["nextNumber"] as? Int, 3)
        let storedCard = try XCTUnwrap((json["cards"] as? [[String: Any]])?.first)
        XCTAssertEqual(storedCard["description"] as? String, "Line one\nLine two")
        XCTAssertTrue((storedCard["createdAt"] as? String)?.hasSuffix("Z") == true)

        let reloaded = reopened(store, root: root)
        XCTAssertNil(reloaded.lastError)
        XCTAssertEqual(reloaded.columns, store.columns)
        XCTAssertEqual(reloaded.cards, store.cards)
        XCTAssertEqual(reloaded.keyPrefix, "LOC")
        let third = try reloaded.createCard(title: "Numbers continue")
        XCTAssertEqual(reloaded.key(for: third), "LOC-3")

        // The original instance catches up with another writer on reload.
        XCTAssertEqual(store.cards.count, 2)
        store.reload()
        XCTAssertEqual(store.cards.map(\.title), ["Plan launch", "Write docs", "Numbers continue"])
        XCTAssertEqual(BoardStore.shared(workspacePath: workspace.path, applicationSupport: root).cards.count, 3)
        XCTAssertTrue(BoardStore.shared(workspacePath: workspace.path, applicationSupport: root)
            === BoardStore.shared(workspacePath: workspace.path + "/", applicationSupport: root))
        XCTAssertEqual(BoardStore.storageIdentity(workspacePath: workspace.path),
                       BoardStore.storageIdentity(workspacePath: " \(workspace.path)/ "))
    }

    func testFileForAnotherWorkspaceIsIgnoredUntilTheNextChange() throws {
        let (store, _, root) = try makeStore()
        let fileURL = try XCTUnwrap(store.fileURL)
        let foreign = BoardDocument(
            version: 1, workspacePath: "/somewhere/else", keyPrefix: "ELS", nextNumber: 9,
            columns: [BoardColumn(id: "only", title: "Only")], cards: [], updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let foreignData = try encoder.encode(foreign)
        try NotebookFileIO.write(foreignData, to: fileURL)

        let loaded = reopened(store, root: root)
        XCTAssertEqual(loaded.columns, BoardStore.defaultColumns)
        XCTAssertEqual(loaded.keyPrefix, "LOC")
        XCTAssertTrue(loaded.cards.isEmpty)
        XCTAssertTrue(loaded.lastError?.contains("different workspace") == true)
        XCTAssertEqual(try Data(contentsOf: fileURL), foreignData, "an unusable file is not overwritten on load")

        let card = try loaded.createCard(title: "Fresh start")
        XCTAssertEqual(loaded.key(for: card), "LOC-1")
        XCTAssertNil(loaded.lastError)
        XCTAssertEqual(reopened(store, root: root).cards.map(\.title), ["Fresh start"])

        try Data("{not json".utf8).write(to: fileURL)
        loaded.reload()
        XCTAssertTrue(loaded.cards.isEmpty)
        XCTAssertTrue(loaded.lastError?.contains("not a valid board") == true)
    }

    func testBlankWorkspaceRefusesEveryChange() throws {
        let (_, _, root) = try makeStore()
        let store = BoardStore.testingStore(workspacePath: "  \n", applicationSupport: root)
        XCTAssertFalse(store.isAvailable)
        XCTAssertEqual(store.workspacePath, "")
        XCTAssertNil(store.fileURL)
        XCTAssertEqual(store.keyPrefix, "CARD")
        assertError(.workspaceRequired) { try store.createCard(title: "Nowhere") }
        assertError(.workspaceRequired) { try store.addColumn(title: "Later") }
        XCTAssertEqual(
            store.perform(tool: "board_read", arguments: [:], author: atlas)["error"] as? String,
            "Open a workspace to use the board."
        )
        XCTAssertEqual(
            store.perform(tool: "board_create_card", arguments: ["title": "x"], author: atlas)["error"] as? String,
            "Open a workspace to use the board."
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(AppEdition.current.displayName).path
        ))
    }

    // MARK: - Keys and lookup

    func testKeyPrefixComesFromTheWorkspaceFolderName() throws {
        XCTAssertEqual(BoardStore.keyPrefix(forWorkspace: "/Users/me/locus"), "LOC")
        XCTAssertEqual(BoardStore.keyPrefix(forWorkspace: "/Users/me/my-app"), "MYA")
        XCTAssertEqual(BoardStore.keyPrefix(forWorkspace: "/Users/me/a1"), "A1")
        XCTAssertEqual(BoardStore.keyPrefix(forWorkspace: "/Users/me/été"), "ETE")
        XCTAssertEqual(BoardStore.keyPrefix(forWorkspace: "/Users/me/日本"), "CARD")
        XCTAssertEqual(BoardStore.keyPrefix(forWorkspace: "/Users/me/__"), "CARD")
        XCTAssertEqual(BoardStore.keyPrefix(forWorkspace: "/"), "CARD")
        XCTAssertEqual(BoardStore.keyPrefix(forWorkspace: ""), "CARD")
        let (store, _, _) = try makeStore()
        let card = try store.createCard(title: "First")
        XCTAssertEqual(card.number, 1)
        XCTAssertEqual(store.key(for: card), "LOC-1")
    }

    func testCardsResolveByKeyNumberHashNumberAndUUID() throws {
        let (store, _, _) = try makeStore()
        try store.createCard(title: "One")
        let two = try store.createCard(title: "Two")
        for reference in ["LOC-2", "loc-2", " Loc-2 ", "2", "#2", two.id.uuidString, two.id.uuidString.lowercased()] {
            XCTAssertEqual(store.card(matching: reference)?.id, two.id, reference)
        }
        for reference in ["LOC-9", "ABC-2", "9", "#", "", "two", UUID().uuidString] {
            XCTAssertNil(store.card(matching: reference), reference)
        }
    }

    func testColumnsResolveByIdOrTitle() throws {
        let (store, _, _) = try makeStore()
        XCTAssertEqual(store.column(matching: "in-progress")?.id, "in-progress")
        XCTAssertEqual(store.column(matching: "IN-PROGRESS")?.id, "in-progress")
        XCTAssertEqual(store.column(matching: "In Progress")?.id, "in-progress")
        XCTAssertEqual(store.column(matching: "to do")?.id, "todo")
        XCTAssertEqual(store.column(matching: "in_progress")?.id, "in-progress")
        XCTAssertNil(store.column(matching: "Doing"))
        XCTAssertNil(store.column(matching: " "))
    }

    // MARK: - Mutations

    func testCreateUpdateAndMoveKeepColumnOrderAndRecordActivity() throws {
        let (store, _, _) = try makeStore()
        let a = try store.createCard(title: "A")
        let b = try store.createCard(title: "B")
        let c = try store.createCard(title: "C", position: 0)
        XCTAssertEqual(a.columnID, "backlog", "the first column is the default")
        XCTAssertEqual(store.cards(in: "backlog").map(\.title), ["C", "A", "B"])
        XCTAssertEqual(c.timeline.map(\.text), ["Created in Backlog"])
        XCTAssertEqual(c.createdBy, .user)

        try store.moveCard(b.id, toColumn: "in-progress")
        try store.moveCard(a.id, toColumn: "in-progress", position: 0)
        XCTAssertEqual(store.cards(in: "in-progress").map(\.title), ["A", "B"])
        XCTAssertEqual(store.cards(in: "backlog").map(\.title), ["C"])
        try store.moveCard(a.id, toColumn: "in-progress", position: 5)
        XCTAssertEqual(store.cards(in: "in-progress").map(\.title), ["B", "A"])
        let before = try XCTUnwrap(store.card(matching: "LOC-1"))
        try store.moveCard(a.id, toColumn: "in-progress")
        XCTAssertEqual(store.card(matching: "LOC-1"), before, "a move to where the card is changes nothing")
        XCTAssertEqual(before.timeline.map(\.text), [
            "Created in Backlog", "Moved from Backlog to In Progress", "Reordered within In Progress",
        ])
        assertError(.columnNotFound("nope", available: ["Backlog", "To Do", "In Progress", "Review", "Done"])) {
            try store.moveCard(a.id, toColumn: "nope")
        }
        assertError(.cardNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!.uuidString)) {
            try store.moveCard(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, toColumn: "todo")
        }

        try store.updateCard(a.id, title: "  A renamed ", details: "Notes", priority: .urgent,
                             labels: [" ui ", "UI", "", "bug"], assignee: "Atlas", author: atlas)
        var updated = try XCTUnwrap(store.card(matching: "LOC-1"))
        XCTAssertEqual(updated.title, "A renamed")
        XCTAssertEqual(updated.details, "Notes")
        XCTAssertEqual(updated.priority, .urgent)
        XCTAssertEqual(updated.labels, ["ui", "bug"])
        XCTAssertEqual(updated.assignee, "Atlas")
        XCTAssertEqual(Array(updated.timeline.suffix(5)).map(\.text), [
            "Renamed to “A renamed”", "Updated the description", "Set priority to Urgent",
            "Set labels to ui, bug", "Assigned to Atlas",
        ])
        XCTAssertTrue(updated.timeline.suffix(5).allSatisfy { $0.author == atlas && $0.kind == .activity })

        let count = updated.timeline.count
        try store.updateCard(a.id, title: "A renamed", priority: .urgent, assignee: nil)
        XCTAssertEqual(store.card(matching: "LOC-1")?.timeline.count, count, "unchanged fields record nothing")
        try store.updateCard(a.id, assignee: .some(nil))
        XCTAssertNil(store.card(matching: "LOC-1")?.assignee)
        try store.updateCard(a.id, labels: [], assignee: "Rin")
        try store.updateCard(a.id, details: "", assignee: "")
        updated = try XCTUnwrap(store.card(matching: "LOC-1"))
        XCTAssertNil(updated.assignee)
        XCTAssertEqual(updated.labels, [])
        XCTAssertEqual(Array(updated.timeline.suffix(5)).map(\.text), [
            "Cleared the assignee", "Cleared labels", "Assigned to Rin",
            "Cleared the description", "Cleared the assignee",
        ])
    }

    func testCommentsAndActivityCarryTheirAuthor() throws {
        let (store, _, _) = try makeStore()
        let card = try store.createCard(title: "Discuss", author: atlas)
        XCTAssertNotNil(store.lastAgentChange, "agent writes are flagged for the UI")
        XCTAssertEqual(card.createdBy, atlas)
        let flagged = store.lastAgentChange

        try store.addComment(to: card.id, text: "  Can you take this?\n ")
        XCTAssertEqual(store.lastAgentChange, flagged, "user writes are not agent changes")
        try store.addComment(to: card.id, text: "On it.", author: atlas)
        let timeline = try XCTUnwrap(store.card(matching: "LOC-1")?.timeline)
        XCTAssertEqual(timeline.map(\.kind), [.activity, .comment, .comment])
        XCTAssertEqual(timeline.map(\.author.name), ["Atlas", "You", "Atlas"])
        XCTAssertEqual(timeline.map(\.author.kind), [.agent, .user, .agent])
        XCTAssertEqual(timeline[1].text, "Can you take this?")
        XCTAssertEqual(timeline[2].author.agentID, "atlas")
        XCTAssertEqual(timeline[2].author.sessionID, "session-1")
        XCTAssertEqual(store.card(matching: "LOC-1")?.commentCount, 2)

        let spoof = BoardAuthor(kind: .agent, name: "\u{202E}Mal\nlory\u{0007}" + String(repeating: "x", count: 100))
        XCTAssertEqual(spoof.name, "Mal lory " + String(repeating: "x", count: 55))
        XCTAssertEqual(BoardAuthor(kind: .agent, name: " \n ").name, "Agent")
        XCTAssertEqual(BoardAuthor.user.name, "You")
    }

    func testTimelineKeepsTheNewestEntriesAndDropsActivityFirst() throws {
        let date = Date()
        func entries(_ kinds: [BoardTimelineEntry.Kind]) -> [BoardTimelineEntry] {
            kinds.enumerated().map { index, kind in
                BoardTimelineEntry(kind: kind, author: .user, text: "\(index)", createdAt: date)
            }
        }
        let pairs = Array(repeating: [BoardTimelineEntry.Kind.activity, .comment], count: 105)
        let mixed = entries(pairs.flatMap { $0 })
        let trimmed = BoardStore.trimmedTimeline(mixed)
        XCTAssertEqual(trimmed.count, 200)
        XCTAssertEqual(trimmed.filter { $0.kind == .comment }.count, 105, "comments outlive activity")
        XCTAssertEqual(trimmed.first?.text, "1")

        let chatty = entries([.activity, .activity]
            + Array(repeating: BoardTimelineEntry.Kind.comment, count: 202))
        let kept = BoardStore.trimmedTimeline(chatty)
        XCTAssertEqual(kept.count, 200)
        XCTAssertTrue(kept.allSatisfy { $0.kind == .comment })
        XCTAssertEqual(kept.first?.text, "4", "then the oldest comments go")

        let (store, _, _) = try makeStore()
        let card = try store.createCard(title: "Busy")
        for index in 1...BoardStore.maximumTimelineEntries {
            try store.addComment(to: card.id, text: "Comment \(index)")
        }
        let timeline = try XCTUnwrap(store.card(matching: "LOC-1")?.timeline)
        XCTAssertEqual(timeline.count, 200)
        XCTAssertEqual(timeline.first?.text, "Comment 1", "the creation activity was dropped first")
    }

    func testLimitsAreEnforcedWithExplicitErrors() throws {
        let (store, _, _) = try makeStore()
        assertError(.titleRequired) { try store.createCard(title: " \n ") }
        assertError(.titleTooLong) { try store.createCard(title: String(repeating: "t", count: 201)) }
        XCTAssertNoThrow(try store.createCard(title: String(repeating: "t", count: 200)))
        assertError(.descriptionTooLong) {
            try store.createCard(title: "Long", details: String(repeating: "d", count: 20_001))
        }
        assertError(.tooManyLabels) {
            try store.createCard(title: "Labels", labels: (1...9).map { "l\($0)" })
        }
        XCTAssertEqual(try store.createCard(title: "Dupes", labels: (1...9).map { _ in "same" }).labels, ["same"])
        let longLabel = String(repeating: "l", count: 33)
        assertError(.labelTooLong(longLabel)) { try store.createCard(title: "Label", labels: [longLabel]) }
        assertError(.assigneeTooLong) {
            try store.createCard(title: "Assignee", assignee: String(repeating: "a", count: 65))
        }
        let card = try XCTUnwrap(store.cards.first)
        assertError(.commentRequired) { try store.addComment(to: card.id, text: "  ") }
        assertError(.commentTooLong) {
            try store.addComment(to: card.id, text: String(repeating: "c", count: 5_001))
        }
        assertError(.titleRequired) { try store.updateCard(card.id, title: "") }
        XCTAssertEqual(store.cards.count, 2, "rejected changes leave the board untouched")
        XCTAssertEqual(store.card(matching: "LOC-1"), card)

        XCTAssertEqual(
            BoardStoreError.titleTooLong.localizedDescription,
            "Card titles are limited to 200 characters (at most 1000 Unicode code points, "
                + "counting accents and other combining marks)."
        )
        XCTAssertEqual(
            BoardStoreError.commentTooLong.localizedDescription,
            "Comments are limited to 5000 characters (at most 10000 Unicode code points, "
                + "counting accents and other combining marks)."
        )
        XCTAssertEqual(BoardStoreError.tooManyLabels.localizedDescription, "A card can have at most 8 labels.")
        XCTAssertEqual(BoardStoreError.boardFull.localizedDescription,
                       "The board already has 1000 cards. Delete finished cards before adding more.")

        try writeDocument(for: store, cardCount: BoardStore.maximumCards)
        assertError(.boardFull) { try store.createCard(title: "One too many") }
        XCTAssertEqual(
            store.perform(tool: "board_create_card", arguments: ["title": "Again"], author: atlas)["error"] as? String,
            BoardStoreError.boardFull.localizedDescription
        )
    }

    func testDeleteCardRemovesItFromDisk() throws {
        let (store, _, root) = try makeStore()
        let keep = try store.createCard(title: "Keep")
        let drop = try store.createCard(title: "Drop")
        try store.deleteCard(drop.id)
        XCTAssertEqual(store.cards.map(\.id), [keep.id])
        assertError(.cardNotFound(drop.id.uuidString)) { try store.deleteCard(drop.id) }
        let reloaded = reopened(store, root: root)
        XCTAssertEqual(reloaded.cards.map(\.id), [keep.id])
        XCTAssertEqual(try reloaded.createCard(title: "Next").number, 3, "numbers are never reused")
    }

    func testColumnsCanBeAddedRenamedMovedAndDeletedWhenEmpty() throws {
        let (store, _, root) = try makeStore()
        let blocked = try store.addColumn(title: "  Blocked / Waiting ")
        XCTAssertEqual(blocked, BoardColumn(id: "blocked-waiting", title: "Blocked / Waiting"))
        assertError(.duplicateColumn("blocked / waiting")) { try store.addColumn(title: "blocked / waiting") }
        assertError(.columnTitleRequired) { try store.addColumn(title: " ") }
        assertError(.columnTitleTooLong) { try store.addColumn(title: String(repeating: "c", count: 41)) }
        XCTAssertEqual(try store.addColumn(title: "!!!").id, "column")
        XCTAssertEqual(try store.addColumn(title: "Review!").id, "review-2")

        try store.renameColumn("todo", to: "Next Up")
        XCTAssertEqual(store.column(matching: "next up")?.id, "todo")
        assertError(.duplicateColumn("Done")) { try store.renameColumn("todo", to: "Done") }
        XCTAssertNoThrow(try store.renameColumn("todo", to: "next up"), "a column may change its own case")

        try store.moveColumn("done", by: -10)
        XCTAssertEqual(store.columns.first?.id, "done")
        try store.moveColumn("done", by: 1)
        XCTAssertEqual(store.columns.map(\.id).prefix(2), ["backlog", "done"])

        let card = try store.createCard(title: "Occupant", columnID: "done")
        assertError(.columnNotEmpty("Done")) { try store.deleteColumn("done") }
        XCTAssertEqual(
            BoardStoreError.columnNotEmpty("Done").localizedDescription,
            "Move or delete the cards in “Done” before deleting the column."
        )
        try store.deleteCard(card.id)
        try store.deleteColumn("done")
        XCTAssertNil(store.column(matching: "done"))

        for index in store.columns.count..<BoardStore.maximumColumns {
            try store.addColumn(title: "Extra \(index)")
        }
        assertError(.tooManyColumns) { try store.addColumn(title: "One more") }
        XCTAssertEqual(reopened(store, root: root).columns, store.columns)

        for column in store.columns.dropFirst() {
            try store.deleteColumn(column.id)
        }
        assertError(.lastColumn) { try store.deleteColumn(store.columns[0].id) }
    }

    // MARK: - Agent tools

    func testToolsReturnContractTextsAndRecordTheAgent() throws {
        let (store, _, _) = try makeStore()
        var result = store.perform(tool: "board_create_card", arguments: [
            "title": "Fix login", "description": "Steps inside", "column": "to do",
            "priority": "HIGH", "labels": ["bug", "Bug", "auth"], "assignee": "Atlas",
        ], author: atlas)
        XCTAssertEqual(result["text"] as? String, "Created LOC-1 “Fix login” in To Do.")
        XCTAssertEqual(result["card_id"] as? String, "LOC-1")
        var card = try XCTUnwrap(store.card(matching: "LOC-1"))
        XCTAssertEqual(card.priority, .high)
        XCTAssertEqual(card.labels, ["bug", "auth"])
        XCTAssertEqual(card.createdBy, atlas)
        XCTAssertNotNil(store.lastAgentChange)

        result = store.perform(tool: "board_create_card", arguments: [
            "title": "Urgent first", "column": "todo", "position": NSNumber(value: 0),
        ], author: atlas)
        XCTAssertEqual(result["text"] as? String, "Created LOC-2 “Urgent first” in To Do.")
        XCTAssertEqual(store.cards(in: "todo").map(\.number), [2, 1])
        result = store.perform(tool: "board_create_card", arguments: ["title": "Defaults"], author: atlas)
        XCTAssertEqual(result["text"] as? String, "Created LOC-3 “Defaults” in Backlog.")

        result = store.perform(tool: "board_update_card", arguments: [
            "card_id": "loc-1", "column": "In Progress", "priority": "high",
        ], author: atlas)
        XCTAssertEqual(result["text"] as? String, "Updated LOC-1: moved To Do → In Progress.")
        result = store.perform(tool: "board_update_card", arguments: [
            "card_id": "#1", "column": "review", "position": 0, "priority": "urgent",
            "labels": [String](), "assignee": "", "title": "Fix login redirect",
        ], author: atlas)
        XCTAssertEqual(
            result["text"] as? String,
            "Updated LOC-1: moved In Progress → Review at position 0; title “Fix login redirect”; "
                + "priority urgent; labels cleared; assignee cleared."
        )
        card = try XCTUnwrap(store.card(matching: "LOC-1"))
        XCTAssertEqual(card.columnID, "review")
        XCTAssertNil(card.assignee)
        XCTAssertEqual(card.timeline.filter { $0.kind == .activity }.map(\.author), Array(repeating: atlas, count: 7))
        result = store.perform(tool: "board_update_card", arguments: ["card_id": 1, "priority": "urgent"], author: atlas)
        XCTAssertEqual(result["text"] as? String, "LOC-1 already matches; nothing changed.")

        // Authorship comes only from the caller, whatever the arguments say.
        result = store.perform(tool: "board_comment", arguments: [
            "card_id": card.id.uuidString, "text": "Fixed on main.",
            "author": ["kind": "user", "name": "You"], "agent_name": "Mallory", "display_name": "Mallory",
        ], author: atlas)
        XCTAssertEqual(result["text"] as? String, "Commented on LOC-1.")
        XCTAssertEqual(result["card_id"] as? String, "LOC-1")
        let comment = try XCTUnwrap(store.card(matching: "LOC-1")?.timeline.last)
        XCTAssertEqual(comment.kind, .comment)
        XCTAssertEqual(comment.author, atlas)

        result = store.perform(tool: "board_delete_card", arguments: ["card_id": "LOC-3"], author: atlas)
        XCTAssertEqual(result["text"] as? String, "Deleted LOC-3 “Defaults”.")
        XCTAssertNil(store.card(matching: "LOC-3"))
    }

    func testToolErrorsAreActionable() throws {
        let (store, _, _) = try makeStore()
        try store.createCard(title: "Existing")
        let cases: [(String, [String: Any], String)] = [
            ("board_update_card", ["card_id": "LOC-99", "title": "x"],
             "No card matches “LOC-99”. Call board_read to list cards."),
            ("board_create_card", ["title": "x", "column": "Doing"],
             "No column matches “Doing”. Columns: Backlog, To Do, In Progress, Review, Done."),
            ("board_update_card", ["card_id": "LOC-1", "column": "Doing"],
             "No column matches “Doing”. Columns: Backlog, To Do, In Progress, Review, Done."),
            ("board_read", ["column": "Doing"],
             "No column matches “Doing”. Columns: Backlog, To Do, In Progress, Review, Done."),
            ("board_read", ["card_id": "LOC-7"], "No card matches “LOC-7”. Call board_read to list cards."),
            ("board_create_card", [:], "board_create_card requires title."),
            ("board_create_card", ["title": "  "], "A card title is required."),
            ("board_create_card", ["title": 5], "title must be a string."),
            ("board_create_card", ["title": "x", "priority": "p1"],
             "priority must be one of none, low, medium, high, urgent."),
            ("board_create_card", ["title": "x", "labels": [1, 2]], "labels must be an array of strings."),
            ("board_create_card", ["title": "x", "position": "first"], "position must be a whole number."),
            ("board_update_card", ["title": "x"], "board_update_card requires card_id."),
            ("board_update_card", ["card_id": "LOC-1"],
             "board_update_card needs at least one of title, description, column, position, priority, labels, assignee, or agent_ids."),
            ("board_comment", ["card_id": "LOC-1"], "board_comment requires text."),
            ("board_comment", ["card_id": "LOC-1", "text": " "], "A comment needs text."),
            ("board_delete_card", [:], "board_delete_card requires card_id."),
            ("board_read", ["include_done": "maybe"], "include_done must be true or false."),
            ("board_nope", [:], "Unknown Board tool: board_nope."),
        ]
        for (tool, arguments, message) in cases {
            let result = store.perform(tool: tool, arguments: arguments, author: atlas)
            XCTAssertEqual(result["error"] as? String, message, "\(tool) \(arguments)")
            XCTAssertNil(result["text"], tool)
        }
        XCTAssertEqual(store.cards.map(\.title), ["Existing"])
        XCTAssertNil(store.lastAgentChange, "failed agent calls change nothing")
    }

    func testBoardReadListsColumnsCardsAndFilters() throws {
        let (store, _, _) = try makeStore()
        let login = try store.createCard(
            title: "Fix login", details: String(repeating: "word ", count: 50) + "\nsecond line",
            columnID: "in-progress", priority: .high, labels: ["bug", "auth"], assignee: "Atlas"
        )
        try store.addComment(to: login.id, text: "Please look.\nIt fails on SSO.")
        try store.addComment(to: login.id, text: "Found it.", author: atlas)
        try store.createCard(title: "Docs", columnID: "todo", labels: ["docs"])
        try store.createCard(title: "Shipped", columnID: "done", assignee: "atlas")

        var result = store.perform(tool: "board_read", arguments: [:], author: atlas)
        var text = try XCTUnwrap(result["text"] as? String)
        XCTAssertTrue(text.hasPrefix("Board for “locus-board”: 3 cards in 5 columns. Card keys look like LOC-12;"))
        XCTAssertTrue(text.contains("## Backlog [backlog] · 0 cards\nNo cards."), text)
        XCTAssertTrue(text.contains("## In Progress [in-progress] · 1 card\n- LOC-1 “Fix login” · priority high · "
            + "labels: bug, auth · assignee: Atlas · 2 comments · updated "), text)
        XCTAssertTrue(text.contains("- LOC-2 “Docs” · labels: docs · unassigned · updated "), text)
        let excerpt = String(repeating: "word ", count: 32)
        XCTAssertTrue(text.contains("\n  > \(excerpt)…\n"), "descriptions are cut to 160 characters and quoted")
        XCTAssertFalse(text.contains("second line"))
        let columns = try XCTUnwrap(result["columns"] as? [[String: Any]])
        XCTAssertEqual(columns.compactMap { $0["id"] as? String }, BoardStore.defaultColumns.map(\.id))
        XCTAssertEqual(columns.map { $0["card_count"] as? Int }, [0, 1, 1, 0, 1])
        var cards = try XCTUnwrap(result["cards"] as? [[String: Any]])
        XCTAssertEqual(cards.map { $0["key"] as? String }, ["LOC-2", "LOC-1", "LOC-3"])
        XCTAssertEqual(cards[1]["comment_count"] as? Int, 2)
        XCTAssertEqual(result["truncated"] as? Bool, false)

        result = store.perform(tool: "board_read", arguments: ["assignee": "ATLAS", "include_done": false], author: atlas)
        text = try XCTUnwrap(result["text"] as? String)
        XCTAssertTrue(text.contains("Filters: assignee “ATLAS”, excluding Done."), text)
        XCTAssertTrue(text.contains("## To Do [todo] · 0 of 1 card\nNo matching cards."), text)
        XCTAssertFalse(text.contains("## Done"))
        cards = try XCTUnwrap(result["cards"] as? [[String: Any]])
        XCTAssertEqual(cards.map { $0["key"] as? String }, ["LOC-1"])

        result = store.perform(tool: "board_read", arguments: ["column": "Done", "include_done": false], author: atlas)
        cards = try XCTUnwrap(result["cards"] as? [[String: Any]])
        XCTAssertEqual(cards.map { $0["key"] as? String }, ["LOC-3"], "an explicit column wins")
        XCTAssertEqual((result["columns"] as? [[String: Any]])?.count, 1)

        for query in ["DOCS", "loc-2"] {
            result = store.perform(tool: "board_read", arguments: ["query": query], author: atlas)
            cards = try XCTUnwrap(result["cards"] as? [[String: Any]])
            XCTAssertEqual(cards.map { $0["key"] as? String }, ["LOC-2"], query)
        }
        result = store.perform(tool: "board_read", arguments: ["query": "WORD word"], author: atlas)
        XCTAssertEqual((result["cards"] as? [[String: Any]])?.count, 1, "query searches descriptions")

        result = store.perform(tool: "board_read", arguments: ["card_id": "1"], author: atlas)
        text = try XCTUnwrap(result["text"] as? String)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(5)), [
            "LOC-1 “Fix login”", "Column: In Progress [in-progress]", "Priority: high",
            "Labels: bug, auth", "Assignee: Atlas",
        ])
        XCTAssertTrue(lines[5].hasPrefix("Created: ") && lines[5].hasSuffix(" by “You” (user)"), lines[5])
        XCTAssertTrue(lines[6].hasPrefix("Updated: ") && lines[6].hasSuffix(" by “Atlas” (agent)"), lines[6])
        let quotedDetails = login.details.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Description:\n" + quotedDetails + "\n\nTimeline (3 entries, oldest first):\n"), text)
        XCTAssertTrue(text.contains(" · “You” (user) · activity: Created in In Progress\n"), text)
        XCTAssertTrue(text.contains(" · “You” (user) · comment:\n  > Please look.\n  > It fails on SSO.\n"), text)
        XCTAssertTrue(text.hasSuffix(" · “Atlas” (agent) · comment:\n  > Found it."), text)
        XCTAssertFalse(text.contains("omitted"), "a small card is shown whole")
        let detail = try XCTUnwrap((result["cards"] as? [[String: Any]])?.first)
        XCTAssertEqual(detail["description"] as? String, login.details)
        let timeline = try XCTUnwrap(detail["timeline"] as? [[String: Any]])
        XCTAssertEqual(timeline.map { $0["kind"] as? String }, ["activity", "comment", "comment"])
        XCTAssertEqual(timeline.map { ($0["author"] as? [String: Any])?["name"] as? String }, ["You", "You", "Atlas"])
    }

    func testBoardReadListsAtMostTwoHundredCards() throws {
        let (store, _, _) = try makeStore()
        try writeDocument(for: store, cardCount: 250)
        let result = store.perform(tool: "board_read", arguments: [:], author: atlas)
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertEqual((result["cards"] as? [[String: Any]])?.count, BoardStore.maximumListedCards)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertTrue(text.contains("## To Do [todo] · 250 cards"))
        XCTAssertTrue(text.contains("- LOC-200 “Card 200”"))
        XCTAssertFalse(text.contains("LOC-201"))
        // The notice sits up top, where a reply cut short still carries it.
        XCTAssertEqual(
            text.components(separatedBy: "\n")[1],
            "Showing the first 200 of 250 matching cards. Narrow the list with column, assignee, or query."
        )
        XCTAssertTrue(text.contains("- LOC-200 “Card 200” · unassigned · updated 2027-01-15T08:00:00Z\n(50 more not listed)\n"), text)
        XCTAssertTrue(text.hasSuffix("## Done [done] · 0 cards\nNo cards."), text)
    }

    func testChatPromptHandsTheCardToTheComposer() throws {
        let (store, _, _) = try makeStore()
        let bare = try store.createCard(title: "Bare")
        let full = try store.createCard(title: "Full", details: "Do the thing.")
        XCTAssertEqual(
            store.chatPrompt(for: bare),
            "Work on board card LOC-1: Bare\n\n"
                + "When you make progress, update the card with board_update_card / board_comment."
        )
        XCTAssertEqual(
            store.chatPrompt(for: full),
            "Work on board card LOC-2: Full\n\nDo the thing.\n\n"
                + "When you make progress, update the card with board_update_card / board_comment."
        )
    }
}
