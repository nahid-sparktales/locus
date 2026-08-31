import Combine
import XCTest

@testable import Locus

@MainActor
final class TranscriptSearchModelTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
    }

    private func makeModel() -> TranscriptSearchModel {
        let model = TranscriptSearchModel()
        model.configure(backend: stubbedBackendService())
        return model
    }

    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeoutMessage: String
    ) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), timeoutMessage)
    }

    func testConstructionAndConfigureAreInert() {
        _ = makeModel()
        XCTAssertNoBackendTraffic()
    }

    func testShortQueriesClearWithoutSearching() {
        let model = makeModel()
        model.transcriptHits = [TranscriptSearchHit](
        )
        model.scheduleHitSearch(query: "a")
        XCTAssertEqual(model.transcriptHits, [])
        XCTAssertFalse(model.isSearchingTranscripts)
        XCTAssertNoBackendTraffic()
    }

    func testDebouncedSearchDeliversHitsAndIndexingFlag() async throws {
        BackendStub.respond(toPath: "/api/sessions/search") { _ in
            ["query": "stock checker", "results": [], "indexing": true]
        }
        let model = makeModel()
        model.scheduleHitSearch(query: "stock checker")
        XCTAssertTrue(model.isSearchingTranscripts)
        try await waitUntil(
            model.isSearchingTranscripts == false,
            timeoutMessage: "search never completed"
        )
        XCTAssertTrue(model.transcriptSearchIndexing)
        XCTAssertEqual(BackendStub.requestPaths, ["/api/sessions/search"])
    }

    func testRapidRetypingCoalescesIntoOneRequest() async throws {
        BackendStub.respond(toPath: "/api/sessions/search") { _ in
            ["query": "second query", "results": [], "indexing": false]
        }
        let model = makeModel()
        model.scheduleHitSearch(query: "first query")
        model.scheduleHitSearch(query: "second query")
        try await waitUntil(
            model.isSearchingTranscripts == false,
            timeoutMessage: "search never completed"
        )
        XCTAssertEqual(BackendStub.requestPaths.count, 1)
        XCTAssertTrue(BackendStub.requests[0].url?.query?.contains("second") ?? false)
    }

    func testAppModelRepublishesSearchChanges() async throws {
        let app = AppModel(startImmediately: false)
        let republished = expectation(description: "AppModel.objectWillChange fired")
        republished.assertForOverFulfill = false
        let cancellable = app.objectWillChange.sink { _ in republished.fulfill() }
        app.transcriptSearch.transcriptHits = []
        await fulfillment(of: [republished], timeout: 1.0)
        cancellable.cancel()
    }
}
