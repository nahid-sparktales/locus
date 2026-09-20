import AppKit
import CryptoKit
import Foundation

/// Owns provider accounts and the model catalogs around them: the agent's
/// model list, the local Ollama lists, per-account catalogs and status, the
/// per-account ChatGPT plan state, the usage rollup, and the last reported
/// Ollama host. Routing decisions — which account the session uses, provider
/// switches — stay with the composition root and reach it through closures.
/// AppModel wires it via configure(...), while views observe this model
/// directly. It never retains AppModel.
@MainActor
final class ProviderAccountsModel: ObservableObject {
    @Published var models: [ModelInfo] = []
    /// The local Ollama models, kept separately because `models` reflects
    /// whichever provider the agent is currently pointed at — with an account
    /// active it holds that account's list, not the local one.
    @Published var localModels: [ModelInfo] = []
    /// Ollama's complete installed list, including models the user has hidden
    /// from Locus. Settings uses this to make hiding reversible.
    @Published var installedLocalModels: [ModelInfo] = []
    @Published private(set) var hasAuthoritativeLocalModelCatalog = false
    @Published var providerAccounts: [ProviderAccount] = [] {
        didSet {
            for previous in oldValue where providerAccounts.first(where: { $0.id == previous.id }) != previous {
                exactModelConfirmations[previous.id] = nil
                exactModelVerificationRequests[previous.id] = nil
            }
        }
    }
    @Published var accountModels: [UUID: [String]] = [:]
    /// The full ChatGPT catalog rows, kept beside the plain name list because
    /// the account editor needs each model's supported reasoning efforts.
    @Published var accountModelCatalogs: [UUID: [ChatGPTModelsResponse.Model]] = [:]
    /// Cached choices can outlive a failed refresh. Only a complete provider
    /// response can establish that an unlisted selection is unavailable.
    @Published private(set) var accountCatalogComplete: [UUID: Bool] = [:]
    @Published var accountStatus: [UUID: ProviderAccountStatus] = [:] {
        didSet {
            let ids = Set(exactModelConfirmations.keys).union(exactModelVerificationRequests.keys)
            for id in ids where accountStatus[id]?.isHealthy != true {
                exactModelConfirmations[id] = nil
                exactModelVerificationRequests[id] = nil
            }
        }
    }
    /// ChatGPT plan state is per account: each one signs in to its own
    /// isolated credential home, so a single set of these would report the
    /// account that happened to refresh last.
    @Published private(set) var chatGPTAccounts: [UUID: ChatGPTAccountResponse] = [:]
    @Published private(set) var chatGPTUsageByAccount: [UUID: ChatGPTUsageResponse] = [:]
    @Published private(set) var chatGPTLoginIDs: [UUID: String] = [:]
    @Published var usageSummary: UsageSummary?

    var lastOllamaHost = "http://127.0.0.1:11434" {
        didSet {
            guard lastOllamaHost != oldValue else { return }
            hasAuthoritativeLocalModelCatalog = false
            localCatalogRequestID = nil
            // The bypass list keeps Ollama direct, so the proxy layer has to
            // hear about the real host the agent just reported.
            ProxyRuntime.shared.noteOllamaHost(lastOllamaHost)
        }
    }
    private var accountCatalogFetchedAt: [UUID: Date] = [:]
    private var accountCatalogRequests: [UUID: UUID] = [:]
    private var localCatalogRequestID: UUID?
    private struct ExactModelConfirmation {
        let model: String
        let account: ProviderAccount
        let credentialDigest: SHA256.Digest
        let verifiedAt: Date
    }
    /// Carries an explicit Settings test across Save without retaining a key.
    /// Its original timestamp and tested account must survive unchanged.
    struct ExactModelConnectionEvidence {
        fileprivate let model: String
        fileprivate let account: ProviderAccount
        fileprivate let credentialDigest: SHA256.Digest
        fileprivate let verifiedAt: Date
        fileprivate let outcome: RemoteEndpointTester.Outcome
    }
    private var exactModelConfirmations: [UUID: [String: ExactModelConfirmation]] = [:]
    private var exactModelVerificationRequests: [UUID: UUID] = [:]
    private let verificationDate: () -> Date
    private let endpointConnectionTest: (String, String, String, ProviderKind) async -> RemoteEndpointTester.Outcome

