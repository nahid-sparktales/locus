import Foundation

/// A hosted model provider Locus knows how to talk to.
///
/// Most use OpenAI chat completions; Claude uses Anthropic's native Messages
/// protocol. The agent adapter hides that difference from the rest of the app.
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case claude
    /// OpenAI-managed ChatGPT subscription access. Authentication and model
    /// traffic stay inside the bundled Codex App Server helper; this is never
    /// interchangeable with an API key account.
    case chatGPT = "chatgpt"
    case codex
    case kimi
    /// Moonshot's coding service, billed through a Kimi membership rather than
    /// per token. A separate kind from `.kimi` rather than a flag on it: it is a
    /// different host, a different key, and a different model line-up, and the
    /// two keys are not interchangeable.
    case kimiCode
    /// Any other OpenAI-compatible endpoint: a rented GPU, a gateway, or the
    /// single remote endpoint configured before accounts existed.
    case custom

    var id: String { rawValue }

    /// What the user calls it.
    var marketingName: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT plan"
        case .codex: "OpenAI API"
        case .kimi: "Kimi"
        case .kimiCode: "Kimi Code"
        case .custom: "Custom endpoint"
        }
    }

    /// Who runs it — shown next to the marketing name so "Codex" is not a riddle.
    var vendorName: String {
        switch self {
        case .claude: "Anthropic"
        case .chatGPT, .codex: "OpenAI"
        case .kimi, .kimiCode: "Moonshot AI"
        case .custom: ""
        }
    }

    var title: String {
        vendorName.isEmpty ? marketingName : "\(marketingName) (\(vendorName))"
    }

    var defaultBaseURL: String {
        switch self {
        case .claude: "https://api.anthropic.com/v1"
        // A display/documentation origin only. Managed ChatGPT traffic never
        // uses this as an inference endpoint.
        case .chatGPT: "https://chatgpt.com"
        case .codex: "https://api.openai.com/v1"
        case .kimi: "https://api.moonshot.ai/v1"
        case .kimiCode: "https://api.kimi.com/coding/v1"
        case .custom: ""
        }
    }

    /// Where to get a key. Documentation pages, never billing pages.
    var keyDocsURL: String {
        switch self {
        case .claude: "https://console.anthropic.com/settings/keys"
        case .chatGPT: "https://learn.chatgpt.com/docs/auth#openai-authentication"
        case .codex: "https://platform.openai.com/api-keys"
        case .kimi: "https://platform.moonshot.ai/console/api-keys"
        case .kimiCode: "https://www.kimi.com/code/docs/en/"
        case .custom: ""
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .claude: "sk-ant-…"
        case .chatGPT: ""
        case .codex, .kimi: "sk-…"
        // Moonshot documents no prefix for these; guessing one would contradict
        // what the user is about to paste.
        case .kimiCode: "Kimi Code Console key"
        case .custom: "API key"
        }
    }

    /// Matches the agent's auth styles. Anthropic's native model listing wants
    /// the key in `x-api-key`; everything else takes a bearer token.
    var authStyle: String {
        switch self {
        case .claude: "anthropic"
        case .chatGPT: "managed"
        case .codex, .kimi, .kimiCode, .custom: "bearer"
        }
    }

    var requiresAPIKey: Bool { self != .chatGPT }

    var usesManagedChatGPTAuthentication: Bool { self == .chatGPT }

    /// Whether `GET {base}/models` is a route this provider actually serves.
    ///
    /// Kimi Code documents only chat completions. Probing an undocumented path
    /// turns a perfectly good subscription key into a misleading "rejected the
    /// API key" the moment that path answers 401 or 403.
    var listsModels: Bool { self != .kimiCode }

    /// Only `.custom` has a URL worth editing — the rest are fixed endpoints,
    /// though a stored override (Moonshot's China domain, say) still wins.
    var allowsBaseURLOverride: Bool { self == .custom }

    /// Shown when the provider's model list cannot be fetched, and merged ahead
    /// of a fetched list so the newest models are easy to find.
    var curatedModels: [String] {
        switch self {
        case .claude:
            ["claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-haiku-4-5"]
        case .chatGPT:
            ["gpt-5.3-codex", "gpt-5.2-codex", "gpt-5.1-codex-max"]
        case .codex:
            ["gpt-5.6", "gpt-5", "gpt-5-mini", "gpt-4.1", "o3"]
        case .kimi:
            ["kimi-k3", "kimi-k2.7-code-highspeed", "kimi-k2.7-code", "kimi-k2.6"]
        case .kimiCode:
            // Order matters: `probeModel` takes the first, and this is the only
            // one every membership tier can reach. Leading with a higher tier
            // would make Test Connection fail in a way that reads like a bad key.
            ["kimi-for-coding", "kimi-for-coding-highspeed", "k3", "k3-256k"]
        case .custom:
            []
        }
    }

    /// The published context window for one of this provider's models, or nil
    /// when it is not a model we have a documented figure for.
    ///
    /// Unlike Ollama — where the runtime window genuinely differs from the
    /// trained one and has to be measured — a hosted model's window is a
    /// published property of the API. Shipping the documented number is not the
    /// guess that `effective_context_length` warns about; it is the spec. It is
    /// still only a default: an account's own value wins, and the meter says
    /// where the figure came from so a stale entry here is visible rather than
    /// silently wrong.
    ///
    /// Verify against vendor documentation when adding a model.
    func publishedContextWindow(for model: String) -> Int? {
        let name = model.lowercased()
        switch self {
        case .claude:
            if name.contains("opus-5")
                || name.contains("sonnet-5")
                || name.contains("fable-5") {
                return 1_000_000
            }
            if name.contains("haiku-4-5") { return 200_000 }
            if name.hasPrefix("claude-") && name.contains("-4") { return 200_000 }
            return nil
        case .chatGPT, .codex:
            if name == "gpt-5.6" || name.hasPrefix("gpt-5.6-") { return 1_050_000 }
            if name == "gpt-5" || name.hasPrefix("gpt-5-") { return 400_000 }
            if name.hasPrefix("gpt-4.1") { return 1_047_576 }
            if name.hasPrefix("o3") || name.hasPrefix("o4") { return 200_000 }
            return nil
        case .kimi, .kimiCode:
            if name.contains("k3-256k") || name.contains("256k") { return 256_000 }
            if name == "k3" || name.hasPrefix("kimi-k3") { return 1_000_000 }
            if name.hasPrefix("kimi-k2") || name.hasPrefix("kimi-for-coding") {
                return 256_000
            }
            if name.contains("128k") { return 128_000 }
            return nil
        case .custom:
            // Someone else's deployment; only they know how it was configured.
            return nil
        }
    }

    /// A model this provider will accept for a one-token connection probe.
    var probeModel: String { curatedModels.first ?? "" }

    /// A provider-specific fact the user needs before their key will work.
    /// Rendered in the account editor, above Test Connection.
    var note: ProviderNote? {
        switch self {
        case .claude:
            ProviderNote(
                text: """
                Claude accounts use an API key from console.anthropic.com. \
                Anthropic does not permit third-party apps to sign in with a \
                Claude.ai account or to route requests through Pro or Max plan \
                credentials, so a Claude subscription cannot be used here.
                """,
                linkTitle: "Anthropic's terms for third-party tools",
                linkURL: "https://code.claude.com/docs/en/legal-and-compliance"
            )
        case .kimiCode:
            ProviderNote(
                text: """
                Kimi Code is billed through a Kimi membership rather than per \
                token. Create a key in the Kimi Code Console — up to five, each \
                shown only once. This is a different key from a \
                platform.moonshot.ai key; the two are not interchangeable.
                """,
                linkTitle: "Kimi Code documentation",
                linkURL: "https://www.kimi.com/code/docs/en/"
            )
        case .kimi:
            ProviderNote(
                text: """
                Kimi accounts are billed per token with a key from \
                platform.moonshot.ai. For a key included in a Kimi membership, \
                add a Kimi Code account instead.
                """,
                linkTitle: "",
                linkURL: ""
            )
        case .chatGPT, .codex, .custom:
            nil
        }
    }
}

