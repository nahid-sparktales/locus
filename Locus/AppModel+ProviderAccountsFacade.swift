import Foundation

// Facade API — the account/catalog state that the send pipeline, model
// router, settings apply, and team ops read on nearly every turn. These
// stay as forwarders; narrowing them is part of the router follow-up.
// Everything else on ProviderAccountsModel is reached through
// `model.providerAccountsModel` directly.
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
