import Combine
import Foundation

/// A divider tracks the width that is actually on screen, which may be smaller
/// than the saved preference in a compact window. Capture it once per gesture
/// so subsequent layout updates cannot compound the pointer translation.
struct InspectorResizeDrag {
    private var startWidth: CGFloat?

    mutating func width(renderedWidth: CGFloat, translation: CGFloat, zoomed: Bool) -> CGFloat {
        if startWidth == nil { startWidth = renderedWidth }
        return (startWidth ?? renderedWidth) + (zoomed ? translation : -translation)
    }

    mutating func end() { startWidth = nil }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case plan
    /// The persistent-agent overview. Session-scoped like Overview, so it is
    /// a rail destination in Agents mode rather than a workspace panel.
    case agent
    case changes
    case files
    case terminal
    case preview
    case simulator
    case notes
    case calendar
    case board
    case checkpoints
    case runs
    case agents
    case router
    case proxies
    case context

    var id: String { rawValue }

    /// The general workspace panels reached from the inspector command. Overview
    /// and Browser have dedicated rail buttons and open only when explicitly
    /// requested (or when an active request needs them).
    static let workspaceTabs: [InspectorTab] = [
        .changes, .files, .terminal, .simulator, .notes, .calendar, .board, .runs,
        .agents, .router, .proxies, .context,
    ]

    var isWorkspaceTab: Bool { Self.workspaceTabs.contains(self) }

    /// The visible label. Kept separate from `rawValue`, which is reserved for
    /// the accessibility identifier and the persisted preference — so copy can
    /// change without breaking either.
    var title: String {
        switch self {
        case .plan: "Overview"
        case .agent: "Agent"
        case .changes: "Changes"
        case .files: "Files"
        case .terminal: "Terminal"
        case .preview: "Browser"
        case .simulator: "Simulator"
        case .notes: "Notes"
        case .calendar: "Calendar"
        case .board: "Board"
        case .checkpoints: "Checkpoints"
        case .runs: "Runs"
        case .agents: "Instructions"
        case .router: "Router"
        case .proxies: "Proxies"
        case .context: "Context"
        }
    }

    /// Explain scope at the point of navigation: Agent covers an assistant,
    /// Overview covers the open conversation, and Instructions covers a file.
    var help: String {
        let detail: String
        switch self {
        case .plan: detail = "Open this chat’s plan, outputs, and sources in a popup"
        case .agent: detail = "Selected agent: trigger, access, chats, and activity"
        case .notes: detail = "Editable notes shared at the scope you choose"
        case .calendar: detail = "Events from Calendar, Google, and Microsoft accounts"
        case .board: detail = "Kanban cards you and your agents plan, move, and discuss"
        case .agents: detail = "Workspace instructions in AGENTS.md"
        case .runs: detail = "This chat’s saved executions, progress, and failures"
        case .changes: detail = "Review workspace file changes"
        case .files: detail = "Browse files and outputs in this workspace"
        case .terminal: detail = "Workspace terminal and background processes"
        case .preview: detail = "Browse and inspect web pages"
        case .simulator: detail = "Control the iOS simulator"
        case .checkpoints: detail = "Restore an earlier workspace checkpoint"
        case .router: detail = "Model routing and provider decisions"
        case .proxies: detail = "Network proxy routes and connection health"
        case .context: detail = "Context window usage and files attached to this chat"
        }
        return "\(title) — \(detail)" + (shortcutKey.map { " (⌘\($0))" } ?? "")
    }

