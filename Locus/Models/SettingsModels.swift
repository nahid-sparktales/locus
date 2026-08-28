import Combine
import Foundation

enum ProxyMode: String, CaseIterable {
    case off
    case system
    case manual
}

enum ProxyType: String, CaseIterable {
    case http
    case socks5
}

/// Independently routable classes of network traffic. The main agent owns
/// model-provider calls, web tools, extensions, and its model-visible child
/// processes, so those stay one class until the agent can isolate them safely.
enum ProxyTrafficScope: String, Codable, CaseIterable, Identifiable {
    case app
    case browser
    case modelAndAgent = "model_agent"
    case downloads
    case gitAndTools = "git_tools"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "App requests"
        case .browser: "Browser"
        case .modelAndAgent: "Models & agent"
        case .downloads: "Downloads"
        case .gitAndTools: "Git & terminal tools"
        }
    }
}

/// A named endpoint in the proxy pool. The original single-proxy settings are
/// represented by `primaryID`; additional profiles live in AppSettings while
/// every password remains in CredentialStore under the immutable id.
struct ProxyProfile: Codable, Hashable, Identifiable {
    static let primaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var id: UUID
    var name: String
    var typeRaw: String
    var host: String
    var port: Int?
    var bypass: String
    var username: String
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "Proxy",
        type: ProxyType = .http,
        host: String = "",
        port: Int? = nil,
        bypass: String = "",
        username: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        typeRaw = type.rawValue
        self.host = host
        self.port = port
        self.bypass = bypass
        self.username = username
        self.enabled = enabled
    }

    var resolvedType: ProxyType { ProxyType(rawValue: typeRaw) ?? .http }
    var isConfigured: Bool {
        enabled && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && AppSettings.clampProxyPort(port) != nil
    }
}

struct ProxyHealthRecord: Identifiable, Equatable {
    let profileID: UUID
    let profileName: String
    let ok: Bool
    let latencyMilliseconds: Int?
    let exitIP: String?
    let location: String?
    let message: String
    let checkedAt: Date

    var id: UUID { profileID }
}

enum AutomaticInspectorPresentation: String, CaseIterable, Identifiable {
    case ask
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask the first time"
        case .always: "Every request"
        case .never: "Never"
        }
    }
}

/// Which conversation context owns the text shown in the Notes inspector.
///
/// The raw value is persisted instead of the enum itself so settings written
/// by a future build can fall back without invalidating every other setting.
enum NotesScope: String, CaseIterable, Identifiable {
    case workspace
    case chat
    case global

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .chat: "Each chat"
        case .global: "Everywhere"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .workspace: "Notes for this workspace"
        case .chat: "Notes for this chat"
        case .global: "Notes shared by every chat and workspace"
        }
    }

    /// Shown beside the notes editor, where the question is which document is
    /// open rather than which setting produced it.
    var documentTitle: String {
        switch self {
        case .workspace: "Workspace notes"
        case .chat: "Chat notes"
        case .global: "Shared notes"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: "folder"
        case .chat: "bubble.left"
        case .global: "globe"
        }
    }
}

