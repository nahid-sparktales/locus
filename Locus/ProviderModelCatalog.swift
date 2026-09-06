import Foundation

/// Fetches each provider account's model list.
///
/// The agent can only report the models of the provider it is currently
/// pointed at, but the picker has to show every account at once — so the list
/// is read here, straight from the provider, the same way "Test Connection"
/// does. A failure is never fatal: the provider's curated models stand in, and
/// the account stays selectable.
enum ProviderModelCatalog {
    struct Result {
        let models: [String]
        let status: ProviderAccountStatus
    }

    private static let session = ProxyAwareSession(
        scope: .modelAndAgent,
        configuration: { .ephemeral },
        delegate: { NoRedirectSessionDelegate() }
    )

    static func fetch(
        for account: ProviderAccount,
        credentialStore: any CredentialStoring = CredentialStore.shared
    ) async -> Result {
        let key = credentialStore.get(account: account.credentialAccount) ?? ""
        // A custom endpoint may genuinely have no key — a local llama.cpp or
        // LM Studio server, say — so probe it unauthenticated rather than
        // giving up before the request.
        guard !key.isEmpty || account.kind.allowsEmptyAPIKey else {
            return Result(models: account.kind.curatedModels, status: .noKey)
        }
        // Kimi Code serves chat completions and nothing else. Asking it for a
        // listing every five minutes would earn an auth error the UI would
        // report as a rejected key, so offer the fixed menu instead.
        guard account.kind.listsModels else {
            return Result(models: fallbackModels(for: account), status: .keySaved)
        }
        let base = RemoteEndpointTester.normalizeBaseURL(account.resolvedBaseURL)
        if let error = RemoteEndpointTester.securityError(baseURL: base, apiKey: key) {
            return Result(models: account.kind.curatedModels, status: .failed(error))
        }
        guard !base.isEmpty, let url = URL(string: base + "/models") else {
            return Result(
                models: account.kind.curatedModels,
                status: .failed("That endpoint URL is not valid.")
            )
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        LocusClientIdentity.apply(to: &request)
        for (field, value) in RemoteEndpointTester.authHeaders(
            apiKey: key,
            kind: account.kind
        ) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await session.current.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 401 || status == 403 {
                // "Rejected the key" would be a riddle when none was sent.
                return Result(
                    models: account.kind.curatedModels,
                    status: key.isEmpty
                        ? .failed("The endpoint requires an API key.")
                        : .keyRejected
                )
            }
            guard (200..<300).contains(status) else {
                // A single-model endpoint answering 404 here is normal, and its
                // configured model is still perfectly usable.
                let fallback = fallbackModels(for: account)
                return Result(
                    models: fallback,
                    status: status == 404
                        ? .keySaved
                        : .failed(RemoteEndpointTester.failureMessage(
                            status: status,
                            data: data,
                            apiKey: key
                        ))
                )
            }
            let names = ProviderModelFilter.parseModelList(data)
            guard !names.isEmpty else {
                return Result(models: fallbackModels(for: account), status: .keySaved)
            }
            let chat = ProviderModelFilter.chatModels(kind: account.kind, names: names)
            let ordered = ProviderModelFilter.ordered(kind: account.kind, fetched: chat)
            return Result(models: ordered, status: .connected(models: ordered.count))
        } catch {
            return Result(
                models: fallbackModels(for: account),
                status: .failed(error.localizedDescription)
            )
        }
    }

    /// What to offer when the provider will not say: its curated models, plus
    /// whatever this account was last used with.
    private static func fallbackModels(for account: ProviderAccount) -> [String] {
        var models = account.kind.curatedModels
        let preferred = account.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty,
           (account.kind == .custom || ProviderModelFilter.matches(kind: account.kind, name: preferred)),
           !models.contains(preferred)
        {
            models.insert(preferred, at: 0)
        }
        return models
    }

    /// Keep one account's fallback history from becoming another provider's
    /// catalog. Team jobs temporarily route the shared backend through several
    /// models; older builds could persist that transient model beside the solo
    /// account and then re-offer it here after relaunch.
    static func scopedModels(
        for account: ProviderAccount,
        result: Result,
        routedModels: [String]
    ) -> [String] {
        let clean = deduplicated(result.models)
        if account.kind != .custom {
            let matching = clean.filter {
                ProviderModelFilter.matches(kind: account.kind, name: $0)
            }
            return matching.isEmpty ? account.kind.curatedModels : matching
        }
        if case .connected = result.status {
            return clean
        }
        let routed = deduplicated(routedModels)
        return routed.isEmpty ? clean : routed
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else {
                return nil
            }
            return trimmed
        }
    }
}
