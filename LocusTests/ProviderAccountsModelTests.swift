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
        let model = ProviderAccountsModel()
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

    func testCatalogRefreshSkipsWithoutPersistence() async {
        let model = makeModel(persistenceEnabled: false)
        model.providerAccounts = [ProviderAccount(kind: .chatGPT, name: "Plan")]
        await model.refreshAccountCatalogs(force: true)
        XCTAssertNoBackendTraffic()
    }

    func testAppModelRepublishesProviderAccountChanges() async throws {
        let app = AppModel(startImmediately: false)
        let republished = expectation(description: "AppModel.objectWillChange fired")
        republished.assertForOverFulfill = false
        let cancellable = app.objectWillChange.sink { _ in republished.fulfill() }
        app.providerAccounts = [ProviderAccount(kind: .chatGPT, name: "Bridged")]
        await fulfillment(of: [republished], timeout: 1.0)
        cancellable.cancel()
    }
}