/// A short provider-specific explanation, with an optional documentation link.
struct ProviderNote: Equatable {
    let text: String
    let linkTitle: String
    let linkURL: String

    var hasLink: Bool { !linkTitle.isEmpty && !linkURL.isEmpty }
}

/// Which of a provider's models belong in a chat model picker.
///
/// OpenAI's `/v1/models` returns everything the account can reach — embeddings,
/// speech, moderation, images — so listing it raw would bury the four models
/// anyone wants. The filters are deliberately forgiving: if one empties the
/// list, the caller falls back to the unfiltered names rather than showing
/// nothing.
enum ProviderModelFilter {
    private static let excludedFragments = [
        "embedding", "whisper", "tts", "dall-e", "audio", "realtime",
        "moderation", "image", "transcribe", "search", "sora",
    ]

    private static let codexPrefixes = ["gpt-", "chatgpt-", "codex", "o1", "o3", "o4"]

    static func chatModels(kind: ProviderKind, names: [String]) -> [String] {
        let filtered = names.filter { matches(kind: kind, name: $0) }
        // A provider that renames its line-up should not produce an empty
        // picker: showing everything beats showing nothing.
        return filtered.isEmpty ? names : filtered
    }

    static func matches(kind: ProviderKind, name: String) -> Bool {
        let lowered = name.lowercased()
        guard !excludedFragments.contains(where: lowered.contains) else { return false }
        switch kind {
        case .claude:
            return lowered.hasPrefix("claude")
        case .chatGPT, .codex:
            return codexPrefixes.contains { lowered.hasPrefix($0) }
        case .kimi:
            return lowered.hasPrefix("kimi") || lowered.hasPrefix("moonshot")
        case .kimiCode:
            // Two of the coding models are named `k3` and `k3-256k`, which the
            // `.kimi` rule above would drop — and the empty-filter fallback
            // would not save them, because `kimi-for-coding` passes it.
            return ["kimi", "k3", "k2", "moonshot"].contains(where: lowered.hasPrefix)
        case .custom:
            return true
        }
    }