struct AppSettings: Codable, Hashable {
    var backendURL = "http://127.0.0.1:8791"
    var backendRoot = NSString(string: "~/Documents/locus/agent").expandingTildeInPath
    var previewURL = "http://localhost:3000"
    var notifyOnCompletion = true
    var notifyOnNeedsAttention = true
    /// Registers the main application with macOS login items. Off by default;
    /// registration is applied only after Settings is saved successfully.
    var launchAtLogin = false
    /// A separately authenticated TLS gateway for the iOS/Android companion.
    /// It never exposes the loopback Python agent and is opt-in on every Mac.
    var mobileAccessEnabled = false
    /// Stored as a raw string so a preference written by a future version
    /// cannot make the rest of the settings payload fail to decode.
    var appearanceRaw = AppAppearance.system.rawValue
    /// Five stable presets plus a separately stored custom swatch. Keeping the
    /// raw value tolerant lets a newer build add presets without resetting the
    /// rest of a person's settings in an older build.
    var accentPresetRaw = LocusAccentPreset.lime.rawValue
    var customAccentHex = LocusAccentSelection.defaultCustomHex
    /// Settings use progressive disclosure like a studio application. Raw
    /// storage keeps future levels from invalidating the remaining payload.
    var settingsLevelRaw = SettingsLevel.standard.rawValue
    var provider: ModelProvider = .ollama
    /// Endpoint base URL. The API key is not stored here — see `CredentialStore`.
    ///
    /// Superseded by provider accounts: the migration moves this into a
    /// `.custom` account on first launch. Kept so a downgrade still decodes.
    var remoteBaseURL = ""
    var remoteModel = ""
    /// The provider account in use, as a UUID string, or nil for local Ollama.
    /// The accounts themselves live under `ProviderAccountStore.defaultsKey` —
    /// they carry credential-file side effects that must not ride the settings draft.
    var activeAccountID: String?
    /// A context window for local Ollama, when the user wants to pin one
    /// exactly rather than let Locus choose from the model's own ceiling.
    var localContextWindow: Int?
    /// Models hidden from Locus stay installed in Ollama and can be restored
    /// from Settings. Names are stored rather than model metadata so an Ollama
    /// refresh remains the source of truth for size and capabilities.
    var hiddenLocalModels: [String] = []
    /// Tool steps one turn may take. nil uses the agent's default of 40. Exposed
    /// because a bad value here is otherwise undiagnosable from inside the app:
    /// the turn just stops, and until this setting existed the only way to see
    /// or change the number was to hand-edit the agent's config file.
    var maxIterations: Int?
    /// Solo-message model routing is off until explicitly enabled. Hosted
    /// accounts require a second opt-in so enabling the router cannot move
    /// private work off the Mac by surprise.
    var automaticModelRoutingEnabled = false
    var automaticModelRoutingAllowHosted = false
    var modelRoutingPolicyRaw = ModelRoutingPolicy.balanced.rawValue
    /// The last route the person chose. Automatic choices never overwrite it,
    /// so disabling the router has a deterministic route to restore.
    var modelRouterFallbackAccountID: String?
    var modelRouterFallbackModel = ""
    var inspectorWidth: Double = AppSettings.defaultInspectorWidth
    /// Preferred width of the conversations/workspaces sidebar. Layout may
    /// temporarily render it narrower in a compact window without overwriting
    /// this preference.
    var sidebarWidth: Double = AppSettings.defaultSidebarWidth
    /// The chat column's width while the panel is zoomed over the window.
    /// The zoom flag itself is deliberately not persisted — it is a focus
    /// mode, and relaunch returns to the normal layout — but the width the
    /// user settled on is worth keeping.
    var inspectorZoomedChatWidth: Double = AppSettings.defaultZoomedChatWidth
    /// The inspector starts collapsed: the conversation is the point, and
    /// ⌘1–⌘8 or ⌘⌥I bring the panel back the moment it is needed.
    var inspectorCollapsed = true
    /// The session sidebar starts open, the way Claude keeps the
    /// conversation list at hand; ⌘0 collapses it for focus.
    var sidebarCollapsed = false
    /// Stored as a raw string, not the enum: an unknown tab from a future
    /// version would otherwise fail the whole settings decode and reset
    /// everything else with it.
    var inspectorLastTab = InspectorTab.plan.rawValue
    /// The last non-Plan, non-Browser panel. The inspector command restores
    /// this value so it never opens a special-purpose surface by accident.
    var inspectorLastWorkspaceTab = InspectorTab.changes.rawValue
    /// Ordered raw values for the inspector's open, closable tabs. Strings
    /// keep settings written by a future version from breaking this one.
    var inspectorOpenTabs: [String] = []
    /// Legacy combined preference from the first implementation. It remains
    /// encoded so a settings file written by that build migrates cleanly; new
    /// UI writes the independent solo and team values below.
    var automaticInspectorPresentationRaw = AutomaticInspectorPresentation.ask.rawValue
    /// Whether a solo Work request should reveal Context & Plan.
    var soloPlanPresentationRaw = AutomaticInspectorPresentation.ask.rawValue
    /// Whether a team request should reveal Team Runs.
    var teamRunsPresentationRaw = AutomaticInspectorPresentation.ask.rawValue
    /// Raw string for the same forward-compatibility reason as the tab.
    var thinkingVisibilityRaw = ThinkingVisibility.collapsed.rawValue
    /// Compact by default so tool-heavy requests do not overwhelm the answer.
    /// Stored raw so a future mode cannot invalidate the rest of the settings.
    var toolActivityVisibilityRaw = ToolActivityVisibility.collapsed.rawValue
    /// Notes belong to the workspace by default, so useful project context is
    /// still present in a fresh chat. People who prefer scratchpads can scope
    /// them back to individual chats from General settings.
    var notesScopeRaw = NotesScope.workspace.rawValue
    /// Optional status controls stay out of the header until the user asks for
    /// them, leaving the widest possible title and model-selection area.
    var showTeamProgressInHeader = false
    var showContextUsageInHeader = false
    /// One-time compatibility marker: releases before adaptive Work persisted
    /// Build because an agentic mode was mandatory, not necessarily chosen.
    var adaptiveWorkMigrationCompleted = false
    /// Computer control is opt-in and is ignored in sandboxed builds.
    var computerControlEnabled = false
    /// Simulator tooling is enabled by the first explicit attach. It remains
    /// opt-in because screenshots can become model input and native helpers use
    /// Xcode's private simulator frameworks.
    var simulatorControlEnabled = false
    /// The browser is on by default and, unlike computer control, works in the
    /// sandboxed App Store build too — a web view needs no special access.
    var browserEnabled = true
    /// Public Sepolia RPC used only by the native wallet broker. It is never
    /// included in model context or sent to the Python agent.
    var walletSepoliaRPCURL = "https://ethereum-sepolia-rpc.publicnode.com"
    /// Raw string, like the tab: an unknown preset from a future version must
    /// not fail the whole settings decode.
    var browserViewportRaw = BrowserViewport.desktop.rawValue
    /// Cookies and logins survive relaunch only when the user opts in; the
    /// default forgets everything when the app quits, because an agent that
    /// can browse anywhere should not quietly accumulate a signed-in profile.
    var browserPersistProfile = false
    /// Real input is delivered as `NSEvent`s, so the page sees `isTrusted`
    /// input carrying a user gesture — which is what makes canvas surfaces and
    /// gesture-gated controls reachable, and equally what lets a clicked page
    /// open a popup or start playback. Off falls back to the synthetic bridge,
    /// which cannot do either.
    var browserRealInput = true
    /// Whether the mobile viewport also presents a mobile device: user agent,
    /// touch points, and coarse-pointer media queries. Resizing alone tests
    /// layout; this tests what the site actually serves a phone.
    var browserEmulateDevice = true
    /// Web Inspector lets any local process attach to the agent's pages and
    /// read their cookies and storage, so it is opt-in and off by default.
    var browserWebInspector = false
    /// Browser privacy settings use raw strings so a value written by a newer
    /// build cannot make the rest of the preferences payload fail to decode.
    var browserAutofillAuthModeRaw = BrowserAutofillAuthMode.session.rawValue
    var browserDownloadDestinationRaw = BrowserDownloadDestinationKind.systemDownloads.rawValue
    var browserDownloadAskEveryTime = false
    /// A security-scoped bookmark, never a plain path. Nil means the custom
    /// destination has not been granted access yet.
    var browserCustomDownloadBookmark: Data?
    var browserHistoryAccessRaw = BrowserHistoryAccess.disabled.rawValue
    var browserPresentationModeRaw = BrowserPresentationMode.fixedCanvas.rawValue
    var browserPageAppearanceRaw = BrowserPageAppearance.automatic.rawValue
    var browserJavaScriptPermissionRaw = BrowserPermissionDecision.allow.rawValue
    var browserUserDownloadPermissionRaw = BrowserPermissionDecision.allow.rawValue
    var browserAgentDownloadPermissionRaw = BrowserPermissionDecision.ask.rawValue
    var browserUploadPermissionRaw = BrowserPermissionDecision.ask.rawValue
    var browserPopupPermissionRaw = BrowserPermissionDecision.ask.rawValue
    var browserExternalPermissionRaw = BrowserPermissionDecision.ask.rawValue
    var browserCameraPermissionRaw = BrowserPermissionDecision.ask.rawValue
    var browserMicrophonePermissionRaw = BrowserPermissionDecision.ask.rawValue
    /// Where "Search in Google" on highlighted conversation text opens. Raw
    /// string for the same forward-compatibility reason as the viewport.
    var webSearchDestinationRaw = WebSearchDestination.defaultBrowser.rawValue
    /// Every executing chat owns a worker. This bounds active turns, not idle
    /// worker processes, and intentionally differs from per-team model calls.
    var maximumActiveChats = 2
    var worktreeRetentionLimit = 15
    var newGitChatsUseWorktree = true
    /// OpenTelemetry export is explicit and disabled by default. The user has
    /// chosen a plain local setting over Keychain prompts; the settings UI
    /// labels this authorization value as unencrypted.
    var otlpExportEnabled = false
    var otlpEndpoint = ""
    var otlpAuthorization = ""
    var otlpSamplingRate = 1.0
    /// Raw strings, like the tab: an unknown mode or type saved by a future
    /// version must not fail the whole settings decode.
    var proxyModeRaw = ProxyMode.off.rawValue
    var proxyTypeRaw = ProxyType.http.rawValue
    /// Hostname or IP only — a pasted scheme or path is stripped on save.
    var proxyHost = ""
    /// nil is "not configured", which manual mode refuses to save. There is no
    /// default port, because guessing one would silently send traffic somewhere.
    var proxyPort: Int?
    /// Comma- or space-separated hosts that connect directly. Loopback, the
    /// agent, and the Ollama host are always direct without being listed here.
    var proxyBypass = ""
    /// Non-empty means the proxy requires sign-in. The password is not stored
    /// in settings — see `CredentialStore.proxyPassword`.
    var proxyUsername = ""
    /// Named standby endpoints. The original fields above remain the primary
    /// profile for a lossless migration from every build before proxy pools.
    var proxyProfiles: [ProxyProfile] = []
    /// Empty or the primary id means the original fields are the default.
    var proxyActiveProfileID = ProxyProfile.primaryID.uuidString
    /// Strict applies only to Manual mode: external traffic is blocked if no
    /// configured/healthy endpoint exists, and custom bypass entries are ignored.
    var proxyStrictModeEnabled = false
    /// Enabled profiles become a failover pool. Health-ranked failover never
    /// falls through to a direct external connection.
    var proxyAutoFailoverEnabled = false
    /// Optional scope, workspace, and provider assignments. Values are profile
    /// UUID strings; invalid future values fall back to the default profile.
    var proxyScopeProfileIDs: [String: String] = [:]
    var proxyWorkspaceProfileIDs: [String: String] = [:]
    var proxyProviderProfileIDs: [String: String] = [:]
    /// Empty follows the user's SHELL and then falls back to /bin/zsh.
    var terminalShell = ""
    /// Login shells load the user's normal profile and PATH, matching
    /// Terminal.app rather than the old one-shot command runner.
    var terminalLoginShell = true
    /// One-time bridge from the version-1 backend config, where these two
    /// retained preferences lived before the Terminal became app-owned.
    var terminalSettingsMigrated = false
    /// Empty means this install has not chosen an app-wide permission mode yet
    /// and should adopt the backend's existing value. Once chosen, the mode is
    /// propagated to the main runtime and every chat worker.
    var permissionModeRaw = ""

