import Combine
import XCTest

@testable import Locus

@MainActor
final class ProviderAccountsModelTests: XCTestCase {
    private var toasts: [String] = []
    private var deactivatedAccountIDs: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
        toasts = []
        deactivatedAccountIDs = []
    }

    private func makeModel(persistenceEnabled: Bool = true) -> ProviderAccountsModel {
        let model = ProviderAccountsModel(credentialStore: InMemoryCredentialStore())
        model.configure(
            backend: stubbedBackendService(),
            persistenceEnabled: persistenceEnabled,
            localModelHidden: { $0 == "hidden-model" },
            routedModelsProvider: { _ in [] },
            activeAccountProvider: { nil },
            accountRoutingDeactivated: { [weak self] id in
                self?.deactivatedAccountIDs.append(id)
            },
            toastHandler: { [weak self] in self?.toasts.append($0) }
        )
        return model
    }

    func testConstructionAndConfigureAreInert() {
        _ = makeModel()
        XCTAssertNoBackendTraffic()
    }

    func testVisibleLocalModelsHonorsTheHiddenList() {
        let model = makeModel()
        let visible = model.visibleLocalModels(in: [
            ModelInfo(name: "hidden-model", size: 0, parameterSize: "", contextLength: 0),
            ModelInfo(name: "llama3", size: 0, parameterSize: "", contextLength: 0),
        ])
        XCTAssertEqual(visible.map(\.name), ["llama3"])
    }

    func testChatGPTAccountRefreshMapsStatusAndFetchesUsage() async throws {
        let account = ProviderAccount(kind: .chatGPT, name: "Plan")
        BackendStub.respond(toPath: "/api/chatgpt/account") { _ in
            [
                "status": "signed_in", "runtime_available": true,
                "email": "user@example.com", "plan_type": "pro",
            ]
        }
        BackendStub.respond(toPath: "/api/chatgpt/usage") { _ in ["unparseable": true] }
        let model = makeModel()
        model.providerAccounts = [account]
        await model.refreshChatGPTAccount(for: account)
        XCTAssertEqual(
            model.accountStatus[account.id],
            .signedIn(email: "user@example.com", plan: "pro")
        )
        XCTAssertTrue(BackendStub.requestPaths.contains("/api/chatgpt/usage"))
    }

    func testNewUnsavedPlanCanRefreshSignInAndUsageWithoutSavingAccount() async {
        for kind in [ProviderKind.chatGPT, .claudePlan] {
            BackendStub.reset()
            let account = ProviderAccount(kind: kind, name: "New plan")
            registerManagedAccount(account, models: [kind == .chatGPT ? "gpt-5.6-sol" : "opus[1m]"], usage: { _ in
                ["status": "signed_in", "rate_limits": [:], "activity": [:]] as [String: Any]
            })
            let model = makeModel()

            await model.refreshChatGPTAccount(for: account)
            XCTAssertNoBackendTraffic()
            await model.refreshChatGPTAccount(for: account, allowUnsavedAccount: true)

            XCTAssertEqual(model.chatGPTAccounts[account.id]?.status, "signed_in")
            XCTAssertEqual(model.chatGPTUsageByAccount[account.id]?.status, "signed_in")
            XCTAssertTrue(model.accountStatus[account.id]?.isHealthy == true)
            XCTAssertTrue(model.providerAccounts.isEmpty, "A status refresh must not save the draft account")
            XCTAssertEqual(BackendStub.requestPaths, [kind.managedAPIPath + "/account", kind.managedAPIPath + "/usage"])
        }
    }

    func testDraftPermissionDoesNotKeepARemovedSavedAccountAlive() async {
        let account = ProviderAccount(kind: .chatGPT)
        let received = expectation(description: "Account requested")
        let release = DispatchSemaphore(value: 0)
        BackendStub.respond(toPath: "/api/chatgpt/account") { _ in
            received.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return ["status": "signed_in", "runtime_available": true]
        }
        let model = makeModel()
        model.providerAccounts = [account]
        let request = Task { await model.refreshChatGPTAccount(for: account, allowUnsavedAccount: true) }
        await fulfillment(of: [received], timeout: 3)
        model.providerAccounts = []
        model.forgetAccountCatalog(account.id)
        release.signal()
        await request.value

        XCTAssertNil(model.chatGPTAccounts[account.id])
        XCTAssertNil(model.accountStatus[account.id])
        XCTAssertFalse(BackendStub.requestPaths.contains("/api/chatgpt/usage"))
    }

    func testSignOutClearsPlanStateAndDeactivatesRouting() async throws {
        let account = ProviderAccount(kind: .chatGPT, name: "Plan")
        BackendStub.respond(toPath: "/api/chatgpt/logout") { _ in
            ["status": "signed_out", "runtime_available": true]
        }
        let model = makeModel()
        model.providerAccounts = [account]
        await model.signOutChatGPT(from: account)
        XCTAssertEqual(model.accountStatus[account.id], .signedOut)
        XCTAssertNil(model.chatGPTUsageByAccount[account.id])
        XCTAssertEqual(deactivatedAccountIDs, [account.id])
    }

    func testIncompleteClaudeCatalogNeverReplacesWorkingSavedModelsWithDefault() async {
        let account = ProviderAccount(kind: .claudePlan)
        BackendStub.respond(toPath: "/api/claude/models") { _ in
            ["status": "signed_in", "catalog_complete": false, "models": [
                ["id": "default", "display_name": "Default", "description": "", "is_default": true]
            ]] as [String: Any]
        }
        BackendStub.respond(toPath: "/api/claude/account") { _ in
            ["status": "signed_in", "runtime_available": true]
        }
        BackendStub.respond(toPath: "/api/claude/usage") { _ in ["status": "signed_in"] }
        let model = makeModel()
        model.providerAccounts = [account]
        model.accountModels[account.id] = ["opus[1m]", "sonnet"]
        await model.refreshAccountCatalogs(force: true)
        XCTAssertEqual(model.accountModels[account.id], ["opus[1m]", "sonnet"])
        XCTAssertTrue(model.accountStatus[account.id]?.isHealthy == true)

        model.accountModels[account.id] = nil
        await model.refreshAccountCatalogs(force: true)
        XCTAssertNil(model.accountModels[account.id], "A fallback is not an authoritative list")
    }

    func testCompleteClaudeCatalogCanReplaceAnOlderList() async {
        let account = ProviderAccount(kind: .claudePlan)
        BackendStub.respond(toPath: "/api/claude/models") { _ in
            ["status": "signed_in", "catalog_complete": true, "models": [
                ["id": "sonnet", "display_name": "Sonnet", "description": "", "is_default": true]
            ]] as [String: Any]
        }
        BackendStub.respond(toPath: "/api/claude/account") { _ in ["status": "signed_in", "runtime_available": true] }
        BackendStub.respond(toPath: "/api/claude/usage") { _ in ["status": "signed_in"] }
        let model = makeModel()
        model.providerAccounts = [account]
        model.accountModels[account.id] = ["old-model"]
        await model.refreshAccountCatalogs(force: true)
        XCTAssertEqual(model.accountModels[account.id], ["sonnet"])
    }

    func testCatalogRefreshSkipsWithoutPersistence() async {
        let model = makeModel(persistenceEnabled: false)
        model.providerAccounts = [ProviderAccount(kind: .chatGPT, name: "Plan")]
        await model.refreshAccountCatalogs(force: true)
        XCTAssertNoBackendTraffic()
    }

    func testChatGPTConnectionUsesSelectedHomeAndKeepsOtherAccountsSeparate() async {
        let account = ProviderAccount(kind: .chatGPT, name: "Work", codexHomeID: "selected-home")
        let other = ProviderAccount(kind: .claudePlan, name: "Other")
        registerManagedAccount(account, models: ["gpt-5.6-sol"])
        let model = makeModel(persistenceEnabled: false)
        model.providerAccounts = [account, other]
        model.accountModels[account.id] = ["gpt-5.3-codex"]
        model.accountModels[other.id] = ["opus[1m]"]

        let result = await model.testConnection(for: account.id, model: "gpt-5.6-sol")

        XCTAssertTrue(result.contains("gpt-5.6-sol is available"), result)
        XCTAssertEqual(model.accountModels[account.id], ["gpt-5.6-sol"])
        XCTAssertEqual(model.accountModels[other.id], ["opus[1m]"])
        XCTAssertTrue(model.hasAuthoritativeModelCatalog(for: account.id))
        XCTAssertTrue(model.accountStatus[account.id]?.isHealthy == true)
        XCTAssertEqual(Set(BackendStub.requestPaths), ["/api/chatgpt/models", "/api/chatgpt/account", "/api/chatgpt/usage"])
        for request in BackendStub.requests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "account_id" })?.value, "selected-home")
        }
    }

    func testClaudeConnectionUsesPlanAuthenticationAndExactAlias() async {
        let account = ProviderAccount(kind: .claudePlan, name: "Claude")
        registerManagedAccount(account, models: ["opus[1m]", "sonnet"])
        let model = makeModel()
        model.providerAccounts = [account]

        let result = await model.testConnection(for: account.id, model: "opus[1m]")

        XCTAssertTrue(result.contains("opus[1m] is available"), result)
        XCTAssertEqual(model.accountModels[account.id], ["opus[1m]", "sonnet"])
        XCTAssertTrue(model.hasAuthoritativeModelCatalog(for: account.id))
        XCTAssertFalse(BackendStub.requestPaths.contains(where: { $0.hasPrefix("/api/chatgpt") }))
        for request in BackendStub.requests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "account_id" })?.value, account.id.uuidString)
        }
    }

    func testIncompleteConnectionCatalogPreservesChoicesWithoutDeclaringModelUnavailable() async {
        let account = ProviderAccount(kind: .chatGPT)
        registerManagedAccount(account, models: ["gpt-5.3-codex"], complete: false)
        let model = makeModel()
        model.providerAccounts = [account]
        model.accountModels[account.id] = ["gpt-5.6-sol"]

        let result = await model.testConnection(for: account.id, model: "gpt-5.6-sol")

        XCTAssertEqual(model.accountModels[account.id], ["gpt-5.6-sol"])
        XCTAssertFalse(model.hasAuthoritativeModelCatalog(for: account.id))
        XCTAssertTrue(result.contains("could not be verified"), result)
        XCTAssertFalse(result.contains("No API key"))
        XCTAssertFalse(result.contains("not in this account"))
    }

    func testCompleteConnectionCatalogReportsAnActuallyMissingModel() async {
        let account = ProviderAccount(kind: .chatGPT)
        registerManagedAccount(account, models: ["gpt-5.6-sol"])
        let model = makeModel()
        model.providerAccounts = [account]

        let result = await model.testConnection(for: account.id, model: "missing-model")

        XCTAssertTrue(result.contains("missing-model was not in this account"), result)
        XCTAssertTrue(model.hasAuthoritativeModelCatalog(for: account.id))
    }

    func testFailedCatalogRefreshPreservesChoicesAndClearsAuthoritativeAbsence() async {
        let account = ProviderAccount(kind: .chatGPT)
        registerManagedAccount(account, models: ["gpt-5.6-sol"])
        let model = makeModel()
        model.providerAccounts = [account]
        await model.refreshAccountCatalogs(force: true)
        XCTAssertTrue(model.hasAuthoritativeModelCatalog(for: account.id))
        BackendStub.reset()
        BackendStub.respond(toPath: "/api/chatgpt/models", status: 503) { _ in ["error": "Runtime unavailable"] }

        _ = await model.testConnection(for: account.id, model: "gpt-5.6-sol")

        XCTAssertEqual(model.accountModels[account.id], ["gpt-5.6-sol"])
        XCTAssertFalse(model.hasAuthoritativeModelCatalog(for: account.id))
        XCTAssertNotEqual(model.accountStatus[account.id], .noKey)
    }

    func testLateManagedCatalogCannotRepopulateRemovedAccount() async {
        let account = ProviderAccount(kind: .chatGPT)
        let received = expectation(description: "Catalog requested")
        let release = DispatchSemaphore(value: 0)
        BackendStub.respond(toPath: "/api/chatgpt/models") { _ in
            received.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return ["status": "signed_in", "models": [
                ["id": "gpt-5.6-sol", "display_name": "Sol", "description": "", "is_default": true]
            ]]
        }
        let model = makeModel()
        model.providerAccounts = [account]
        let request = Task { await model.testConnection(for: account.id, model: "gpt-5.6-sol") }
        await fulfillment(of: [received], timeout: 3)
        model.providerAccounts = []
        model.forgetAccountCatalog(account.id)
        release.signal()
        _ = await request.value

        XCTAssertNil(model.accountModels[account.id])
        XCTAssertNil(model.accountModelCatalogs[account.id])
        XCTAssertNil(model.accountStatus[account.id])
        XCTAssertFalse(model.hasAuthoritativeModelCatalog(for: account.id))
        XCTAssertEqual(BackendStub.requestPaths, ["/api/chatgpt/models"])
    }

    func testRemovingAccountDuringManagedUsageCannotRepopulateItsStatus() async {
        let account = ProviderAccount(kind: .chatGPT)
        let received = expectation(description: "Usage requested")
        let release = DispatchSemaphore(value: 0)
        registerManagedAccount(account, models: ["gpt-5.6-sol"], usage: { _ in
            received.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return [
                "status": "signed_in", "limit_status": "rejected",
                "rate_limits": [:], "activity": [:],
            ] as [String: Any]
        })
        let model = makeModel()
        model.providerAccounts = [account]
        let request = Task { await model.testConnection(for: account.id, model: "gpt-5.6-sol") }
        await fulfillment(of: [received], timeout: 3)
        model.providerAccounts = []
        model.forgetAccountCatalog(account.id)
        release.signal()
        _ = await request.value

        XCTAssertNil(model.accountModels[account.id])
        XCTAssertNil(model.chatGPTUsageByAccount[account.id])
        XCTAssertNil(model.accountStatus[account.id])
        XCTAssertFalse(model.hasAuthoritativeModelCatalog(for: account.id))
    }

    func testInvalidatedManagedUsageCannotOverwriteNewerAccountStatus() async {
        let account = ProviderAccount(kind: .chatGPT)
        let received = expectation(description: "Usage requested")
        let release = DispatchSemaphore(value: 0)
        registerManagedAccount(account, models: ["gpt-5.6-sol"], usage: { _ in
            received.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return [
                "status": "signed_in", "limit_status": "rejected",
                "rate_limits": [:], "activity": [:],
            ] as [String: Any]
        })
        let model = makeModel()
        model.providerAccounts = [account]
        let request = Task { await model.testConnection(for: account.id, model: "gpt-5.6-sol") }
        await fulfillment(of: [received], timeout: 3)
        model.forgetAccountCatalog(account.id)
        model.accountStatus[account.id] = .signedOut
        release.signal()
        _ = await request.value

        XCTAssertEqual(model.accountStatus[account.id], .signedOut)
        XCTAssertNil(model.chatGPTUsageByAccount[account.id])
        XCTAssertFalse(model.hasAuthoritativeModelCatalog(for: account.id))
    }

    func testInvalidatedManagedAccountResponseCannotOverwriteNewerStatus() async {
        let account = ProviderAccount(kind: .chatGPT)
        let received = expectation(description: "Account requested")
        let release = DispatchSemaphore(value: 0)
        BackendStub.respond(toPath: "/api/chatgpt/models") { _ in
            ["status": "signed_in", "models": [
                ["id": "gpt-5.6-sol", "display_name": "Sol", "description": "", "is_default": true]
            ]]
        }
        BackendStub.respond(toPath: "/api/chatgpt/account") { _ in
            received.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return ["status": "signed_in", "runtime_available": true]
        }
        let model = makeModel()
        model.providerAccounts = [account]
        let request = Task { await model.testConnection(for: account.id, model: "gpt-5.6-sol") }
        await fulfillment(of: [received], timeout: 3)
        model.forgetAccountCatalog(account.id)
        model.accountStatus[account.id] = .signedOut
        release.signal()
        _ = await request.value

        XCTAssertEqual(model.accountStatus[account.id], .signedOut)
        XCTAssertNil(model.chatGPTAccounts[account.id])
        XCTAssertFalse(BackendStub.requestPaths.contains("/api/chatgpt/usage"))
    }

    func testFilteredEndpointCatalogDoesNotMakeCuratedFallbackAuthoritative() {
        let account = ProviderAccount(kind: .codex)
        for names in [["dall-e-3"], ["claude-opus-5"], [" "]] {
            let result = ProviderModelCatalog.Result(models: names, status: .connected(models: names.count))
            let scoped = ProviderModelCatalog.scopedModels(for: account, result: result, routedModels: [])

            XCTAssertEqual(scoped, account.kind.curatedModels)
            XCTAssertFalse(result.hasCompleteCatalog(for: account))
        }
        let valid = ProviderModelCatalog.Result(models: ["gpt-5.6-sol"], status: .connected(models: 1))
        XCTAssertTrue(valid.hasCompleteCatalog(for: account))
        let custom = ProviderAccount(kind: .custom)
        XCTAssertTrue(ProviderModelCatalog.Result(models: ["private-model"], status: .connected(models: 1))
            .hasCompleteCatalog(for: custom))
    }

    private func registerManagedAccount(
        _ account: ProviderAccount,
        models: [String],
        complete: Bool = true,
        usage: @escaping (URL) -> Any = { _ in ["status": "signed_in"] }
    ) {
        BackendStub.respond(toPath: account.kind.managedAPIPath + "/models") { _ in
            ["status": "signed_in", "catalog_complete": complete, "models": models.map {
                ["id": $0, "display_name": $0, "description": "", "is_default": false] as [String: Any]
            }] as [String: Any]
        }
        BackendStub.respond(toPath: account.kind.managedAPIPath + "/account") { _ in
            ["status": "signed_in", "runtime_available": true]
        }
        BackendStub.respond(toPath: account.kind.managedAPIPath + "/usage", with: usage)
    }

}