    /// Parses the `{"data": [{"id": …}]}` listing all three providers return.
    static func parseModelList(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    /// Curated models first, then whatever else the provider reported.
    static func ordered(kind: ProviderKind, fetched: [String]) -> [String] {
        let curated = kind.curatedModels.filter(fetched.contains)
        let rest = fetched.filter { !curated.contains($0) }
        return curated + rest
    }
}

/// One signed-in provider account. The API key is not here — it lives in the
/// credential file under `CredentialStore.providerAccountKey(id)`.
struct ProviderAccount: Identifiable, Codable, Hashable {
    let id: UUID
    /// Stored raw, not as the enum: a kind added by a future version must not
    /// fail the decode and take the user's other accounts with it.
    var kindRaw: String
    /// The user's name for this account — "Work", "Personal". May be empty.
    var name: String
    /// Only meaningful for `.custom`, and for regional hosts such as
    /// Moonshot's `api.moonshot.cn`.
    var baseURLOverride: String?
    /// The model last used through this account, re-applied when it is chosen.
    var preferredModel: String
    /// A context window the user set for this account, overriding the
    /// provider's published figure. Optional so accounts stored before this
    /// existed decode unchanged.
    var contextWindow: Int?
    var createdAt: Date
    /// Set only by the migration, for the account made from the single remote
    /// endpoint that existed before accounts: it keeps pointing at the old
    /// credential entry so the key never has to be re-entered.
    var legacyKeychainAccount: String?

    init(
        id: UUID = UUID(),
        kind: ProviderKind,
        name: String = "",
        baseURLOverride: String? = nil,
        preferredModel: String = "",
        contextWindow: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.name = name
        self.baseURLOverride = baseURLOverride
        self.preferredModel = preferredModel
        self.contextWindow = contextWindow
        self.createdAt = createdAt
    }

    /// An unknown kind resolves to `.custom`, which keeps the account usable:
    /// it still has a base URL and a key.
    var kind: ProviderKind { ProviderKind(rawValue: kindRaw) ?? .custom }

    var resolvedBaseURL: String {
        let override = (baseURLOverride ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? kind.defaultBaseURL : override
    }

    /// "Claude — Work", or just "Claude" when the account has no name.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.marketingName : "\(kind.marketingName) — \(trimmed)"
    }

    /// The label for the model picker's closed state, where the provider is
    /// already implied by the model name.
    var shortName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.marketingName : trimmed
    }

    var keychainAccount: String {
        legacyKeychainAccount ?? CredentialStore.providerAccountKey(id)
    }

    var hasKey: Bool {
        kind.usesManagedChatGPTAuthentication
            || CredentialStore.has(account: keychainAccount)
    }

    /// The window to budget this account against: what the user set, else
    /// the provider's published figure for the selected model, else none.
    var resolvedContextWindow: Int? {
        if let contextWindow, contextWindow > 0 { return contextWindow }
        return kind.publishedContextWindow(for: preferredModel)
    }
}

/// The saved accounts, and the rules for reading a list that may have been
/// written by a different version.
enum ProviderAccountStore {
    static let defaultsKey = "Locus.providerAccounts"