    static let defaultInspectorWidth: Double = 340
    static let minimumInspectorWidth: Double = 280
    static let maximumInspectorWidth: Double = 520

    static func clampInspectorWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultInspectorWidth }
        return min(max(width, minimumInspectorWidth), maximumInspectorWidth)
    }

    static let defaultSidebarWidth: Double = 260
    static let minimumSidebarWidth: Double = 220
    static let maximumSidebarWidth: Double = 420

    static func clampSidebarWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultSidebarWidth }
        return min(max(width, minimumSidebarWidth), maximumSidebarWidth)
    }

    static func renderedSidebarWidth(_ preferred: Double, availableWidth: Double) -> Double {
        guard availableWidth.isFinite else { return clampSidebarWidth(preferred) }
        return min(clampSidebarWidth(preferred), max(availableWidth, 0))
    }

    static let defaultZoomedChatWidth: Double = 420
    static let minimumZoomedChatWidth: Double = 360
    static let maximumZoomedChatWidth: Double = 600

    static func clampZoomedChatWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultZoomedChatWidth }
        return min(max(width, minimumZoomedChatWidth), maximumZoomedChatWidth)
    }

    /// Ports outside 1...65535 read back as "not configured" rather than as a
    /// number the proxy layer would then try to dial.
    static func clampProxyPort(_ port: Int?) -> Int? {
        guard let port, (1...65535).contains(port) else { return nil }
        return port
    }

    static func clampMaximumActiveChats(_ value: Int) -> Int {
        min(max(value, 1), 4)
    }

    static func clampWorktreeRetentionLimit(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    static func clampOTLPSamplingRate(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }

    var resolvedInspectorTab: InspectorTab {
        let tab = InspectorTab(rawValue: inspectorLastTab) ?? .plan
        return tab == .checkpoints ? .plan : tab
    }

    var resolvedAppearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var resolvedAccent: LocusAccentSelection {
        let recognizedRawValue = LocusAccentPreset(rawValue: accentPresetRaw) != nil
            || accentPresetRaw == LocusAccentSelection.customRawValue
            ? accentPresetRaw
            : LocusAccentPreset.lime.rawValue
        return LocusAccentSelection(
            rawValue: recognizedRawValue,
            customHex: customAccentHex
        )
    }

    var resolvedSettingsLevel: SettingsLevel {
        SettingsLevel(rawValue: settingsLevelRaw) ?? .standard
    }

    mutating func applyImmediatePreferences(from draft: AppSettings) {
        settingsLevelRaw = draft.settingsLevelRaw
        appearanceRaw = draft.appearanceRaw
        accentPresetRaw = draft.accentPresetRaw
        customAccentHex = draft.customAccentHex
        showTeamProgressInHeader = draft.showTeamProgressInHeader
        showContextUsageInHeader = draft.showContextUsageInHeader
        notesScopeRaw = draft.notesScopeRaw
        soloPlanPresentationRaw = draft.soloPlanPresentationRaw
        teamRunsPresentationRaw = draft.teamRunsPresentationRaw
        thinkingVisibilityRaw = draft.thinkingVisibilityRaw
        toolActivityVisibilityRaw = draft.toolActivityVisibilityRaw
        maximumActiveChats = draft.maximumActiveChats
        worktreeRetentionLimit = draft.worktreeRetentionLimit
        newGitChatsUseWorktree = draft.newGitChatsUseWorktree
        launchAtLogin = draft.launchAtLogin
        mobileAccessEnabled = draft.mobileAccessEnabled
        notifyOnCompletion = draft.notifyOnCompletion
        notifyOnNeedsAttention = draft.notifyOnNeedsAttention
        browserEnabled = draft.browserEnabled
        walletSepoliaRPCURL = draft.walletSepoliaRPCURL
        previewURL = draft.previewURL
        browserViewportRaw = draft.browserViewportRaw
        browserPersistProfile = draft.browserPersistProfile
        browserRealInput = draft.browserRealInput
        browserEmulateDevice = draft.browserEmulateDevice
        browserWebInspector = draft.browserWebInspector
        browserAutofillAuthModeRaw = draft.browserAutofillAuthModeRaw
        browserDownloadDestinationRaw = draft.browserDownloadDestinationRaw
        browserDownloadAskEveryTime = draft.browserDownloadAskEveryTime
        browserCustomDownloadBookmark = draft.browserCustomDownloadBookmark
        browserHistoryAccessRaw = draft.browserHistoryAccessRaw
        browserPresentationModeRaw = draft.browserPresentationModeRaw
        browserPageAppearanceRaw = draft.browserPageAppearanceRaw
        browserJavaScriptPermissionRaw = draft.browserJavaScriptPermissionRaw
        browserUserDownloadPermissionRaw = draft.browserUserDownloadPermissionRaw
        browserAgentDownloadPermissionRaw = draft.browserAgentDownloadPermissionRaw
        browserUploadPermissionRaw = draft.browserUploadPermissionRaw
        browserPopupPermissionRaw = draft.browserPopupPermissionRaw
        browserExternalPermissionRaw = draft.browserExternalPermissionRaw
        browserCameraPermissionRaw = draft.browserCameraPermissionRaw
        browserMicrophonePermissionRaw = draft.browserMicrophonePermissionRaw
        webSearchDestinationRaw = draft.webSearchDestinationRaw
    }

    var resolvedInspectorWorkspaceTab: InspectorTab {
        let tab = InspectorTab(rawValue: inspectorLastWorkspaceTab) ?? .changes
        return tab.isWorkspaceTab ? tab : .changes
    }

    var resolvedInspectorOpenTabs: [InspectorTab] {
        var seen: Set<InspectorTab> = []
        return inspectorOpenTabs.compactMap { rawValue in
            guard let tab = InspectorTab(rawValue: rawValue),
                  tab != .checkpoints,
                  seen.insert(tab).inserted else {
                return nil
            }
            return tab
        }
    }

    var resolvedRestoredInspectorTab: InspectorTab {
        let openTabs = resolvedInspectorOpenTabs
        let selected = resolvedInspectorTab
        if openTabs.contains(selected) { return selected }
        if let first = openTabs.first { return first }
        return selected.isWorkspaceTab ? selected : resolvedInspectorWorkspaceTab
    }

    var resolvedAutomaticInspectorPresentation: AutomaticInspectorPresentation {
        AutomaticInspectorPresentation(rawValue: automaticInspectorPresentationRaw) ?? .ask
    }

    var resolvedSoloPlanPresentation: AutomaticInspectorPresentation {
        AutomaticInspectorPresentation(rawValue: soloPlanPresentationRaw) ?? .ask
    }

    var resolvedTeamRunsPresentation: AutomaticInspectorPresentation {
        AutomaticInspectorPresentation(rawValue: teamRunsPresentationRaw) ?? .ask
    }

    var resolvedBrowserViewport: BrowserViewport {
        BrowserViewport(rawValue: browserViewportRaw) ?? .desktop
    }

    var resolvedBrowserAutofillAuthMode: BrowserAutofillAuthMode {
        BrowserAutofillAuthMode(rawValue: browserAutofillAuthModeRaw) ?? .session
    }

    var resolvedBrowserDownloadDestination: BrowserDownloadDestinationKind {
        BrowserDownloadDestinationKind(rawValue: browserDownloadDestinationRaw) ?? .systemDownloads
    }

    var resolvedBrowserHistoryAccess: BrowserHistoryAccess {
        BrowserHistoryAccess(rawValue: browserHistoryAccessRaw) ?? .disabled
    }

    var resolvedBrowserPresentationMode: BrowserPresentationMode {
        BrowserPresentationMode(rawValue: browserPresentationModeRaw) ?? .fixedCanvas
    }

    var resolvedBrowserPageAppearance: BrowserPageAppearance {
        BrowserPageAppearance(rawValue: browserPageAppearanceRaw) ?? .automatic
    }

    var resolvedBrowserPermissionDefaults: [BrowserPermissionKind: BrowserPermissionDecision] {
        [
            .javascript: BrowserPermissionDecision(rawValue: browserJavaScriptPermissionRaw) ?? .allow,
            .userDownloads: BrowserPermissionDecision(rawValue: browserUserDownloadPermissionRaw) ?? .allow,
            .agentDownloads: BrowserPermissionDecision(rawValue: browserAgentDownloadPermissionRaw) ?? .ask,
            .fileUploads: BrowserPermissionDecision(rawValue: browserUploadPermissionRaw) ?? .ask,
            .popups: BrowserPermissionDecision(rawValue: browserPopupPermissionRaw) ?? .ask,
            .externalSchemes: BrowserPermissionDecision(rawValue: browserExternalPermissionRaw) ?? .ask,
            .camera: BrowserPermissionDecision(rawValue: browserCameraPermissionRaw) ?? .ask,
            .microphone: BrowserPermissionDecision(rawValue: browserMicrophonePermissionRaw) ?? .ask,
        ]
    }

    var resolvedWebSearchDestination: WebSearchDestination {
        WebSearchDestination(rawValue: webSearchDestinationRaw) ?? .defaultBrowser
    }

    var resolvedProxyMode: ProxyMode {
        ProxyMode(rawValue: proxyModeRaw) ?? .off
    }

    var resolvedProxyType: ProxyType {
        ProxyType(rawValue: proxyTypeRaw) ?? .http
    }

    var primaryProxyProfile: ProxyProfile {
        ProxyProfile(
            id: ProxyProfile.primaryID,
            name: "Default",
            type: resolvedProxyType,
            host: proxyHost,
            port: proxyPort,
            bypass: proxyBypass,
            username: proxyUsername,
            enabled: true
        )
    }

    var allProxyProfiles: [ProxyProfile] {
        var seen = Set<UUID>()
        return ([primaryProxyProfile] + proxyProfiles).filter { seen.insert($0.id).inserted }
    }

    var resolvedModelRoutingPolicy: ModelRoutingPolicy {
        ModelRoutingPolicy(rawValue: modelRoutingPolicyRaw) ?? .balanced
    }

    var resolvedThinkingVisibility: ThinkingVisibility {
        ThinkingVisibility(rawValue: thinkingVisibilityRaw) ?? .collapsed
    }

    var resolvedToolActivityVisibility: ToolActivityVisibility {
        ToolActivityVisibility(rawValue: toolActivityVisibilityRaw) ?? .collapsed
    }

    var resolvedNotesScope: NotesScope {
        NotesScope(rawValue: notesScopeRaw) ?? .workspace
    }

    var preferredPermissionMode: PermissionMode? {
        PermissionMode(rawValue: permissionModeRaw)
    }

    init() {}

    // Tolerant decoding so settings saved by older versions keep their values
    // when new fields are added instead of being reset to defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        backendURL = try container.decodeIfPresent(String.self, forKey: .backendURL) ?? defaults.backendURL
        backendRoot = try container.decodeIfPresent(String.self, forKey: .backendRoot) ?? defaults.backendRoot
        previewURL = try container.decodeIfPresent(String.self, forKey: .previewURL) ?? defaults.previewURL
        notifyOnCompletion = try container.decodeIfPresent(Bool.self, forKey: .notifyOnCompletion)
            ?? defaults.notifyOnCompletion
        notifyOnNeedsAttention = try container.decodeIfPresent(
            Bool.self, forKey: .notifyOnNeedsAttention
        ) ?? notifyOnCompletion
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? defaults.launchAtLogin
        mobileAccessEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .mobileAccessEnabled
        ) ?? defaults.mobileAccessEnabled
        appearanceRaw = try container.decodeIfPresent(String.self, forKey: .appearanceRaw)
            ?? defaults.appearanceRaw
        accentPresetRaw = try container.decodeIfPresent(String.self, forKey: .accentPresetRaw)
            ?? defaults.accentPresetRaw
        customAccentHex = try container.decodeIfPresent(String.self, forKey: .customAccentHex)
            ?? defaults.customAccentHex
        settingsLevelRaw = try container.decodeIfPresent(String.self, forKey: .settingsLevelRaw)
            ?? defaults.settingsLevelRaw
        provider = try container.decodeIfPresent(ModelProvider.self, forKey: .provider)
            ?? defaults.provider
        remoteBaseURL = try container.decodeIfPresent(String.self, forKey: .remoteBaseURL)
            ?? defaults.remoteBaseURL
        remoteModel = try container.decodeIfPresent(String.self, forKey: .remoteModel)
            ?? defaults.remoteModel
        activeAccountID = try container.decodeIfPresent(String.self, forKey: .activeAccountID)
            ?? defaults.activeAccountID
        localContextWindow = try container.decodeIfPresent(Int.self, forKey: .localContextWindow)
        hiddenLocalModels = try container.decodeIfPresent(
            [String].self,
            forKey: .hiddenLocalModels
        ) ?? defaults.hiddenLocalModels
        maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations)
        automaticModelRoutingEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .automaticModelRoutingEnabled
        ) ?? defaults.automaticModelRoutingEnabled
        automaticModelRoutingAllowHosted = try container.decodeIfPresent(
            Bool.self, forKey: .automaticModelRoutingAllowHosted
        ) ?? defaults.automaticModelRoutingAllowHosted
        modelRoutingPolicyRaw = try container.decodeIfPresent(
            String.self, forKey: .modelRoutingPolicyRaw
        ) ?? defaults.modelRoutingPolicyRaw
        modelRouterFallbackAccountID = try container.decodeIfPresent(
            String.self, forKey: .modelRouterFallbackAccountID
        ) ?? defaults.modelRouterFallbackAccountID
        modelRouterFallbackModel = try container.decodeIfPresent(
            String.self, forKey: .modelRouterFallbackModel
        ) ?? defaults.modelRouterFallbackModel
        // Clamped on the way in as well as on the way out: a corrupt or
        // out-of-range stored value must not produce an unusable panel.
        inspectorWidth = Self.clampInspectorWidth(
            try container.decodeIfPresent(Double.self, forKey: .inspectorWidth)
                ?? defaults.inspectorWidth
        )
        sidebarWidth = Self.clampSidebarWidth(
            try container.decodeIfPresent(Double.self, forKey: .sidebarWidth)
                ?? defaults.sidebarWidth
        )
        inspectorZoomedChatWidth = Self.clampZoomedChatWidth(
            try container.decodeIfPresent(Double.self, forKey: .inspectorZoomedChatWidth)
                ?? defaults.inspectorZoomedChatWidth
        )
        inspectorCollapsed = try container.decodeIfPresent(Bool.self, forKey: .inspectorCollapsed)
            ?? defaults.inspectorCollapsed
        sidebarCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed)
            ?? defaults.sidebarCollapsed
        inspectorLastTab = try container.decodeIfPresent(String.self, forKey: .inspectorLastTab)
            ?? defaults.inspectorLastTab
        inspectorLastWorkspaceTab = try container.decodeIfPresent(
            String.self,
            forKey: .inspectorLastWorkspaceTab
        ) ?? defaults.inspectorLastWorkspaceTab
        if container.contains(.inspectorOpenTabs) {
            // A malformed future value should lose only the tab restoration,
            // not the rest of the user's settings.
            inspectorOpenTabs = (try? container.decode([String].self, forKey: .inspectorOpenTabs))
                ?? []
            inspectorOpenTabs = resolvedInspectorOpenTabs.map(\.rawValue)
        } else {
            // Before tabs were dynamic, relaunch deliberately restored the
            // last general workspace panel instead of Plan or Browser.
            let last = InspectorTab(rawValue: inspectorLastTab)
            let legacy = last.flatMap { $0.isWorkspaceTab ? $0 : nil }
                ?? (InspectorTab(rawValue: inspectorLastWorkspaceTab) ?? .changes)
            inspectorOpenTabs = [legacy.rawValue]
        }
        automaticInspectorPresentationRaw = try container.decodeIfPresent(
            String.self,
            forKey: .automaticInspectorPresentationRaw
        ) ?? defaults.automaticInspectorPresentationRaw
        // Settings written before solo/team choices were split carry one
        // combined value. Use it for both new choices exactly once on decode.
        soloPlanPresentationRaw = try container.decodeIfPresent(
            String.self,
            forKey: .soloPlanPresentationRaw
        ) ?? automaticInspectorPresentationRaw
        teamRunsPresentationRaw = try container.decodeIfPresent(
            String.self,
            forKey: .teamRunsPresentationRaw
        ) ?? automaticInspectorPresentationRaw
        thinkingVisibilityRaw = try container.decodeIfPresent(String.self, forKey: .thinkingVisibilityRaw)
            ?? defaults.thinkingVisibilityRaw
        toolActivityVisibilityRaw = try container.decodeIfPresent(
            String.self,
            forKey: .toolActivityVisibilityRaw
        ) ?? defaults.toolActivityVisibilityRaw
        notesScopeRaw = try container.decodeIfPresent(String.self, forKey: .notesScopeRaw)
            ?? defaults.notesScopeRaw
        showTeamProgressInHeader = try container.decodeIfPresent(
            Bool.self,
            forKey: .showTeamProgressInHeader
        ) ?? defaults.showTeamProgressInHeader
        showContextUsageInHeader = try container.decodeIfPresent(
            Bool.self,
            forKey: .showContextUsageInHeader
        ) ?? defaults.showContextUsageInHeader
        adaptiveWorkMigrationCompleted = try container.decodeIfPresent(
            Bool.self,
            forKey: .adaptiveWorkMigrationCompleted
        ) ?? defaults.adaptiveWorkMigrationCompleted
        computerControlEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .computerControlEnabled
        ) ?? defaults.computerControlEnabled
        simulatorControlEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .simulatorControlEnabled
        ) ?? defaults.simulatorControlEnabled
        browserEnabled = try container.decodeIfPresent(Bool.self, forKey: .browserEnabled)
            ?? defaults.browserEnabled
        walletSepoliaRPCURL = try container.decodeIfPresent(
            String.self, forKey: .walletSepoliaRPCURL
        ) ?? defaults.walletSepoliaRPCURL
        browserViewportRaw = try container.decodeIfPresent(String.self, forKey: .browserViewportRaw)
            ?? defaults.browserViewportRaw
        browserPersistProfile = try container.decodeIfPresent(
            Bool.self,
            forKey: .browserPersistProfile
        ) ?? defaults.browserPersistProfile
        browserRealInput = try container.decodeIfPresent(Bool.self, forKey: .browserRealInput)
            ?? defaults.browserRealInput
        browserEmulateDevice = try container.decodeIfPresent(
            Bool.self,
            forKey: .browserEmulateDevice
        ) ?? defaults.browserEmulateDevice
        browserWebInspector = try container.decodeIfPresent(
            Bool.self,
            forKey: .browserWebInspector
        ) ?? defaults.browserWebInspector
        browserAutofillAuthModeRaw = try container.decodeIfPresent(
            String.self, forKey: .browserAutofillAuthModeRaw
        ) ?? defaults.browserAutofillAuthModeRaw
        browserDownloadDestinationRaw = try container.decodeIfPresent(
            String.self, forKey: .browserDownloadDestinationRaw
        ) ?? defaults.browserDownloadDestinationRaw
        browserDownloadAskEveryTime = try container.decodeIfPresent(
            Bool.self, forKey: .browserDownloadAskEveryTime
        ) ?? defaults.browserDownloadAskEveryTime
        browserCustomDownloadBookmark = try container.decodeIfPresent(
            Data.self, forKey: .browserCustomDownloadBookmark
        )
        browserHistoryAccessRaw = try container.decodeIfPresent(
            String.self, forKey: .browserHistoryAccessRaw
        ) ?? defaults.browserHistoryAccessRaw
        browserPresentationModeRaw = try container.decodeIfPresent(
            String.self, forKey: .browserPresentationModeRaw
        ) ?? defaults.browserPresentationModeRaw
        browserPageAppearanceRaw = try container.decodeIfPresent(
            String.self, forKey: .browserPageAppearanceRaw
        ) ?? defaults.browserPageAppearanceRaw
        browserJavaScriptPermissionRaw = try container.decodeIfPresent(
            String.self, forKey: .browserJavaScriptPermissionRaw
        ) ?? defaults.browserJavaScriptPermissionRaw
        browserUserDownloadPermissionRaw = try container.decodeIfPresent(
            String.self, forKey: .browserUserDownloadPermissionRaw
        ) ?? defaults.browserUserDownloadPermissionRaw
        browserAgentDownloadPermissionRaw = try container.decodeIfPresent(
            String.self, forKey: .browserAgentDownloadPermissionRaw
        ) ?? defaults.browserAgentDownloadPermissionRaw
        browserUploadPermissionRaw = try container.decodeIfPresent(
            String.self, forKey: .browserUploadPermissionRaw
        ) ?? defaults.browserUploadPermissionRaw
        browserPopupPermissionRaw = try container.decodeIfPresent(
            String.self, forKey: .browserPopupPermissionRaw
        ) ?? defaults.browserPopupPermissionRaw
        browserExternalPermissionRaw = try container.decodeIfPresent(
            String.self, forKey: .browserExternalPermissionRaw
        ) ?? defaults.browserExternalPermissionRaw
        browserCameraPermissionRaw = try container.decodeIfPresent(
            String.self, forKey: .browserCameraPermissionRaw
        ) ?? defaults.browserCameraPermissionRaw
        browserMicrophonePermissionRaw = try container.decodeIfPresent(
            String.self, forKey: .browserMicrophonePermissionRaw
        ) ?? defaults.browserMicrophonePermissionRaw
        webSearchDestinationRaw = try container.decodeIfPresent(
            String.self,
            forKey: .webSearchDestinationRaw
        ) ?? defaults.webSearchDestinationRaw
        maximumActiveChats = Self.clampMaximumActiveChats(
            try container.decodeIfPresent(Int.self, forKey: .maximumActiveChats)
                ?? defaults.maximumActiveChats
        )
        worktreeRetentionLimit = Self.clampWorktreeRetentionLimit(
            try container.decodeIfPresent(Int.self, forKey: .worktreeRetentionLimit)
                ?? defaults.worktreeRetentionLimit
        )
        newGitChatsUseWorktree = try container.decodeIfPresent(
            Bool.self,
            forKey: .newGitChatsUseWorktree
        ) ?? defaults.newGitChatsUseWorktree
        otlpExportEnabled = try container.decodeIfPresent(Bool.self, forKey: .otlpExportEnabled)
            ?? defaults.otlpExportEnabled
        otlpEndpoint = try container.decodeIfPresent(String.self, forKey: .otlpEndpoint)
            ?? defaults.otlpEndpoint
        otlpAuthorization = try container.decodeIfPresent(String.self, forKey: .otlpAuthorization)
            ?? defaults.otlpAuthorization
        otlpSamplingRate = Self.clampOTLPSamplingRate(
            try container.decodeIfPresent(Double.self, forKey: .otlpSamplingRate)
                ?? defaults.otlpSamplingRate
        )
        proxyModeRaw = try container.decodeIfPresent(String.self, forKey: .proxyModeRaw)
            ?? defaults.proxyModeRaw
        proxyTypeRaw = try container.decodeIfPresent(String.self, forKey: .proxyTypeRaw)
            ?? defaults.proxyTypeRaw
        proxyHost = try container.decodeIfPresent(String.self, forKey: .proxyHost)
            ?? defaults.proxyHost
        // Clamped on the way in like the inspector width: a corrupt port must
        // read as unconfigured, not as a destination.
        proxyPort = Self.clampProxyPort(
            try container.decodeIfPresent(Int.self, forKey: .proxyPort)
        )
        proxyBypass = try container.decodeIfPresent(String.self, forKey: .proxyBypass)
            ?? defaults.proxyBypass
        proxyUsername = try container.decodeIfPresent(String.self, forKey: .proxyUsername)
            ?? defaults.proxyUsername
        proxyProfiles = try container.decodeIfPresent(
            [ProxyProfile].self, forKey: .proxyProfiles
        ) ?? defaults.proxyProfiles
        proxyActiveProfileID = try container.decodeIfPresent(
            String.self, forKey: .proxyActiveProfileID
        ) ?? defaults.proxyActiveProfileID
        proxyStrictModeEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .proxyStrictModeEnabled
        ) ?? defaults.proxyStrictModeEnabled
        proxyAutoFailoverEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .proxyAutoFailoverEnabled
        ) ?? defaults.proxyAutoFailoverEnabled
        proxyScopeProfileIDs = try container.decodeIfPresent(
            [String: String].self, forKey: .proxyScopeProfileIDs
        ) ?? defaults.proxyScopeProfileIDs
        proxyWorkspaceProfileIDs = try container.decodeIfPresent(
            [String: String].self, forKey: .proxyWorkspaceProfileIDs
        ) ?? defaults.proxyWorkspaceProfileIDs
        proxyProviderProfileIDs = try container.decodeIfPresent(
            [String: String].self, forKey: .proxyProviderProfileIDs
        ) ?? defaults.proxyProviderProfileIDs
        terminalShell = try container.decodeIfPresent(String.self, forKey: .terminalShell)
            ?? defaults.terminalShell
        terminalLoginShell = try container.decodeIfPresent(Bool.self, forKey: .terminalLoginShell)
            ?? defaults.terminalLoginShell
        terminalSettingsMigrated = try container.decodeIfPresent(
            Bool.self,
            forKey: .terminalSettingsMigrated
        ) ?? defaults.terminalSettingsMigrated
        permissionModeRaw = try container.decodeIfPresent(
            String.self,
            forKey: .permissionModeRaw
        ) ?? defaults.permissionModeRaw
    }
}

struct PermissionStateResponse: Codable {
    let mode: String
    let skipAll: Bool
    let allowed: [String]

    enum CodingKeys: String, CodingKey {
        case mode, allowed
        case skipAll = "skip_all"
    }
}

struct BackgroundServiceRecord: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let command: String
    let cwd: String
    let port: Int?
    let pid: Int?
    let running: Bool
    let exitCode: Int?
    let startedAt: String
    let uptimeSeconds: Int
    let tail: String?

    enum CodingKeys: String, CodingKey {
        case name, command, cwd, port, pid, running, tail
        case exitCode = "exit_code"
        case startedAt = "started_at"
        case uptimeSeconds = "uptime_seconds"
    }
}

struct BackgroundServicesResponse: Codable {
    let services: [BackgroundServiceRecord]
}

struct BackgroundServiceStopResponse: Codable {
    let ok: Bool
    let stopped: [String]
}

// MARK: - Extensions
