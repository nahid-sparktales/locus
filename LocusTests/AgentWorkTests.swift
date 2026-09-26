import XCTest
@testable import Locus

@MainActor
final class AgentWorkTests: XCTestCase {
    private func setup() throws -> (URL, BoardStore, AgentWorkLedger) {
        BackendStub.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentWorkTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let board = BoardStore.testingStore(workspacePath: root.path, applicationSupport: root)
        let ledger = AgentWorkLedger(root: root, boardProvider: { _ in board })
        return (root, board, ledger)
    }

    private func run(_ id: String, workspace: String, state: String = "completed", scheduleID: String? = nil, created: Double = 1) throws -> OrchestrationRun {
        var body: [String: Any] = ["id": id, "session_id": "session-1", "workspace_root": workspace,
            "state": state, "request": "Task", "created_at": created, "updated_at": created,
            "last_seq": 1, "pinned": false, "legacy": false, "recoverable": false]
        body["schedule_id"] = scheduleID
        return try XCTUnwrap(decode(OrchestrationRun.self, from: body))
    }

    func testRestoringAssignmentsIsInertAndPreservesSourceAndRunIdentity() throws {
        let (root, board, ledger) = try setup()
        let card = try board.createCard(title: "Review website")
        let source = AgentWorkSource.board(card, store: board)
        var record = AgentWorkRecord(sourceID: source.sourceID, kind: source.kind, workspace: board.workspacePath,
            title: source.title, profileID: UUID())
        record.runID = "queued-run"; record.state = "queued"
        try ledger.save(record)
        let restored = AgentWorkLedger(root: root, boardProvider: { _ in board })
        XCTAssertEqual(restored.latest(for: source), record)
        XCTAssertFalse(try XCTUnwrap(restored.latest(for: source)).canStartAgain)
        XCTAssertNil(restored.latest(for: .init(kind: "calendar", sourceID: source.sourceID, workspace: source.workspace, title: "", prompt: "")))
        XCTAssertNoBackendTraffic()
    }

    func testCompletedWorkMovesToReviewAndOnlyExplicitReviewMovesToDone() throws {
        let (_, board, ledger) = try setup()
        let card = try board.createCard(title: "Review website")
        var record = AgentWorkRecord(sourceID: card.id.uuidString, kind: "board", workspace: board.workspacePath,
            title: card.title, profileID: UUID())
        record.runID = "run-1"
        try ledger.save(record)
        ledger.reconcile(runs: [try run("run-1", workspace: board.workspacePath, state: "running")], schedules: [])
        XCTAssertEqual(board.cards.first?.columnID, "in-progress")
        ledger.reconcile(runs: [try run("run-1", workspace: board.workspacePath)], schedules: [])
        XCTAssertEqual(board.cards.first?.columnID, "review")
        XCTAssertEqual(ledger.records.first?.status, "Ready to review")
        try ledger.markReviewed(runID: "run-1")
        XCTAssertEqual(board.cards.first?.columnID, "done")
        XCTAssertEqual(ledger.records.first?.status, "Reviewed")
    }

    func testReconciliationRejectsOtherWorkspaceAndDoesNotSubstituteOlderScheduleRun() throws {
        let (_, board, ledger) = try setup()
        var record = AgentWorkRecord(sourceID: "event", kind: "calendar", workspace: board.workspacePath,
            title: "Research", profileID: UUID())
        record.runID = "new"; record.scheduleID = "schedule"; record.state = "queued"
        try ledger.save(record)
        ledger.reconcile(runs: [try run("new", workspace: "/wrong"),
            try run("old", workspace: board.workspacePath, scheduleID: "schedule")], schedules: [])
        XCTAssertEqual(ledger.records.first?.state, "queued")
        XCTAssertEqual(ledger.records.first?.runID, "new")
        ledger.reconcile(runs: [try run("old", workspace: board.workspacePath, scheduleID: "schedule"),
            try run("new", workspace: board.workspacePath, state: "failed", scheduleID: "schedule")], schedules: [])
        XCTAssertEqual(ledger.records.first?.runID, "new")
        XCTAssertEqual(ledger.records.first?.state, "failed")
        XCTAssertTrue(try XCTUnwrap(ledger.records.first).canStartAgain)
    }

    func testScheduleRecoveryMatchesNewestOccurrenceOnlyInItsWorkspace() throws {
        let (_, board, ledger) = try setup()
        var record = AgentWorkRecord(sourceID: "event", kind: "calendar", workspace: board.workspacePath,
            title: "Research", profileID: UUID())
        record.scheduleID = "schedule"; record.state = "uncertain"
        try ledger.save(record)
        ledger.reconcile(runs: [try run("other", workspace: "/other", scheduleID: "schedule", created: 100),
            try run("old", workspace: board.workspacePath, scheduleID: "schedule"),
            try run("new", workspace: board.workspacePath, scheduleID: "schedule", created: 2)], schedules: [])
        XCTAssertEqual(ledger.records.first?.runID, "new")
        XCTAssertEqual(ledger.records.first?.state, "completed")
    }

    func testCorruptLedgerIsPreservedAndRefusesNewDispatchRecords() throws {
        let (root, board, _) = try setup()
        let file = root.appendingPathComponent(AppEdition.current.displayName).appendingPathComponent("Agent Work/assignments.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("{broken".utf8); try damaged.write(to: file)
        let ledger = AgentWorkLedger(root: root, boardProvider: { _ in board })
        XCTAssertNotNil(ledger.error)
        XCTAssertThrowsError(try ledger.save(.init(sourceID: "x", kind: "board", workspace: board.workspacePath, title: "Task", profileID: UUID())))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        XCTAssertNoBackendTraffic()
    }

    func testAnOlderReviewedAssignmentCannotCompleteNewerWork() throws {
        let (_, board, ledger) = try setup()
        let card = try board.createCard(title: "Build")
        var older = AgentWorkRecord(sourceID: card.id.uuidString, kind: "board", workspace: board.workspacePath,
            title: card.title, profileID: UUID())
        older.runID = "old"; older.state = "completed"; older.reviewed = true
        try ledger.save(older)
        var newer = AgentWorkRecord(sourceID: card.id.uuidString, kind: "board", workspace: board.workspacePath,
            title: card.title, profileID: older.profileID)
        newer.runID = "new"; newer.state = "running"
        try ledger.save(newer)
        ledger.reconcile(runs: [], schedules: [])
        XCTAssertEqual(board.cards.first?.columnID, "in-progress")
        ledger.reconcile(runs: [], schedules: [])
        XCTAssertEqual(board.cards.first?.columnID, "in-progress")
    }

    func testExternalRecurringOccurrencesGetDistinctAssignments() {
        let first = LocusCalendarEntry(id: "external", title: "Weekly", startDate: Date(timeIntervalSince1970: 10),
            endDate: Date(timeIntervalSince1970: 20), calendarID: "external-calendar")
        var second = first; second.startDate = Date(timeIntervalSince1970: 100)
        XCTAssertNotEqual(AgentWorkSource.calendar(first, workspace: "/tmp").id, AgentWorkSource.calendar(second, workspace: "/tmp").id)
        var local = first; local.calendarID = "locus"
        let initial = AgentWorkSource.calendar(local, workspace: "/tmp")
        local.startDate = second.startDate
        XCTAssertEqual(initial.id, AgentWorkSource.calendar(local, workspace: "/tmp").id)
    }
}
