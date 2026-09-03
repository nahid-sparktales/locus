import Foundation

// Compatibility facade for the send pipeline, model router, settings apply,
// and team orchestration. Reactive views observe ProviderAccountsModel
// directly; these forwarders do not establish an observation boundary.
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

    var lastOllamaHost: String {
        get { providerAccountsModel.lastOllamaHost }
        set { providerAccountsModel.lastOllamaHost = newValue }
    }
}