    private var backend: BackendService?
    private var persistenceEnabled = false
    private var localModelHidden: (String) -> Bool = { _ in false }
    private var routedModelsProvider: (UUID) -> [String] = { _ in [] }
    private var activeAccountProvider: () -> ProviderAccount? = { nil }
    private var accountRoutingDeactivated: (UUID) async -> Void = { _ in }
    private var toastHandler: (String) -> Void = { _ in }
    let credentialStore: any CredentialStoring

    init(
        credentialStore: any CredentialStoring = CredentialStore.shared,
        verificationDate: @escaping () -> Date = Date.init,
        endpointConnectionTest: @escaping (String, String, String, ProviderKind) async -> RemoteEndpointTester.Outcome = {
            await RemoteEndpointTester.test(baseURL: $0, model: $1, apiKey: $2, kind: $3)
        }
    ) {
        self.credentialStore = credentialStore
        self.verificationDate = verificationDate
        self.endpointConnectionTest = endpointConnectionTest
    }

    func configure(
        backend: BackendService,
        persistenceEnabled: Bool,
        localModelHidden: @escaping (String) -> Bool,
        routedModelsProvider: @escaping (UUID) -> [String],
        activeAccountProvider: @escaping () -> ProviderAccount?,
        accountRoutingDeactivated: @escaping (UUID) async -> Void,
        toastHandler: @escaping (String) -> Void
    ) {
        self.backend = backend
        self.persistenceEnabled = persistenceEnabled
        self.localModelHidden = localModelHidden
        self.routedModelsProvider = routedModelsProvider
        self.activeAccountProvider = activeAccountProvider
        self.accountRoutingDeactivated = accountRoutingDeactivated
        self.toastHandler = toastHandler
    }

    func refreshLocalModels() async {
        let requestID = UUID()
        localCatalogRequestID = requestID
        hasAuthoritativeLocalModelCatalog = false
        guard let url = URL(string: lastOllamaHost + "/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await ProxyRuntime.shared.urlSession.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? -1),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["models"] as? [[String: Any]]
        else { return }  // Ollama not running is normal; keep the last list.
        guard localCatalogRequestID == requestID else { return }
        let knownModels = Dictionary(
            (installedLocalModels + models).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        installedLocalModels = entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return ModelInfo(
                name: name,
                size: (entry["size"] as? NSNumber)?.int64Value ?? 0,
                parameterSize: (entry["details"] as? [String: Any])?["parameter_size"] as? String ?? "",
                // This route is Ollama's /api/tags, which carries no window at
                // all. Zeroing it unconditionally meant that with an account
                // active, every local model in the picker read as unknown even
                // though the agent had already reported a window for it.
                contextLength: knownModels[name]?.contextLength ?? 0,
                trainedContextLength: knownModels[name]?.trainedContextLength ?? 0,
                visionCapable: knownModels[name]?.visionCapable
            )
        }
        localModels = visibleLocalModels(in: installedLocalModels)
        hasAuthoritativeLocalModelCatalog = true
    }

    func visibleLocalModels(in models: [ModelInfo]) -> [ModelInfo] {
        models.filter { !localModelHidden($0.name) }
    }

    /// Refreshes every account's model list, unless it was fetched recently.
    func refreshAccountCatalogs(force: Bool = false, accountID: UUID? = nil) async {
        guard backend != nil, persistenceEnabled else { return }
        let stale = Date().addingTimeInterval(-Self.accountCatalogTTL)
        let due = providerAccounts.filter { account in
            (accountID == nil || account.id == accountID)
                && (force || (accountCatalogFetchedAt[account.id] ?? .distantPast) < stale)
        }
        guard !due.isEmpty else { return }
        let now = Date()
        for account in due { accountCatalogFetchedAt[account.id] = now }
        for account in due where account.kind.isManagedPlan {
            _ = await refreshManagedCatalog(for: account)
        }
        let endpointAccounts = due.filter { !$0.kind.isManagedPlan }
        let requests = Dictionary(uniqueKeysWithValues: endpointAccounts.map {
            ($0.id, beginCatalogRequest(for: $0))
        })
        await withTaskGroup(of: (UUID, ProviderModelCatalog.Result).self) { group in
            for account in endpointAccounts {
                let credentialStore = credentialStore
                group.addTask {
                    (account.id, await ProviderModelCatalog.fetch(for: account, credentialStore: credentialStore))
                }
            }
            for await (id, result) in group {
                guard let account = endpointAccounts.first(where: { $0.id == id }),
                      let request = requests[id], isCurrentCatalogRequest(request, for: account) else {
                    continue
                }
                let routedModels = routedModelsProvider(id)
                let scoped = ProviderModelCatalog.scopedModels(
                    for: account,
                    result: result,
                    routedModels: routedModels
                )
                accountModels[id] = scoped
                accountStatus[id] = result.status
                accountCatalogComplete[id] = result.hasCompleteCatalog(for: account)
                if let replacement = scoped.first,
                   !scoped.contains(where: {
                       $0.caseInsensitiveCompare(account.preferredModel) == .orderedSame
                   }),
                   let index = providerAccounts.firstIndex(where: { $0.id == id })
                {
                    providerAccounts[index].preferredModel = replacement
                    persistProviderAccounts()
                }
            }
        }
    }

    func hasAuthoritativeModelCatalog(for accountID: UUID) -> Bool {
        accountCatalogComplete[accountID] == true
    }

    /// Non-listing providers need an explicit, successful chat probe for the
    /// exact model. A saved key or curated menu is never availability evidence.
    /// This memory-only evidence expires with the normal catalog freshness and
    /// cannot survive changed settings, credentials, or a failed connection.
    func confirmedExactModels(for accountID: UUID) -> [String] {
        guard let account = providerAccounts.first(where: { $0.id == accountID }),
              !account.kind.listsModels, accountStatus[accountID]?.isHealthy == true else {
            exactModelConfirmations[accountID] = nil
            return []
        }
        let digest = SHA256.hash(data: Data((credentialStore.get(account: account.credentialAccount) ?? "").utf8))
        let now = verificationDate()
        let valid = (exactModelConfirmations[accountID] ?? [:]).filter { _, confirmation in
            let age = now.timeIntervalSince(confirmation.verifiedAt)
            return confirmation.account == account && confirmation.credentialDigest == digest
                && age >= 0 && age < Self.accountCatalogTTL
        }
        exactModelConfirmations[accountID] = valid.isEmpty ? nil : valid
        return valid.values.map(\.model).sorted()
    }

    func exactModelConnectionEvidence(
        for account: ProviderAccount, model: String, apiKey: String, outcome: RemoteEndpointTester.Outcome
    ) -> ExactModelConnectionEvidence? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.kind.listsModels, !name.isEmpty else { return nil }
        return ExactModelConnectionEvidence(model: name, account: account,
            credentialDigest: SHA256.hash(data: Data(apiKey.utf8)), verifiedAt: verificationDate(), outcome: outcome)
    }

