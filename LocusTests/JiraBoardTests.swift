import XCTest
@testable import Locus

@MainActor
final class JiraBoardTests: XCTestCase {
    private func store() throws -> BoardStore {
        BackendStub.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JiraBoardTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return BoardStore.testingStore(workspacePath: root.path, applicationSupport: root)
    }
    private func issue(_ key: String = "APP-1", title: String = "Original", details: String = "Description") -> JiraIssueLink {
        .init(serverID: "jira", cloudID: "site", siteURL: "https://example.atlassian.net", key: key,
            remoteTitle: title, remoteDetails: details, remoteUpdated: "2026-09-24T12:00:00Z", status: "To Do", statusCategory: "new")
    }
    private func jsonIssue(_ key: String = "APP-1", title: String = "Original") -> [String: Any] {
        ["key": key, "fields": ["summary": title, "description": "Description", "updated": "now",
            "status": ["name": "To Do", "statusCategory": ["key": "new"]]]]
    }

    func testImportIsIdempotentAndPreservesAgentTagsAndTaskProgress() throws {
        let store = try store()
        try store.importJira([issue()])
        let card = try XCTUnwrap(store.cards.first)
        let agent = UUID()
        try store.updateCard(card.id, agentIDs: [agent])
        try store.moveCard(card.id, toColumn: "review")
        try store.importJira([issue(), issue()])
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards.first?.id, card.id)
        XCTAssertEqual(store.cards.first?.agentIDs, [agent])
        XCTAssertEqual(store.cards.first?.columnID, "review")
        store.reload()
        XCTAssertEqual(store.cards.first?.jira?.key, "APP-1")
    }

    func testRemoteChangesMergeWithIndependentLocalEdits() throws {
        let store = try store()
        try store.importJira([issue()])
        let id = try XCTUnwrap(store.cards.first?.id)
        try store.updateCard(id, title: "Local title")
        try store.importJira([issue(details: "Remote details")])
        XCTAssertEqual(store.cards.first?.title, "Local title")
        XCTAssertEqual(store.cards.first?.details, "Remote details")
        XCTAssertEqual(store.cards.first?.jira?.remoteTitle, "Original")
    }

    func testConflictingImportRollsBackWholeBatchAndKeepsLocalChanges() throws {
        let store = try store()
        try store.importJira([issue()])
        let id = try XCTUnwrap(store.cards.first?.id)
        try store.updateCard(id, title: "Local title")
        XCTAssertThrowsError(try store.importJira([issue("APP-2"), issue(title: "Remote title")]))
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards.first?.title, "Local title")
        XCTAssertEqual(store.cards.first?.jira?.remoteTitle, "Original")
        store.reload()
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.cards.first?.title, "Local title")
    }

    func testOversizedIssueDoesNotPartiallyImport() throws {
        let store = try store()
        XCTAssertThrowsError(try store.importJira([issue(), issue("APP-2", title: String(repeating: "x", count: 201))]))
        XCTAssertTrue(store.cards.isEmpty)
    }

    func testJiraRichTextPreservesParagraphsAndOldCardsDecodeWithoutLink() throws {
        let value: JSONValue = .object(["key": .string("APP-1"), "fields": .object([
            "summary": .string("Task"), "updated": .string("now"),
            "description": .object(["type": .string("doc"), "content": .array([
                .object(["type": .string("paragraph"), "content": .array([.object(["text": .string("One")])])]),
                .object(["type": .string("paragraph"), "content": .array([.object(["text": .string("Two")])])])
            ])])])])
        let parsed = try JiraBoardClient.issue(value, serverID: "jira", site: .init(id: "site", name: "Site", url: "https://example.atlassian.net"))
        XCTAssertEqual(parsed.remoteDetails, "One\nTwo")
        let store = try store()
        let card = try store.createCard(title: "Local")
        let data = try JSONEncoder().encode(card)
        XCTAssertNil(try JSONDecoder().decode(BoardCard.self, from: data).jira)
    }

    func testDescriptionWhitespaceSurvivesJiraReadback() throws {
        let value: JSONValue = .object(["key": .string("APP-1"), "fields": .object([
            "summary": .string("Task"), "updated": .string("now"),
            "description": .object(["type": .string("doc"), "content": .array([
                .object(["type": .string("paragraph"), "content": .array([.object(["text": .string("  Detail  ")])])]),
                .object(["type": .string("paragraph"), "content": .array([])])
            ])])])])
        let parsed = try JiraBoardClient.issue(value, serverID: "jira", site: .init(id: "site", name: "Site", url: "https://example.atlassian.net"))
        XCTAssertEqual(parsed.remoteDetails, "  Detail  \n")
    }

    func testSearchRejectsRepeatedPaginationAndMissingContinuation() async throws {
        for next in [true, false] {
            BackendStub.reset()
            BackendStub.respond(toPath: "/api/integrations/jira") { _ in
                var page: [String: Any] = ["issues": [self.jsonIssue()], "isLast": false]
                if next { page["nextPageToken"] = "same-page" }
                return ["data": page]
            }
            let client = JiraBoardClient(backend: stubbedBackendService(), workspace: "/tmp")
            do {
                _ = try await client.search(serverID: "jira", site: .init(id: "site", name: "Site", url: "https://example.atlassian.net"), jql: "project = APP")
                XCTFail("An incomplete sync must fail")
            } catch { XCTAssertTrue(error is JiraBoardError) }
            XCTAssertLessThanOrEqual(BackendStub.requests.count, 2)
        }
    }

    func testPublishingRejectsRemoteConflictBeforeAnyWrite() async throws {
        let store = try store()
        try store.importJira([issue()])
        let id = try XCTUnwrap(store.cards.first?.id)
        try store.updateCard(id, title: "Local title")
        BackendStub.respond(toPath: "/api/integrations/jira") { _ in ["data": self.jsonIssue(title: "Remote change")] }
        let client = JiraBoardClient(backend: stubbedBackendService(), workspace: store.workspacePath)
        do {
            _ = try await client.publish(try XCTUnwrap(store.cards.first))
            XCTFail("Conflicting changes must not be published")
        } catch { XCTAssertTrue(error is JiraBoardError) }
        XCTAssertEqual(BackendStub.requests.count, 1, "Only the preflight read is allowed")
        XCTAssertEqual(store.cards.first?.title, "Local title")
    }
}
