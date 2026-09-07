import XCTest

@testable import Locus

@MainActor
final class TaskCapsuleRoutingTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
    }

    func testIdenticalChatGPTLabelsStillSelectTheSavedAccount() {
        let first = ProviderAccount(kind: .chatGPT, name: "Personal", preferredModel: "same-model")
        let second = ProviderAccount(kind: .chatGPT, name: "Personal", preferredModel: "same-model")
        let selected = AgentProfile(name: "Planner", route: .providerAccount(second.id), model: "same-model")

        XCTAssertEqual(AppModel.capsuleAccount(profile: selected, accounts: [first, second])?.id, second.id)
        XCTAssertEqual(AppModel.capsuleAccount(profile: selected, accounts: [second, first])?.codexHomeIdentifier,
                       second.codexHomeIdentifier)
        XCTAssertNotEqual(first.codexHomeIdentifier, second.codexHomeIdentifier)
    }

    func testMissingAccountNeverFallsBackToTheOnlyOtherPlan() {
        let missing = ProviderAccount(kind: .chatGPT, name: "Same name")
        let replacement = ProviderAccount(kind: .chatGPT, name: "Same name")
        let selected = AgentProfile(name: "Planner", route: .providerAccount(missing.id), model: "exact-model")

        XCTAssertNil(AppModel.capsuleAccount(profile: selected, accounts: [replacement]))
        XCTAssertNil(AppModel.capsuleAccount(profile: selected, accounts: []))
    }

    func testKimiMembershipCannotBeReplacedByKimiAPI() {
        let membership = ProviderAccount(kind: .kimiCode, name: "Coding", preferredModel: "same-model")
        let api = ProviderAccount(kind: .kimi, name: "Coding", preferredModel: "same-model")
        let selected = AgentProfile(name: "Builder", route: .providerAccount(membership.id), model: "same-model")

        let resolved = AppModel.capsuleAccount(profile: selected, accounts: [api, membership])
        XCTAssertEqual(resolved?.kind, .kimiCode)
        XCTAssertEqual(resolved?.resolvedBaseURL, membership.resolvedBaseURL)
        XCTAssertNotEqual(resolved?.credentialAccount, api.credentialAccount)
        XCTAssertNil(AppModel.capsuleAccount(profile: selected, accounts: [api]))
    }

    func testLocalProfileDoesNotAdoptAnAvailablePaidAccount() {
        let selected = AgentProfile(name: "Local builder", route: .localOllama, model: "local-model")
        let paid = ProviderAccount(kind: .codex, preferredModel: "local-model")

        XCTAssertNil(AppModel.capsuleAccount(profile: selected, accounts: [paid]))
    }

    func testOrdinaryDispatchRestoresSelectedChatGPTAccountOnWorkerOnly() async throws {
        registerProviderResponse()
        let control = makeService(port: 9)
        let worker = makeService(port: 10)
        let model = AppModel(startImmediately: false, backendOverride: control)
        let account = ProviderAccount(kind: .chatGPT, name: "Ordinary", preferredModel: "ordinary-model")
        model.providerAccounts = [account]
        model.settings.activeAccountID = account.id.uuidString
        let body = model.providerRequestBody()

        let remainsOverridden = try await model.prepareChatWorkerCapsuleRoute(
            using: worker, capsuleDispatch: nil, restoringOverride: true, ordinaryProviderBody: body
        )

        XCTAssertFalse(remainsOverridden)
        let request = try XCTUnwrap(BackendStub.requests.first)
        XCTAssertEqual(BackendStub.requests.count, 1)
        XCTAssertEqual(request.url?.port, 10)
        let payload = try requestBody(request)
        XCTAssertEqual(payload["provider"] as? String, "chatgpt")
        XCTAssertEqual(payload["account_id"] as? String, account.id.uuidString)
        XCTAssertEqual(payload["codex_home_id"] as? String, account.codexHomeIdentifier)
        XCTAssertEqual(payload["model"] as? String, "ordinary-model")
        XCTAssertNil(payload["api_key"])
        XCTAssertEqual(model.settings.activeAccountID, account.id.uuidString)
    }

    func testLocalRestoreUsesControlModelAndWritesOnlyWorker() async throws {
        registerProviderResponse(model: "ordinary-local-model")
        BackendStub.respond(toPath: "/api/config") { _ in [:] }
        let model = AppModel(startImmediately: false, backendOverride: makeService(port: 9))

        let remainsOverridden = try await model.prepareChatWorkerCapsuleRoute(
            using: makeService(port: 10), capsuleDispatch: nil, restoringOverride: true,
            ordinaryProviderBody: ["provider": "ollama", "context_window": 32_768]
        )

        XCTAssertFalse(remainsOverridden)
        let requests = BackendStub.requests
        XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "POST", "POST"])
        XCTAssertEqual(requests.map { $0.url?.port }, [9, 10, 10])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/provider", "/api/provider", "/api/config"])
        XCTAssertEqual(try requestBody(requests[2])["model"] as? String, "ordinary-local-model")
        XCTAssertNil(model.settings.activeAccountID)
    }

    func testPendingPlannerContinuationKeepsItsSelectedAccount() async throws {
        registerProviderResponse()
        let model = AppModel(startImmediately: false, backendOverride: makeService(port: 9))
        let planner = AgentProfile(name: "Premium planner", model: "premium-model")
        let dispatch = TaskCapsuleDispatch(
            profile: planner, provider: "chatgpt", accountID: "premium-account",
            providerBody: ["provider": "chatgpt", "account_id": "premium-account",
                           "codex_home_id": "premium-home", "model": "premium-model"],
            context: ["stage": "plan"], mode: .plan
        )

        let remainsOverridden = try await model.prepareChatWorkerCapsuleRoute(
            using: makeService(port: 10), capsuleDispatch: dispatch, restoringOverride: true,
            ordinaryProviderBody: ["provider": "ollama"]
        )

        XCTAssertTrue(remainsOverridden)
        XCTAssertEqual(BackendStub.requests.count, 1)
        let request = try XCTUnwrap(BackendStub.requests.first)
        XCTAssertEqual(request.url?.port, 10)
        XCTAssertEqual(try requestBody(request)["codex_home_id"] as? String, "premium-home")
    }

    func testFailedRestoreLeavesOverridePendingAndDoesNotTryAnotherAccount() async {
        BackendStub.respond(toPath: "/api/provider", status: 409) { _ in ["detail": "Sign in again"] }
        let model = AppModel(startImmediately: false, backendOverride: makeService(port: 9))
        var remainsOverridden = true
        do {
            remainsOverridden = try await model.prepareChatWorkerCapsuleRoute(
                using: makeService(port: 10), capsuleDispatch: nil, restoringOverride: remainsOverridden,
                ordinaryProviderBody: ["provider": "chatgpt", "account_id": "selected-account",
                                       "codex_home_id": "selected-home", "model": "ordinary-model"]
            )
            XCTFail("A rejected restore must stop dispatch")
        } catch {
            XCTAssertTrue(remainsOverridden)
        }
        XCTAssertEqual(BackendStub.requestPaths, ["/api/provider"])
    }

    func testOrdinaryWorkerWithoutCapsuleOverrideIsUntouched() async throws {
        let model = AppModel(startImmediately: false, backendOverride: makeService(port: 9))
        let remainsOverridden = try await model.prepareChatWorkerCapsuleRoute(
            using: makeService(port: 10), capsuleDispatch: nil, restoringOverride: false,
            ordinaryProviderBody: ["provider": "ollama"]
        )

        XCTAssertFalse(remainsOverridden)
        XCTAssertNoBackendTraffic()
    }

    func testEveryGenericCapsuleRecoveryOpensTheSavedPlanWithoutChangingWorkspace() async throws {
        BackendStub.respond(toPath: "/api/capsules") { _ in ["capsules": []] }
        let model = AppModel(startImmediately: false, backendOverride: makeService(port: 9))
        let workspace = model.workspacePath
        let capsuleID = UUID().uuidString.lowercased()
        let run = try recoveryRun(teamID: "capsule-\(capsuleID)")
        let attempt = try JSONDecoder().decode(AgentJobAttempt.self, from: JSONSerialization.data(withJSONObject: [
            "run_id": run.id, "job_id": "step-1", "attempt": 1,
            "attempt_id": "attempt-1", "state": "failed", "goal": "Partial work",
        ]))
        let replacement = AgentProfile(name: "Replacement", model: "local-model")
        let actions: [(String, () -> Void)] = [
            ("resume", { model.resumeOrchestration(run) }),
            ("job retry", { model.retryOrchestrationJob(attempt, in: run) }),
            ("branch retry", { model.retryOrchestrationBranch(attempt, in: run) }),
            ("reassign", { model.reassignOrchestrationJob(attempt, in: run, to: replacement) }),
            ("run with Locus", { model.runOrchestrationWithLocus(run) }),
            ("replay", { model.replayOrchestration(run) }),
            ("duplicate", { model.duplicateOrchestration(run) }),
        ]

        for (label, action) in actions {
            model.taskCapsules.isPresented = false
            model.taskCapsules.selectedID = nil
            action()
            XCTAssertTrue(model.taskCapsules.isPresented, label)
            XCTAssertEqual(model.taskCapsules.selectedID, capsuleID, label)
            XCTAssertEqual(model.workspacePath, workspace, label)
            XCTAssertEqual(model.taskCapsules.workspaceRoot, TaskCapsuleModel.canonicalWorkspace(workspace), label)
        }
        await model.taskCapsules.refresh()
        XCTAssertEqual(model.taskCapsules.status,
                       "Review the partial work and ask the planner for an updated plan before running again.")
        XCTAssertTrue(BackendStub.requests.allSatisfy {
            $0.httpMethod == "GET" && $0.url?.path == "/api/capsules"
        })
    }

    func testOrdinaryTeamRecoveryIsNotRedirectedToCapsules() throws {
        let model = AppModel(startImmediately: false, backendOverride: makeService(port: 9))
        XCTAssertFalse(model.redirectCapsuleRecovery(try recoveryRun(teamID: UUID().uuidString)))
        XCTAssertFalse(model.taskCapsules.isPresented)
        XCTAssertNil(model.taskCapsules.selectedID)
        XCTAssertNoBackendTraffic()
    }

    private func recoveryRun(teamID: String) throws -> OrchestrationRun {
        try JSONDecoder().decode(OrchestrationRun.self, from: JSONSerialization.data(withJSONObject: [
            "id": "recovery-run", "team_id": teamID, "workspace_root": "/different/workspace",
            "state": "failed", "request": "Preserve the saved constraints", "created_at": 1,
            "updated_at": 2, "last_seq": 0, "pinned": false, "legacy": false, "recoverable": true,
        ]))
    }

    private func makeService(port: Int) -> BackendService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendStub.self]
        return BackendService(baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                              authToken: "test-token", session: URLSession(configuration: configuration))
    }

    private func registerProviderResponse(model: String = "stub-model") {
        BackendStub.respond(toPath: "/api/provider") { _ in
            ["provider": "ollama", "host": "http://127.0.0.1:11434", "model": model,
             "remote_base_url": "", "remote_model": "", "has_api_key": false]
        }
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