    /// Unsaved or edited Settings drafts cannot establish availability for a
    /// saved route, even when their probe succeeds. Save may offer the same
    /// evidence again after its exact settings and key have been committed.
    @discardableResult
    func acceptExactModelConnectionEvidence(_ evidence: ExactModelConnectionEvidence) -> Bool {
        let id = evidence.account.id
        let age = verificationDate().timeIntervalSince(evidence.verifiedAt)
        guard providerAccounts.first(where: { $0.id == id }) == evidence.account,
              age >= 0, age < Self.accountCatalogTTL,
              SHA256.hash(data: Data((credentialStore.get(account: evidence.account.credentialAccount) ?? "").utf8))
                == evidence.credentialDigest else { return false }
        guard evidence.outcome.ok else {
            exactModelConfirmations[id] = nil
            accountStatus[id] = .failed(evidence.outcome.message)
            return false
        }
        exactModelConfirmations[id, default: [:]][evidence.model.lowercased()] = ExactModelConfirmation(
            model: evidence.model, account: evidence.account, credentialDigest: evidence.credentialDigest,
            verifiedAt: evidence.verifiedAt
        )
        accountStatus[id] = .connected(models: exactModelConfirmations[id]?.count ?? 1)
        return true
    }

    private func beginCatalogRequest(for account: ProviderAccount) -> UUID {
        let request = UUID()
        accountCatalogRequests[account.id] = request
        accountCatalogComplete[account.id] = false
        return request
    }

    private func isCurrentAccount(
        _ account: ProviderAccount,
        catalogRequestID: UUID? = nil,
        allowUnsavedAccount: Bool = false
    ) -> Bool {
        guard let current = providerAccounts.first(where: { $0.id == account.id }) else {
            return allowUnsavedAccount && catalogRequestID == nil
        }
        if let catalogRequestID, accountCatalogRequests[account.id] != catalogRequestID { return false }
        return current.kind == account.kind
            && current.resolvedBaseURL == account.resolvedBaseURL
            && current.managedHomeIdentifier == account.managedHomeIdentifier
            && current.credentialAccount == account.credentialAccount
    }

