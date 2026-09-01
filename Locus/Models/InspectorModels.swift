import Combine
import Foundation

enum InspectorTab: String, CaseIterable, Identifiable {
    case plan
    case changes
    case files
    case terminal
    case preview
    case simulator
    case notes
    case checkpoints
    case runs
    case agents
    case router
    case proxies

    var id: String { rawValue }

    /// The general workspace panels reached from the inspector command. Overview
    /// and Browser have dedicated rail buttons and open only when explicitly
    /// requested (or when an active request needs them).
    static let workspaceTabs: [InspectorTab] = [
        .changes, .files, .terminal, .simulator, .notes, .runs, .agents,
        .router, .proxies,
    ]

    var isWorkspaceTab: Bool { Self.workspaceTabs.contains(self) }

    /// The visible label. Kept separate from `rawValue`, which is reserved for
    /// the accessibility identifier and the persisted preference — so copy can
    /// change without breaking either.
    var title: String {
        switch self {
        case .plan: "Overview"
        case .changes: "Changes"
        case .files: "Files"
        case .terminal: "Terminal"
        case .preview: "Browser"
        case .simulator: "Simulator"
        case .notes: "Notes"
        case .checkpoints: "Checkpoints"
        case .runs: "Runs"
        case .agents: "AGENTS.md"
        case .router: "Router"
        case .proxies: "Proxies"
        }
    }

    var symbol: String {
        switch self {
        case .plan: "rectangle.grid.2x2"
        case .changes: "plusminus.circle"
        case .files: "folder"
        case .terminal: "terminal"
        case .preview: "globe"
        case .simulator: "ipad.and.iphone"
        case .notes: "note.text"
        case .checkpoints: "clock.arrow.circlepath"
        // Runs stopped being Teams-only; the three-node orchestration graph
        // now belongs to the team dispatcher alone.
        case .runs: "play.square.stack"
        case .agents: "doc.text.fill"
        case .router: "arrow.triangle.branch"
        case .proxies: "network.badge.shield.half.filled"
        }
    }

    /// Existing number bindings remain stable. ⌘6 opens the on-demand manual
    /// checkpoint manager rather than a persistent inspector tab, and Notes
    /// uses ⌘9. New panels stay reachable from the rail without stealing ⌘0.
    var shortcutKey: Character? {
        switch self {
        case .plan: "1"
        case .changes: "2"
        case .files: "3"
        case .terminal: "4"
        case .preview: "5"
        case .checkpoints: "6"
        case .runs: "7"
        case .agents: "8"
        case .notes: "9"
        case .simulator, .router, .proxies: nil
        }
    }
}

enum SettingsNavigationGroup: String, CaseIterable, Identifiable {
    case app = "App"
    case models = "Models"
    case tools = "Tools"
    case system = "System"

    var id: String { rawValue }
}

enum SettingsMutationPolicy: Equatable {
    case immediate
    case staged
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case chat = "Chat"
    case accounts = "Models & Providers"
    case agents = "Agents & Teams"
    case knowledge = "Memory & Knowledge"
    case browser = "Browser"
    case wallet = "Wallets"
    case extensions = "Extensions"
    case permissions = "Permissions"
    case network = "Network"
    case developer = "Developer"
    case updates = "Updates"
    case shortcuts = "Keyboard Shortcuts"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .chat: "bubble.left.and.bubble.right"
        case .network: "network"
        case .browser: "globe"
        case .wallet: "wallet.bifold"
        case .accounts: "person.crop.circle"
        case .agents: "person.3.sequence.fill"
        case .knowledge: "books.vertical.fill"
        case .permissions: "lock.shield"
        case .extensions: "puzzlepiece.extension"
        case .developer: "hammer"
        case .updates: "arrow.triangle.2.circlepath"
        case .shortcuts: "keyboard"
        }
    }

    var accessibilityKey: String {
        switch self {
        case .accounts: "accounts"
        case .agents: "agents"
        case .knowledge: "knowledge"
        case .shortcuts: "shortcuts"
        default: rawValue.lowercased()
        }
    }

    var navigationGroup: SettingsNavigationGroup {
        switch self {
        case .general, .appearance, .chat: .app
        case .accounts, .agents, .knowledge: .models
        case .browser, .wallet, .extensions, .permissions, .network: .tools
        case .developer, .updates, .shortcuts: .system
        }
    }

    var mutationPolicy: SettingsMutationPolicy {
        switch self {
        case .accounts, .network, .developer: .staged
        default: .immediate
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup, background work, companion access, and notifications"
        case .appearance: "Theme and workspace presentation"
        case .chat: "Conversation display, notes, and automatic panels"
        case .accounts: "Local models and hosted model connections"
        case .agents: "Profiles, teams, routing, and evaluation"
        case .knowledge: "Workspace memory, indexing, and handoffs"
        case .browser: "Built-in browsing, input, and privacy"
        case .wallet: "Locus Vault, transaction policies, and external approval wallets"
        case .extensions: "Skills and MCP integrations"
        case .permissions: "Agent authority and macOS access"
        case .network: "Proxy routing and connection security"
        case .developer: "Runtime, terminal, and diagnostic controls"
        case .updates: "Installed components and software updates"
        case .shortcuts: "Keyboard access for the full workspace"
        }
    }
}

