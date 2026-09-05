import Combine
import XCTest

@testable import Locus

@MainActor
final class WorkspaceKnowledgeModelTests: XCTestCase {
    private var toasts: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        toasts = []
    }

    private func makeModel(
        workspace: String = "/tmp/knowledge-tests",
        knowledgePageVisible: Bool = false
    ) -> WorkspaceKnowledgeModel {
        let model = WorkspaceKnowledgeModel()
        model.configure(
            backend: stubbedBackendService(),
            isUITesting: false,
            workspacePathProvider: { workspace },
            sessionAttribution: { ("session-1", "run-1") },
            ollamaHostProvider: { "http://127.0.0.1:11434" },
            knowledgePageVisible: { knowledgePageVisible },
            toastHandler: { [weak self] in self?.toasts.append($0) }
        )
        return model
    }

    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeoutMessage: String
    ) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), timeoutMessage)
    }

    func testConstructionAndConfigureAreInert() {
        _ = makeModel()
        XCTAssertNoBackendTraffic()
    }

    func testWatchSchedulesAnImmediateReindex() async throws {
        BackendStub.respond(toPath: "/api/knowledge/reindex") { _ in ["unparseable": true] }
        let model = makeModel()
        model.watchWorkspaceKnowledge("/tmp/knowledge-tests")
        try await waitUntil(
            BackendStub.requestPaths.contains("/api/knowledge/reindex"),
            timeoutMessage: "reindex was never posted"
        )
        // A decode failure is deliberately swallowed: watcher noise must never
        // surface to the user or interrupt workspace switching.
        XCTAssertEqual(toasts, [])
        model.cancelAll()
    }

    func testRefreshFansOutToAllSevenKnowledgeEndpoints() async throws {
        // An error in the first awaited async-let cancels its siblings, whose
        // URLProtocol requests might not have started yet. Make every earlier
        // response valid and fail only the last awaited endpoint, so returning
        // from refresh proves all seven requests completed without a timing wait.
        BackendStub.respond(toPath: "/api/knowledge/status") { _ in
            [
                "workspace": "/tmp/knowledge-tests",
                "enabled": true,
                "embedding_model": "fixture-embedding",
                "ollama_host": "http://127.0.0.1:11434",
                "vector_generation": 0,
                "document_count": 0,
                "chunk_count": 0,
                "memory_count": 0,
                "vector_available": false,
                "vector_backend": "fixture",
            ]
        }
        BackendStub.respond(toPath: "/api/memory") { _ in ["memories": []] }
        BackendStub.respond(toPath: "/api/memory/status") { _ in
            [
                "encrypted": true,
                "cipher": "fixture",
                "approved_count": 0,
                "candidate_count": 0,
                "candidate_ttl_days": 30,
            ]
        }
        BackendStub.respond(toPath: "/api/memory/diagnostics") { _ in
            [
                "approved_count": 0,
                "candidate_count": 0,
                "indexed_files": 0,
                "search_chunks": 0,
                "embedding_model": "fixture-embedding",
                "embedding_error": "",
                "history_available": false,
                "events": [],
                "counts": [:],
            ]
        }
        BackendStub.respond(toPath: "/api/context-snapshots") { _ in ["snapshots": []] }
        // /api/skill-observations remains an intentional 404.
        let model = makeModel()
        await model.refreshWorkspaceKnowledge()
        let paths = Set(BackendStub.requestPaths)
        XCTAssertEqual(paths, [
            "/api/knowledge/status",
            "/api/memory",
            "/api/memory/status",
            "/api/memory/diagnostics",
            "/api/context-snapshots",
            "/api/skill-observations",
        ])
        XCTAssertEqual(BackendStub.requestPaths.filter { $0 == "/api/memory" }.count, 2)
        XCTAssertEqual(toasts.count, 1, "the failed final endpoint must surface one load failure toast")
    }

    func testDeleteSkillObservationSendsWorkspaceScopedDelete() async throws {
        BackendStub.respond(whenPathHasPrefix: "/api/skill-observations/") { _ in ["ok": true] }
        let model = makeModel()
        let observation = SkillObservation(
            id: "obs-1",
            number: 1,
            status: "OPEN",
            title: "t",
            sessionContext: "ctx",
            skill: "s",
            type: "open-source",
            phaseArea: "area",
            issue: "issue",
            suggestedImprovement: "improve",
            principle: "principle",
            checkpointOnly: false,
            sourceSessionID: "session-1",
            sourceRunID: "run-1",
            createdAt: 1,
            updatedAt: 1
        )
        model.deleteSkillObservation(observation)
        try await waitUntil(
            BackendStub.requests.isEmpty == false,
            timeoutMessage: "delete was never sent"
        )
        let request = BackendStub.requests[0]
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/skill-observations/obs-1")
        XCTAssertTrue(request.url?.query?.contains("workspace=") ?? false)
    }

}