    private func isCurrentCatalogRequest(_ request: UUID, for account: ProviderAccount) -> Bool {
        accountCatalogRequests[account.id] == request && isCurrentAccount(account)
    }

    private func refreshManagedCatalog(for account: ProviderAccount) async -> ChatGPTModelsResponse? {
        guard let backend, account.kind.isManagedPlan, isCurrentAccount(account) else { return nil }
        let request = beginCatalogRequest(for: account)
        do {
            let response = try await backend.get(
                account.kind.managedAPIPath + "/models",
                query: [URLQueryItem(name: "account_id", value: account.managedHomeIdentifier)],
                as: ChatGPTModelsResponse.self
            )
            guard isCurrentCatalogRequest(request, for: account) else { return nil }
            let rows = response.models.filter {
                ProviderModelFilter.matchesCatalog(kind: account.kind, name: $0.id)
            }
            if response.catalogComplete != false, !rows.isEmpty {
                accountModels[account.id] = rows.map(\.id)
                accountModelCatalogs[account.id] = rows
                accountCatalogComplete[account.id] = true
            }
            // Keep working choices on an incomplete response without using
            // that fallback to reject models or overwrite the selected account.
            await refreshChatGPTAccount(for: account, catalogRequestID: request)
            guard isCurrentCatalogRequest(request, for: account) else { return nil }
            return response
        } catch {
            guard isCurrentCatalogRequest(request, for: account) else { return nil }
            accountStatus[account.id] = .runtimeUnavailable(error.localizedDescription)
            return nil
        }
    }

    /// Test the selected account through its own authentication route. Plan
    /// accounts never use the API-key catalog fetcher or its curated fallback.
    func testConnection(for accountID: UUID, model: String) async -> String {
        guard let account = providerAccounts.first(where: { $0.id == accountID }) else {
            return "That provider account is unavailable."
        }
        if account.kind.isManagedPlan {
            guard backend != nil else { return "The subscription runtime is unavailable." }
            let response = await refreshManagedCatalog(for: account)
            guard isCurrentAccount(account) else { return "The provider account changed. Test the connection again." }
            guard let status = accountStatus[accountID] else { return "Could not check this account. Try again." }
            guard status.isHealthy else { return status.summary }
            guard let response, response.catalogComplete != false, !response.models.isEmpty else {
                return "\(status.summary). The model list could not be verified. Try refreshing it again."
            }
            guard response.models.contains(where: {
                ProviderModelFilter.matchesCatalog(kind: account.kind, name: $0.id)
                    && $0.id.caseInsensitiveCompare(model) == .orderedSame
            }) else {
                return "Connected to \(account.displayName), but \(model) was not in this account’s model list."
            }
            return "Connected to \(account.displayName). \(model) is available."
        }
        let request = beginCatalogRequest(for: account)
        let apiKey = credentialStore.get(account: account.credentialAccount) ?? ""
        if !account.kind.listsModels { exactModelVerificationRequests[accountID] = request }
        let result = await ProviderModelCatalog.fetch(for: account, credentialStore: credentialStore)
        guard isCurrentCatalogRequest(request, for: account) else {
            return "The provider account changed. Test the connection again."
        }
        let scoped = ProviderModelCatalog.scopedModels(
            for: account, result: result, routedModels: routedModelsProvider(accountID)
        )
        accountModels[accountID] = scoped
        accountStatus[accountID] = result.status
        accountCatalogComplete[accountID] = result.hasCompleteCatalog(for: account)
        guard result.status.isHealthy else { return result.status.summary }
        if result.hasCompleteCatalog(for: account) {
            guard scoped.contains(where: { $0.caseInsensitiveCompare(model) == .orderedSame }) else {
                return "Connected, but the exact model was not in this account’s model list."
            }
            return result.status.summary
        }
        let outcome = await endpointConnectionTest(account.resolvedBaseURL, model, apiKey, account.kind)
        guard isCurrentCatalogRequest(request, for: account) else {
            return "The provider account changed. Test the connection again."
        }
        if !account.kind.listsModels {
            guard exactModelVerificationRequests[accountID] == request,
                  providerAccounts.first(where: { $0.id == accountID }) == account,
                  (credentialStore.get(account: account.credentialAccount) ?? "") == apiKey else {
                exactModelConfirmations[accountID] = nil
                return "The provider account changed. Test the connection again."
            }
            exactModelVerificationRequests[accountID] = nil
            if let evidence = exactModelConnectionEvidence(for: account, model: model, apiKey: apiKey, outcome: outcome) {
                acceptExactModelConnectionEvidence(evidence)
            } else {
                exactModelConfirmations[accountID] = nil
                accountStatus[accountID] = .failed(outcome.message)
            }
        }
        return outcome.message
    }