    static func load(from defaults: UserDefaults = .standard) -> [ProviderAccount] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return decode(data)
    }

    /// How many accounts the stored blob claims to hold, or nil when nothing
    /// is stored or the blob is not even an array.
    ///
    /// Exists so a caller can tell a complete read from a salvaged one.
    /// `decode` is deliberately lossy, and anything destructive — deleting a
    /// key, say — must not act on the difference between what was stored and
    /// what could be understood.
    static func storedCount(in defaults: UserDefaults = .standard) -> Int? {
        guard let data = defaults.data(forKey: defaultsKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        return raw.count
    }

    /// Decodes element by element: one unreadable account must not delete the
    /// rest of them.
    static func decode(_ data: Data) -> [ProviderAccount] {
        let decoder = JSONDecoder()
        if let accounts = try? decoder.decode([ProviderAccount].self, from: data) {
            return accounts
        }
        guard let elements = try? decoder.decode([FailableAccount].self, from: data) else {
            return []
        }
        return elements.compactMap(\.account)
    }

    static func save(_ accounts: [ProviderAccount], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private struct FailableAccount: Decodable {
        let account: ProviderAccount?

        init(from decoder: Decoder) throws {
            account = try? ProviderAccount(from: decoder)
        }
    }

    /// A name that does not collide with the provider's other accounts, so two
    /// "Claude — Work" rows can never appear in the picker.
    static func uniqueName(
        _ proposed: String,
        kind: ProviderKind,
        existing: [ProviderAccount],
        excluding excludedID: UUID? = nil
    ) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(
            existing
                .filter { $0.id != excludedID && $0.kind == kind }
                .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        guard taken.contains(trimmed.lowercased()) else { return trimmed }
        for suffix in 2...99 {
            let candidate = trimmed.isEmpty ? "\(suffix)" : "\(trimmed) \(suffix)"
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        return trimmed
    }

    /// Turns the single pre-accounts remote endpoint into a `.custom` account.
    ///
    /// Returns nil when there is nothing to migrate. The key is not copied: the
    /// new account points at the existing credential entry, so an interrupted
    /// migration cannot lose it.
    static func migrateLegacyEndpoint(settings: AppSettings, existing: [ProviderAccount])
        -> ProviderAccount?
    {
        guard existing.isEmpty else { return nil }
        let base = settings.remoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty || CredentialStore.has(account: CredentialStore.remoteAPIKeyAccount) else {
            return nil
        }
        var account = ProviderAccount(
            kind: .custom,
            name: "",
            baseURLOverride: base,
            preferredModel: settings.remoteModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        account.legacyKeychainAccount = CredentialStore.remoteAPIKeyAccount
        return account
    }
}

/// How an account is doing, for the Settings row and the picker.
enum ProviderAccountStatus: Equatable {
    case signingIn
    case signedIn(email: String?, plan: String?)
    case signedOut
    case runtimeUnavailable(String)
    case rateLimited(resetAt: Date?)
    /// A key is saved but nothing has confirmed it yet.
    case keySaved
    /// The provider answered — `models` is what it offered.
    case connected(models: Int)
    /// The endpoint rejected the key.
    case keyRejected
    /// Something else went wrong; the message is the provider's.
    case failed(String)
    /// No key at all.
    case noKey

    var summary: String {
        switch self {
        case .signingIn: "Waiting for ChatGPT sign-in"
        case let .signedIn(email, plan):
            {
                let details = [email, plan?.capitalized]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                return details.isEmpty ? "Signed in" : details
            }()
        case .signedOut: "Not signed in"
        case let .runtimeUnavailable(message): message
        case let .rateLimited(resetAt):
            resetAt.map { "Limit reached · resets \($0.formatted(.relative(presentation: .named)))" }
                ?? "ChatGPT plan limit reached"
        case .keySaved: "Key saved"
        case let .connected(models):
            models == 1 ? "Connected · 1 model" : "Connected · \(models) models"
        case .keyRejected: "The endpoint rejected the API key"
        case let .failed(message): message
        case .noKey: "No API key"
        }
    }

    var isHealthy: Bool {
        switch self {
        case .connected, .keySaved, .signedIn: true
        case .signingIn, .signedOut, .runtimeUnavailable, .rateLimited,
             .keyRejected, .failed, .noKey: false
        }
    }
}

/// One group in the model picker: local Ollama, or one account.
struct ModelPickerSection: Identifiable {
    /// nil for the local section.
    let account: ProviderAccount?
    let title: String
    let models: [String]
    /// Shown as a disabled row when there is nothing to choose.
    let emptyMessage: String?

    var id: String { account?.id.uuidString ?? "local" }

    static func build(
        localModels: [String],
        accounts: [ProviderAccount],
        accountModels: [UUID: [String]],
        accountStatus: [UUID: ProviderAccountStatus]
    ) -> [ModelPickerSection] {
        var sections = [
            ModelPickerSection(
                account: nil,
                title: "Local (Ollama)",
                models: localModels,
                emptyMessage: localModels.isEmpty ? "No Ollama models found" : nil
            )
        ]
        for account in accounts {
            let models = accountModels[account.id] ?? []
            let empty: String?
            if !models.isEmpty {
                empty = nil
            } else {
                switch accountStatus[account.id] {
                case .keyRejected: empty = "Check the API key in Settings"
                case let .failed(message): empty = message
                case .noKey: empty = "Add an API key in Settings"
                default: empty = "No models available"
                }
            }
            sections.append(
                ModelPickerSection(
                    account: account,
                    title: account.displayName,
                    models: models,
                    emptyMessage: empty
                )
            )
        }
        return sections
    }
}
