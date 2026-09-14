import Foundation

/// Keeps an editor's choices scoped to one account, and separates a verified
/// catalog from fallback suggestions while discovery is still pending.
struct AgentProfileModelOptions {
    enum Availability: Equatable {
        case available
        case unverified
        case unavailable
    }

    let account: ProviderAccount?
    let choices: [String]
    let hasAuthoritativeCatalog: Bool

    init(account: ProviderAccount?, reportedModels: [String], hasAuthoritativeCatalog: Bool) {
        self.account = account
        self.hasAuthoritativeCatalog = hasAuthoritativeCatalog
        let models: [String]
        if let account {
            if !reportedModels.isEmpty {
                models = reportedModels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
                    ProviderModelFilter.matchesCatalog(kind: account.kind, name: $0)
                }
            } else {
                models = ([account.preferredModel] + account.kind.curatedModels).filter {
                    ProviderModelFilter.matchesFallback(kind: account.kind, name: $0)
                }
            }
        } else {
            models = reportedModels
        }
        var seen: Set<String> = []
        choices = models.compactMap { value in
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }

    func availability(of model: String) -> Availability {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .unverified }
        if choices.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return hasAuthoritativeCatalog ? .available : .unverified
        }
        if hasAuthoritativeCatalog { return .unavailable }
        if let account, account.kind != .custom {
            if account.kind == .claudePlan {
                // Managed catalogs may introduce new aliases. Only reject a
                // recognizable model from another provider before discovery.
                if ProviderModelFilter.matches(kind: .chatGPT, name: name)
                    || ProviderModelFilter.matches(kind: .kimiCode, name: name) {
                    return .unavailable
                }
            } else if !ProviderModelFilter.matches(kind: account.kind, name: name) {
                return .unavailable
            }
        }
        return .unverified
    }

    func selecting(_ route: AgentRoute, in profile: AgentProfile) -> AgentProfile {
        var selected = profile
        selected.route = route
        let preferred = account?.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        selected.model = choices.first(where: {
            $0.caseInsensitiveCompare(preferred) == .orderedSame
        }) ?? choices.first ?? ""
        return selected
    }
}