    /// Long enough that the 15-second metadata poll cannot hammer a provider,
    /// short enough that a new model shows up without a relaunch.
    static let accountCatalogTTL: TimeInterval = 300

    func forgetAccountCatalog(_ id: UUID) {
        accountCatalogFetchedAt[id] = nil
        accountModels[id] = nil
        accountModelCatalogs[id] = nil
        accountCatalogComplete[id] = nil
        accountCatalogRequests[id] = nil
        exactModelConfirmations[id] = nil
        exactModelVerificationRequests[id] = nil
        accountStatus[id] = nil
    }

    func noteLocalHost(from info: SessionInfo) {
        guard info.provider == "ollama", !info.host.isEmpty else { return }
        lastOllamaHost = info.host
    }

    /// Refreshes every ChatGPT account, each against its own credential home.
    func refreshChatGPTAccounts(forceTokenRefresh: Bool = false) async {
        for account in providerAccounts where account.kind.isManagedPlan {
            await refreshChatGPTAccount(for: account, forceTokenRefresh: forceTokenRefresh)
        }
    }

    func refreshChatGPTAccount(
        for account: ProviderAccount,
        forceTokenRefresh: Bool = false,
        catalogRequestID: UUID? = nil,
        allowUnsavedAccount: Bool = false
    ) async {
        // The account editor signs a new account in before Save. Opt in only
        // for an account absent at the start; removing a saved account while
        // this request runs must still invalidate its response.
        let isDraft = allowUnsavedAccount && !providerAccounts.contains { $0.id == account.id }
        guard let backend, isCurrentAccount(account, catalogRequestID: catalogRequestID, allowUnsavedAccount: isDraft) else { return }
        var query = [URLQueryItem(name: "account_id", value: account.managedHomeIdentifier)]
        if forceTokenRefresh {
            query.append(URLQueryItem(name: "refresh", value: "true"))
        }
        do {
            let state = try await backend.get(
                account.kind.managedAPIPath + "/account",
                query: query,
                as: ChatGPTAccountResponse.self
            )
            guard isCurrentAccount(account, catalogRequestID: catalogRequestID, allowUnsavedAccount: isDraft) else { return }
            chatGPTAccounts[account.id] = state
            if account.kind == .claudePlan && state.status == "signed_out" {
                chatGPTLoginIDs[account.id] = nil
            }
            accountStatus[account.id] = switch state.status {
            case "signed_in": .signedIn(email: state.email, plan: state.planType)
            case "runtime_unavailable":
                .runtimeUnavailable(state.message ?? "The subscription runtime is unavailable")
            case "signing_in": .signingIn
            default: .signedOut
            }
            if state.status == "signed_in" {
                chatGPTLoginIDs[account.id] = nil
                await refreshChatGPTUsage(for: account, catalogRequestID: catalogRequestID, allowUnsavedAccount: isDraft)
            }
        } catch {
            guard isCurrentAccount(account, catalogRequestID: catalogRequestID, allowUnsavedAccount: isDraft) else { return }
            accountStatus[account.id] = .runtimeUnavailable(error.localizedDescription)
        }
    }

    func startChatGPTLogin(for account: ProviderAccount, allowUnsavedAccount: Bool = false) async {
        guard let backend else { return }
        do {
            let response = try await backend.post(
                account.kind.managedAPIPath + "/login/start",
                body: ["account_id": account.managedHomeIdentifier],
                as: ChatGPTLoginResponse.self
            )
            chatGPTLoginIDs[account.id] = response.loginID
            accountStatus[account.id] = .signingIn
            if response.authURL.isEmpty { return }
            guard let url = URL(string: response.authURL), NSWorkspace.shared.open(url) else {
                toastHandler("Could not open the subscription sign-in page")
                return
            }
        } catch {
            toastHandler("Could not start subscription sign-in: \(error.localizedDescription)")
            await refreshChatGPTAccount(for: account, allowUnsavedAccount: allowUnsavedAccount)
        }
    }