struct SettingsSearchDescriptor: Identifiable, Hashable {
    let id: String
    let page: SettingsPage
    let title: String
    let keywords: [String]
    let anchor: String
    let isAdvanced: Bool

    init(
        _ id: String,
        page: SettingsPage,
        title: String,
        keywords: [String] = [],
        anchor: String? = nil,
        isAdvanced: Bool = false
    ) {
        self.id = id
        self.page = page
        self.title = title
        self.keywords = keywords
        self.anchor = anchor ?? id
        self.isAdvanced = isAdvanced
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return ([title, page.rawValue] + keywords)
            .contains { $0.lowercased().contains(needle) }
    }

    static let all: [SettingsSearchDescriptor] = [
        .init("settings.launchAtLogin", page: .general, title: "Launch at login", keywords: ["startup", "menu bar"]),
        .init("settings.maximumActiveChats", page: .general, title: "Background chats", keywords: ["concurrency", "worktrees"]),
        .init("settings.appearance", page: .appearance, title: "Appearance", keywords: ["light", "dark", "system"]),
        .init("settings.accentColor", page: .appearance, title: "Accent colour", keywords: ["logo", "brand", "lime", "green", "dark green", "blue", "purple", "orange", "pink", "neutral", "grey", "gray", "custom"]),
        .init("settings.showTeamProgressInHeader", page: .appearance, title: "Header status", keywords: ["team", "context usage"]),
        .init("settings.notesScope", page: .chat, title: "Conversation notes", keywords: ["workspace", "scratchpad"]),
        .init("settings.thinkingVisibility", page: .chat, title: "Reasoning display", keywords: ["thinking", "collapsed"]),
        .init("settings.toolActivityVisibility", page: .chat, title: "Tool activity display", keywords: ["tools", "collapsed"]),
        .init(
            "settings.voice",
            page: .chat,
            title: "Voice and dictation",
            keywords: ["microphone", "speech", "push to talk", "transcription", "spoken replies", "OpenAI audio"]
        ),
        .init("settings.accounts.add", page: .accounts, title: "Provider accounts", keywords: ["API", "model", "Ollama"]),
        .init("settings.wallet.status", page: .wallet, title: "Locus Vault", keywords: ["crypto", "account", "lock", "unlock"]),
        .init("settings.wallet.connectors", page: .wallet, title: "External wallets", keywords: ["Phantom", "MetaMask", "Slush", "Sui", "Solana", "EVM"]),
        .init("settings.wallet.rpc-url", page: .wallet, title: "Wallet network connection", keywords: ["Sepolia", "RPC", "endpoint"], isAdvanced: true),
        .init("settings.wallet.policies", page: .wallet, title: "Wallet budgets and contracts", keywords: ["ABI", "registry", "policy"], isAdvanced: true),
        .init("settings.localContextWindow", page: .accounts, title: "Local context window", keywords: ["tokens", "Ollama"], isAdvanced: true),
        .init("settings.agents.primary", page: .agents, title: "Primary agent", keywords: ["behavior", "model"]),
        .init("settings.agents.quickTeam", page: .agents, title: "Create a quick team", keywords: ["dispatcher", "specialist"]),
        .init("settings.agents.scheduler", page: .agents, title: "Agent scheduler", keywords: ["concurrency", "simultaneous"], isAdvanced: true),
        .init("settings.agents.evaluations", page: .agents, title: "Evaluation Lab", keywords: ["suite", "benchmark"], isAdvanced: true),
        .init("settings.memory.saved", page: .knowledge, title: "Saved memory", keywords: ["approved", "remember", "inbox"]),
        .init("settings.memory.context", page: .knowledge, title: "Cross-chat handoffs", keywords: ["snapshots", "context"]),
        .init("settings.memory.index", page: .knowledge, title: "Workspace search index", keywords: ["knowledge", "Ollama", "embedding"], isAdvanced: true),
        .init("settings.memory.health", page: .knowledge, title: "Memory health", keywords: ["diagnostics", "maintenance"], isAdvanced: true),
        .init("settings.browserEnabled", page: .browser, title: "Built-in browser", keywords: ["web", "privacy"]),
        .init("settings.browser.passwords", page: .browser, title: "Passwords and Autofill", keywords: ["login", "credentials", "save", "fill"]),
        .init("settings.browser.contacts", page: .browser, title: "Contact information", keywords: ["address", "email", "phone", "autofill"]),
        .init("settings.browser.cards", page: .browser, title: "Payment cards", keywords: ["credit card", "billing", "autofill", "CVV"]),
        .init("settings.browser.history", page: .browser, title: "Browsing history", keywords: ["visits", "search", "agent access", "clear"]),
        .init("settings.browser.downloads", page: .browser, title: "Downloads", keywords: ["destination", "folder", "pause", "resume"]),
        .init("settings.browser.permissions", page: .browser, title: "Site permissions", keywords: ["camera", "microphone", "popups", "JavaScript", "uploads"]),
        .init("settings.browser.siteData", page: .browser, title: "Cookies and site data", keywords: ["cache", "storage", "clear"]),
        .init("settings.browser.import", page: .browser, title: "Import browser data", keywords: ["CSV", "vCard", "JSON"]),
        .init("settings.browser.webInspector", page: .browser, title: "Browser Web Inspector", keywords: ["developer", "debug"], isAdvanced: true),
        .init("settings.permissionMode", page: .permissions, title: "Agent permissions", keywords: ["approval", "full access"]),
        .init("settings.proxyMode", page: .network, title: "Outbound proxy", keywords: ["SOCKS5", "HTTP", "network"]),
        .init("settings.maxIterations", page: .developer, title: "Maximum tool steps", keywords: ["agent", "iterations"], isAdvanced: true),
        .init("settings.terminalShell", page: .developer, title: "Terminal shell", keywords: ["zsh", "login"], isAdvanced: true),
        .init("settings.backendURL", page: .developer, title: "Local agent runtime", keywords: ["backend", "diagnostics"], isAdvanced: true),
        .init("settings.automaticUpdateChecks", page: .updates, title: "Software updates", keywords: ["automatic", "version"]),
        .init("settings.shortcuts", page: .shortcuts, title: "Keyboard shortcuts", keywords: ["commands", "hotkeys"]),
    ]
}

