import Foundation
import XCTest
@testable import Locus

final class OutputsLibraryTests: XCTestCase {
    private func fixture() throws -> (URL, URL, OutputsLibraryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locus-library-test-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (root, workspace, OutputsLibraryStore(directory: root.appendingPathComponent("library")))
    }

    func testVersionsRemainImmutableAfterOverwriteAndOriginalRemoval() async throws {
        let (root, workspace, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = workspace.appendingPathComponent("report.md")
        try Data("First report".utf8).write(to: source)
        let first = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "chat", runID: "first"))!
        try Data("Second report".utf8).write(to: source, options: .atomic)
        let second = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "chat", runID: "second"))!
        XCTAssertEqual(second.versions.count, 2)
        XCTAssertNotEqual(first.latest?.hash, second.latest?.hash)
        try FileManager.default.removeItem(at: source)
        let firstURL = await store.versionURL(first, version: first.latest!)!
        XCTAssertEqual(try String(contentsOf: firstURL), "First report")
        let secondURL = await store.versionURL(second, version: second.latest!)!
        XCTAssertEqual(try String(contentsOf: secondURL), "Second report")
        let restored = OutputsLibraryStore(directory: root.appendingPathComponent("library"))
        let list = try await restored.list(workspace: workspace.path)
        XCTAssertEqual(list.first?.versions.count, 2)
    }

    func testDuplicateReportsDeduplicateBytesAndKeepExactOriginEvidence() async throws {
        let (root, workspace, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Same report".utf8).write(to: workspace.appendingPathComponent("report.md"))
        _ = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "", runID: nil))
        let attributed = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "chat1", runID: "run1"))!
        XCTAssertEqual(attributed.versions.count, 1)
        XCTAssertTrue(attributed.latest!.belongsTo(sessionID: "chat1", runID: "run1"))
        let repeated = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "chat2", runID: "run2"))!
        XCTAssertEqual(repeated.versions.count, 1)
        XCTAssertTrue(repeated.latest!.belongsTo(sessionID: "chat2", runID: "run2"))
        XCTAssertFalse(repeated.latest!.belongsTo(sessionID: "chat1", runID: "run2"))
    }

    func testStorageLimitAndMissingFilesDoNotDestroySavedHistory() async throws {
        let (root, workspace, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = workspace.appendingPathComponent("report.md")
        try Data("Saved content".utf8).write(to: source)
        _ = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "chat", runID: "1"))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(OutputsLibraryStore.fileLimit + 1))
        try handle.close()
        let oversized = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "chat", runID: "2"))!
        XCTAssertEqual(oversized.versions.count, 2)
        XCTAssertNotNil(oversized.versions[0].hash)
        XCTAssertNil(oversized.latest?.hash)
        XCTAssertTrue(oversized.latest?.unavailableReason?.contains("100 MB") == true)
        try FileManager.default.removeItem(at: source)
        let missing = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "chat", runID: "3"))!
        XCTAssertNotNil(missing.versions[0].hash)
        XCTAssertTrue(missing.latest?.unavailableReason?.contains("unavailable") == true)
    }

    func testRemovingLibraryHistoryNeverRemovesOriginal() async throws {
        let (root, workspace, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = workspace.appendingPathComponent("report.md")
        try Data("Keep me".utf8).write(to: source)
        let item = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "chat", runID: nil))!
        try await store.remove(item)
        XCTAssertEqual(try String(contentsOf: source), "Keep me")
        let remaining = try await store.list(workspace: workspace.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSymlinkAndTraversalCannotEscapeWorkspace() async throws {
        let (root, workspace, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.txt")
        try Data("External".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("external.txt"), withDestinationURL: outside)
        let symlink = try await store.capture(OutputCapture(workspace: workspace.path, path: "external.txt", sessionID: "chat", runID: nil))
        let traversal = try await store.capture(OutputCapture(workspace: workspace.path, path: "../outside.txt", sessionID: "chat", runID: nil))
        XCTAssertNil(symlink)
        XCTAssertNil(traversal)
    }

    func testImportCollisionsKeepBothFilesAndVisibleFolder() throws {
        let (root, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.pdf")
        try Data("First".utf8).write(to: source)
        let first = try WorkspaceLibraryModel.importCopy(source, workspace: workspace.path)
        try Data("Second".utf8).write(to: source)
        let second = try WorkspaceLibraryModel.importCopy(source, workspace: workspace.path)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "Locus Documents")
        XCTAssertEqual(second.lastPathComponent, "report (2).pdf")
        XCTAssertEqual(try String(contentsOf: first), "First")
        XCTAssertEqual(try String(contentsOf: second), "Second")
    }

    func testDocumentCitationRoundTripPreservesPageHashAndRejectsOtherWorkspace() throws {
        let reference = DocumentReference(workspace: "/tmp/workspace", path: "Locus Documents/report.pdf",
            contentHash: "abc123", location: DocumentLocation(kind: "pdf", page: 4))
        let url = try XCTUnwrap(reference.navigationURL)
        XCTAssertEqual(DocumentReference.fromNavigationURL(url, workspace: "/tmp/workspace"), reference)
        XCTAssertNil(DocumentReference.fromNavigationURL(url, workspace: "/tmp/another"))
    }

    func testBackendCitationSurvivesMarkdownLinkPolicy() throws {
        let (root, workspace, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("A PDF fixture".utf8).write(to: workspace.appendingPathComponent("report.pdf"))
        var components = URLComponents(string: "locus-workspace://open/report.pdf")!
        components.queryItems = [.init(name: "hash", value: "abc123"), .init(name: "locator", value: "{\"kind\":\"pdf\",\"page\":4}")]
        let safe = try XCTUnwrap(MarkdownLinkPolicy.safeURL(components.url!.absoluteString, workspacePath: workspace.path))
        let parsed = WorkspaceArtifactReference.fromNavigationURL(safe, workspacePath: workspace.path)
        XCTAssertEqual(parsed?.documentReference?.contentHash, "abc123")
        XCTAssertEqual(parsed?.documentReference?.location?.page, 4)
    }

    func testSearchDecodesMixedMemoryAndFileResultsWithoutLosingDocuments() throws {
        let raw = """
        [{"id":"memory:1","kind":"memory","snippet":"Remember this"},
         {"id":"file:2","kind":"file","path":"report.pdf","snippet":"A finding","content_hash":"abc",
          "locator":{"kind":"pdf","page":3},"line_start":0,"line_end":0}]
        """
        let hits = try JSONDecoder().decode([DocumentSearchHit].self, from: Data(raw.utf8)).filter { !$0.path.isEmpty }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, "file:2")
        XCTAssertEqual(hits.first?.locator?.page, 3)
    }

    func testBuildOutputsReachClassifierAndTextComparisonShowsChanges() {
        let exclusions = SessionOutputWatcher.exclusionPaths(root: "/workspace")
        XCTAssertFalse(exclusions.contains("/workspace/build"))
        XCTAssertFalse(exclusions.contains("/workspace/dist"))
        XCTAssertFalse(exclusions.contains("/workspace/target"))
        let changes = OutputTextComparison.lines(before: "Heading\nOld\nEnd", after: "Heading\nNew\nEnd")
        XCTAssertEqual(changes, ["  Heading", "− Old", "+ New", "  End"])
    }

    @MainActor
    func testOverlappingRunsDoNotInventFilesystemAttribution() async throws {
        let (root, workspace, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = OutputsLibraryModel(store: store)
        model.configure(emitter: SessionStateEmitter(), enabled: true)
        model.activate(workspace: workspace.path)
        model.beginRun(workspace: workspace.path, sessionID: "chat1", runID: "run1")
        model.beginRun(workspace: workspace.path, sessionID: "chat2", runID: "run2")
        try Data("A report".utf8).write(to: workspace.appendingPathComponent("report.md"))
        model.recordObservedChanges([.init(path: "report.md", effect: .created)], sessionID: "chat1")
        model.recordObservedChanges([.init(path: "report.md", effect: .created)], sessionID: "chat2")
        await model.flush()
        let ambiguous = try await store.list(workspace: workspace.path)
        XCTAssertEqual(ambiguous.first?.latest?.sessionID, "")
        XCTAssertNil(ambiguous.first?.latest?.runID)
        model.recordToolEffects(["file_effects": [["path": "report.md", "effect": "create"]]], workspace: workspace.path, sessionID: "chat2", runID: "run2")
        model.endRun(sessionID: "chat1")
        model.endRun(sessionID: "chat2")
        await model.flush()
        let exact = try await store.list(workspace: workspace.path)
        XCTAssertTrue(exact.first!.latest!.belongsTo(sessionID: "chat2", runID: "run2"))
        XCTAssertFalse(exact.first!.latest!.belongsTo(sessionID: "chat1", runID: "run1"))
    }

    @MainActor
    func testRetryBindsActualRunIdentityAndRejectsStaleAcknowledgmentsAndResults() async throws {
        let (root, workspace, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = OutputsLibraryModel(store: store)
        model.configure(emitter: SessionStateEmitter(), enabled: true)
        model.beginRun(workspace: workspace.path, sessionID: "chat", runID: "old-run")
        model.endRun(sessionID: "chat")
        model.beginRun(workspace: workspace.path, sessionID: "chat")
        XCTAssertFalse(model.bindRunIdentity(workspace: workspace.path, sessionID: "chat", runID: "old-run"))
        XCTAssertFalse(model.bindRunIdentity(workspace: workspace.path, sessionID: "chat", runID: "unseen-stale-run", occurredAt: .distantPast))
        XCTAssertFalse(model.bindRunIdentity(workspace: root.path, sessionID: "chat", runID: "retry-run"))
        let source = workspace.appendingPathComponent("summary.md")
        try Data("A retry output".utf8).write(to: source)
        model.recordObservedChanges([.init(path: "summary.md", effect: .created)], sessionID: "chat")
        XCTAssertTrue(model.bindRunIdentity(workspace: workspace.path, sessionID: "chat", runID: "retry-run", occurredAt: Date()))
        XCTAssertFalse(model.bindRunIdentity(workspace: workspace.path, sessionID: "chat", runID: "other-run", occurredAt: Date()))
        model.recordToolEffects(["run_id": "old-run", "file_effects": [["path": "old-result.md", "effect": "create"]]],
            workspace: workspace.path, sessionID: "chat", runID: "old-run")
        await model.finishCapturesForShutdown()
        let items = try await store.list(workspace: workspace.path)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.target, "summary.md")
        XCTAssertTrue(items.first!.latest!.belongsTo(sessionID: "chat", runID: "retry-run"))
        XCTAssertFalse(items.first!.latest!.belongsTo(sessionID: "chat", runID: "old-run"))
    }

    @MainActor
    func testShutdownFlushesFinalEditBeforeReturning() async throws {
        let (root, workspace, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = OutputsLibraryModel(store: store)
        model.configure(emitter: SessionStateEmitter(), enabled: true)
        let source = workspace.appendingPathComponent("summary.md")
        try Data("First version".utf8).write(to: source)
        model.beginRun(workspace: workspace.path, sessionID: "chat", runID: "run")
        model.recordObservedChanges([.init(path: "summary.md", effect: .created)], sessionID: "chat")
        await model.flush()
        try Data("Final edit".utf8).write(to: source, options: .atomic)
        XCTAssertTrue(model.hasCaptureWork)
        await model.finishCapturesForShutdown()
        let items = try await store.list(workspace: workspace.path)
        XCTAssertEqual(items.first?.versions.count, 2)
        let url = await store.versionURL(items.first!, version: items.first!.latest!)!
        XCTAssertEqual(try String(contentsOf: url), "Final edit")
    }

    @MainActor
    func testDocumentSearchRefreshesCatalogAndScopesPaginationToQuery() async throws {
        BackendStub.reset()
        defer { BackendStub.reset() }
        BackendStub.respond(toPath: "/api/knowledge/status") { _ in
            ["enabled": true, "documents_enabled": true]
        }
        BackendStub.respond(toPath: "/api/documents") { url in
            let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = parameters.first { $0.name == "query" }?.value ?? ""
            let offset = Int(parameters.first { $0.name == "offset" }?.value ?? "0") ?? 0
            let count = query.isEmpty ? 205 : query == "older" ? 102 : 0
            let rows: [[String: Any]] = (min(offset, count)..<min(offset + 100, count)).map { index in
                let name = "\(query.isEmpty ? "new" : query)-\(index).pdf"
                return ["id": name, "path": name, "title": name, "format": "pdf",
                        "status": "failed", "warnings": [], "truncated": false, "excluded": false,
                        "segment_count": 0, "updated_at": 1, "size": 100]
            }
            return ["documents": rows, "total": count]
        }
        BackendStub.respond(toPath: "/api/knowledge/search") { _ in
            ["results": [["path": "content-only.pdf", "snippet": "A matching phrase", "line_start": 1]]]
        }
        let model = WorkspaceLibraryModel()
        model.configure(backend: stubbedBackendService())
        model.activate(workspace: "/tmp/library-catalog-search")
        for _ in 0..<100 where model.total != 205 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.documents.count, 100)
        model.query = "older"
        model.search()
        for _ in 0..<150 where model.total != 102 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.total, 102)
        XCTAssertTrue(model.documents.allSatisfy { $0.path.hasPrefix("older-") })
        await model.refresh(loadMore: true)
        XCTAssertEqual(model.documents.count, 102)
        XCTAssertEqual(Set(model.documents.map(\.id)).count, 102)
        model.query = "content phrase"
        model.search()
        for _ in 0..<150 where model.total != 0 || model.searchResults.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.total, 0)
        XCTAssertTrue(model.documents.isEmpty)
        XCTAssertEqual(model.searchResults.first?.path, "content-only.pdf")
        model.query = ""
        model.search()
        for _ in 0..<100 where model.total != 205 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.documents.count, 100)
        XCTAssertTrue(model.searchResults.isEmpty)
        let queries = BackendStub.requests.compactMap(\.url).filter { $0.path == "/api/documents" }
            .compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        XCTAssertTrue(queries.contains { parameters in
            parameters.contains(.init(name: "query", value: "older"))
                && parameters.contains(.init(name: "offset", value: "100"))
        })
    }
}