    func cancelChatGPTLogin(for account: ProviderAccount, allowUnsavedAccount: Bool = false) async {
        guard let backend else { return }
        guard let loginID = chatGPTLoginIDs[account.id] else { return }
        do {
            let state = try await backend.post(
                account.kind.managedAPIPath + "/login/cancel",
                body: [
                    "login_id": loginID,
                    "account_id": account.managedHomeIdentifier,
                ],
                as: ChatGPTAccountResponse.self
            )
            chatGPTLoginIDs[account.id] = nil
            chatGPTAccounts[account.id] = state
            await refreshChatGPTAccount(for: account, allowUnsavedAccount: allowUnsavedAccount)
        } catch {
            toastHandler("Could not cancel subscription sign-in: \(error.localizedDescription)")
        }
    }

    func signOutChatGPT(from account: ProviderAccount) async {
        guard let backend else { return }
        do {
            let state = try await backend.post(
                account.kind.managedAPIPath + "/logout",
                body: ["account_id": account.managedHomeIdentifier],
                as: ChatGPTAccountResponse.self
            )
            chatGPTAccounts[account.id] = state
            chatGPTLoginIDs[account.id] = nil
            chatGPTUsageByAccount[account.id] = nil
            accountStatus[account.id] = .signedOut
            // Only the account in use costs the app its provider. Signing out
            // of a second plan must leave a chat running on the first alone.
            await accountRoutingDeactivated(account.id)
        } catch {
            toastHandler("Could not sign out of the account: \(error.localizedDescription)")
        }
    }

    /// The plan usage of the ChatGPT account currently routing requests, which
    /// is the only one the usage dashboard's plan section can be about.
    var activeChatGPTUsage: ChatGPTUsageResponse? {
        guard let account = activeAccountProvider(), account.kind.isManagedPlan else { return nil }
        return chatGPTUsageByAccount[account.id]
    }

    func refreshActiveChatGPTUsage() async {
        guard let account = activeAccountProvider(), account.kind.isManagedPlan else { return }
        await refreshChatGPTUsage(for: account)
    }

    func refreshChatGPTUsage(
        for account: ProviderAccount,
        catalogRequestID: UUID? = nil,
        allowUnsavedAccount: Bool = false
    ) async {
        let isDraft = allowUnsavedAccount && !providerAccounts.contains { $0.id == account.id }
        guard let backend, isCurrentAccount(account, catalogRequestID: catalogRequestID, allowUnsavedAccount: isDraft) else { return }
        do {
            let usage = try await backend.get(
                account.kind.managedAPIPath + "/usage",
                query: [URLQueryItem(name: "account_id", value: account.managedHomeIdentifier)],
                as: ChatGPTUsageResponse.self
            )
            guard isCurrentAccount(account, catalogRequestID: catalogRequestID, allowUnsavedAccount: isDraft) else { return }
            chatGPTUsageByAccount[account.id] = usage
            if usage.limitStatus == "rejected" {
                accountStatus[account.id] = .rateLimited(resetAt: usage.rateLimits.rateLimits?.primary?.resetsAt.map { Date(timeIntervalSince1970: Double($0)) })
            }
            if let window = usage.rateLimits.rateLimits?.primary,
               window.usedPercent >= 100
            {
                let reset = window.resetsAt.map { Date(timeIntervalSince1970: Double($0)) }
                accountStatus[account.id] = .rateLimited(resetAt: reset)
            }
        } catch {
            // Usage is supplementary; the account and working providers stay
            // available when this one read fails.
        }
    }

    /// Fetch the usage rollup for the dashboard. A failure leaves the previous
    /// summary in place; the sheet's spinner covers the initial load.
    func refreshUsageSummary(since: Double) {
        Task { [weak self] in
            guard let self else { return }
            let query = since > 0
                ? [URLQueryItem(name: "since", value: String(since))]
                : []
            guard let backend = self.backend,
                  let summary = try? await backend.get(
                "/api/usage/summary",
                query: query,
                as: UsageSummary.self
            ) else { return }
            usageSummary = summary
        }
    }

    func persistProviderAccounts() {
        guard persistenceEnabled else { return }
        ProviderAccountStore.save(providerAccounts)
    }
}