enum LocusProjectKind: String, Equatable {
    case swift
    case web
    case python
    case general
}

enum LocusRecommendationKind: String, Equatable {
    case chooseModel
    case recoverRun
    case reviewMemory
    case reviewChanges
    case continuePlan
    case verifyTests
    case exploreProject
    case makePlan
    case polishInterface
    case legacy

    var symbol: String {
        switch self {
        case .chooseModel: "cpu"
        case .recoverRun: "arrow.clockwise.circle"
        case .reviewMemory: "brain.head.profile"
        case .reviewChanges: "plusminus.circle"
        case .continuePlan: "list.bullet.clipboard"
        case .verifyTests: "checkmark.seal"
        case .exploreProject: "doc.text.magnifyingglass"
        case .makePlan: "checklist"
        case .polishInterface: "sparkles"
        case .legacy: "arrow.turn.down.right"
        }
    }
}

enum LocusRecommendationIntent: Equatable {
    case prefill(String)
    case openInspector(InspectorTab)
    case openSettings(SettingsPage)
    case openModelLibrary
}

struct LocusRecommendation: Identifiable, Equatable {
    let id: String
    let kind: LocusRecommendationKind
    let title: String
    let rationale: String
    let priority: Int
    let intent: LocusRecommendationIntent
}

/// A value-only snapshot keeps ranking deterministic and unit-testable. It is
/// deliberately assembled from state the app already owns; producing a list
/// can never contact a provider or start a background fetch.
struct RecommendationContext: Equatable {
    var runtimeUnavailable = false
    var modelUnavailable = false
    var lastRunFailed = false
    var changedFileCount = 0
    var hasPendingPlanSteps = false
    var hasTestFiles = false
    var projectKind: LocusProjectKind = .general
    var memoryConflictCount = 0
    var legacySuggestions: [String] = []
}