    var symbol: String {
        switch self {
        case .plan: "rectangle.grid.2x2"
        case .agent: LocusSymbol.robot
        case .changes: "plusminus.circle"
        case .files: "folder"
        case .terminal: "terminal"
        case .preview: "globe"
        case .simulator: "ipad.and.iphone"
        case .notes: "note.text"
        case .calendar: "calendar"
        case .board: "rectangle.split.3x1"
        case .checkpoints: "clock.arrow.circlepath"
        // Runs stopped being Teams-only; the three-node orchestration graph
        // now belongs to the team dispatcher alone.
        case .runs: "play.square.stack"
        case .agents: "doc.text.fill"
        case .router: "arrow.triangle.branch"
        case .proxies: "network.badge.shield.half.filled"
        case .context: "circle.dotted.circle"
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
        case .agent, .simulator, .calendar, .board, .router, .proxies, .context: nil
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
    case runtimes = "Runtimes"
    case knowledge = "Memory & Knowledge"
    case browser = "Browser"
    #if LOCUS_WALLET
    case wallet = "Wallets"
    #endif
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
        #if LOCUS_WALLET
        case .wallet: "wallet.bifold"
        #endif
        case .accounts: "person.crop.circle"
        case .agents: "person.3.sequence.fill"
        case .runtimes: "server.rack"
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
        case .accounts, .agents, .knowledge, .runtimes: .models
        case .browser, .extensions, .permissions, .network: .tools
        #if LOCUS_WALLET
        case .wallet: .tools
        #endif
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
        case .runtimes: "Independent agents and remote execution"
        case .knowledge: "Workspace memory, indexing, and handoffs"
        case .browser: "Built-in browsing, input, and privacy"
        #if LOCUS_WALLET
        case .wallet: "Your vault, connected accounts, and transaction approvals"
        #endif
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
        .init("settings.maximumActiveChats", page: .general, title: "Parallel chats and agent events", keywords: ["concurrency", "queue", "automations", "worktrees"]),
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
            keywords: ["microphone", "push to talk", "spoken replies"]
        ),
        .init(
            "settings.audioAccounts", page: .accounts, title: "Audio accounts",
            keywords: ["speech engine", "transcription", "voice provider", "OpenAI audio", "TTS"]
        ),
        .init("settings.accounts.add", page: .accounts, title: "Provider accounts", keywords: ["API", "model", "Ollama"]),
        .init("settings.localContextWindow", page: .accounts, title: "Local context window", keywords: ["tokens", "Ollama"], isAdvanced: true),
        .init(
            "settings.imageGeneration",
            page: .accounts,
            title: "Image generation",
            keywords: ["images", "pictures", "generate", "edit image", "gpt-image", "OpenAI", "interactive answers", "widgets"]
        ),
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
    ] + editionDescriptors

    #if LOCUS_WALLET
    private static let editionDescriptors: [SettingsSearchDescriptor] = [
        .init("settings.wallet.status", page: .wallet, title: "Locus Vault", keywords: ["crypto", "account", "lock", "unlock"]),
        .init("settings.wallet.connectors", page: .wallet, title: "External wallets", keywords: ["Phantom", "MetaMask", "Slush", "Sui", "Solana", "EVM"]),
        .init("settings.wallet.rpc-url", page: .wallet, title: "Wallet network connection", keywords: ["Sepolia", "RPC", "endpoint"], isAdvanced: true),
        .init("settings.wallet.policies", page: .wallet, title: "Wallet budgets and contracts", keywords: ["ABI", "registry", "policy"], isAdvanced: true),
    ]
    #else
    private static let editionDescriptors: [SettingsSearchDescriptor] = []
    #endif
}

struct AutomaticInspectorPrompt: Equatable {
    let tab: InspectorTab
    let runID: String?

    var isTeamRun: Bool { tab == .runs }

    var title: String {
        isTeamRun
            ? "Open Runs for team requests?"
            : "Open Overview for solo requests?"
    }

    var message: String {
        if isTeamRun {
            return "Locus can open Runs whenever you send a team request so you can follow its agents and progress. You can change this anytime in Settings → General → Conversation."
        }
        return "Locus can show the Overview popup whenever you send a solo Work request so you can follow the plan, outputs, and sources. Context usage is available in the Context panel. You can change this anytime in Settings → General → Conversation."
    }

    var confirmationTitle: String {
        isTeamRun ? "Open Runs Every Time" : "Open Overview Every Time"
    }
}

struct RunsNavigationRequest: Equatable, Identifiable {
    let id = UUID()
    let runID: String
}
