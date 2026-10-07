import XCTest
@testable import Locus

@MainActor
final class CompanionContinuityTests: XCTestCase {
    private let profileID = UUID()
    private var scope: CompanionConversationScope {
        .init(sessionID: "companion", workspace: "/tmp/companion", profileID: profileID)
    }

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
    }

    func testFeatureModelsAreInertAndContextNeedsReview() {
        let context = CompanionContextSharingModel()
        var captures = 0
        context.configure(browserSnapshot: {
            captures += 1
            return CompanionContextSharingModel.textAttachment("Page", name: "Browser")
        }, applicationSnapshot: {
            captures += 1
            return CompanionContextSharingModel.textAttachment("Window", name: "App")
        })
        _ = CompanionCatchUpModel()
        _ = CompanionMemoryNotebookModel()
        context.activate(scope)
        XCTAssertEqual(captures, 0)
        XCTAssertNoBackendTraffic()
        context.previewText("Only this error", name: "Error")
        XCTAssertTrue(context.attachments.isEmpty)
        XCTAssertEqual(context.pending.first?.textContent, "Only this error")
        XCTAssertTrue(context.approvePreview())
        XCTAssertEqual(context.attachments.count, 1)
        XCTAssertTrue(context.pending.isEmpty)
    }

    func testContextClearAndAcceptancePreserveNewerInputs() {
        let model = CompanionContextSharingModel()
        model.activate(scope)
        model.previewText("Old input", name: "Old")
        XCTAssertTrue(model.approvePreview())
        let accepted = Set(model.attachments.map(\.id))
        model.previewText("New input", name: "New")
        XCTAssertTrue(model.approvePreview())
        model.consume(accepted, for: scope)
        XCTAssertEqual(model.attachments.map(\.name), ["New"])
        let replacement = CompanionConversationScope(sessionID: "replacement", workspace: scope.workspace, profileID: profileID)
        model.activate(replacement)
        XCTAssertTrue(model.attachments.isEmpty)
        model.previewText("Replacement input", name: "Replacement")
        XCTAssertTrue(model.approvePreview())
        model.consume(Set(model.attachments.map(\.id)), for: scope)
        XCTAssertEqual(model.attachments.count, 1, "A late acceptance from a cleared chat must not erase new context")
    }

    func testContextRejectsOversizedPayloadWithoutDiscardingReview() {
        let model = CompanionContextSharingModel()
        model.activate(scope)
        model.previewText(String(repeating: "a", count: 450_000), name: "First")
        XCTAssertTrue(model.approvePreview())
        model.previewText(String(repeating: "b", count: 450_000), name: "Second")
        XCTAssertFalse(model.approvePreview())
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertEqual(model.pending.count, 1)
        XCTAssertNotNil(model.notice)
    }

    func testLateCaptureCannotEnterReplacementConversation() async throws {
        let model = CompanionContextSharingModel()
        var finish: CheckedContinuation<ChatAttachment, Error>?
        model.configure(browserSnapshot: {
            try await withCheckedThrowingContinuation { finish = $0 }
        }, applicationSnapshot: { throw CancellationError() })
        model.activate(scope)
        model.previewBrowser()
        for _ in 0..<100 where finish == nil { await Task.yield() }
        XCTAssertNotNil(finish)
        model.activate(.init(sessionID: "replacement", workspace: scope.workspace, profileID: profileID))
        finish?.resume(returning: CompanionContextSharingModel.textAttachment("Old page", name: "Old page"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertFalse(model.isPreparing)
    }

    func testCatchUpNeverPresentsAPlanAsVerifiedImplementation() throws {
        var saved = taskFixture()
        saved["state"] = "planned"
        saved["plan"] = ["title": "Reconnect runtime", "decisions": ["Keep permissions in Locus"]]
        saved["verification"] = ["current_status": "unverified"]
        let task = try JSONDecoder().decode(TaskDetailSnapshot.self, from: JSONSerialization.data(withJSONObject: saved))
        let card = CompanionCatchUpCard.task(task)
        XCTAssertEqual(card.progress, "Saved plan awaiting implementation.")
        XCTAssertEqual(card.decisions, ["Keep permissions in Locus"])
        XCTAssertEqual(card.evidence, "Verification: unverified.")
        XCTAssertFalse(card.canResume)
    }

    func testCatchUpUsesConversationFallbackOnlyWhenTaskDoesNotExist() async {
        stubConversation()
        let model = CompanionCatchUpModel()
        await model.refresh(backend: stubbedBackendService(), scope: scope)
        XCTAssertEqual(model.card?.objective, "Explain this error")
        XCTAssertEqual(model.card?.canResume, false)
        XCTAssertTrue(model.card?.evidence.contains("not been independently verified") == true)
        XCTAssertNil(model.error)
        BackendStub.reset()
        stubConversation()
        BackendStub.respond(toPath: "/api/sessions/companion/task", status: 503) { _ in ["detail": "Unavailable"] }
        await model.refresh(backend: stubbedBackendService(), scope: scope)
        XCTAssertNil(model.card)
        XCTAssertEqual(model.error, "Unavailable")
    }

    func testContinuityAndNotebookRejectWrongCompanionOwner() async {
        stubConversation(owner: UUID())
        let catchUp = CompanionCatchUpModel()
        await catchUp.refresh(backend: stubbedBackendService(), scope: scope)
        XCTAssertNil(catchUp.card)
        XCTAssertNotNil(catchUp.error)
        let notebook = CompanionMemoryNotebookModel()
        await notebook.refresh(backend: stubbedBackendService(), scope: scope)
        XCTAssertFalse(notebook.isAvailable)
        XCTAssertTrue(notebook.memories.isEmpty)
        XCTAssertTrue(BackendStub.requestPaths.allSatisfy { $0 == "/api/sessions/companion" })
    }

    func testNotebookRequestsUseCompanionScopeAndUnavailableVaultFailsClosed() async {
        stubConversation()
        BackendStub.respond(toPath: "/api/memory/status") { _ in
            ["encrypted": true, "cipher": "AES-256-GCM", "approved_count": 0,
             "candidate_count": 0, "candidate_ttl_days": 30, "memory_available": false,
             "storage_error": "Resolve the conflicting memory files before editing."]
        }
        let notebook = CompanionMemoryNotebookModel()
        await notebook.refresh(backend: stubbedBackendService(), scope: scope)
        XCTAssertFalse(notebook.isAvailable)
        XCTAssertEqual(notebook.error, "Resolve the conflicting memory files before editing.")
        XCTAssertFalse(BackendStub.requestPaths.contains("/api/memory"))
        let request = BackendStub.requests.first { $0.url?.path == "/api/memory/status" }
        let query = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "workspace" }?.value, scope.workspace)
        XCTAssertEqual(query.first { $0.name == "agent_id" }?.value, profileID.uuidString)
        let body = CompanionMemoryNotebookModel.memoryBody(scope: scope, title: "Examples", content: "Show examples first", memoryScope: .agent)
        XCTAssertEqual(body["source_session_id"] as? String, "companion")
        XCTAssertEqual(body["scope"] as? String, "agent")
        XCTAssertEqual(body["agent_id"] as? String, profileID.uuidString)
    }

    func testConversationalMemoryProposalPreservesUserMeaningBeforeConfirmation() {
        XCTAssertEqual(CompanionMemoryNotebookModel.proposedMemory(from: " Remember that I prefer examples before explanations "),
                       "I prefer examples before explanations")
        XCTAssertEqual(CompanionMemoryNotebookModel.proposedMemory(from: "Please remember to use short answers"), "to use short answers")
        XCTAssertEqual(CompanionMemoryNotebookModel.proposedMemory(from: "Use examples first"), "Use examples first")
        XCTAssertNoBackendTraffic()
    }

    func testNotebookEditUsesReviewedRevisionAndPreservesMemoryWhenServerRejectsStaleEdit() async throws {
        stubConversation()
        BackendStub.respond(toPath: "/api/memory/status") { _ in
            ["encrypted": false, "cipher": "none", "approved_count": 1,
             "candidate_count": 0, "candidate_ttl_days": 30, "memory_available": true]
        }
        let original: [String: Any] = ["id": "original", "status": "approved", "scope": "agent",
            "title": "Examples", "content": "Use examples first", "tags": [], "pinned": false,
            "stale": false, "created_at": 1, "updated_at": 1, "kind": "preference", "revision": 7]
        BackendStub.respond(toPath: "/api/memory") { _ in ["memories": [original]] }
        BackendStub.respond(toPath: "/api/memory/original", status: 422) { _ in
            ["detail": "The memory changed on this host; reload it before saving your edit."]
        }
        let backend = stubbedBackendService()
        let model = CompanionMemoryNotebookModel()
        await model.refresh(backend: backend, scope: scope)
        let memory = try XCTUnwrap(model.memories.first)
        let saved = await model.save(backend: backend, title: memory.title, content: "Keep explanations short",
                                     memoryScope: .agent, existing: memory, expectedScope: scope)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.memories.first?.content, memory.content)
        XCTAssertTrue(model.error?.contains("reload") == true)
        let request = try XCTUnwrap(BackendStub.requests.first { $0.httpMethod == "PUT" })
        let body = try requestBody(request)
        XCTAssertEqual(body["expected_revision"] as? Int, 7)
        XCTAssertNil(body["revision"])
        XCTAssertEqual(body["agent_id"] as? String, profileID.uuidString)
    }

    func testScopeRestrictionRollsBackIfOriginalCannotBeForgotten() async throws {
        stubConversation()
        BackendStub.respond(toPath: "/api/memory/status") { _ in
            ["encrypted": true, "cipher": "AES-256-GCM", "approved_count": 1,
             "candidate_count": 0, "candidate_ttl_days": 30, "memory_available": true]
        }
        let original: [String: Any] = ["id": "original", "status": "approved", "scope": "personal",
            "title": "Examples", "content": "Use examples first", "tags": [], "pinned": false,
            "stale": false, "created_at": 1, "updated_at": 1, "kind": "preference", "source_session_id": "source", "revision": 7]
        var replacement = original
        replacement["id"] = "replacement"
        replacement["scope"] = "workspace"
        BackendStub.respond(toPath: "/api/memory") { _ in
            if BackendStub.requests.last?.httpMethod == "POST" { return ["ok": true, "memory": replacement] }
            return ["memories": [original]]
        }
        BackendStub.respond(toPath: "/api/memory/original", status: 503) { _ in ["detail": "Busy"] }
        BackendStub.respond(toPath: "/api/memory/replacement") { _ in ["ok": true] }
        let backend = stubbedBackendService()
        let model = CompanionMemoryNotebookModel()
        await model.refresh(backend: backend, scope: scope)
        let memory = try XCTUnwrap(model.memories.first)
        let saved = await model.save(backend: backend, title: memory.title, content: memory.content,
                                     memoryScope: .workspace, existing: memory, expectedScope: scope)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.memories.first?.resolvedScope, .personal)
        XCTAssertTrue(model.error?.contains("original memory was kept") == true, model.error ?? "Missing rollback error")
        let mutations = BackendStub.requests.filter { $0.httpMethod != "GET" }
        XCTAssertEqual(mutations.map { $0.httpMethod ?? "" }, ["POST", "DELETE", "DELETE"])
        XCTAssertEqual(mutations.compactMap { $0.url?.path }, ["/api/memory", "/api/memory/original", "/api/memory/replacement"])
        let body = try requestBody(XCTUnwrap(mutations.first))
        XCTAssertNil(body["expected_revision"], "Creating a replacement must not reuse the original record's revision")
        XCTAssertEqual(body["source_session_id"] as? String, "source")
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

    private func stubConversation(owner: UUID? = nil) {
        let id = owner ?? profileID
        BackendStub.respond(toPath: "/api/sessions/companion") { _ in
            ["id": "companion", "agent_profile_id": id.uuidString, "cwd": "/tmp/companion",
             "preview": "", "messages": [["role": "user", "content": "Explain this error"],
                                              ["role": "assistant", "content": "I will inspect it."]]]
        }
    }

    private func taskFixture() -> [String: Any] {
        ["id": "session:companion", "request": "Reconnect runtime", "state": "completed", "revision": 1,
         "blocker": "", "files": [], "progress": [], "links": [], "restorations": [], "reviews": [], "actions": [],
         "usage": ["known_subtotal": 0, "coverage": "complete", "unknown_entries": 0, "pending_entries": 0,
                   "subscription_entries": 0, "local_entries": 0, "entries": [], "spans": []]]
    }
}