enum RecommendationEngine {
    static func recommendations(for context: RecommendationContext) -> [LocusRecommendation] {
        var candidates: [LocusRecommendation] = []

        if context.runtimeUnavailable || context.modelUnavailable {
            candidates.append(LocusRecommendation(
                id: "choose-model",
                kind: .chooseModel,
                title: "Choose a ready model",
                rationale: context.runtimeUnavailable
                    ? "Local services need attention before Locus can start work."
                    : "The selected model is not currently available.",
                priority: 1_000,
                intent: .openSettings(.accounts)
            ))
        }

        if context.lastRunFailed {
            candidates.append(LocusRecommendation(
                id: "recover-run",
                kind: .recoverRun,
                title: "Review the failure and retry safely",
                rationale: "The last run stopped before it completed.",
                priority: 950,
                intent: .prefill("Review the last run's error, explain the cause, and retry only the failed work.")
            ))
        }

        if context.memoryConflictCount > 0 {
            let count = context.memoryConflictCount
            candidates.append(LocusRecommendation(
                id: "review-memory",
                kind: .reviewMemory,
                title: "Review memory conflicts",
                rationale: "\(count) suggestion\(count == 1 ? "" : "s") need your decision before approval.",
                priority: 900,
                intent: .openSettings(.knowledge)
            ))
        }

        if context.changedFileCount > 0 {
            let count = context.changedFileCount
            candidates.append(LocusRecommendation(
                id: "review-changes",
                kind: .reviewChanges,
                title: "Review the current changes",
                rationale: "\(count) file\(count == 1 ? " has" : "s have") unreviewed edits.",
                priority: 800,
                intent: .openInspector(.changes)
            ))
        }

        if context.hasPendingPlanSteps {
            candidates.append(LocusRecommendation(
                id: "continue-plan",
                kind: .continuePlan,
                title: "Continue the remaining plan",
                rationale: "This session still has incomplete steps.",
                priority: 700,
                intent: .prefill("Continue the remaining plan steps. Verify each completed step before moving on.")
            ))
        }

        if context.hasTestFiles && context.changedFileCount > 0 {
            candidates.append(LocusRecommendation(
                id: "verify-tests",
                kind: .verifyTests,
                title: "Run the relevant tests",
                rationale: "This project has tests and the workspace contains changes.",
                priority: 600,
                intent: .prefill("Run the tests relevant to the current changes, investigate any failures, and report the result.")
            ))
        }

        for (index, raw) in context.legacySuggestions.enumerated() {
            let suggestion = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suggestion.isEmpty else { continue }
            candidates.append(LocusRecommendation(
                id: "legacy-\(index)",
                kind: .legacy,
                title: suggestion,
                rationale: "Suggested from the previous session state.",
                priority: 500 - index,
                intent: .prefill(suggestion)
            ))
        }

        let discovery: (String, String, String) = switch context.projectKind {
        case .swift:
            (
                "Audit the Swift architecture",
                "This workspace contains Swift sources.",
                "Audit this Swift project and identify the three highest-risk architectural or concurrency areas."
            )
        case .web:
            (
                "Polish the primary interface",
                "This workspace contains a web application.",
                "Polish the primary interface without changing its behavior, and verify the result in the browser."
            )
        case .python:
            (
                "Map the Python service and its risks",
                "This workspace contains a Python project.",
                "Map this Python project and identify the three highest-risk reliability or maintenance areas."
            )
        case .general:
            (
                "Audit the project’s highest-risk areas",
                "A focused audit is a useful first step for this workspace.",
                "Audit this project and identify the three highest-risk areas."
            )
        }
        candidates.append(LocusRecommendation(
            id: "explore-project",
            kind: .exploreProject,
            title: discovery.0,
            rationale: discovery.1,
            priority: 300,
            intent: .prefill(discovery.2)
        ))
        candidates.append(LocusRecommendation(
            id: "make-plan",
            kind: .makePlan,
            title: "Turn outstanding work into a plan",
            rationale: "Planning first keeps implementation focused and reviewable.",
            priority: 200,
            intent: .prefill("Find the outstanding work in this project and turn it into a prioritized implementation plan.")
        ))
        candidates.append(LocusRecommendation(
            id: "polish-interface",
            kind: .polishInterface,
            title: "Polish an existing interface",
            rationale: "Improve clarity and craft without changing behavior.",
            priority: 100,
            intent: .prefill("Polish an existing interface without changing its behavior.")
        ))

        var seenKinds = Set<LocusRecommendationKind>()
        return candidates
            .sorted {
                $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority
            }
            .filter { seenKinds.insert($0.kind).inserted }
            .prefix(3)
            .map { $0 }
    }
}

struct AutomaticInspectorPrompt: Equatable {
    let tab: InspectorTab
    let runID: String?

    var isTeamRun: Bool { tab == .runs }

    var title: String {
        isTeamRun
            ? "Open Runs for team requests?"
            : "Open Context & Plan for solo requests?"
    }

    var message: String {
        if isTeamRun {
            return "Locus can open Runs whenever you send a team request so you can follow its agents and progress. You can change this anytime in Settings → General → Conversation."
        }
        return "Locus can open Context & Plan whenever you send a solo Work request so you can follow context use and the current plan. You can change this anytime in Settings → General → Conversation."
    }

    var confirmationTitle: String {
        isTeamRun ? "Open Runs Every Time" : "Open Context & Plan Every Time"
    }
}

struct RunsNavigationRequest: Equatable, Identifiable {
    let id = UUID()
    let runID: String
}
