import Foundation

/// Forwarders kept while consumers still reach accounts and model catalogs
/// through AppModel; each is deleted once its last caller observes
/// `model.providerAccountsModel` directly.
extension AppModel {
    var models: [ModelInfo] {
        get { providerAccountsModel.models }
        set { providerAccountsModel.models = newValue }
    }

    var localModels: [ModelInfo] {
        get { providerAccountsModel.localModels }
        set { providerAccountsModel.localModels = newValue }
    }

    var installedLocalModels: [ModelInfo] {
        get { providerAccountsModel.installedLocalModels }
        set { providerAccountsModel.installedLocalModels = newValue }
    }

    var providerAccounts: [ProviderAccount] {
        get { providerAccountsModel.providerAccounts }
        set { providerAccountsModel.providerAccounts = newValue }
    }

    var accountModels: [UUID: [String]] {
        get { providerAccountsModel.accountModels }
        set { providerAccountsModel.accountModels = newValue }
    }

    var accountStatus: [UUID: ProviderAccountStatus] {
        get { providerAccountsModel.accountStatus }
        set { providerAccountsModel.accountStatus = newValue }
    }

    var accountModelCatalogs: [UUID: [ChatGPTModelsResponse.Model]] {
        get { providerAccountsModel.accountModelCatalogs }
        set { providerAccountsModel.accountModelCatalogs = newValue }
    }

    var chatGPTAccounts: [UUID: ChatGPTAccountResponse] { providerAccountsModel.chatGPTAccounts }
    var chatGPTUsageByAccount: [UUID: ChatGPTUsageResponse] {
        providerAccountsModel.chatGPTUsageByAccount
    }
    var chatGPTLoginIDs: [UUID: String] { providerAccountsModel.chatGPTLoginIDs }
    var usageSummary: UsageSummary? { providerAccountsModel.usageSummary }
    var activeChatGPTUsage: ChatGPTUsageResponse? { providerAccountsModel.activeChatGPTUsage }

    var lastOllamaHost: String {
        get { providerAccountsModel.lastOllamaHost }
        set { providerAccountsModel.lastOllamaHost = newValue }
    }

    func refreshLocalModels() async { await providerAccountsModel.refreshLocalModels() }

    func visibleLocalModels(in models: [ModelInfo]) -> [ModelInfo] {
        providerAccountsModel.visibleLocalModels(in: models)
    }

    func refreshAccountCatalogs(force: Bool = false) async {
        await providerAccountsModel.refreshAccountCatalogs(force: force)
    }

    func forgetAccountCatalog(_ id: UUID) { providerAccountsModel.forgetAccountCatalog(id) }

    func noteLocalHost(from info: SessionInfo) {
        providerAccountsModel.noteLocalHost(from: info)
    }

    func refreshChatGPTAccounts(forceTokenRefresh: Bool = false) async {
        await providerAccountsModel.refreshChatGPTAccounts(forceTokenRefresh: forceTokenRefresh)
    }

    func refreshChatGPTAccount(
        for account: ProviderAccount,
        forceTokenRefresh: Bool = false
    ) async {
        await providerAccountsModel.refreshChatGPTAccount(
            for: account, forceTokenRefresh: forceTokenRefresh
        )
    }

    func startChatGPTLogin(for account: ProviderAccount) async {
        await providerAccountsModel.startChatGPTLogin(for: account)
    }

    func cancelChatGPTLogin(for account: ProviderAccount) async {
        await providerAccountsModel.cancelChatGPTLogin(for: account)
    }

    func signOutChatGPT(from account: ProviderAccount) async {
        await providerAccountsModel.signOutChatGPT(from: account)
    }

    func refreshActiveChatGPTUsage() async {
        await providerAccountsModel.refreshActiveChatGPTUsage()
    }

    func refreshChatGPTUsage(for account: ProviderAccount) async {
        await providerAccountsModel.refreshChatGPTUsage(for: account)
    }

    func refreshUsageSummary(since: Double) {
        providerAccountsModel.refreshUsageSummary(since: since)
    }

    func persistProviderAccounts() { providerAccountsModel.persistProviderAccounts() }
}
