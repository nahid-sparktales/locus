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

    func testRefreshFansOutToKnowledgeAndStorageEndpoints() async throws {
        // An error in the first awaited async-let cancels its siblings, whose
        // URLProtocol requests might not have started yet. Make every earlier
        // response valid and fail only the last awaited endpoint, so returning
        // from refresh proves all requests completed without a timing wait.
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
        BackendStub.respond(toPath: "/api/memory/storage") { _ in
            ["format": "markdown", "root": "/host/memory", "files": [["path": "/host/memory/USER.md", "scope": "personal", "status": "approved"]]]
        }
        // /api/skill-observations remains an intentional 404.
        let model = makeModel()
        await model.refreshWorkspaceKnowledge()
        let paths = Set(BackendStub.requestPaths)
        XCTAssertEqual(paths, [
            "/api/knowledge/status",
            "/api/memory",
            "/api/memory/status",
            "/api/memory/diagnostics",
            "/api/memory/storage",
            "/api/context-snapshots",
            "/api/skill-observations",
        ])
        XCTAssertEqual(BackendStub.requestPaths.filter { $0 == "/api/memory" }.count, 2)
        XCTAssertEqual(toasts.count, 1, "the failed final endpoint must surface one load failure toast")
        XCTAssertEqual(model.memoryStorage?.files.first?.path, "/host/memory/USER.md")
        XCTAssertEqual(model.memoryStorage?.usesMarkdown, true)
    }

    func testConsolidationScopesItsRequestAndReleasesBusyStateAfterFailure() async throws {
        BackendStub.respond(toPath: "/api/memory/consolidate", status: 409) { _ in ["error": "changed"] }
        let model = makeModel()
        model.consolidateMemory(agentID: "specialist")
        XCTAssertTrue(model.isMemoryMaintenanceRunning)
        model.checkMemorySources(agentID: "specialist")
        try await waitUntil(!model.isMemoryMaintenanceRunning, timeoutMessage: "consolidation never finished")

        let request = try XCTUnwrap(BackendStub.requests.first)
        XCTAssertEqual(request.url?.path, "/api/memory/consolidate")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try requestBody(request)
        XCTAssertEqual(body["workspace"] as? String, "/tmp/knowledge-tests")
        XCTAssertEqual(body["agent_id"] as? String, "specialist")
        XCTAssertFalse(BackendStub.requestPaths.contains("/api/memory/check-sources"))
        XCTAssertTrue(toasts.contains { $0.contains("Could not consolidate memory") })
    }

    func testSourceCheckCallsTheDedicatedEndpoint() async throws {
        BackendStub.respond(toPath: "/api/memory/check-sources", status: 409) { _ in ["error": "changed"] }
        let model = makeModel()
        model.checkMemorySources(agentID: "primary")
        try await waitUntil(!model.isMemoryMaintenanceRunning, timeoutMessage: "source check never finished")
        let request = try XCTUnwrap(BackendStub.requests.first)
        XCTAssertEqual(request.url?.path, "/api/memory/check-sources")
        XCTAssertEqual(try requestBody(request)["agent_id"] as? String, "primary")
    }

    func testSourceRefreshCarriesRevisionForConcurrentEditProtection() async throws {
        BackendStub.respond(toPath: "/api/memory/memory-1/refresh-sources", status: 409) { _ in ["error": "revision changed"] }
        let memory = try JSONDecoder().decode(WorkspaceMemory.self, from: Data(#"{"id":"memory-1","title":"Build","content":"Use the build script","tags":[],"pinned":false,"stale":true,"revision":7,"created_at":1,"updated_at":2}"#.utf8))
        let model = makeModel()
        model.refreshMemorySources(memory, agentID: "reviewer")
        try await waitUntil(!model.isMemoryMaintenanceRunning, timeoutMessage: "source refresh never finished")
        let request = try XCTUnwrap(BackendStub.requests.first)
        let body = try requestBody(request)
        XCTAssertEqual(body["expected_revision"] as? Int, 7)
        XCTAssertEqual(body["agent_id"] as? String, "reviewer")
        XCTAssertFalse(BackendStub.requestPaths.contains("/api/memory/memory-1"), "verification must not silently toggle stale through the generic edit route")
    }

    func testMemoryEditCarriesTheDisplayedRevision() async throws {
        BackendStub.respond(toPath: "/api/memory/memory-1", status: 409) { _ in ["error": "revision changed"] }
        let memory = try JSONDecoder().decode(WorkspaceMemory.self, from: Data(#"{"id":"memory-1","title":"Build","content":"Use the build script","tags":[],"pinned":false,"stale":false,"revision":7,"created_at":1,"updated_at":2}"#.utf8))
        let model = makeModel()
        model.updateWorkspaceMemory(memory, agentID: "reviewer")
        try await waitUntil(!toasts.isEmpty, timeoutMessage: "memory edit never finished")
        let request = try XCTUnwrap(BackendStub.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        let body = try requestBody(request)
        XCTAssertEqual(body["expected_revision"] as? Int, 7)
        XCTAssertEqual(body["agent_id"] as? String, "reviewer")
    }

    func testMarkdownStorageConflictKeepsHealthyRestoreProtectionDistinct() throws {
        let status = try JSONDecoder().decode(MemoryVaultStatus.self, from: Data(#"{"encrypted":false,"cipher":"plaintext Markdown; AES-256-GCM history/index","approved_count":0,"candidate_count":0,"candidate_ttl_days":30,"memory_available":false,"counts_available":false,"storage_error":"Both the memory and its Markdown text changed; resolve the conflict before recall.","storage_root":"/remote/memories","restore_protection":{"available":true,"enrolled":true,"state":"protected"}}"#.utf8))
        XCTAssertFalse(try XCTUnwrap(status.memoryAvailable))
        XCTAssertEqual(status.storageError, "Both the memory and its Markdown text changed; resolve the conflict before recall.")
        XCTAssertEqual(status.storageRoot, "/remote/memories")
        XCTAssertEqual(status.restoreProtection?.state, "protected")
    }

    func testSourceRefreshEligibilityExcludesSupersededAndSourceFreeMemories() throws {
        var memory = try JSONDecoder().decode(WorkspaceMemory.self, from: Data(#"{"id":"memory-1","title":"Build","content":"Use the build script","scope":"workspace","kind":"fact","tags":[],"pinned":false,"stale":true,"revision":7,"created_at":1,"updated_at":2,"provenance":{"locus_sources":{"version":1,"files":{"build.sh":{"sha256":"digest","size":12}}}}}"#.utf8))
        XCTAssertTrue(memory.canRefreshSources)
        memory.supersededBy = "survivor"
        XCTAssertFalse(memory.canRefreshSources)
        memory.supersededBy = nil
        memory.provenance = nil
        XCTAssertFalse(memory.canRefreshSources)
    }

    func testSharedMemoryUsesRemoteWorkerScopeInsteadOfLocalOrSuppliedScope() async throws {
        BackendStub.respond(toPath: "/api/runtime/remotes/host-1/request") { _ in ["ok": true] }
        let worker = try JSONDecoder().decode(SharedMemoryWorker.self, from: Data(#"{"session_id":"remote-session","workspace":"/srv/project & notes","configuration":{"agent_id":"remote-agent"}}"#.utf8))
        let connection = SharedMemoryConnection(backend: stubbedBackendService(), runtimeID: "host-1")
        let _: [String: Bool] = try await connection.request(
            worker: worker, method: "POST",
            fields: ["title": "Remote fact", "workspace": "/local/workspace", "agent_id": "local-agent"],
            as: [String: Bool].self
        )

        let envelope = try requestBody(XCTUnwrap(BackendStub.requests.first))
        XCTAssertEqual(envelope["method"] as? String, "POST")
        let path = try XCTUnwrap(envelope["path"] as? String)
        let components = try XCTUnwrap(URLComponents(string: path))
        XCTAssertEqual(components.path, "/api/runtime/workers/remote-session/api/memory")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["workspace"], "/srv/project & notes")
        XCTAssertEqual(query["agent_id"], "remote-agent")
        let body = try XCTUnwrap(envelope["body"] as? [String: Any])
        XCTAssertEqual(body["workspace"] as? String, "/srv/project & notes")
        XCTAssertEqual(body["agent_id"] as? String, "remote-agent")
        XCTAssertEqual(body["title"] as? String, "Remote fact")
    }

    func testSharedMemoryDiscoversWorkersThroughTheSelectedHost() async throws {
        BackendStub.respond(toPath: "/api/runtime/remotes/host-2/request") { _ in
            ["workers": [["session_id": "remote-primary", "workspace": "/srv/project", "configuration": ["agent_id": ""]]]]
        }
        let workers = try await SharedMemoryConnection(backend: stubbedBackendService(), runtimeID: "host-2").workers()
        XCTAssertEqual(workers.first?.agentID, "primary")
        let body = try requestBody(XCTUnwrap(BackendStub.requests.first))
        XCTAssertEqual(body["method"] as? String, "GET")
        XCTAssertEqual(body["path"] as? String, "/api/runtime")
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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
