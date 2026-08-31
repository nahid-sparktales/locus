import AppKit
import Foundation

/// Owns provider accounts and the model catalogs around them: the agent's
/// model list, the local Ollama lists, per-account catalogs and status, the
/// per-account ChatGPT plan state, the usage rollup, and the last reported
/// Ollama host. Routing decisions — which account the session uses, provider
/// switches — stay with the composition root and reach it through closures.
/// AppModel wires it via configure(...) and bridges its publication; it
/// never retains AppModel.
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
    @Published var providerAccounts: [ProviderAccount] = []
    @Published var accountModels: [UUID: [String]] = [:]
    /// The full ChatGPT catalog rows, kept beside the plain name list because
    /// the account editor needs each model's supported reasoning efforts.
    @Published var accountModelCatalogs: [UUID: [ChatGPTModelsResponse.Model]] = [:]
    @Published var accountStatus: [UUID: ProviderAccountStatus] = [:]
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
            // The bypass list keeps Ollama direct, so the proxy layer has to
            // hear about the real host the agent just reported.
            ProxyRuntime.shared.noteOllamaHost(lastOllamaHost)
        }
    }
    private var accountCatalogFetchedAt: [UUID: Date] = [:]

    private var backend: BackendService?
    private var persistenceEnabled = false
    private var localModelHidden: (String) -> Bool = { _ in false }
    private var routedModelsProvider: (UUID) -> [String] = { _ in [] }
    private var activeAccountProvider: () -> ProviderAccount? = { nil }
    private var accountRoutingDeactivated: (UUID) async -> Void = { _ in }
    private var toastHandler: (String) -> Void = { _ in }

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
        guard let url = URL(string: lastOllamaHost + "/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await ProxyRuntime.shared.urlSession.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? -1),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["models"] as? [[String: Any]]
        else { return }  // Ollama not running is normal; keep the last list.
        let knownWindows = Dictionary(
            (installedLocalModels + models).map { ($0.name, $0.contextLength) },
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
                contextLength: knownWindows[name] ?? 0
            )
        }
        localModels = visibleLocalModels(in: installedLocalModels)
    }

    func visibleLocalModels(in models: [ModelInfo]) -> [ModelInfo] {
        models.filter { !localModelHidden($0.name) }
    }

    /// Refreshes every account's model list, unless it was fetched recently.
    func refreshAccountCatalogs(force: Bool = false) async {
        guard let backend, persistenceEnabled else { return }
        let stale = Date().addingTimeInterval(-Self.accountCatalogTTL)
        let due = providerAccounts.filter { account in
            force || (accountCatalogFetchedAt[account.id] ?? .distantPast) < stale
        }
        guard !due.isEmpty else { return }
        let now = Date()
        for account in due { accountCatalogFetchedAt[account.id] = now }
        for account in due where account.kind == .chatGPT {
            do {
                let response = try await backend.get(
                    "/api/chatgpt/models",
                    query: [URLQueryItem(name: "account_id", value: account.codexHomeIdentifier)],
                    as: ChatGPTModelsResponse.self
                )
                let names = response.models.map(\.id)
                accountModels[account.id] = names.isEmpty ? account.kind.curatedModels : names
                accountModelCatalogs[account.id] = response.models
                await refreshChatGPTAccount(for: account)
            } catch {
                accountModels[account.id] = account.kind.curatedModels
                accountStatus[account.id] = .runtimeUnavailable(error.localizedDescription)
            }
        }
        let endpointAccounts = due.filter { $0.kind != .chatGPT }
        await withTaskGroup(of: (UUID, ProviderModelCatalog.Result).self) { group in
            for account in endpointAccounts {
                group.addTask { (account.id, await ProviderModelCatalog.fetch(for: account)) }
            }
            for await (id, result) in group {
                guard let account = providerAccounts.first(where: { $0.id == id }) else {
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

    /// Long enough that the 15-second metadata poll cannot hammer a provider,
    /// short enough that a new model shows up without a relaunch.
    static let accountCatalogTTL: TimeInterval = 300

    func forgetAccountCatalog(_ id: UUID) {
        accountCatalogFetchedAt[id] = nil
        accountModels[id] = nil
        accountModelCatalogs[id] = nil
        accountStatus[id] = nil
    }

    func noteLocalHost(from info: SessionInfo) {
        guard info.provider != "remote", !info.host.isEmpty else { return }
        lastOllamaHost = info.host
    }

    /// Refreshes every ChatGPT account, each against its own credential home.
    func refreshChatGPTAccounts(forceTokenRefresh: Bool = false) async {
        for account in providerAccounts where account.kind == .chatGPT {
            await refreshChatGPTAccount(for: account, forceTokenRefresh: forceTokenRefresh)
        }
    }

    func refreshChatGPTAccount(
        for account: ProviderAccount,
        forceTokenRefresh: Bool = false
    ) async {
        guard let backend else { return }
        var query = [URLQueryItem(name: "account_id", value: account.codexHomeIdentifier)]
        if forceTokenRefresh {
            query.append(URLQueryItem(name: "refresh", value: "true"))
        }
        do {
            let state = try await backend.get(
                "/api/chatgpt/account",
                query: query,
                as: ChatGPTAccountResponse.self
            )
            chatGPTAccounts[account.id] = state
            accountStatus[account.id] = switch state.status {
            case "signed_in": .signedIn(email: state.email, plan: state.planType)
            case "runtime_unavailable":
                .runtimeUnavailable(state.message ?? "The ChatGPT runtime is unavailable")
            case "signing_in": .signingIn
            default: .signedOut
            }
            if state.status == "signed_in" {
                chatGPTLoginIDs[account.id] = nil
                await refreshChatGPTUsage(for: account)
            }
        } catch {
            accountStatus[account.id] = .runtimeUnavailable(error.localizedDescription)
        }
    }

    func startChatGPTLogin(for account: ProviderAccount) async {
        guard let backend else { return }
        do {
            let response = try await backend.post(
                "/api/chatgpt/login/start",
                body: ["account_id": account.codexHomeIdentifier],
                as: ChatGPTLoginResponse.self
            )
            chatGPTLoginIDs[account.id] = response.loginID
            accountStatus[account.id] = .signingIn
            guard let url = URL(string: response.authURL), NSWorkspace.shared.open(url) else {
                toastHandler("Could not open the ChatGPT sign-in page")
                return
            }
        } catch {
            toastHandler("Could not start ChatGPT sign-in: \(error.localizedDescription)")
            await refreshChatGPTAccount(for: account)
        }
    }

    func cancelChatGPTLogin(for account: ProviderAccount) async {
        guard let backend else { return }
        guard let loginID = chatGPTLoginIDs[account.id] else { return }
        do {
            let state = try await backend.post(
                "/api/chatgpt/login/cancel",
                body: [
                    "login_id": loginID,
                    "account_id": account.codexHomeIdentifier,
                ],
                as: ChatGPTAccountResponse.self
            )
            chatGPTLoginIDs[account.id] = nil
            chatGPTAccounts[account.id] = state
            await refreshChatGPTAccount(for: account)
        } catch {
            toastHandler("Could not cancel ChatGPT sign-in: \(error.localizedDescription)")
        }
    }

    func signOutChatGPT(from account: ProviderAccount) async {
        guard let backend else { return }
        do {
            let state = try await backend.post(
                "/api/chatgpt/logout",
                body: ["account_id": account.codexHomeIdentifier],
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
            toastHandler("Could not sign out of ChatGPT: \(error.localizedDescription)")
        }
    }

    /// The plan usage of the ChatGPT account currently routing requests, which
    /// is the only one the usage dashboard's plan section can be about.
    var activeChatGPTUsage: ChatGPTUsageResponse? {
        guard let account = activeAccountProvider(), account.kind == .chatGPT else { return nil }
        return chatGPTUsageByAccount[account.id]
    }

    func refreshActiveChatGPTUsage() async {
        guard let account = activeAccountProvider(), account.kind == .chatGPT else { return }
        await refreshChatGPTUsage(for: account)
    }

    func refreshChatGPTUsage(for account: ProviderAccount) async {
        guard let backend else { return }
        guard providerAccounts.contains(where: { $0.id == account.id }) else {
            chatGPTUsageByAccount[account.id] = nil
            return
        }
        do {
            let usage = try await backend.get(
                "/api/chatgpt/usage",
                query: [URLQueryItem(name: "account_id", value: account.codexHomeIdentifier)],
                as: ChatGPTUsageResponse.self
            )
            chatGPTUsageByAccount[account.id] = usage
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
