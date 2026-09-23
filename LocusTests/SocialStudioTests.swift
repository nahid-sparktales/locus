import XCTest
@testable import Locus

@MainActor
final class SocialStudioTests: XCTestCase {
    private func fixture() throws -> (SocialStudioStore, URL, InMemoryConnectorCredentialStore, URLSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SocialStudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root); BackendStub.reset() }
        BackendStub.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BackendStub.self]
        let session = URLSession(configuration: config)
        let credentials = InMemoryConnectorCredentialStore()
        return (SocialStudioStore(workspace: root.path, applicationSupport: root, credentials: credentials, session: session), root, credentials, session)
    }

    private func publication(status: String = "draft", revision: Int = 3) -> [String: Any] {
        ["id": "pub_123", "workspace_id": "ws_123", "title": "Release", "source_text": "Something useful.",
         "status": status, "revision": revision, "renditions": [], "scheduled_at": "2099-01-01T12:00:00Z"]
    }

    private func connect(_ store: SocialStudioStore, workspace: String = "ws_123") throws {
        try store.connect(origin: "https://openpost.example", token: "fixture-secret", workspace: .init(id: workspace, name: "Brand", canEdit: true))
    }

    func testDraftsAndBrandPersistAndProjectsRemainIsolated() throws {
        let (store, root, credentials, session) = try fixture()
        var draft = SocialDraft(); draft.title = "Hello"; draft.text = "Original"; draft.variants["x"] = "Short"; draft.plannedAt = Date()
        XCTAssertTrue(store.save(draft))
        XCTAssertTrue(store.saveBrand(.init(name: "Studio", audience: "Founders", voice: "Plain", topics: "Building")))
        let reopened = SocialStudioStore(workspace: store.workspace, applicationSupport: root, credentials: credentials, session: session)
        XCTAssertEqual(reopened.document, store.document)
        let another = SocialStudioStore(workspace: root.appendingPathComponent("other").path, applicationSupport: root, credentials: credentials)
        XCTAssertTrue(another.document.drafts.isEmpty)
        XCTAssertNotEqual(another.fileURL, store.fileURL)
        XCTAssertNoBackendTraffic()
    }

    func testCorruptStoreIsNeverOverwrittenWithEmptyState() throws {
        let (store, root, credentials, session) = try fixture()
        XCTAssertTrue(store.save(SocialDraft()))
        let corrupt = Data("not json".utf8); try corrupt.write(to: store.fileURL)
        let reopened = SocialStudioStore(workspace: store.workspace, applicationSupport: root, credentials: credentials, session: session)
        XCTAssertNotNil(reopened.error)
        XCTAssertFalse(reopened.save(SocialDraft()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testOriginValidationRejectsCredentialDestinationsAndPublicHTTP() throws {
        for raw in ["http://example.com", "https://user:pass@example.com", "https://example.com/api/v1", "https://example.com?token=x", "file:///tmp/key", "https://example.com#fragment"] {
            XCTAssertThrowsError(try OpenPostClient.validatedOrigin(raw), raw)
        }
        XCTAssertEqual(try OpenPostClient.validatedOrigin("http://localhost:8080/").absoluteString, "http://localhost:8080")
        XCTAssertEqual(try OpenPostClient.validatedOrigin(" https://example.com/ ").absoluteString, "https://example.com")
    }

    func testPayloadUsesChannelVariantsAndCreatesOnlyDraft() throws {
        var draft = SocialDraft(); draft.text = "Source"; draft.title = "Title"; draft.variants["x"] = "Short version"
        draft.plannedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let accounts = [OpenPostAccount(id: "x1", platform: "x", accountUsername: "team", isActive: true),
                        OpenPostAccount(id: "b1", platform: "bluesky", accountUsername: "team", isActive: true)]
        let data = try OpenPostClient.publicationBody(draft: draft, workspaceID: "ws", accounts: accounts)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["content_profile"] as? String, "short_text")
        let renditions = try XCTUnwrap(body["renditions"] as? [[String: String]])
        XCTAssertEqual(renditions.map { $0["body"] }, ["Short version", "Source"])
        XCTAssertNotNil(body["scheduled_at"])
        XCTAssertNil(body["status"])
        XCTAssertThrowsError(try OpenPostClient.publicationBody(draft: SocialDraft(), workspaceID: "ws", accounts: []))
    }

    func testConnectionKeepsSecretOutOfDocument() throws {
        let (store, _, credentials, _) = try fixture()
        try connect(store)
        let connection = try XCTUnwrap(store.document.connection)
        XCTAssertEqual(try credentials.load(for: connection.credentialID)?["token"], "fixture-secret")
        XCTAssertFalse(try String(contentsOf: store.fileURL, encoding: .utf8).contains("fixture-secret"))
        store.disconnect()
        XCTAssertNil(store.document.connection)
        XCTAssertNil(try credentials.load(for: connection.credentialID))
    }

    func testFailedDraftTransferReusesExactEnvelopeAcrossRestart() async throws {
        let (store, root, credentials, session) = try fixture(); try connect(store)
        var draft = SocialDraft(); draft.text = "Keep this exact text"; XCTAssertTrue(store.save(draft))
        BackendStub.respond(toPath: "/api/v1/publications", status: 500) { _ in ["detail": "failure"] }
        await store.sendDraft(draft.id, accountIDs: [])
        XCTAssertNotNil(store.error)
        let first = try XCTUnwrap(BackendStub.requests.first)
        let envelope = try XCTUnwrap(store.document.drafts.first?.handoff)
        XCTAssertFalse(store.save(draft), "Frozen transfers cannot be edited under the same idempotency key")
        let reopened = SocialStudioStore(workspace: store.workspace, applicationSupport: root, credentials: credentials, session: session)
        BackendStub.reset()
        let reply = publication()
        BackendStub.respond(toPath: "/api/v1/publications") { _ in reply }
        await reopened.sendDraft(draft.id, accountIDs: [])
        XCTAssertNil(reopened.error)
        XCTAssertEqual(BackendStub.requests.first?.value(forHTTPHeaderField: "Idempotency-Key"), first.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(reopened.document.drafts.first?.handoff?.body, envelope.body)
        XCTAssertEqual(reopened.document.drafts.first?.handoff?.publicationID, "pub_123")
        XCTAssertEqual(BackendStub.requestPaths, ["/api/v1/publications"], "Sending a draft must never publish or schedule")
    }

    func testTransferCannotCrossOpenPostWorkspace() async throws {
        let (store, _, _, _) = try fixture(); try connect(store)
        var draft = SocialDraft(); draft.text = "Draft"; XCTAssertTrue(store.save(draft))
        BackendStub.respond(toPath: "/api/v1/publications", status: 500) { _ in [:] }
        await store.sendDraft(draft.id, accountIDs: [])
        try connect(store, workspace: "another")
        BackendStub.reset()
        await store.sendDraft(draft.id, accountIDs: [])
        XCTAssertTrue(store.error?.contains("another OpenPost workspace") == true)
        XCTAssertNoBackendTraffic()
    }

    func testFailedValidationPreventsPublication() async throws {
        let (store, _, _, _) = try fixture(); try connect(store)
        BackendStub.respond(toPath: "/api/v1/publications/pub_123/validate") { _ in ["valid": false, "issues": [["message": "Image required", "severity": "error"]]] }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let post = try decoder.decode(OpenPostPublication.self, from: JSONSerialization.data(withJSONObject: publication()))
        await store.perform("publish-now", publication: post)
        XCTAssertEqual(BackendStub.requestPaths, ["/api/v1/publications/pub_123/validate"])
        XCTAssertTrue(store.error?.contains("Image required") == true)
    }

    func testPublishingConflictDoesNotSilentlyApproveNewRevision() async throws {
        let (store, _, _, _) = try fixture(); try connect(store)
        BackendStub.respond(toPath: "/api/v1/publications/pub_123/validate") { _ in ["valid": true, "issues": []] }
        BackendStub.respond(toPath: "/api/v1/publications/pub_123/publish-now", status: 409) { _ in [:] }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let post = try decoder.decode(OpenPostPublication.self, from: JSONSerialization.data(withJSONObject: publication(revision: 3)))
        await store.perform("publish-now", publication: post)
        XCTAssertTrue(store.error?.contains("publication changed") == true)
        XCTAssertEqual(BackendStub.requestPaths.count, 2)
        XCTAssertEqual(BackendStub.requests.last?.value(forHTTPHeaderField: "Idempotency-Key"), "locus-pub_123-3-publish-now")
    }

    func testRefreshReadsRealAccountAndDestinationResults() async throws {
        let (store, _, _, _) = try fixture(); try connect(store)
        BackendStub.respond(toPath: "/api/v1/accounts") { _ in [["id": "a1", "platform": "x", "account_username": "locus", "is_active": true]] }
        var reply = publication(status: "partial")
        reply["scheduled_at"] = "2099-01-01T12:00:00.123Z"
        reply["renditions"] = [["id": "r1", "platform": "x", "status": "failed", "body": "X version", "social_account_id": "a1", "error_message": "Provider refused", "external_url": ""]]
        BackendStub.respond(toPath: "/api/v1/publications") { _ in [reply] }
        await store.refresh()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.accounts.first?.accountUsername, "locus")
        XCTAssertEqual(store.publications.first?.renditions?.first?.errorMessage, "Provider refused")
        XCTAssertEqual(store.publications.first?.renditions?.first?.body, "X version")
        XCTAssertNotNil(store.publications.first?.scheduledDate)
        XCTAssertNotNil(store.lastSynced)
        for request in BackendStub.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
            XCTAssertTrue(request.url?.query?.contains("workspace_id=ws_123") == true)
        }
    }

    func testAcceptedPublicationRemainsPendingUntilProviderReportsSuccess() async throws {
        let (store, _, _, _) = try fixture(); try connect(store)
        BackendStub.respond(toPath: "/api/v1/publications/pub_123/validate") { _ in ["valid": true, "issues": []] }
        BackendStub.respond(toPath: "/api/v1/publications/pub_123/publish-now") { _ in ["message": "Queued", "job_id": "job_1"] }
        let queued = publication(status: "publishing", revision: 4)
        BackendStub.respond(toPath: "/api/v1/publications/pub_123") { _ in queued }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let post = try decoder.decode(OpenPostPublication.self, from: JSONSerialization.data(withJSONObject: publication()))
        await store.perform("publish-now", publication: post)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.publications.first?.status, "publishing")
        XCTAssertTrue(store.notice?.contains("accepted the request") == true)
        XCTAssertEqual(BackendStub.requestPaths, ["/api/v1/publications/pub_123/validate", "/api/v1/publications/pub_123/publish-now", "/api/v1/publications/pub_123"])
    }

    func testRevocationBlocksSavedContentAndNetworkActions() async throws {
        let (store, _, _, _) = try fixture(); try connect(store)
        var draft = SocialDraft(); draft.text = "Draft"; XCTAssertTrue(store.save(draft))
        store.revoke()
        XCTAssertFalse(store.save(draft))
        await store.refresh(); await store.sendDraft(draft.id, accountIDs: [])
        XCTAssertNoBackendTraffic()
    }

    func testNativeScreenCapabilityHasNoWebAgentAccess() {
        let screen = ExtensionPluginScreen(id: "social-studio", title: "Social Studio", entrypoint: "ui/index.html", version: 1, capabilities: ["social.workspace"])
        XCTAssertTrue(screen.isSupported); XCTAssertTrue(screen.isSocialStudio)
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "createAgent"], screen: screen))
        let mixed = ExtensionPluginScreen(id: "social-studio", title: "Social Studio", entrypoint: "ui/index.html", version: 1, capabilities: ["social.workspace", "agents.read"])
        XCTAssertFalse(mixed.isSupported)
    }

    func testResearchPromptIncludesSkillAndBrandWithoutPublishing() {
        let text = SocialAssistantAction.research.prompt(topic: "Local AI", draft: nil,
            brand: .init(name: "Locus", audience: "Builders", voice: "Direct", topics: "Tools"))
        XCTAssertTrue(text.contains("last30days skill")); XCTAssertTrue(text.contains("Local AI"))
        XCTAssertTrue(text.contains("Audience: Builders")); XCTAssertTrue(text.contains("Do not schedule or publish"))
    }
}