extension ProviderAccountsModelTests {
    func testClaudePlanPreservesAPIAccountAndUsesManagedEndpoints() async throws {
        let api = ProviderAccount(kind: .claude)
        let plan = ProviderAccount(kind: .claudePlan)
        XCTAssertEqual(api.kind.rawValue, "claude")
        XCTAssertEqual(api.kind.marketingName, "Claude API")
        XCTAssertTrue(api.kind.requiresAPIKey)
        XCTAssertEqual(plan.kind.rawValue, "claude_plan")
        XCTAssertFalse(plan.kind.requiresAPIKey)
        XCTAssertFalse(plan.kind.supportsImageGeneration)
        XCTAssertEqual(plan.managedHomeIdentifier, plan.id.uuidString)
        XCTAssertNotEqual(plan.managedHomeIdentifier, ProviderAccount(kind: .claudePlan).managedHomeIdentifier)
        let decoded = try JSONDecoder().decode(ProviderAccount.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded.id, plan.id)
        XCTAssertEqual(decoded.kind, .claudePlan)
        BackendStub.respond(toPath: "/api/claude/account") { request in
            XCTAssertTrue(request.query?.contains(plan.id.uuidString) == true)
            return ["status": "signed_in", "runtime_available": true, "plan_type": "max"]
        }
        BackendStub.respond(toPath: "/api/claude/usage") { _ in
            ["status": "signed_in", "rate_limits": ["rateLimits": [:]], "activity": [:]]
        }
        let model = makeModel()
        model.providerAccounts = [plan]
        await model.refreshChatGPTAccount(for: plan)
        XCTAssertEqual(model.accountStatus[plan.id], .signedIn(email: nil, plan: "max"))
        XCTAssertTrue(BackendStub.requestPaths.contains("/api/claude/usage"))
        XCTAssertFalse(BackendStub.requestPaths.contains("/api/chatgpt/account"))
        XCTAssertNil(model.chatGPTUsageByAccount[plan.id]?.rateLimits.rateLimits?.primary)
    }

    func testClaudePlanHasNoInventedReasoningOrContextDefaults() {
        XCTAssertEqual(ProviderKind.claudePlan.curatedModels, ["default"])
        XCTAssertEqual(ProviderKind.claudePlan.publishedReasoningEfforts(for: "sonnet"), [])
        XCTAssertNil(ProviderKind.claudePlan.publishedContextWindow(for: "sonnet"))
        XCTAssertNil(AccountEditorView.blocker(kind: .claudePlan, resolvedBaseURL: "", keyStored: false, typedKey: ""))
    }
}
