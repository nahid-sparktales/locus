import AppKit
import CoreServices
import CryptoKit
import Foundation
import WebKit

/// Schemes a browser tool may navigate to.
///
/// This is a security boundary, not tidiness. `_targets_workspace` in the agent
/// only inspects an argument named `path`, so a URL argument is always treated
/// as inside the workspace and auto-approved — which would make
/// `browser_navigate` with a `file://` URL an unscoped file reader that skips
/// `read_file`'s scoping and its permission prompt entirely. Locus also
/// registers its own `locus:` scheme for the MCP OAuth redirect, so handing
/// unknown schemes to the system would let a visited page drive the app's own
/// callback.
enum BrowserScheme {
    static let allowed: Set<String> = ["http", "https", "about"]

    static func permits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowed.contains(scheme)
    }

    /// Coerce what a person or a model typed into a URL, matching the preview's
    /// long-standing rule: a bare host gets `http://`, and the result must have
    /// a real host.
    static func normalize(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value == "about:blank" { return URL(string: value) }
        if !value.contains("://") { value = "http://\(value)" }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// Whether a URL points at this machine — the hot-reloading dev-server
    /// case, where stale cached assets hide the edit the user just made.
    static func isLoopback(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
            || host == "[::1]" || host.hasSuffix(".localhost")
    }

    /// Cache policy per destination. WebKit propagates the main document's
    /// `reloadIgnoringLocalCacheData` to every subresource, so using it for
    /// ordinary browsing refetches all assets on every navigation — the
    /// policy came from the dev-server Preview pane and stays only for its
    /// loopback case. Everything else browses through the HTTP cache.
    static func cachePolicy(for url: URL) -> URLRequest.CachePolicy {
        isLoopback(url) ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
    }
}

/// How a navigation ended. A slow page returns `stillLoading` rather than an
/// error: the load is genuinely still running, and telling the model it failed
/// would desynchronise its picture of the page from the real one. A link that
/// turns out to be a file fires neither `didFinish` nor `didFail` — without its
/// own case the navigation would sit on its full budget and then claim the
/// page never loaded.
enum BrowserLoadOutcome {
    case finished
    case failed(String)
    case stillLoading
    case cancelled
    case becameDownload
}

/// Native broker for the in-app browser.
///
/// Shaped after `ComputerControlService` — same result contract, same
/// generation-based cancellation — but it deliberately parts company in two
/// places. Actions are queued rather than rejected when one is already running,
/// because several agent workers share this one service. And every wait races a
/// deadline, because the browser's suspension point is a navigation callback
/// that a redirect loop or a wedged page can simply never deliver.
@MainActor
final class BrowserService: NSObject, ObservableObject {
    final class DownloadContext: NSObject {
        let id: UUID
        let sourceURL: URL?
        let agentInitiated: Bool
        let requiresApproval: Bool
        let approvalAction: String
        weak var webView: WKWebView?
        var destination: URL?
        var scopedDirectory: URL?
        var progressObservation: NSKeyValueObservation?

        init(
            id: UUID,
            sourceURL: URL?,
            agentInitiated: Bool,
            requiresApproval: Bool? = nil,
            approvalAction: String? = nil,
            webView: WKWebView?
        ) {
            self.id = id
            self.sourceURL = sourceURL
            self.agentInitiated = agentInitiated
            self.requiresApproval = requiresApproval ?? agentInitiated
            self.approvalAction = approvalAction
                ?? (agentInitiated ? "let the agent download this file" : "download this file")
            self.webView = webView
        }

        deinit { scopedDirectory?.stopAccessingSecurityScopedResource() }
    }

    /// One tab: a web view parked off-screen, plus the delegate state that
    /// drives it.
    @MainActor
    final class Tab: NSObject {
        let id: String
        let host: OffscreenWebHost
        /// The agent session that opened this tab. Concurrent chat workers each
        /// drive their own so one cannot navigate another's out from under it.
        let ownerSessionID: String
        let log = BrowserCaptureLog()
        let openedAt = Date()
        fileprivate var gate: NavigationGate?
        fileprivate weak var service: BrowserService?
        /// One-shot answer for the next `confirm`/`prompt`, armed by
        /// `browser_input {action: "dialog"}` before the click that triggers
        /// it. A tool that answered an *open* dialog would deadlock: the dialog
        /// blocks the click's JavaScript call, which holds the FIFO slot the
        /// answering tool would need.
        fileprivate var armedDialogResponse: (accept: Bool, text: String?)?
        /// Dialog outcomes since the last agent action, folded into that
        /// action's result text — a model should not have to guess why its
        /// click "did nothing".
        fileprivate var dialogNotices: [String] = []
        /// KVO tokens feeding the published snapshots. Held here so closing
        /// the tab tears them down with it.
        fileprivate var observations: [NSKeyValueObservation] = []
        /// Whether this tab presents itself to pages as a mobile device.
        fileprivate(set) var emulatesDevice = false
        /// Used for history attribution and to keep an agent-triggered upload,
        /// popup, or save prompt from being mistaken for a person's action.
        fileprivate var navigationSource: BrowserVisitSource = .user
        fileprivate var agentInteractionUntil = Date.distantPast
        fileprivate var pendingUserDownload = false
        fileprivate var walletOrigin: String?
        fileprivate var walletPendingRequestIDs: Set<String> = []
        fileprivate var walletRequestTimes: [Date] = []

        init(id: String, host: OffscreenWebHost, ownerSessionID: String) {
            self.id = id
            self.host = host
            self.ownerSessionID = ownerSessionID
        }

        var webView: WKWebView { host.webView }

        func invalidateObservations() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
        }
    }

    /// One-shot settlement for a navigation. `didFinish` and `didFail` can both
    /// arrive for one load, and the deadline can beat either, so the first
    /// answer wins and the rest are dropped — a second resume of a
    /// `CheckedContinuation` is a crash, not an error.
    final class NavigationGate {
        private var continuation: CheckedContinuation<BrowserLoadOutcome, Never>?
        private var settled: BrowserLoadOutcome?

        func settle(_ outcome: BrowserLoadOutcome) {
            guard settled == nil else { return }
            settled = outcome
            continuation?.resume(returning: outcome)
            continuation = nil
        }

        func value() async -> BrowserLoadOutcome {
            if let settled { return settled }
            return await withCheckedContinuation { continuation in
                if let settled {
                    continuation.resume(returning: settled)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    struct TabSnapshot: Identifiable, Equatable {
        let id: String
        var title: String
        var url: String
        var isLoading: Bool
        var isActive: Bool
        var progress: Double
        var canGoBack: Bool
        var canGoForward: Bool
        var ownerSessionID: String
        /// Surfaced so the toolbar can show when a tab is no longer at 100% or
        /// is presenting itself as a phone — both change what a screenshot
        /// means, and neither is visible in the page itself.
        var pageZoom: CGFloat
        var emulatesDevice: Bool
    }

    @Published private(set) var tabs: [TabSnapshot] = []
    /// Page icons keyed by host — deliberately not on `TabSnapshot`, so the
    /// snapshot diff stays untouched and same-host tabs share one icon.
    /// Written only by the favicon extension (BrowserFavicons.swift), which
    /// is why the setter is not file-private.
    @Published var favicons: [String: NSImage] = [:]
    /// Hosts fetched, in-flight, or failed. One attempt per host per app
    /// session: tab churn must never become request churn.
    var faviconHostsAttempted: Set<String> = []
    /// Injectable for tests; the default rides the configured proxy.
    var faviconFetcher: (URL) async -> Data? = { url in
        await BrowserService.proxiedFaviconFetch(url)
    }
    @Published private(set) var isExecuting = false
    @Published var autofillPrompt: BrowserAutofillPrompt?
    @Published var pendingPasswordSave: BrowserPasswordSavePrompt?
    let autofillVault: BrowserAutofillVault
    let activityStore = BrowserActivityStore()
    let permissionStore = BrowserPermissionStore()
    /// More live web views than this and the oldest idle one is closed. Each
    /// carries a WebContent process; a long day of team runs must not
    /// accumulate them without bound.
    static let maximumLiveTabs = 12

    private var openTabs: [Tab] = []
    private var activeTabBySession: [String: String] = [:]
    private struct ClosedTab {
        var url: URL
        var viewport: CGSize
        var emulatesDevice: Bool
    }
    private var recentlyClosedTabs: [String: [ClosedTab]] = [:]
    private var tabCounter = 0
    /// Cancellation is per agent session. One shared counter would let a stop
    /// in one conversation relabel another conversation's genuine failure as
    /// "cancelled" — actions from different sessions share the FIFO.
    private var cancellationGenerations: [String: Int] = [:]
    private var currentSessionID: String?
    private var proxyGeneration: Int?
    /// Session ids whose worker runtimes are alive, mirrored in by AppModel so
    /// tab eviction never sacrifices a tab an active agent is standing on.
    private var protectedSessionIDs: Set<String> = []
    /// The emulated size new tabs start at; follows the settings preset.
    var defaultViewport: CGSize = BrowserViewport.desktop.size
    /// Whether actions are delivered as real `NSEvent`s rather than through the
    /// bridge's synthetic events. Follows the setting; the bridge remains the
    /// fallback whenever real delivery is impossible.
    var realInputEnabled = true
    /// Whether a mobile viewport also presents a mobile device to the page.
    var deviceEmulationEnabled = true
    /// Whether new tabs allow the Web Inspector to attach.
    var webInspectorEnabled = false
    var historyAccess: BrowserHistoryAccess = .disabled
    /// Categories the active model may read or fill. The Python runtime uses
    /// the same set to shape its schema, but this native set is authoritative
    /// for guessed or stale calls and for secure-field input.
    var agentAutofillCategories: Set<BrowserAutofillCategory> = []
    var downloadDestination: BrowserDownloadDestinationKind = .systemDownloads
    var downloadAskEveryTime = false
    var customDownloadBookmark: Data?
    var pageAppearance: BrowserPageAppearance = .automatic
    /// Surfaced as a toast by AppModel — download completions and the like.
    var onUserNotice: ((String) -> Void)?
    private weak var walletGateway: WalletGateway?

    // FIFO admission. Concurrent workers queue instead of being refused, so a
    // background agent's call is never dropped just because the foreground one
    // is mid-navigation.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // One store for the whole browser. `nonPersistent()` hands back a *new*
    // store on every call, so building one per tab would mean tabs silently
    // not sharing cookies — a login on one would not carry to the next.
    private var dataStore: WKWebsiteDataStore = .nonPersistent()
    /// Set while the opt-in persistent profile is active; the identifier is
    /// derived from the workspace path, so the same project always finds its
    /// own cookies and nothing else's.
    private var persistentProfileID: UUID?

    /// A blank web view created at idle purely to launch WebKit's WebContent,
    /// Networking and GPU processes before the user's first navigation, which
    /// otherwise pays their cold start inside the perceived page load. No
    /// explicit process pool: WebKit shares processes app-wide since macOS 12,
    /// so warming any web view on the same data store warms them all.
    private var prewarmView: WKWebView?
    private var activeDownloads: [UUID: WKDownload] = [:]
    private var resumeDataByDownload: [UUID: Data] = [:]
    private var recentDownloadStarts: [String: [Date]] = [:]

    override init() {
        // The fixture key is a known constant, so this branch must not be
        // reachable in a signed Release or App Store build: anyone able to
        // influence the launch environment would otherwise get a vault sealed
        // with a publicly known 32 bytes.
        #if DEBUG
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" {
            // UI tests must never inherit or mutate the person's real browser
            // records. A per-process encrypted fixture also makes the empty
            // manager states deterministic while exercising the real vault
            // loading path.
            let fixtureDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "LocusUITests-Autofill-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            autofillVault = BrowserAutofillVault(
                fileURL: fixtureDirectory.appendingPathComponent("vault.bin"),
                keyProvider: InMemoryBrowserVaultKeyProvider()
            )
        } else {
            autofillVault = BrowserAutofillVault()
        }
        #else
        autofillVault = BrowserAutofillVault()
        #endif
        super.init()
    }

    init(autofillVault: BrowserAutofillVault) {
        self.autofillVault = autofillVault
        super.init()
    }

    func configureWalletGateway(_ gateway: WalletGateway) {
        walletGateway = gateway
        gateway.onBrowserGrantsRevoked = { [weak self] origin in
            self?.emitWalletRevocation(origin: origin)
        }
        applyWalletProviderAccess(reloadTabs: false)
    }

    /// User scripts are fixed at document start, so an approved access change
    /// must rebuild the script set and reload live pages. Native revocation is
    /// performed by WalletGateway before this method is called.
    func applyWalletProviderAccess(reloadTabs: Bool) {
        for tab in openTabs {
            let controller = tab.webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: BrowserBridge.walletHandlerName)
            if walletGateway?.browserProviderEnabled == true {
                controller.add(
                    WeakScriptMessageHandler(self),
                    name: BrowserBridge.walletHandlerName
                )
            }
            installUserScripts(on: controller, emulatingDevice: tab.emulatesDevice)
            if reloadTabs, tab.webView.url != nil { tab.webView.reloadFromOrigin() }
        }
    }

    /// Point the browser at a workspace's profile. Ephemeral by default; the
    /// opt-in persistent store is keyed per **workspace** — session ids are
    /// re-keyed by worker processes and recycled by chat deletion's Undo, so
    /// they are not a stable identity for a cookie jar.
    func configureProfile(workspacePath: String, persistent: Bool) {
        let identifier = persistent ? Self.profileIdentifier(for: workspacePath) : nil
        // Same identity — including ephemeral→ephemeral — keeps the same
        // store. This runs on every session_info; rebuilding `.nonPersistent()`
        // each time silently threw away the in-memory cache and cookies.
        guard identifier != persistentProfileID else { return }
        // A data store cannot be swapped under a live page; the pages go too.
        if !openTabs.isEmpty {
            cancelPendingActions()
            for tab in openTabs { retire(tab) }
            openTabs.removeAll()
            activeTabBySession.removeAll()
            onUserNotice?("Browser tabs closed — the browsing profile changed")
        }
        persistentProfileID = identifier
        dataStore = identifier.map { WKWebsiteDataStore(forIdentifier: $0) }
            ?? .nonPersistent()
        let activityProfileID = identifier?.uuidString ?? "ephemeral"
        activityStore.configure(profileID: activityProfileID, persistent: persistent)
        permissionStore.configure(profileID: activityProfileID, persistent: persistent)
        proxyGeneration = nil
        // The prewarm view holds the old store; keeping it would warm the
        // wrong networking process.
        prewarmView = nil
        publishTabs()
    }

    /// Erase selected parts of the active profile without silently deleting
    /// downloaded files. Clearing all WebKit storage closes live tabs so pages
    /// cannot immediately rewrite the data being removed.
    func clearBrowsingData(_ types: Set<BrowserDataType> = Set(BrowserDataType.allCases)) {
        if types.contains(.history) { activityStore.clearHistory() }
        if types.contains(.downloadHistory) { activityStore.clearDownloads() }
        let webKitTypes = types.reduce(into: Set<String>()) { result, type in
            result.formUnion(type.webKitTypes)
        }
        guard !webKitTypes.isEmpty else {
            onUserNotice?("Selected browser data cleared")
            return
        }
        let identifier = persistentProfileID
        let storeBeingCleared = dataStore
        if !openTabs.isEmpty {
            cancelPendingActions()
            for tab in openTabs { retire(tab) }
            openTabs.removeAll()
            activeTabBySession.removeAll()
        }
        dataStore = identifier.map { WKWebsiteDataStore(forIdentifier: $0) }
            ?? .nonPersistent()
        proxyGeneration = nil
        prewarmView = nil
        // Icons are derived from browsed pages, so the sweeper covers them too.
        favicons.removeAll()
        faviconHostsAttempted.removeAll()
        publishTabs()
        Task {
            await storeBeingCleared.removeData(ofTypes: webKitTypes, modifiedSince: .distantPast)
        }
        onUserNotice?("Selected browser data cleared")
    }

    func websiteDataRecords() async -> [BrowserWebsiteDataRecord] {
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return records.map { .init(displayName: $0.displayName, dataTypes: $0.dataTypes) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func removeWebsiteData(named displayName: String) async {
        let records = await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            .filter { $0.displayName == displayName }
        guard !records.isEmpty else { return }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        onUserNotice?("Data for \(displayName) cleared")
    }

    /// Deterministic per-workspace identity: the first 16 bytes of the
    /// canonical path's SHA-256. No registry to maintain, stable across
    /// launches, distinct per project.
    static func profileIdentifier(for workspacePath: String) -> UUID {
        let canonical = URL(fileURLWithPath: workspacePath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Prewarm

    /// Launch WebKit's helper processes before the first real navigation.
    /// Loading `about:blank` in a throwaway view forces WebContent, Networking
    /// and GPU processes up at idle, so the user's first page load starts from
    /// a warm runtime instead of paying their cold start. Does nothing once a
    /// real tab exists — the processes are already up.
    func prewarm() {
        guard prewarmView == nil, openTabs.isEmpty else { return }
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration())
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        prewarmView = webView
    }

    // MARK: - Session lifecycle

    /// Note which conversation is in front. Deliberately *not* the computer
    /// broker's scorched-earth reset: tabs belong to the agent session that
    /// opened them, background chat workers keep browsing while the user reads
    /// another chat, and coming back to a conversation finds its pages as they
    /// were.
    func beginSession(_ sessionID: String) {
        guard !sessionID.isEmpty, currentSessionID != sessionID else { return }
        currentSessionID = sessionID
        HostedScreenshotConsent.shared.beginSession(sessionID)
        publishTabs()
    }

    /// Stop what one session is doing — or, with `nil`, everything. Only the
    /// named session's generation moves, so an unaffected conversation's
    /// in-flight action keeps its real result instead of being relabelled
    /// "cancelled".
    func cancelPendingActions(ownedBy sessionID: String? = nil) {
        for tab in openTabs where sessionID == nil || tab.ownerSessionID == sessionID {
            tab.webView.stopLoading()
            tab.gate?.settle(.cancelled)
            tab.gate = nil
        }
        if let sessionID {
            cancellationGenerations[sessionID, default: 0] += 1
        } else {
            for key in cancellationGenerations.keys {
                cancellationGenerations[key, default: 0] += 1
            }
            isExecuting = false
        }
    }

    /// A conversation ended — its worker stopped or the chat was deleted — so
    /// its pages have nothing to belong to any more.
    func closeTabs(ownedBy sessionID: String) {
        cancelPendingActions(ownedBy: sessionID)
        for tab in openTabs where tab.ownerSessionID == sessionID {
            retire(tab)
        }
        openTabs.removeAll { $0.ownerSessionID == sessionID }
        activeTabBySession.removeValue(forKey: sessionID)
        publishTabs()
    }

    /// AppModel mirrors the live worker set in, so eviction can tell a
    /// dormant conversation's tab from one an agent is actively using.
    func setProtectedSessions(_ sessionIDs: Set<String>) {
        protectedSessionIDs = sessionIDs
    }

    // MARK: - Tools

    /// Run one browser tool. The result dictionary matches the native-broker
    /// contract the agent already speaks: `text` on success, `error` on
    /// failure, and never both.
    func perform(
        tool: String,
        arguments: [String: Any],
        sessionID: String,
        hostedProvider: String? = nil,
        timeoutMilliseconds: Int
    ) async -> [String: Any] {
        await acquire()
        isExecuting = true
        if let tab = existingTab(for: sessionID) {
            tab.agentInteractionUntil = Date().addingTimeInterval(3)
        }
        defer {
            isExecuting = false
            release()
        }

        let generation = cancellationGenerations[sessionID, default: 0]
        let budget = Duration.milliseconds(max(1_000, min(timeoutMilliseconds, 120_000)))

        do {
            let result = try await dispatch(
                tool,
                arguments: arguments,
                sessionID: sessionID,
                hostedProvider: hostedProvider,
                budget: budget
            )
            return annotatingDialogNotices(result, sessionID: sessionID)
        } catch let error as BrowserToolError {
            return ["error": error.message]
        } catch {
            guard generation == cancellationGenerations[sessionID, default: 0] else {
                return ["error": "cancelled by the user"]
            }
            return ["error": error.localizedDescription]
        }
    }

    private func dispatch(
        _ tool: String,
        arguments: [String: Any],
        sessionID: String,
        hostedProvider: String?,
        budget: Duration
    ) async throws -> [String: Any] {
            switch tool {
            case "browser_navigate":
                return try await navigate(arguments, sessionID: sessionID, budget: budget)
            case "browser_read_page":
                return try await readPage(arguments, sessionID: sessionID)
            case "browser_get_text":
                return try await getText(arguments, sessionID: sessionID)
            case "browser_find":
                return try await find(arguments, sessionID: sessionID)
            case "browser_screenshot":
                return try await screenshot(arguments, sessionID: sessionID, provider: hostedProvider)
            case "browser_wait_for":
                return try await waitFor(arguments, sessionID: sessionID, budget: budget)
            case "browser_input":
                return try await input(arguments, sessionID: sessionID)
            case "browser_javascript":
                return try await runJavaScript(arguments, sessionID: sessionID)
            case "browser_resize":
                return try resize(arguments, sessionID: sessionID)
            case "browser_console":
                return consoleLog(arguments, sessionID: sessionID)
            case "browser_network":
                return networkLog(arguments, sessionID: sessionID)
            case "browser_tabs":
                return tabsTool(arguments, sessionID: sessionID)
            case "browser_history":
                return try await historyTool(arguments)
            case "browser_autofill":
                return try await autofillTool(arguments, sessionID: sessionID)
            default:
                return ["error": "unsupported browser tool '\(tool)'"]
            }
    }

    private func historyTool(_ arguments: [String: Any]) async throws -> [String: Any] {
        switch historyAccess {
        case .disabled:
            throw BrowserToolError("browsing history access is disabled in Browser Settings")
        case .ask:
            guard await requestHistoryAccess() else {
                throw BrowserToolError("the user did not allow access to browsing history")
            }
        case .always:
            break
        }

        let query = (arguments["query"] as? String) ?? ""
        let limit = max(1, min((arguments["limit"] as? Int) ?? 25, 100))
        let offset = max(0, Int((arguments["cursor"] as? String) ?? "0") ?? 0)
        let from = Self.parseHistoryDate(arguments["date_from"] ?? arguments["from"])
        let to = Self.parseHistoryDate(arguments["date_to"] ?? arguments["to"])
        let matches = activityStore.searchHistory(query: query, limit: 1_000).filter { entry in
            (from == nil || entry.visitedAt >= from!) && (to == nil || entry.visitedAt <= to!)
        }
        let page = Array(matches.dropFirst(offset).prefix(limit))
        let formatter = ISO8601DateFormatter()
        let entries = page.map { entry in
            [
                "url": entry.url,
                "title": entry.title,
                "visited_at": formatter.string(from: entry.visitedAt),
            ]
        }
        let next = offset + page.count < matches.count ? String(offset + page.count) : nil
        let data = try JSONSerialization.data(
            withJSONObject: ["entries": entries, "next_cursor": (next as Any?) ?? NSNull()],
            options: [.sortedKeys]
        )
        return ["text": String(decoding: data, as: UTF8.self)]
    }

    /// Model-facing access to the encrypted Autofill store. Settings shape the
    /// advertised schema, while this check is the boundary for stale schemas and
    /// guessed calls. Password records are additionally scoped to the exact
    /// origin of the target tab.
    private func autofillTool(
        _ arguments: [String: Any],
        sessionID: String
    ) async throws -> [String: Any] {
        guard let rawCategory = arguments["category"] as? String,
              let category = BrowserAutofillCategory(rawValue: rawCategory)
        else {
            throw BrowserToolError("'category' must be password, contact, or paymentCard")
        }
        guard agentAutofillCategories.contains(category) else {
            throw BrowserToolError("model access to \(category.title.lowercased()) is disabled in Browser Settings")
        }
        guard await autofillVault.load() else {
            throw BrowserToolError(autofillVault.lastError ?? "Autofill data could not be loaded")
        }

        let action = ((arguments["action"] as? String) ?? "list").lowercased()
        let tabID = arguments["tab_id"] as? String
        let passwordOrigin: String?
        if category == .password {
            passwordOrigin = try autofillPasswordOrigin(sessionID: sessionID, tabID: tabID)
        } else {
            passwordOrigin = nil
        }

        switch action {
        case "list":
            let records: [[String: Any]]
            switch category {
            case .password:
                records = autofillVault.passwords.filter {
                    BrowserAutofillVault.normalizedOrigin($0.origin) == passwordOrigin
                }.map {
                    [
                        "id": $0.id.uuidString,
                        "label": $0.label,
                        "origin": $0.origin,
                        "username": $0.username,
                    ]
                }
            case .contact:
                records = autofillVault.contacts.map {
                    [
                        "id": $0.id.uuidString,
                        "label": $0.label,
                        "display_name": $0.fullName.isEmpty ? $0.label : $0.fullName,
                    ]
                }
            case .paymentCard:
                records = autofillVault.cards.map {
                    [
                        "id": $0.id.uuidString,
                        "nickname": $0.nickname,
                        "last_four": $0.lastFour,
                    ]
                }
            }
            return ["text": try autofillJSON(["category": category.rawValue, "records": records])]

        case "get":
            let id = try autofillRecordID(arguments)
            let record: [String: Any]
            switch category {
            case .password:
                guard let password = autofillVault.passwords.first(where: {
                    $0.id == id && BrowserAutofillVault.normalizedOrigin($0.origin) == passwordOrigin
                }) else {
                    throw BrowserToolError("no saved password for this site has that record_id")
                }
                // The secret itself is deliberately withheld. A tool result
                // becomes a message that is appended verbatim to the on-disk
                // session transcript and the run ledger, neither of which is
                // encrypted or scrubbed — returning the password here would
                // write it in clear next to the vault that exists to protect
                // it. `fill` applies the credential natively without it ever
                // passing through the model.
                record = [
                    "id": password.id.uuidString,
                    "label": password.label,
                    "origin": password.origin,
                    "username": password.username,
                ]
            case .contact:
                guard let contact = autofillVault.contacts.first(where: { $0.id == id }) else {
                    throw BrowserToolError("no saved contact has that record_id")
                }
                record = [
                    "id": contact.id.uuidString,
                    "label": contact.label,
                    "full_name": contact.fullName,
                    "organization": contact.organization,
                    "email": contact.email,
                    "phone": contact.phone,
                    "street": contact.street,
                    "city": contact.city,
                    "region": contact.region,
                    "postal_code": contact.postalCode,
                    "country": contact.country,
                ]
            case .paymentCard:
                guard let card = autofillVault.cards.first(where: { $0.id == id }) else {
                    throw BrowserToolError("no saved payment card has that record_id")
                }
                // Same reasoning as passwords: the full PAN never enters a
                // tool result. `last_four` is enough for the model to confirm
                // it picked the right card; `fill` supplies the real number.
                record = [
                    "id": card.id.uuidString,
                    "nickname": card.nickname,
                    "cardholder": card.cardholder,
                    "last_four": card.lastFour,
                    "expiration_month": card.expirationMonth,
                    "expiration_year": card.expirationYear,
                    "billing_contact_id": (card.billingContactID?.uuidString as Any?) ?? NSNull(),
                ]
            }
            return ["text": try autofillJSON(["category": category.rawValue, "record": record])]

        case "fill":
            let id = try autofillRecordID(arguments)
            let filled: Bool
            switch category {
            case .password:
                guard autofillVault.passwords.contains(where: {
                    $0.id == id && BrowserAutofillVault.normalizedOrigin($0.origin) == passwordOrigin
                }) else {
                    throw BrowserToolError("no saved password for this site has that record_id")
                }
                filled = await fillPassword(id, sessionID: sessionID, tabID: tabID)
            case .contact:
                guard autofillVault.contacts.contains(where: { $0.id == id }) else {
                    throw BrowserToolError("no saved contact has that record_id")
                }
                filled = await fillContact(id, sessionID: sessionID, tabID: tabID)
            case .paymentCard:
                guard autofillVault.cards.contains(where: { $0.id == id }) else {
                    throw BrowserToolError("no saved payment card has that record_id")
                }
                filled = await fillCard(id, sessionID: sessionID, tabID: tabID)
            }
            guard filled else {
                throw BrowserToolError("the page has no matching Autofill fields in the focused form")
            }
            return ["text": "Filled saved \(category.title.lowercased())."]

        default:
            throw BrowserToolError("'action' must be list, get, or fill")
        }
    }

    private func autofillPasswordOrigin(sessionID: String, tabID: String?) throws -> String {
        let tab = try openTab(for: sessionID, tabID: tabID)
        guard let url = tab.webView.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            throw BrowserToolError("open the website before accessing its saved passwords")
        }
        return BrowserAutofillVault.normalizedOrigin(url.absoluteString)
    }

    private func autofillRecordID(_ arguments: [String: Any]) throws -> UUID {
        guard let raw = arguments["record_id"] as? String, let id = UUID(uuidString: raw) else {
            throw BrowserToolError("'record_id' must be an id returned by browser_autofill list")
        }
        return id
    }

    private func autofillJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseHistoryDate(_ value: Any?) -> Date? {
        if let number = value as? Double { return Date(timeIntervalSince1970: number) }
        if let number = value as? Int { return Date(timeIntervalSince1970: Double(number)) }
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private func requestHistoryAccess() async -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        let alert = NSAlert()
        alert.messageText = "Allow this agent to read browsing history?"
        alert.informativeText = "Only page titles, addresses, and visit times from the current workspace profile are shared. Passwords, autofill records, cookies, and downloads stay private."
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Don’t Allow")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private func resolvePermission(
        _ kind: BrowserPermissionKind,
        url: URL?,
        action: String
    ) async -> Bool {
        switch permissionStore.decision(for: kind, url: url) {
        case .allow:
            return true
        case .block:
            return false
        case .ask:
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
            let alert = NSAlert()
            alert.messageText = "Allow \(action)?"
            alert.informativeText = "\(url?.host ?? "This site") is requesting this action. You can change its remembered permission in Browser Settings."
            alert.addButton(withTitle: "Allow Once")
            alert.addButton(withTitle: "Block")
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
    }

    /// Fold any dialogs that fired during the action into its result, so the
    /// model learns immediately that its click met a confirm() and what
    /// happened to it.
    private func annotatingDialogNotices(
        _ result: [String: Any],
        sessionID: String
    ) -> [String: Any] {
        guard let tab = existingTab(for: sessionID), !tab.dialogNotices.isEmpty else {
            return result
        }
        let notices = tab.dialogNotices.joined(separator: "\n")
        tab.dialogNotices.removeAll()
        guard let text = result["text"] as? String else { return result }
        var annotated = result
        annotated["text"] = "\(text)\n\n\(notices)"
        return annotated
    }

    private func navigate(
        _ arguments: [String: Any],
        sessionID: String,
        budget: Duration
    ) async throws -> [String: Any] {
        let tab = try tab(for: sessionID, tabID: arguments["tab_id"] as? String)
        tab.navigationSource = .agent
        tab.agentInteractionUntil = Date().addingTimeInterval(3)
        let action = (arguments["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !action.isEmpty else {
            throw BrowserToolError("'url' is required; pass a URL, or back, forward or reload")
        }

        applyProxyIfNeeded()
        let gate = NavigationGate()
        tab.gate = gate

        switch action.lowercased() {
        case "back":
            guard tab.webView.canGoBack else {
                tab.gate = nil
                throw BrowserToolError("there is nothing to go back to")
            }
            tab.webView.goBack()
        case "forward":
            guard tab.webView.canGoForward else {
                tab.gate = nil
                throw BrowserToolError("there is nothing to go forward to")
            }
            tab.webView.goForward()
        case "reload":
            if arguments["force"] as? Bool == true {
                tab.webView.reloadFromOrigin()
            } else {
                tab.webView.reload()
            }
        default:
            guard let url = BrowserScheme.normalize(action) else {
                tab.gate = nil
                throw BrowserToolError("'\(action)' is not a URL Locus can open")
            }
            guard BrowserScheme.permits(url) else {
                tab.gate = nil
                throw BrowserToolError(
                    "the \(url.scheme ?? "unknown") scheme is not allowed; "
                    + "the browser opens http and https pages only"
                )
            }
            tab.webView.load(URLRequest(url: url, cachePolicy: BrowserScheme.cachePolicy(for: url)))
        }

        let outcome = await withDeadline(gate: gate, budget: budget)
        tab.gate = nil
        publishTabs()

        let location = tab.webView.url?.absoluteString ?? action
        let title = tab.webView.title ?? ""
        switch outcome {
        case .cancelled:
            throw BrowserToolError("cancelled by the user")
        case .failed(let message):
            throw BrowserToolError("could not open \(location): \(message)")
        case .stillLoading:
            return ["text": """
            Opened \(location) — still loading when the wait ran out. \
            The page is live and readable; call browser_read_page, or \
            browser_navigate again to retry.
            """]
        case .becameDownload:
            return ["text": """
            That link is a file, not a page. Its download is waiting for the \
            configured site permission and destination, and will be reported \
            when it finishes. The previous page is still open.
            """]
        case .finished:
            let heading = title.isEmpty ? location : "\(title) — \(location)"
            return ["text": "Opened \(heading). Call browser_read_page to see the page."]
        }
    }

    private func readPage(
        _ arguments: [String: Any],
        sessionID: String
    ) async throws -> [String: Any] {
        let tab = try openTab(for: sessionID, tabID: arguments["tab_id"] as? String)

        var options: [String: Any] = [
            "filter": (arguments["filter"] as? String) ?? "interactive",
        ]
        if let refID = arguments["ref_id"] as? String, !refID.isEmpty {
            options["ref_id"] = refID
        }
        if let depth = arguments["depth"] as? Int { options["depth"] = depth }
        if let maxChars = arguments["max_chars"] as? Int { options["max_chars"] = maxChars }

        let raw = try await callBridge(tab, "return __locus.readPage(options)", ["options": options])
        guard let payload = raw as? [String: Any] else {
            throw BrowserToolError("the page could not be read")
        }
        if payload["stale"] as? Bool == true {
            throw BrowserToolError(BrowserBridge.staleReferenceMessage.droppingErrorPrefix)
        }

        let tree = (payload["tree"] as? String) ?? ""
        let url = (payload["url"] as? String) ?? ""
        let title = (payload["title"] as? String) ?? ""
        let count = (payload["count"] as? Int) ?? 0
        var text = "\(title.isEmpty ? "Untitled" : title) — \(url)\n\n"
        text += tree.isEmpty ? "(no visible elements)" : tree
        if payload["truncated"] as? Bool == true {
            let omitted = (payload["omitted"] as? Int) ?? 0
            text += "\n\n… \(omitted) more elements omitted; "
            text += "raise max_chars or pass ref_id to read one subtree."
        }
        text += "\n\n\(count) element\(count == 1 ? "" : "s") are addressable as ref_N "
        text += "until the page changes."
        return ["text": text]
    }

    private func getText(
        _ arguments: [String: Any],
        sessionID: String
    ) async throws -> [String: Any] {
        let tab = try openTab(for: sessionID, tabID: arguments["tab_id"] as? String)
        let maxChars = (arguments["max_chars"] as? Int) ?? 20_000
        let raw = try await callBridge(tab, "return __locus.getText(limit)", ["limit": maxChars])
        guard let payload = raw as? [String: Any] else {
            throw BrowserToolError("the page could not be read")
        }
        var text = "\((payload["title"] as? String) ?? "Untitled") — \((payload["url"] as? String) ?? "")\n\n"
        text += (payload["text"] as? String) ?? ""
        if payload["truncated"] as? Bool == true {
            text += "\n\n… truncated; raise max_chars for more."
        }
        return ["text": text]
    }

    private func find(
        _ arguments: [String: Any],
        sessionID: String
    ) async throws -> [String: Any] {
        let tab = try openTab(for: sessionID, tabID: arguments["tab_id"] as? String)
        guard let query = (arguments["query"] as? String)?.nilIfBlank else {
            throw BrowserToolError("'query' is required")
        }
        let raw = try await callBridge(
            tab,
            "return __locus.find(query, limit)",
            ["query": query, "limit": (arguments["limit"] as? Int) ?? 10]
        )
        guard let payload = raw as? [String: Any],
              let matches = payload["matches"] as? [[String: Any]]
        else { throw BrowserToolError("the page could not be searched") }
        if (payload["searched"] as? Int) == 0 {
            throw BrowserToolError("call browser_read_page first; there is nothing to search yet")
        }
        guard !matches.isEmpty else {
            return ["text": "Nothing on the page matches '\(query)'."]
        }
        let lines = matches.map { match in
            let role = (match["role"] as? String) ?? ""
            let name = (match["name"] as? String) ?? ""
            return "\(role) \"\(name)\" [\((match["ref"] as? String) ?? "")]"
        }
        return ["text": lines.joined(separator: "\n")]
    }

    private func screenshot(
        _ arguments: [String: Any],
        sessionID: String,
        provider: String?
    ) async throws -> [String: Any] {
        let tab = try openTab(for: sessionID, tabID: arguments["tab_id"] as? String)
        // The same gate and the same consent set computer control uses: a
        // picture of a logged-in page is no less sensitive than one of Notes.
        guard HostedScreenshotConsent.shared.isAllowed(provider: provider) else {
            return ["text": """
            Screenshot not shared; the user declined hosted-provider consent. \
            browser_read_page and browser_get_text still work.
            """]
        }
        if let ref = (arguments["ref"] as? String)?.nilIfBlank {
            // A region only exists once it is on screen: WKWebView captures the
            // viewport and has no equivalent of capture-beyond-viewport.
            let raw = try await callBridge(tab, "return __locus.scrollTo(ref)", ["ref": ref])
            if (raw as? [String: Any])?["stale"] as? Bool == true {
                throw BrowserToolError(BrowserBridge.staleReferenceMessage.droppingErrorPrefix)
            }
        }

        let region = try Self.captureRegion(arguments["region"])
        let requested = Self.coordinate(arguments["scale"]).map { max(0.1, min($0, 1.0)) } ?? 1.0
        // The live page area, not the emulated viewport: while the view is lent
        // to the visible panel it takes the panel's size, and a frame described
        // in terms of the viewport would not match the picture.
        let visible = tab.host.visibleSizeInCSSPixels
        let full = region?.width ?? visible.width

        // Shrink and retry rather than refuse. A capture that overruns the cap
        // is nearly always a large viewport, and telling the model to resize
        // costs it a round trip to learn something we can just do.
        var scale = requested
        var capture: (data: Data, pixels: CGSize)?
        for attempt in 0..<4 {
            let width = max(160, full * scale)
            let taken = try await tab.host.snapshotPNG(region: region, maximumWidth: width)
            if taken.data.count <= Self.maximumScreenshotBytes {
                capture = taken
                break
            }
            if attempt == 3 { capture = nil } else { scale *= 0.6 }
        }
        guard let capture else {
            throw BrowserToolError(
                "the capture is still over \(Self.maximumScreenshotBytes / 1_024 / 1_024) MB "
                + "at the smallest scale; capture a 'region' instead of the whole viewport"
            )
        }

        let location = tab.webView.url?.absoluteString ?? "the page"
        let origin = region?.origin ?? .zero
        let covered = region ?? CGRect(origin: .zero, size: visible)
        var text = region == nil
            ? "Captured the visible viewport of \(location)."
            : "Captured a \(Int(covered.width))×\(Int(covered.height)) region of \(location) "
                + "at (\(Int(origin.x)), \(Int(origin.y)))."
        // Whatever the model measures on this image has to be translated back
        // before browser_input can use it, so say how.
        text += "\n\nThe image is \(Int(capture.pixels.width))×\(Int(capture.pixels.height)) pixels "
            + "covering \(Int(covered.width))×\(Int(covered.height)) page pixels from "
            + "(\(Int(origin.x)), \(Int(origin.y))). To act on something in it, pass "
            + "browser_input x = \(Int(origin.x)) + imageX × \(Self.ratio(covered.width, capture.pixels.width)), "
            + "y = \(Int(origin.y)) + imageY × \(Self.ratio(covered.height, capture.pixels.height))."
        return [
            "text": text,
            "screenshot": [
                "mime_type": "image/png",
                "data": capture.data.base64EncodedString(),
                "description": "Newest browser viewport for \(location)",
            ],
        ]
    }

    /// Ratio of page pixels to image pixels, rounded to something a model can
    /// multiply by without it reading as false precision.
    private static func ratio(_ page: CGFloat, _ image: CGFloat) -> String {
        guard image > 0 else { return "1" }
        return String(format: "%.3g", Double(page / image))
    }

    /// `[x, y, width, height]` in page pixels.
    private static func captureRegion(_ raw: Any?) throws -> CGRect? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let values = raw as? [Any], values.count == 4 else {
            throw BrowserToolError("'region' must be [x, y, width, height] in page pixels")
        }
        let numbers = values.compactMap(coordinate)
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else {
            throw BrowserToolError("'region' needs four numbers and a positive width and height")
        }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private func waitFor(
        _ arguments: [String: Any],
        sessionID: String,
        budget: Duration
    ) async throws -> [String: Any] {
        if let seconds = Self.coordinate(arguments["seconds"]) {
            let capped = max(0, min(seconds, 30))
            try await Task.sleep(for: .milliseconds(Int(capped * 1_000)))
            return ["text": String(format: "Waited %.1f seconds.", Double(capped))]
        }
        let tab = try openTab(for: sessionID, tabID: arguments["tab_id"] as? String)
        var options: [String: Any] = [:]
        for key in ["text", "selector", "ref"] {
            if let value = (arguments[key] as? String)?.nilIfBlank { options[key] = value }
        }
        options["timeout_ms"] = (arguments["timeout_ms"] as? Int) ?? 10_000
        let raw = try await callBridge(
            tab, "return await __locus.waitFor(options)", ["options": options]
        )
        let payload = (raw as? [String: Any]) ?? [:]
        if payload["ok"] as? Bool == true {
            return ["text": "The page settled (\((payload["reason"] as? String) ?? "ready"))."]
        }
        return ["text": "Still waiting when the timeout ran out; the page may not reach that state."]
    }

    /// Where a pointer action lands, in page CSS pixels.
    private struct PointerTarget {
        let point: CGPoint
        /// Accessible name, when the target came from a ref; empty for raw
        /// coordinates, which name nothing.
        let name: String
        let fromRef: Bool
    }

    private static func coordinate(_ value: Any?) -> CGFloat? {
        if let int = value as? Int { return CGFloat(int) }
        if let double = value as? Double { return CGFloat(double) }
        if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
        return nil
    }

    /// Resolve `ref`, or a raw `x`/`y` pair, to a point in the page.
    ///
    /// A ref goes through the bridge so the element is scrolled into view and
    /// hit-tested first — that pre-flight is the only thing that catches a
    /// cookie banner sitting over the control, and it has no coordinate
    /// equivalent, because pixels are exactly what a person would aim at too.
    /// A coordinate pair, written either as `at: [x, y]` or as loose `x`/`y`
    /// keys. The array is what the schema advertises; the scalars are accepted
    /// because a model that has not read it closely reaches for them, and
    /// refusing a well-aimed click over its spelling helps nobody.
    private static func point(
        _ arguments: [String: Any],
        pairKey: String,
        xKey: String,
        yKey: String
    ) -> CGPoint? {
        if let pair = arguments[pairKey] as? [Any], pair.count >= 2,
           let x = coordinate(pair[0]), let y = coordinate(pair[1])
        {
            return CGPoint(x: x, y: y)
        }
        guard let x = coordinate(arguments[xKey]), let y = coordinate(arguments[yKey]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private func pointerTarget(
        _ tab: Tab,
        arguments: [String: Any],
        ref: String?,
        pairKey: String = "at",
        xKey: String = "x",
        yKey: String = "y"
    ) async throws -> PointerTarget {
        if let ref {
            let raw = try await callBridge(tab, "return __locus.locate(ref)", ["ref": ref])
            let payload = (raw as? [String: Any]) ?? [:]
            if payload["stale"] as? Bool == true {
                throw BrowserToolError(BrowserBridge.staleReferenceMessage.droppingErrorPrefix)
            }
            if payload["blocked"] as? Bool == true {
                let by = (payload["by"] as? String)?.nilIfBlank ?? "something else"
                throw BrowserToolError("\(by) is covering that element; scroll or dismiss it first")
            }
            guard let x = Self.coordinate(payload["x"]), let y = Self.coordinate(payload["y"]) else {
                throw BrowserToolError("that element has no position on the page")
            }
            return PointerTarget(
                point: CGPoint(x: x, y: y),
                name: (payload["name"] as? String)?.nilIfBlank ?? "",
                fromRef: true
            )
        }
        guard let point = Self.point(arguments, pairKey: pairKey, xKey: xKey, yKey: yKey) else {
            throw BrowserToolError(
                "pass 'ref' from browser_read_page, or '\(pairKey)' as [x, y] in page pixels"
            )
        }
        return PointerTarget(point: point, name: "", fromRef: false)
    }

    /// Whether this tab should be driven with real events right now.
    private func prefersRealInput(_ tab: Tab) -> Bool {
        realInputEnabled && tab.host.canDeliverRealInput
    }

    /// Appended when real input was wanted and could not be delivered, so a
    /// page that ignores untrusted events fails legibly instead of silently.
    private static let syntheticFallbackNotice = """
    Delivered as synthetic events because real input was unavailable; a page \
    that checks event.isTrusted will have ignored it.
    """

    /// Round-trip to the page after real input.
    ///
    /// An `NSEvent` is handled asynchronously in the web process, so the page's
    /// own handler — and any dialog it opens — may not have run by the time
    /// delivery returns. A trivial evaluation queues behind the event, so
    /// awaiting it is what lets the action's result report what the action
    /// actually caused. The bridge path never needed this: its call *was* the
    /// handler running.
    private func settleAfterRealInput(_ tab: Tab) async {
        _ = try? await callBridge(tab, "return 1", [:])
    }

    private func describeInput(
        verb: String,
        target: PointerTarget,
        real: Bool
    ) -> [String: Any] {
        let named = target.name.isEmpty
            ? " at (\(Int(target.point.x)), \(Int(target.point.y)))"
            : " \"\(target.name)\""
        var text = "\(verb)\(named). Call browser_read_page to see what changed."
        if !real, realInputEnabled { text += "\n\n\(Self.syntheticFallbackNotice)" }
        return ["text": text]
    }

    private func input(
        _ arguments: [String: Any],
        sessionID: String
    ) async throws -> [String: Any] {
        let action = (arguments["action"] as? String)?.lowercased() ?? "click"
        let tab = try openTab(for: sessionID, tabID: arguments["tab_id"] as? String)
        let ref = (arguments["ref"] as? String)?.nilIfBlank
        let modifierNames = (arguments["modifiers"] as? [String]) ?? []
        let repeatCount = max(1, min((arguments["repeat"] as? Int) ?? 1, 50))

        switch action {
        case "click", "double_click", "right_click", "triple_click":
            let target = try await pointerTarget(tab, arguments: arguments, ref: ref)
            let clickCount = action == "double_click" ? 2 : (action == "triple_click" ? 3 : 1)
            let button: BrowserInput.MouseButton = action == "right_click" ? .right : .left

            if prefersRealInput(tab) {
                let delivered = await tab.host.deliverClick(
                    at: target.point,
                    button: button,
                    clickCount: clickCount,
                    modifiers: BrowserInput.modifiers(from: modifierNames)
                )
                if delivered {
                    await settleAfterRealInput(tab)
                    return describeInput(verb: "Clicked", target: target, real: true)
                }
            }

            var options: [String: Any] = [:]
            if clickCount > 1 { options["detail"] = clickCount }
            if button == .right { options["button"] = "right" }
            applyModifiers(arguments, to: &options)
            let raw: Any?
            if let ref {
                raw = try await callBridge(
                    tab, "return __locus.click(ref, options)", ["ref": ref, "options": options]
                )
            } else {
                raw = try await callBridge(
                    tab,
                    "return __locus.clickAt(x, y, options)",
                    ["x": target.point.x, "y": target.point.y, "options": options]
                )
            }
            _ = try describeAction(raw, verb: "Clicked")
            return describeInput(verb: "Clicked", target: target, real: false)

        case "hover":
            let target = try await pointerTarget(tab, arguments: arguments, ref: ref)
            let hold = Duration.milliseconds(max(0, min((arguments["duration"] as? Int) ?? 0, 5_000)))
            if prefersRealInput(tab),
               await tab.host.deliverHover(at: target.point, holding: hold)
            {
                await settleAfterRealInput(tab)
                    return describeInput(verb: "Hovered over", target: target, real: true)
            }
            let raw: Any?
            if let ref {
                raw = try await callBridge(tab, "return __locus.hover(ref)", ["ref": ref])
            } else {
                raw = try await callBridge(
                    tab, "return __locus.hoverAt(x, y)",
                    ["x": target.point.x, "y": target.point.y]
                )
            }
            _ = try describeAction(raw, verb: "Hovered over")
            return describeInput(verb: "Hovered over", target: target, real: false)

        case "scroll_to":
            guard let ref else { throw BrowserToolError("'ref' is required") }
            let raw = try await callBridge(tab, "return __locus.scrollTo(ref)", ["ref": ref])
            return try describeAction(raw, verb: "Scrolled to")

        case "drag":
            let from = try await pointerTarget(
                tab,
                arguments: arguments,
                ref: (arguments["from_ref"] as? String)?.nilIfBlank
            )
            let to = try await pointerTarget(
                tab,
                arguments: arguments,
                ref: (arguments["to_ref"] as? String)?.nilIfBlank,
                pairKey: "to",
                xKey: "x2",
                yKey: "y2"
            )
            if prefersRealInput(tab),
               await tab.host.deliverDrag(
                   from: from.point,
                   to: to.point,
                   modifiers: BrowserInput.modifiers(from: modifierNames)
               )
            {
                await settleAfterRealInput(tab)
                    return describeInput(verb: "Dragged to", target: to, real: true)
            }
            let raw = try await callBridge(
                tab,
                "return __locus.dragBetween(from, to)",
                [
                    "from": ["x": from.point.x, "y": from.point.y],
                    "to": ["x": to.point.x, "y": to.point.y],
                ]
            )
            _ = try describeAction(raw, verb: "Dragged to")
            return describeInput(verb: "Dragged to", target: to, real: false)

        case "scroll":
            let deltaX = CGFloat(arguments["delta_x"] as? Int ?? 0)
            let deltaY = CGFloat(arguments["delta_y"] as? Int ?? 600)
            // Scrolling at a point is what reaches an inner container; with no
            // point given, the middle of the viewport is what a person would
            // have the pointer over.
            let point: CGPoint
            if ref != nil || arguments["at"] != nil || arguments["x"] != nil {
                point = try await pointerTarget(tab, arguments: arguments, ref: ref).point
            } else {
                let visible = tab.host.visibleSizeInCSSPixels
                point = CGPoint(x: visible.width / 2, y: visible.height / 2)
            }
            if prefersRealInput(tab) {
                var delivered = true
                for _ in 0..<repeatCount {
                    delivered = await tab.host.deliverScroll(
                        at: point, deltaX: deltaX, deltaY: deltaY
                    )
                    if !delivered { break }
                }
                if delivered {
                    // Doubles as the settle round trip: the page has run its
                    // scroll handlers by the time this answers.
                    let raw = try? await callBridge(tab, "return __locus.scrollBy(0, 0)", [:])
                    let y = Self.coordinate((raw as? [String: Any])?["y"]) ?? 0
                    return ["text": "Scrolled at (\(Int(point.x)), \(Int(point.y))); the page is now at y=\(Int(y))."]
                }
            }
            var y: CGFloat = 0
            for _ in 0..<repeatCount {
                let raw = try await callBridge(
                    tab,
                    "return __locus.scrollBy(dx, dy)",
                    ["dx": deltaX, "dy": deltaY]
                )
                y = Self.coordinate((raw as? [String: Any])?["y"]) ?? y
            }
            return ["text": "Scrolled; the page is now at y=\(Int(y))."]

        case "key":
            guard let name = (arguments["key"] as? String)?.nilIfBlank else {
                throw BrowserToolError("'key' is required")
            }
            if prefersRealInput(tab) {
                guard let key = BrowserInput.Key(name: name) else {
                    throw BrowserToolError(
                        "no key called '\(name)'; use a single character or a name "
                        + "like Enter, Tab, Escape, Backspace, ArrowDown, Home or PageUp"
                    )
                }
                if await tab.host.deliverKey(
                    key,
                    modifiers: BrowserInput.modifiers(from: modifierNames),
                    repeatCount: repeatCount
                ) {
                    await settleAfterRealInput(tab)
                    let times = repeatCount > 1 ? " \(repeatCount) times" : ""
                    return ["text": "Pressed \(name)\(times). Call browser_read_page to see what changed."]
                }
            }
            var modifiers: [String: Any] = [:]
            applyModifiers(arguments, to: &modifiers)
            for _ in 0..<repeatCount {
                _ = try await callBridge(
                    tab, "return __locus.pressKey(key, modifiers)",
                    ["key": name, "modifiers": modifiers]
                )
            }
            let times = repeatCount > 1 ? " \(repeatCount) times" : ""
            return ["text": "Pressed \(name)\(times). Call browser_read_page to see what changed."]

        case "dialog":
            let response = (arguments["response"] as? String)?.lowercased() ?? "dismiss"
            guard response == "accept" || response == "dismiss" else {
                throw BrowserToolError("'response' must be accept or dismiss")
            }
            tab.armedDialogResponse = (
                accept: response == "accept",
                text: arguments["text"] as? String
            )
            return ["text": """
            Armed: the next confirm or prompt on this tab will be \
            \(response == "accept" ? "accepted" : "dismissed"). Now take the \
            action that triggers it.
            """]

        case "type":
            let value = (arguments["text"] as? String) ?? (arguments["value"] as? String) ?? ""
            guard !value.isEmpty else { throw BrowserToolError("'text' is required") }
            if let ref {
                try await refuseSecureField(tab, ref: ref)
                _ = try await callBridge(tab, "return __locus.focus(ref)", ["ref": ref])
            } else {
                try await refuseSecureFocus(tab)
            }
            if prefersRealInput(tab), await tab.host.deliverText(value) {
                await settleAfterRealInput(tab)
                return ["text": "Typed. Call browser_read_page to see what changed."]
            }
            let raw = try await callBridge(tab, "return __locus.typeText(text)", ["text": value])
            return try describeAction(raw, verb: "Typed into")

        case "set_value":
            let value = (arguments["text"] as? String) ?? (arguments["value"] as? String) ?? ""
            if let ref {
                try await refuseSecureField(tab, ref: ref)
                let raw = try await callBridge(
                    tab, "return __locus.setValue(ref, value)", ["ref": ref, "value": value]
                )
                return try describeAction(raw, verb: "Set the value of")
            }
            try await refuseSecureFocus(tab)
            let raw = try await callBridge(tab, "return __locus.typeText(text)", ["text": value])
            return try describeAction(raw, verb: "Typed into")

        default:
            throw BrowserToolError("unknown input action '\(action)'")
        }
    }

    /// The half of the credential gate only Swift can do.
    ///
    /// The agent-side check can only read arguments, and a click's argument is
    /// `ref_12` — the meaning lives in the page. Here the element's type, its
    /// autocomplete hint and whether its form holds a password are all visible.
    private func refuseSecureField(_ tab: Tab, ref: String) async throws {
        let raw = try await callBridge(tab, "return __locus.describe(ref)", ["ref": ref])
        // Fail closed. Since the agent-side text scan was removed for
        // `browser_input`, this is the only credential gate left, so a bridge
        // that cannot describe the target must refuse the typing rather than
        // wave it through.
        guard let described = raw as? [String: Any] else {
            throw BrowserToolError("that field could not be inspected; type it yourself")
        }
        if described["stale"] as? Bool == true {
            throw BrowserToolError(BrowserBridge.staleReferenceMessage.droppingErrorPrefix)
        }
        try authorizeSensitiveInput(described, subject: "that field")
    }

    /// The same gate for typing that names no element. Real input goes wherever
    /// focus already is, so the focused element is what has to be vetted.
    private func refuseSecureFocus(_ tab: Tab) async throws {
        // `try?` plus a permissive guard meant a throwing or malformed bridge
        // reply silently authorised typing into whatever held focus.
        let raw = try await callBridge(tab, "return __locus.describeActive()", [:])
        guard let described = raw as? [String: Any] else {
            throw BrowserToolError("the focused field could not be inspected; type it yourself")
        }
        try authorizeSensitiveInput(described, subject: "the focused field")
    }

    private func authorizeSensitiveInput(_ described: [String: Any], subject: String) throws {
        guard described["secure"] as? Bool == true else { return }
        switch described["secureCategory"] as? String {
        case BrowserAutofillCategory.password.rawValue:
            guard agentAutofillCategories.contains(.password) else {
                throw BrowserToolError(
                    "\(subject) is a password field; enable model password access in Browser Settings"
                )
            }
        case BrowserAutofillCategory.paymentCard.rawValue:
            guard agentAutofillCategories.contains(.paymentCard) else {
                throw BrowserToolError(
                    "\(subject) is a payment-card field; enable model payment-card access in Browser Settings"
                )
            }
        case "oneTimeCode":
            throw BrowserToolError("\(subject) is a one-time-code field; the user has to type it themselves")
        case "securityCode":
            throw BrowserToolError("\(subject) is a card security-code field; the user has to type it themselves")
        default:
            throw BrowserToolError("\(subject) is a protected field; the user has to type it themselves")
        }
    }

    private func runJavaScript(
        _ arguments: [String: Any],
        sessionID: String
    ) async throws -> [String: Any] {
        let tab = try openTab(for: sessionID, tabID: arguments["tab_id"] as? String)
        guard let code = (arguments["code"] as? String)?.nilIfBlank else {
            throw BrowserToolError("'code' is required")
        }
        // Evaluated in the private world, so page scripts can neither observe
        // it nor collide with it.
        let raw = try await tab.webView.callAsyncJavaScript(
            code.contains("return") ? code : "return (\(code))",
            arguments: [:],
            in: nil,
            contentWorld: BrowserBridge.readerWorld
        )
        return ["text": Self.describeJavaScriptResult(raw)]
    }

    private func resize(
        _ arguments: [String: Any],
        sessionID: String
    ) throws -> [String: Any] {
        let tab = try tab(for: sessionID, tabID: arguments["tab_id"] as? String)
        var size = tab.host.viewport
        let preset = (arguments["preset"] as? String).flatMap(BrowserViewport.init(rawValue:))
        if let preset {
            size = preset.size
        }
        if let width = arguments["width"] as? Int { size.width = CGFloat(width) }
        if let height = arguments["height"] as? Int { size.height = CGFloat(height) }
        tab.host.setViewport(size)
        if let scheme = (arguments["color_scheme"] as? String)?.lowercased() {
            tab.webView.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
        }

        // The same rule Claude's browser uses, and the one that matches what a
        // site means by "mobile": the phone preset, or anything narrower than
        // the usual tablet breakpoint.
        let narrow = preset == .mobile || tab.host.viewport.width < 768
        let emulate = (arguments["emulate_device"] as? Bool) ?? (deviceEmulationEnabled && narrow)
        let changed = setDeviceEmulation(emulate, on: tab)

        var text = """
        Viewport is now \(Int(tab.host.viewport.width))×\(Int(tab.host.viewport.height)) CSS pixels.
        """
        if emulate {
            text += """
            \n\nThe page is also being presented with a mobile user agent, five touch \
            points and coarse-pointer media queries, so feature detection sees a phone.
            """
        }
        if changed {
            text += """
            \n\nReload before reading the page: a site decides what to serve at load \
            time, so the document currently open was built for the previous profile.
            """
        }
        text += """
        \n\nStill not emulated: the hardware pixel ratio, and real touch hardware — \
        input is delivered as mouse events\(emulate ? ", translated to touch where WebKit allows it" : "").
        """
        return ["text": text]
    }

    private func consoleLog(
        _ arguments: [String: Any],
        sessionID: String
    ) -> [String: Any] {
        guard let tab = existingTab(for: sessionID, tabID: arguments["tab_id"] as? String) else {
            return ["text": "No page has been opened, so there is nothing in the console."]
        }
        var entries = tab.log.console
        if arguments["only_errors"] as? Bool == true {
            entries = entries.filter(\.isError)
        }
        if let pattern = (arguments["pattern"] as? String)?.nilIfBlank {
            entries = entries.filter { $0.message.localizedCaseInsensitiveContains(pattern) }
        }
        let limit = max(1, min((arguments["limit"] as? Int) ?? 50, 200))
        entries = Array(entries.suffix(limit))
        guard !entries.isEmpty else { return ["text": "The console is empty."] }
        var text = entries.map { "[\($0.level)] \($0.message)" }.joined(separator: "\n")
        if tab.log.droppedEntries > 0 {
            text += "\n\n(\(tab.log.droppedEntries) entries dropped while the page was noisy.)"
        }
        text += "\n\n\(Self.captureCaveat)"
        return ["text": text]
    }

    private func networkLog(
        _ arguments: [String: Any],
        sessionID: String
    ) -> [String: Any] {
        guard let tab = existingTab(for: sessionID, tabID: arguments["tab_id"] as? String) else {
            return ["text": "No page has been opened, so no requests have been seen."]
        }
        if let requestID = (arguments["request_id"] as? String)?.nilIfBlank {
            guard let body = tab.log.body(forRequest: requestID) else {
                return ["text": """
                No stored body for \(requestID). Only the newest \
                \(BrowserCaptureLog.bodyLimit) text responses keep one.
                """]
            }
            return ["text": body]
        }
        var entries = tab.log.network
        if let pattern = (arguments["url_pattern"] as? String)?.nilIfBlank {
            entries = entries.filter { $0.url.localizedCaseInsensitiveContains(pattern) }
        }
        let limit = max(1, min((arguments["limit"] as? Int) ?? 50, 200))
        entries = Array(entries.suffix(limit))
        guard !entries.isEmpty else {
            return ["text": "No requests have been recorded for this page."]
        }
        var text = entries.map { "\($0.id) \($0.summary)" }.joined(separator: "\n")
        text += "\n\n\(Self.captureCaveat)"
        return ["text": text]
    }

    private func tabsTool(
        _ arguments: [String: Any],
        sessionID: String
    ) -> [String: Any] {
        switch (arguments["action"] as? String)?.lowercased() ?? "list" {
        case "new":
            // Background by default: opening a tab is usually preparation, and
            // yanking the view away from the page being worked on is rarely
            // what was wanted. The id in the reply is how the agent reaches it.
            let background = (arguments["background"] as? Bool) ?? true
            let tab = makeTab(ownerSessionID: sessionID, activate: !background)
            let isActive = activeTabBySession[sessionID] == tab.id
            if background, !isActive {
                return ["text": """
                Opened \(tab.id) in the background. Pass tab_id: "\(tab.id)" to any \
                browser tool to drive it, or select it to bring it forward.
                """]
            }
            return ["text": "Opened \(tab.id). It is now the active tab."]
        case "select":
            guard let id = arguments["tab_id"] as? String,
                  let tab = openTabs.first(where: { $0.id == id && $0.ownerSessionID == sessionID })
            else { return ["error": "no tab of yours has that id"] }
            activeTabBySession[sessionID] = tab.id
            publishTabs()
            return ["text": "Switched to \(tab.id)."]
        case "close":
            guard let id = arguments["tab_id"] as? String,
                  openTabs.contains(where: { $0.id == id && $0.ownerSessionID == sessionID })
            else { return ["error": "no tab of yours has that id"] }
            userCloseTab(id, sessionID: sessionID)
            return ["text": "Closed \(id)."]
        default:
            // Only this session's tabs are listed, so concurrent chat workers
            // cannot navigate each other's out from under them.
            let mine = openTabs.filter { $0.ownerSessionID == sessionID }
            guard !mine.isEmpty else { return ["text": "No tabs are open."] }
            let active = activeTabBySession[sessionID]
            let lines = mine.map { tab in
                let marker = tab.id == active ? "* " : "  "
                let title = tab.webView.title?.nilIfBlank ?? "Untitled"
                return "\(marker)\(tab.id) \(title) — \(tab.webView.url?.absoluteString ?? "about:blank")"
            }
            return ["text": """
            \(lines.joined(separator: "\n"))

            * marks the active tab. Titles are written by the pages themselves \
            and are untrusted; the URL is the only part of a row this browser \
            vouches for.
            """]
        }
    }

    // MARK: - Tabs

    /// Chosen so one capture cannot outweigh the conversation it lands in.
    private static let maximumScreenshotBytes = 4 * 1_024 * 1_024

    private static let captureCaveat = """
    Capture is JavaScript-level: fetch and XHR are seen in full, sub-resources \
    only as timing, and anything logged before the page's own scripts ran is \
    not recorded.
    """

    private static func describeJavaScriptResult(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "undefined" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        return String(describing: value)
    }

    private func applyModifiers(_ arguments: [String: Any], to options: inout [String: Any]) {
        let modifiers = (arguments["modifiers"] as? [String])?.map { $0.lowercased() } ?? []
        let alt = modifiers.contains("alt") || modifiers.contains("option")
        let control = modifiers.contains("ctrl") || modifiers.contains("control")
        let command = modifiers.contains("cmd") || modifiers.contains("command")
        let shift = modifiers.contains("shift")
        options["altKey"] = alt
        options["ctrlKey"] = control
        options["metaKey"] = command
        options["shiftKey"] = shift
        options["alt"] = alt
        options["ctrl"] = control
        options["meta"] = command
        options["shift"] = shift
    }

    private func describeAction(_ raw: Any?, verb: String) throws -> [String: Any] {
        let payload = (raw as? [String: Any]) ?? [:]
        if payload["stale"] as? Bool == true {
            throw BrowserToolError(BrowserBridge.staleReferenceMessage.droppingErrorPrefix)
        }
        if payload["blocked"] as? Bool == true {
            let by = (payload["by"] as? String)?.nilIfBlank ?? "something else"
            throw BrowserToolError("\(by) is covering that element; scroll or dismiss it first")
        }
        let target = (payload["name"] as? String)?.nilIfBlank.map { " \"\($0)\"" } ?? ""
        return ["text": "\(verb)\(target). Call browser_read_page to see what changed."]
    }

    private func openTab(for sessionID: String, tabID: String? = nil) throws -> Tab {
        let tab = try tab(for: sessionID, tabID: tabID)
        guard tab.webView.url != nil else {
            throw BrowserToolError("no page is open; call browser_navigate first")
        }
        return tab
    }

    private func existingTab(for sessionID: String, tabID: String? = nil) -> Tab? {
        if let tabID {
            return openTabs.first { $0.id == tabID && $0.ownerSessionID == sessionID }
        }
        guard let id = activeTabBySession[sessionID] else { return nil }
        return openTabs.first { $0.id == id }
    }

    /// The session's active tab, opening one on first use. The inspector's
    /// browser panel uses this to borrow the live web view.
    func tab(for sessionID: String) -> Tab {
        if let id = activeTabBySession[sessionID],
           let existing = openTabs.first(where: { $0.id == id })
        {
            return existing
        }
        return makeTab(ownerSessionID: sessionID)
    }

    /// A named tab, or the session's active one.
    ///
    /// Naming a tab reaches only the calling session's own — the same
    /// ownership rule `browser_tabs` enforces, and for the same reason:
    /// concurrent chat workers share this service, and one steering another's
    /// tab out from under it would be indistinguishable from the page
    /// navigating itself. Acting on a named tab deliberately does not make it
    /// active, so a background tab can be driven without stealing the view.
    func tab(for sessionID: String, tabID: String?) throws -> Tab {
        guard let tabID = tabID?.nilIfBlank else { return tab(for: sessionID) }
        guard let named = openTabs.first(
            where: { $0.id == tabID && $0.ownerSessionID == sessionID }
        ) else {
            throw BrowserToolError("no tab of yours has the id '\(tabID)'")
        }
        return named
    }

    @discardableResult
    private func makeTab(
        ownerSessionID: String,
        adopting adopted: WKWebViewConfiguration? = nil,
        activate: Bool = true
    ) -> Tab {
        tabCounter += 1
        let configuration: WKWebViewConfiguration
        if let adopted {
            // A window.open popup: the API contract requires building the view
            // with exactly the configuration WebKit handed over — and it
            // already carries the opener's data store, user scripts and
            // capture handler, so re-registering any of them would crash on
            // the duplicate handler name.
            configuration = adopted
        } else {
            configuration = makeConfiguration()
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        switch pageAppearance {
        case .automatic: webView.appearance = nil
        case .light: webView.appearance = NSAppearance(named: .aqua)
        case .dark: webView.appearance = NSAppearance(named: .darkAqua)
        }
        // Web Inspector lets any local process attach and read cookies and
        // localStorage for whatever the agent browsed. On in debug builds, and
        // in a shipping build only where the user has asked for it.
        #if DEBUG
        webView.isInspectable = true
        #else
        webView.isInspectable = webInspectorEnabled
        #endif

        let host = OffscreenWebHost(webView: webView, viewport: defaultViewport)
        let tab = Tab(
            id: "tab_\(tabCounter)",
            host: host,
            ownerSessionID: ownerSessionID
        )
        tab.service = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        objc_setAssociatedObject(webView, &Self.tabKey, tab, .OBJC_ASSOCIATION_RETAIN)

        // The delegate callbacks catch page loads; these catch everything else
        // the chrome shows live — progress, title changes from the page's own
        // script, pushState URL changes, history depth. Scheduled rather than
        // immediate: a single navigation fires most of these in one runloop
        // turn, and each used to rebuild every snapshot on the main actor
        // while WebKit was mid-load.
        let republish: (WKWebView, Any) -> Void = { [weak self] _, _ in
            self?.schedulePublish()
        }
        tab.observations = [
            webView.observe(\.estimatedProgress, changeHandler: republish),
            webView.observe(\.title, changeHandler: republish),
            webView.observe(\.url, changeHandler: republish),
            webView.observe(\.canGoBack, changeHandler: republish),
            webView.observe(\.canGoForward, changeHandler: republish),
            webView.observe(\.isLoading, changeHandler: republish),
        ]

        openTabs.append(tab)
        // A background tab must not steal the view: the session keeps looking
        // at whatever it was, and the agent reaches the new one by id.
        if activate || activeTabBySession[ownerSessionID] == nil {
            activeTabBySession[ownerSessionID] = tab.id
        }
        evictIfOverCap()
        applyProxyIfNeeded()
        publishTabs()
        return tab
    }

    /// The configuration every managed tab starts from. Shared with the
    /// prewarm view so the processes WebKit warms up are the ones real tabs
    /// will use.
    private func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        installUserScripts(on: configuration.userContentController, emulatingDevice: false)
        // Weak, because the content controller retains its handlers
        // strongly and the cycle would keep every closed tab's buffers
        // alive for good.
        configuration.userContentController.add(
            WeakScriptMessageHandler(self),
            name: BrowserBridge.captureHandlerName
        )
        configuration.userContentController.add(
            WeakScriptMessageHandler(self),
            contentWorld: BrowserBridge.readerWorld,
            name: BrowserBridge.autofillHandlerName
        )
        if walletGateway?.browserProviderEnabled == true {
            configuration.userContentController.add(
                WeakScriptMessageHandler(self),
                name: BrowserBridge.walletHandlerName
            )
        }
        // Agent clicks carry no user gesture, so this blocks programmatic
        // window.open; links and user-gestured popups route through
        // createWebViewWith into a managed tab.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Without this, the UA is the bare embedded-WebView signature
        // (no Version/Safari tokens), which bot-detection vendors route
        // into challenge interstitials and UA sniffers serve degraded
        // fallbacks to. Completing the token set makes the UA read as
        // the Safari this WebKit actually is.
        configuration.applicationNameForUserAgent = "Version/17.4 Safari/605.1.15"
        return configuration
    }

    /// (Re)install the injected scripts.
    ///
    /// `WKUserContentController` can only drop *all* user scripts, so turning
    /// the device profile on or off means rebuilding the set. The message
    /// handler is registered separately and survives this.
    private func installUserScripts(
        on controller: WKUserContentController,
        emulatingDevice: Bool
    ) {
        controller.removeAllUserScripts()
        controller.addUserScript(BrowserBridge.readerScript())
        controller.addUserScript(BrowserBridge.autofillScript())
        controller.addUserScript(BrowserBridge.captureScript())
        if walletGateway?.browserProviderEnabled == true {
            controller.addUserScript(BrowserBridge.walletProviderScript())
        }
        if emulatingDevice {
            controller.addUserScript(BrowserBridge.deviceScript())
        }
    }

    /// A Safari that really is an iPhone's. WebKit is the engine here, so an
    /// iOS user agent is the honest way to be served the mobile site rather
    /// than claiming to be a browser this is not.
    static let mobileUserAgent = """
    Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 \
    (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1
    """.replacingOccurrences(of: "\n", with: "")

    /// Present a tab as a phone, or stop. Takes effect on the next load, which
    /// is why the caller tells the model to reload.
    @discardableResult
    func setDeviceEmulation(_ emulate: Bool, on tab: Tab) -> Bool {
        guard tab.emulatesDevice != emulate else { return false }
        tab.emulatesDevice = emulate
        installUserScripts(
            on: tab.webView.configuration.userContentController,
            emulatingDevice: emulate
        )
        tab.webView.customUserAgent = emulate ? Self.mobileUserAgent : nil
        return true
    }

    /// Keep the live web-view count bounded. Victims are the oldest tabs from
    /// conversations that are neither in front nor backed by a live worker —
    /// a parked tab is a live agent's steady state between tool calls, so
    /// idleness alone is not grounds.
    private func evictIfOverCap() {
        while openTabs.count > Self.maximumLiveTabs {
            guard let victim = openTabs.first(where: { tab in
                tab.ownerSessionID != currentSessionID
                    && !protectedSessionIDs.contains(tab.ownerSessionID)
                    && tab.host.isParked
                    && tab.gate == nil
            }) else { return }
            retire(victim)
            openTabs.removeAll { $0 === victim }
            if activeTabBySession[victim.ownerSessionID] == victim.id {
                activeTabBySession[victim.ownerSessionID] = openTabs
                    .first { $0.ownerSessionID == victim.ownerSessionID }?.id
            }
        }
    }

    private static var tabKey: UInt8 = 0

    fileprivate func tab(owning webView: WKWebView) -> Tab? {
        objc_getAssociatedObject(webView, &Self.tabKey) as? Tab
    }

    /// Tear down a tab that is leaving `openTabs`. Clearing the associated
    /// object breaks the webView→Tab→host→webView retain cycle, so the whole
    /// subgraph — WebContent process, off-screen panel, capture buffers —
    /// actually deallocates instead of living forever; ordering the panel out
    /// first stops the page rendering at full "visible" rate while ARC gets
    /// there. Delegate callbacks that race the teardown find `tab(owning:)`
    /// nil and stand down.
    private func retire(_ tab: Tab) {
        tab.invalidateObservations()
        tab.gate?.settle(.cancelled)
        tab.gate = nil
        tab.host.setKeptLive(false)
        objc_setAssociatedObject(tab.webView, &Self.tabKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    /// True while a publish is queued behind the current runloop turn.
    private var publishScheduled = false

    /// Coalesce the KVO storm of a page load into one snapshot rebuild per
    /// runloop turn. User actions keep calling `publishTabs()` directly —
    /// they want the snapshot synchronously, and tests rely on that.
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            self.publishTabs()
        }
    }

    private func publishTabs() {
        let active = Set(activeTabBySession.values)
        // Only tabs a session is standing on keep WebKit's "visible" state;
        // the rest throttle like any browser's background tabs instead of
        // competing with the page actually being loaded.
        for tab in openTabs {
            tab.host.setKeptLive(active.contains(tab.id))
        }
        let fresh = openTabs.map { tab in
            TabSnapshot(
                id: tab.id,
                title: tab.webView.title ?? "",
                url: tab.webView.url?.absoluteString ?? "",
                isLoading: tab.webView.isLoading,
                isActive: active.contains(tab.id),
                // Quantized so the snapshot diff below caps progress-driven
                // publishes at ~20 per load instead of every KVO tick. The
                // 2px progress line cannot show finer steps anyway.
                progress: (tab.webView.estimatedProgress * 20).rounded() / 20,
                canGoBack: tab.webView.canGoBack,
                canGoForward: tab.webView.canGoForward,
                ownerSessionID: tab.ownerSessionID,
                pageZoom: tab.webView.pageZoom,
                emulatesDevice: tab.emulatesDevice
            )
        }
        // KVO fires for every progress tick; only real changes republish.
        if fresh != tabs { tabs = fresh }
    }

    // MARK: - Human driver

    /// The person's actions go straight to the web view — no broker queue, no
    /// permission layer — but through the same normalization and scheme
    /// allowlist the agent gets, and the same proxy re-check.
    @discardableResult
    func userNavigate(_ raw: String, sessionID: String) -> Bool {
        guard let url = BrowserScheme.normalize(raw), BrowserScheme.permits(url) else {
            return false
        }
        applyProxyIfNeeded()
        let tab = tab(for: sessionID)
        tab.navigationSource = .user
        tab.webView.load(URLRequest(url: url, cachePolicy: BrowserScheme.cachePolicy(for: url)))
        publishTabs()
        return true
    }

    func userGoBack(sessionID: String) {
        guard let tab = existingTab(for: sessionID), tab.webView.canGoBack else { return }
        tab.navigationSource = .user
        tab.webView.goBack()
        publishTabs()
    }

    func userGoForward(sessionID: String) {
        guard let tab = existingTab(for: sessionID), tab.webView.canGoForward else { return }
        tab.navigationSource = .user
        tab.webView.goForward()
        publishTabs()
    }

    func userReload(sessionID: String) {
        guard let tab = existingTab(for: sessionID) else { return }
        tab.navigationSource = .user
        applyProxyIfNeeded()
        tab.webView.reload()
        publishTabs()
    }

    func userStopLoading(sessionID: String) {
        guard let tab = existingTab(for: sessionID) else { return }
        tab.webView.stopLoading()
        tab.gate?.settle(.cancelled)
        tab.gate = nil
        publishTabs()
    }

    func userNewTab(sessionID: String) {
        _ = makeTab(ownerSessionID: sessionID)
    }

    func userSelectTab(_ tabID: String, sessionID: String) {
        guard openTabs.contains(where: { $0.id == tabID && $0.ownerSessionID == sessionID })
        else { return }
        activeTabBySession[sessionID] = tabID
        publishTabs()
    }

    func userCloseTab(_ tabID: String, sessionID: String) {
        guard let index = openTabs.firstIndex(where: {
            $0.id == tabID && $0.ownerSessionID == sessionID
        }) else { return }
        let closed = openTabs.remove(at: index)
        if let url = closed.webView.url {
            recentlyClosedTabs[sessionID, default: []].insert(
                .init(
                    url: url,
                    viewport: closed.host.viewport,
                    emulatesDevice: closed.emulatesDevice
                ),
                at: 0
            )
            recentlyClosedTabs[sessionID] = Array(
                recentlyClosedTabs[sessionID, default: []].prefix(10)
            )
        }
        retire(closed)
        if activeTabBySession[sessionID] == closed.id {
            activeTabBySession[sessionID] = openTabs
                .first { $0.ownerSessionID == sessionID }?.id
        }
        publishTabs()
    }

    func canReopenClosedTab(sessionID: String) -> Bool {
        recentlyClosedTabs[sessionID]?.isEmpty == false
    }

    func userReopenClosedTab(sessionID: String) {
        guard var closed = recentlyClosedTabs[sessionID], !closed.isEmpty else { return }
        let item = closed.removeFirst()
        recentlyClosedTabs[sessionID] = closed
        let tab = makeTab(ownerSessionID: sessionID)
        tab.host.setViewport(item.viewport)
        _ = setDeviceEmulation(item.emulatesDevice, on: tab)
        tab.navigationSource = .user
        tab.webView.load(URLRequest(url: item.url))
    }

    func userDuplicateTab(_ tabID: String, sessionID: String) {
        guard let source = openTabs.first(where: {
            $0.id == tabID && $0.ownerSessionID == sessionID
        }), let url = source.webView.url else { return }
        let tab = makeTab(ownerSessionID: sessionID)
        tab.host.setViewport(source.host.viewport)
        _ = setDeviceEmulation(source.emulatesDevice, on: tab)
        tab.navigationSource = .user
        tab.webView.load(URLRequest(url: url))
    }

    func userMoveTab(_ tabID: String, before targetID: String, sessionID: String) {
        guard tabID != targetID,
              let sourceIndex = openTabs.firstIndex(where: {
                  $0.id == tabID && $0.ownerSessionID == sessionID
              }),
              let targetIndex = openTabs.firstIndex(where: {
                  $0.id == targetID && $0.ownerSessionID == sessionID
              })
        else { return }
        let tab = openTabs.remove(at: sourceIndex)
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        openTabs.insert(tab, at: adjustedTarget)
        publishTabs()
    }

    /// The live page in the default browser — the current URL, not a settings
    /// field that may never have been visited.
    func openCurrentTabExternally(sessionID: String) {
        guard let url = existingTab(for: sessionID)?.webView.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Close every other tab the session owns. A keeper the session does not
    /// own is refused outright — a partial close would be worse than a no-op.
    func userCloseOtherTabs(keeping tabID: String, sessionID: String) {
        guard openTabs.contains(where: { $0.id == tabID && $0.ownerSessionID == sessionID })
        else { return }
        let victims = openTabs.filter { $0.ownerSessionID == sessionID && $0.id != tabID }
        guard !victims.isEmpty else { return }
        for tab in victims {
            retire(tab)
        }
        openTabs.removeAll { tab in victims.contains { $0 === tab } }
        activeTabBySession[sessionID] = tabID
        publishTabs()
    }

    /// Move the active tab within the session's own ring, wrapping both ways.
    func userCycleTab(sessionID: String, forward: Bool) {
        let mine = openTabs.filter { $0.ownerSessionID == sessionID }
        guard mine.count > 1,
              let activeID = activeTabBySession[sessionID],
              let index = mine.firstIndex(where: { $0.id == activeID })
        else { return }
        let next = mine[(index + (forward ? 1 : mine.count - 1)) % mine.count]
        activeTabBySession[sessionID] = next.id
        publishTabs()
    }

    /// Any of the session's tabs in the default browser, not just the active
    /// one — the chip context menu addresses tabs directly.
    func userOpenTabExternally(_ tabID: String, sessionID: String) {
        guard let tab = openTabs.first(where: {
            $0.id == tabID && $0.ownerSessionID == sessionID
        }), let url = tab.webView.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// What the chrome should draw for this session right now.
    /// Find on the page, the way ⌘F does everywhere else.
    ///
    /// WebKit's public find API reports only whether there was a match — there
    /// is no match count to show — so the interface says found or not found
    /// rather than inventing a number.
    func userFind(
        _ query: String,
        sessionID: String,
        forward: Bool = true
    ) async -> Bool {
        guard let tab = existingTab(for: sessionID), !query.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        configuration.caseSensitive = false
        // Throws when the web view has nothing loaded to search, which is a
        // "no match" for the person, not an error worth surfacing.
        return (try? await tab.webView.find(query, configuration: configuration))?
            .matchFound ?? false
    }

    /// Drop the highlight. Searching for nothing is how WebKit clears it.
    func userClearFind(sessionID: String) {
        guard let tab = existingTab(for: sessionID) else { return }
        Task { _ = try? await tab.webView.find("", configuration: WKFindConfiguration()) }
    }

    func userPageZoom(sessionID: String) -> CGFloat {
        existingTab(for: sessionID)?.webView.pageZoom ?? 1
    }

    /// Zoom the page itself, not the window. Clamped to the range a browser
    /// offers, because past either end the page stops being usable and the
    /// agent's coordinates stop being legible.
    func userSetPageZoom(_ zoom: CGFloat, sessionID: String) {
        guard let tab = existingTab(for: sessionID) else { return }
        tab.webView.pageZoom = max(0.25, min(zoom, 3.0))
        schedulePublish()
    }

    func userDeviceEmulation(sessionID: String) -> Bool {
        existingTab(for: sessionID)?.emulatesDevice ?? false
    }

    /// Turn the phone profile on or off from the interface, and reload — a
    /// site decides what to serve at load time, so the open document was built
    /// for the profile being replaced.
    func userSetDeviceEmulation(_ emulate: Bool, sessionID: String) {
        guard let tab = existingTab(for: sessionID) else { return }
        guard setDeviceEmulation(emulate, on: tab) else { return }
        if tab.webView.url != nil { tab.webView.reload() }
        schedulePublish()
    }

    /// Light or dark, for the person as well as the agent — `browser_resize`
    /// could already do this and the interface could not.
    func userSetColorScheme(_ scheme: String, sessionID: String) {
        guard let tab = existingTab(for: sessionID) else { return }
        switch BrowserPageAppearance(rawValue: scheme) ?? .automatic {
        case .automatic: tab.webView.appearance = nil
        case .light: tab.webView.appearance = NSAppearance(named: .aqua)
        case .dark: tab.webView.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Point one tab's emulated viewport at a size, from the interface.
    func userSetViewport(_ size: CGSize, sessionID: String) {
        guard let tab = existingTab(for: sessionID) else { return }
        tab.host.setViewport(size)
        // The width is what decides whether a phone profile makes sense, so the
        // toolbar's preset and the agent's `browser_resize` agree on the rule.
        if deviceEmulationEnabled {
            userSetDeviceEmulation(size.width < 768, sessionID: sessionID)
        }
    }

    func activeSnapshot(for sessionID: String) -> TabSnapshot? {
        guard let id = activeTabBySession[sessionID] else { return nil }
        return tabs.first { $0.id == id }
    }

    /// The live capture log behind the drawer, or nil before any page opens.
    func activeLog(for sessionID: String) -> BrowserCaptureLog? {
        existingTab(for: sessionID)?.log
    }

    /// The host whose web view a visible container may borrow.
    func activeHost(for sessionID: String) -> OffscreenWebHost? {
        existingTab(for: sessionID)?.host
    }

    func snapshots(for sessionID: String) -> [TabSnapshot] {
        tabs.filter { $0.ownerSessionID == sessionID }
    }

    // MARK: - Plumbing

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Race the navigation against its budget so the queue slot is always
    /// released, even when the callback never arrives.
    private func withDeadline(gate: NavigationGate, budget: Duration) async -> BrowserLoadOutcome {
        let timer = Task { @MainActor in
            try? await Task.sleep(for: budget)
            gate.settle(.stillLoading)
        }
        defer { timer.cancel() }
        return await gate.value()
    }

    private func callBridge(
        _ tab: Tab,
        _ body: String,
        _ arguments: [String: Any]
    ) async throws -> Any? {
        // `callAsyncJavaScript` passes values as real arguments rather than
        // interpolating them into source, which keeps page-derived strings from
        // becoming an injection vector.
        try await tab.webView.callAsyncJavaScript(
            body,
            arguments: arguments,
            in: nil,
            contentWorld: BrowserBridge.readerWorld
        )
    }

    /// The preview re-applied the proxy inside `updateNSView`, which a
    /// model-driven navigation never goes through — so it is re-checked here,
    /// on every navigation, or proxied traffic would silently escape direct.
    private func applyProxyIfNeeded() {
        let generation = ProxyRuntime.shared.generation
        guard proxyGeneration != generation else { return }
        proxyGeneration = generation
        if let proxy = ProxyRuntime.shared.current(for: .browser) {
            dataStore.proxyConfigurations = [
                ProxyConfigurator.networkProxyConfiguration(for: proxy)
            ]
        } else {
            dataStore.proxyConfigurations = []
        }
    }
}

// MARK: - Navigation

extension BrowserService: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false,
           let tab = tab(owning: webView)
        {
            tab.pendingUserDownload = navigationAction.navigationType == .linkActivated
                || navigationAction.navigationType == .formSubmitted
        }
        preferences.allowsContentJavaScript = permissionStore.decision(
            for: .javascript,
            url: url
        ) != .block
        if BrowserScheme.permits(url) {
            decisionHandler(.allow, preferences)
            return
        }
        guard let scheme = url.scheme?.lowercased(),
              !["file", "data", "javascript", "blob", "locus"].contains(scheme)
        else {
            decisionHandler(.cancel, preferences)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                decisionHandler(.cancel, preferences)
                return
            }
            let allowed = await self.resolvePermission(
                .externalSchemes,
                url: webView.url ?? url,
                action: "open \(scheme) in another application"
            )
            if allowed { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tab(owning: webView) {
            tab.gate?.settle(.finished)
            if let url = webView.url {
                let nextOrigin = Self.walletOrigin(for: url)
                if let previous = tab.walletOrigin, previous != nextOrigin {
                    walletGateway?.revokeBrowserOrigin(previous)
                }
                tab.walletOrigin = nextOrigin
                activityStore.recordVisit(
                    url: url,
                    title: webView.title ?? "",
                    source: tab.navigationSource
                )
            }
        }
        noteFaviconOpportunity(for: webView)
        publishTabs()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        tab(owning: webView)?.gate?.settle(.failed(error.localizedDescription))
        publishTabs()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        tab(owning: webView)?.gate?.settle(.failed(error.localizedDescription))
        publishTabs()
    }

    /// pushState routing never fires `didFinish`, and the reader script does not
    /// re-run, so refs have to be retired here or they would outlive the view
    /// they describe.
    func webView(
        _ webView: WKWebView,
        didSameDocumentNavigation navigation: WKNavigation!
    ) {
        if let tab = tab(owning: webView), let url = webView.url {
            activityStore.recordVisit(url: url, title: webView.title ?? "", source: tab.navigationSource)
        }
        publishTabs()
    }

    /// A crashed content process leaves a permanently blank rectangle unless
    /// something reloads it.
    /// The only place the main document's status is visible, and the fork
    /// where a response that cannot render becomes a download instead of a
    /// blank page.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        adopt(download, from: webView)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        adopt(download, from: webView)
    }

    /// Basic-auth and TLS challenges get the system's default handling and
    /// nothing more — never a blanket trust, never a stored credential.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab(owning: webView)?.gate?.settle(.failed("the page's content process stopped"))
        webView.reload()
    }
}

// MARK: - Dialogs, popups, uploads

extension BrowserService: WKUIDelegate {
    /// Every completion handler here fires synchronously. Skipping one raises
    /// an uncatchable exception, and a nested modal would deadlock against the
    /// JavaScript call the dialog is blocking.
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        recordDialog(on: webView, kind: "alert", message: message, outcome: "shown")
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        // Auto-accepting is more dangerous than auto-cancelling: an unarmed
        // "Delete this?" takes the safe branch.
        let armed = tab(owning: webView)?.armedDialogResponse
        tab(owning: webView)?.armedDialogResponse = nil
        let accept = armed?.accept ?? false
        recordDialog(
            on: webView,
            kind: "confirm",
            message: message,
            outcome: armed == nil
                ? "auto-dismissed (arm a response with browser_input action=dialog to accept)"
                : (accept ? "accepted as armed" : "dismissed as armed")
        )
        completionHandler(accept)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let armed = tab(owning: webView)?.armedDialogResponse
        tab(owning: webView)?.armedDialogResponse = nil
        let answer: String? = (armed?.accept == true) ? (armed?.text ?? defaultText ?? "") : nil
        recordDialog(
            on: webView,
            kind: "prompt",
            message: prompt,
            outcome: answer.map { "answered \"\($0)\"" }
                ?? "auto-dismissed (arm a response with browser_input action=dialog to answer)"
        )
        completionHandler(answer)
    }

    /// `window.open` and `target="_blank"` become a managed tab owned by the
    /// opener's session. The API contract requires the returned view to be
    /// built with exactly this configuration — which also carries the opener's
    /// data store, scripts and capture handler, so nothing is re-registered —
    /// and WebKit performs the load itself.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let opener = tab(owning: webView) else { return nil }
        guard let url = navigationAction.request.url, BrowserScheme.permits(url) else {
            return nil
        }
        let permission = permissionStore.decision(for: .popups, url: webView.url)
        if permission == .block || (permission == .ask && opener.agentInteractionUntil > Date()) {
            recordDialog(
                on: webView,
                kind: "popup",
                message: url.absoluteString,
                outcome: "blocked by site permissions"
            )
            return nil
        }
        if permission == .ask {
            let alert = NSAlert()
            alert.messageText = "Allow a popup from \(webView.url?.host ?? "this site")?"
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: "Allow Once")
            alert.addButton(withTitle: "Block")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }
        let popup = makeTab(ownerSessionID: opener.ownerSessionID, adopting: configuration)
        // A popup opened from a page being viewed as a phone has to stay a
        // phone. The adopted configuration already carries the opener's scripts;
        // the user agent is per-web-view and would otherwise revert to desktop
        // halfway through a mobile flow.
        if opener.emulatesDevice {
            popup.emulatesDevice = true
            popup.webView.customUserAgent = Self.mobileUserAgent
        }
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(owning: webView) else { return }
        userCloseTab(tab.id, sessionID: tab.ownerSessionID)
    }

    /// Uploads remain a user-only capability. An agent can reveal the control,
    /// but only a physical user action may open this native picker.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        guard let tab = tab(owning: webView), tab.agentInteractionUntil <= Date() else {
            recordDialog(
                on: webView,
                kind: "file picker",
                message: "the page asked for a file upload",
                outcome: "refused; agents cannot select local files"
            )
            completionHandler(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  await self.resolvePermission(
                    .fileUploads,
                    url: webView.url,
                    action: "choose local files for upload"
                  )
            else {
                completionHandler(nil)
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            if let window = webView.window ?? NSApp.keyWindow {
                panel.beginSheetModal(for: window) { response in
                    completionHandler(response == .OK ? panel.urls : nil)
                }
            } else {
                completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let kinds: [BrowserPermissionKind]
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        case .cameraAndMicrophone: kinds = [.camera, .microphone]
        @unknown default: kinds = [.camera, .microphone]
        }
        Task { @MainActor [weak self] in
            guard let self else {
                decisionHandler(.deny)
                return
            }
            for kind in kinds {
                guard await self.resolvePermission(
                    kind,
                    url: webView.url,
                    action: "use the \(kind.title.lowercased())"
                ) else {
                    decisionHandler(.deny)
                    return
                }
            }
            decisionHandler(.grant)
        }
    }

    private func recordDialog(
        on webView: WKWebView,
        kind: String,
        message: String,
        outcome: String
    ) {
        guard let tab = tab(owning: webView) else { return }
        let line = "[dialog] \(kind): \"\(message.prefix(300))\" — \(outcome)"
        tab.dialogNotices.append(line)
        tab.log.append(console: BrowserConsoleEntry(
            level: "dialog",
            message: line,
            url: webView.url?.absoluteString ?? "",
            at: Date()
        ))
    }
}

// MARK: - Downloads

extension BrowserService: WKDownloadDelegate {
    static let maximumDownloadBytes: Int64 = 512 * 1_024 * 1_024

    private static var downloadContextKey: UInt8 = 0

    private func adopt(_ download: WKDownload, from webView: WKWebView) {
        download.delegate = self
        let tab = tab(owning: webView)
        let agentInitiated = (tab?.agentInteractionUntil ?? .distantPast) > Date()
        let directUserGesture = tab?.pendingUserDownload == true && !agentInitiated
        tab?.pendingUserDownload = false
        let origin = (download.originalRequest?.url ?? webView.url).map {
            BrowserPermissionStore.normalizedOrigin($0)
        } ?? "unknown"
        let now = Date()
        let recent = recentDownloadStarts[origin, default: []]
            .filter { now.timeIntervalSince($0) < 30 }
        recentDownloadStarts[origin] = recent + [now]
        let repeated = directUserGesture && !recent.isEmpty
        let requiresApproval = agentInitiated || !directUserGesture || repeated
        let context = DownloadContext(
            id: UUID(),
            sourceURL: download.originalRequest?.url ?? webView.url,
            agentInitiated: agentInitiated,
            requiresApproval: requiresApproval,
            approvalAction: agentInitiated
                ? "let the agent download this file"
                : repeated
                    ? "allow another download from this site"
                    : directUserGesture
                        ? "download this file"
                        : "allow this site to start a download automatically",
            webView: webView
        )
        objc_setAssociatedObject(
            download,
            &Self.downloadContextKey,
            context,
            .OBJC_ASSOCIATION_RETAIN
        )
        activeDownloads[context.id] = download
        context.progressObservation = download.progress.observe(\.fractionCompleted) {
            [weak self, weak context] progress, _ in
            guard let self, let context else { return }
            Task { @MainActor in
                self.activityStore.updateDownload(
                    id: context.id,
                    progress: progress.fractionCompleted
                )
            }
        }
        activityStore.beginDownload(.init(
            id: context.id,
            profileID: activityStore.currentProfileID,
            sourceURL: context.sourceURL?.absoluteString ?? "",
            destinationPath: "",
            fileName: context.sourceURL?.lastPathComponent.nilIfBlank ?? "download"
        ))
        // The navigation this became will never fire didFinish/didFail; the
        // waiting tool gets its own honest answer.
        tab?.gate?.settle(.becameDownload)
    }

    static func locusDownloadsDirectory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = base.appendingPathComponent("Locus/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        if response.expectedContentLength > Self.maximumDownloadBytes {
            notifyDownload(download, line: "[download] refused: larger than 512 MB")
            if let context = downloadContext(download) {
                activityStore.updateDownload(
                    id: context.id,
                    state: .failed,
                    error: "Larger than 512 MB"
                )
            }
            completionHandler(nil)
            return
        }
        guard let context = downloadContext(download) else {
            completionHandler(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            let permissionKind: BrowserPermissionKind = context.requiresApproval
                ? .agentDownloads : .userDownloads
            guard await self.resolvePermission(
                permissionKind,
                url: context.sourceURL,
                action: context.approvalAction
            ) else {
                self.activityStore.updateDownload(
                    id: context.id,
                    state: .cancelled,
                    error: "Blocked by site permissions"
                )
                completionHandler(nil)
                return
            }
            let destination = await self.chooseDownloadDestination(
                suggestedFilename: suggestedFilename,
                context: context
            )
            context.destination = destination
            if let destination {
                self.activityStore.updateDownload(
                    id: context.id,
                    destinationPath: destination.path
                )
            }
            completionHandler(destination)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let context = downloadContext(download), let destination = context.destination else { return }
        // Quarantined per file — the targeted alternative to a process-wide
        // LSFileQuarantineEnabled, which would stamp every file the app writes.
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        var url = destination
        try? url.setResourceValues(values)
        activityStore.updateDownload(id: context.id, state: .completed, progress: 1)
        finishDownload(context)
        notifyDownload(download, line: "[download] saved \(destination.lastPathComponent) to \(destination.path)")
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        if let context = downloadContext(download) {
            if let resumeData { resumeDataByDownload[context.id] = resumeData }
            activityStore.updateDownload(
                id: context.id,
                state: .failed,
                error: error.localizedDescription
            )
            finishDownload(context, keepResumeData: resumeData != nil)
        }
        notifyDownload(download, line: "[download] failed: \(error.localizedDescription)")
    }

    func pauseDownload(_ id: UUID) {
        guard let download = activeDownloads[id] else { return }
        download.cancel { [weak self] resumeData in
            Task { @MainActor in
                guard let self else { return }
                if let resumeData { self.resumeDataByDownload[id] = resumeData }
                self.activeDownloads.removeValue(forKey: id)
                self.activityStore.updateDownload(id: id, state: .paused)
            }
        }
    }

    func resumeDownload(_ id: UUID) {
        guard let data = resumeDataByDownload[id],
              let context = activityStore.downloads.first(where: { $0.id == id }),
              let webView = openTabs.first?.webView
        else { return }
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            guard let self else { return }
            Task { @MainActor in
                let metadata = DownloadContext(
                    id: id,
                    sourceURL: URL(string: context.sourceURL),
                    agentInitiated: false,
                    requiresApproval: false,
                    webView: webView
                )
                objc_setAssociatedObject(
                    download,
                    &Self.downloadContextKey,
                    metadata,
                    .OBJC_ASSOCIATION_RETAIN
                )
                self.activeDownloads[id] = download
                self.resumeDataByDownload.removeValue(forKey: id)
                download.delegate = self
                self.activityStore.updateDownload(id: id, state: .running, error: nil)
            }
        }
    }

    func cancelDownload(_ id: UUID) {
        guard let download = activeDownloads[id] else {
            resumeDataByDownload.removeValue(forKey: id)
            activityStore.updateDownload(id: id, state: .cancelled)
            return
        }
        download.cancel { [weak self] _ in
            Task { @MainActor in
                self?.activeDownloads.removeValue(forKey: id)
                self?.resumeDataByDownload.removeValue(forKey: id)
                self?.activityStore.updateDownload(id: id, state: .cancelled)
            }
        }
    }

    func retryDownload(_ id: UUID) {
        guard let record = activityStore.downloads.first(where: { $0.id == id }),
              let url = URL(string: record.sourceURL),
              let tab = openTabs.first
        else { return }
        tab.navigationSource = .user
        tab.webView.load(URLRequest(url: url))
    }

    func openDownload(_ id: UUID) {
        guard let url = activityStore.downloads.first(where: { $0.id == id })?.destinationURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        NSWorkspace.shared.open(url)
    }

    func revealDownload(_ id: UUID) {
        guard let url = activityStore.downloads.first(where: { $0.id == id })?.destinationURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @discardableResult
    func deleteDownloadedFile(_ id: UUID) -> Bool {
        guard let url = activityStore.downloads.first(where: { $0.id == id })?.destinationURL else {
            return false
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            activityStore.removeDownload(id)
            return true
        } catch {
            onUserNotice?("Could not move \(url.lastPathComponent) to Trash")
            return false
        }
    }

    private func chooseDownloadDestination(
        suggestedFilename: String,
        context: DownloadContext
    ) async -> URL? {
        let base = suggestedFilename.nilIfBlank ?? "download"
        if downloadAskEveryTime, !context.agentInitiated {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = base
            return await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }

        var directory: URL?
        switch downloadDestination {
        case .systemDownloads:
            directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .locus:
            directory = Self.locusDownloadsDirectory()
        case .custom:
            guard let bookmark = customDownloadBookmark else { return nil }
            var stale = false
            directory = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if let directory, directory.startAccessingSecurityScopedResource() {
                context.scopedDirectory = directory
            }
        }
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Self.uniqueDestination(in: directory, suggestedFilename: base)
    }

    private static func uniqueDestination(in directory: URL, suggestedFilename: String) -> URL {
        var candidate = directory.appendingPathComponent(suggestedFilename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = (suggestedFilename as NSString).deletingPathExtension
            let ext = (suggestedFilename as NSString).pathExtension
            let renamed = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(renamed)
            counter += 1
        }
        return candidate
    }

    private func downloadContext(_ download: WKDownload) -> DownloadContext? {
        objc_getAssociatedObject(download, &Self.downloadContextKey) as? DownloadContext
    }

    private func finishDownload(_ context: DownloadContext, keepResumeData: Bool = false) {
        context.progressObservation?.invalidate()
        context.progressObservation = nil
        context.scopedDirectory?.stopAccessingSecurityScopedResource()
        context.scopedDirectory = nil
        activeDownloads.removeValue(forKey: context.id)
        if !keepResumeData { resumeDataByDownload.removeValue(forKey: context.id) }
    }

    private func notifyDownload(_ download: WKDownload, line: String) {
        onUserNotice?(line)
        guard let webView = download.webView, let tab = tab(owning: webView) else { return }
        tab.dialogNotices.append(line)
        tab.log.append(console: BrowserConsoleEntry(
            level: "download",
            message: line,
            url: webView.url?.absoluteString ?? "",
            at: Date()
        ))
    }
}

// MARK: - User-only Autofill

extension BrowserService {
    func dismissAutofillPrompt() { autofillPrompt = nil }
    func dismissPasswordSavePrompt() { pendingPasswordSave = nil }

    func acceptPasswordSavePrompt() async -> Bool {
        guard let prompt = pendingPasswordSave else { return false }
        guard await autofillVault.load() else {
            return false
        }
        do {
            try autofillVault.save(.init(
                origin: prompt.origin,
                username: prompt.username,
                password: prompt.password
            ))
            pendingPasswordSave = nil
            onUserNotice?("Password saved in Autofill")
            return true
        } catch {
            onUserNotice?(error.localizedDescription)
            return false
        }
    }

    func fillPassword(_ id: UUID, sessionID: String, tabID: String? = nil) async -> Bool {
        guard await prepareVaultForFill(),
              let record = autofillVault.passwords.first(where: { $0.id == id })
        else { return false }
        let payload: [String: Any] = [
            "kind": "password",
            "username": record.username,
            "password": record.password,
        ]
        return await completeFill(
            payload,
            sessionID: sessionID,
            tabID: tabID,
            expectedOrigin: record.origin
        )
    }

    func fillContact(_ id: UUID, sessionID: String, tabID: String? = nil) async -> Bool {
        guard await prepareVaultForFill(),
              let record = autofillVault.contacts.first(where: { $0.id == id })
        else { return false }
        let payload: [String: Any] = [
            "kind": "contact",
            "fullName": record.fullName,
            "organization": record.organization,
            "email": record.email,
            "phone": record.phone,
            "street": record.street,
            "city": record.city,
            "region": record.region,
            "postalCode": record.postalCode,
            "country": record.country,
        ]
        return await completeFill(payload, sessionID: sessionID, tabID: tabID)
    }

    func fillCard(_ id: UUID, sessionID: String, tabID: String? = nil) async -> Bool {
        guard await prepareVaultForFill(),
              let record = autofillVault.cards.first(where: { $0.id == id })
        else { return false }
        // There is intentionally no security-code key in this payload.
        let payload: [String: Any] = [
            "kind": "paymentCard",
            "cardholder": record.cardholder,
            "number": record.normalizedNumber,
            "expirationMonth": String(format: "%02d", record.expirationMonth),
            "expirationYear": String(record.expirationYear),
        ]
        return await completeFill(payload, sessionID: sessionID, tabID: tabID)
    }

    private func prepareVaultForFill() async -> Bool {
        await autofillVault.load()
    }

    /// A saved record may only be written into a page that could legitimately
    /// have asked for it. Passwords additionally pin the exact origin they were
    /// saved against; contacts and payment cards are not origin-bound, so the
    /// destination itself is what has to be vetted — without this, a full PAN
    /// was written into whatever page happened to be open, including `file:`,
    /// `data:` and plain-http pages.
    private static func isSecureFillDestination(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            // Loopback only, so local development still works.
            guard let host = url.host?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default:
            return false
        }
    }

    private func completeFill(
        _ payload: [String: Any],
        sessionID: String,
        tabID: String? = nil,
        expectedOrigin: String? = nil
    ) async -> Bool {
        guard let tab = existingTab(for: sessionID, tabID: tabID) else { return false }
        guard let destination = tab.webView.url,
              Self.isSecureFillDestination(destination)
        else { return false }
        if let expectedOrigin {
            guard let pageURL = tab.webView.url,
                  BrowserAutofillVault.normalizedOrigin(pageURL.absoluteString)
                    == BrowserAutofillVault.normalizedOrigin(expectedOrigin)
            else { return false }
        }
        do {
            let result = try await tab.webView.callAsyncJavaScript(
                "return globalThis.__locusAutofill && globalThis.__locusAutofill.fill(record)",
                arguments: ["record": payload],
                in: nil,
                contentWorld: BrowserBridge.readerWorld
            )
            autofillPrompt = nil
            return (result as? Bool) == true
        } catch {
            return false
        }
    }
}

// MARK: - Capture

extension BrowserService: WKScriptMessageHandler {
    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let payload = message.body as? [String: Any],
              let webView = message.webView,
              let tab = tab(owning: webView)
        else { return }
        if message.name == BrowserBridge.walletHandlerName {
            handleWalletMessage(payload, tab: tab, webView: webView, message: message)
            return
        }
        if message.name == BrowserBridge.autofillHandlerName {
            handleAutofillMessage(payload, tab: tab, webView: webView)
            return
        }
        tab.log.note(dropped: (payload["dropped"] as? Int) ?? 0)
        for entry in (payload["entries"] as? [[String: Any]]) ?? [] {
            record(entry, into: tab.log)
        }
    }

    private func handleWalletMessage(
        _ payload: [String: Any],
        tab: Tab,
        webView: WKWebView,
        message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame,
              walletGateway?.browserProviderEnabled == true,
              let id = payload["id"] as? String, id.count <= 128,
              let method = payload["method"] as? String, method.count <= 96,
              let origin = Self.walletOrigin(for: message.frameInfo.securityOrigin),
              Self.walletOrigin(for: webView.url) == origin else { return }
        let params = payload["params"] as? [Any] ?? []
        let now = Date()
        tab.walletRequestTimes.removeAll { now.timeIntervalSince($0) > 10 }
        guard JSONSerialization.isValidJSONObject(params),
              let paramsData = try? JSONSerialization.data(withJSONObject: params),
              paramsData.count <= 256 * 1024,
              tab.walletPendingRequestIDs.count < 32,
              tab.walletRequestTimes.count < 80,
              tab.walletPendingRequestIDs.insert(id).inserted else {
            sendWalletResponse(
                walletError(-32005, "The website sent too many or invalid wallet requests."),
                requestID: id, origin: origin, tab: tab, webView: webView
            )
            return
        }
        tab.walletRequestTimes.append(now)
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            defer { tab.walletPendingRequestIDs.remove(id) }
            let response = await self.walletResponse(method: method, params: params, origin: origin)
            guard Self.walletOrigin(for: webView.url) == origin else { return }
            self.sendWalletResponse(
                response, requestID: id, origin: origin, tab: tab, webView: webView
            )
        }
    }

    private func sendWalletResponse(
        _ response: [String: Any],
        requestID: String,
        origin: String,
        tab: Tab,
        webView: WKWebView
    ) {
        guard tab.webView === webView, Self.walletOrigin(for: webView.url) == origin else { return }
        Task { @MainActor [weak webView] in
            _ = try? await webView?.callAsyncJavaScript(
                "globalThis.__locusWalletReceive(requestID, response)",
                arguments: ["requestID": requestID, "response": response],
                in: nil,
                contentWorld: .page
            )
        }
    }

    private func walletResponse(method: String, params: [Any], origin: String) async -> [String: Any] {
        guard let gateway = walletGateway else { return walletError(4900, "Locus Vault is unavailable.") }
        do {
            switch method {
            case "eth_requestAccounts":
                guard let accounts = await gateway.requestBrowserAccounts(origin: origin) else {
                    return walletError(4001, "The Locus Vault connection was rejected.")
                }
                emitWalletEvent("accountsChanged", value: accounts, origin: origin)
                return ["result": accounts]
            case "eth_accounts":
                return ["result": gateway.browserAccounts(origin: origin)]
            case "eth_chainId":
                return ["result": "0xaa36a7"]
            case "wallet_switchEthereumChain":
                guard let object = params.first as? [String: Any],
                      (object["chainId"] as? String)?.lowercased() == "0xaa36a7" else {
                    return walletError(4902, "Only Sepolia is supported.")
                }
                return ["result": NSNull()]
            case "eth_sendTransaction":
                guard let transaction = params.first as? [String: Any] else {
                    return walletError(-32602, "A transaction object is required.")
                }
                return ["result": try await gateway.browserSendTransaction(
                    origin: origin, transaction: transaction
                )]
            case "personal_sign", "eth_sign", "eth_signTypedData", "eth_signTypedData_v3",
                 "eth_signTypedData_v4", "wallet_addEthereumChain":
                return walletError(4200, "Locus Vault does not support message signing or chain addition.")
            default:
                return ["result": try await gateway.browserReadRPC(
                    origin: origin, method: method, params: params
                )]
            }
        } catch {
            return walletError(4100, error.localizedDescription)
        }
    }

    private func walletError(_ code: Int, _ message: String) -> [String: Any] {
        ["error": ["code": code, "message": message]]
    }

    private func emitWalletEvent(_ event: String, value: Any, origin: String?) {
        for tab in openTabs where origin == nil || tab.walletOrigin == origin {
            Task { @MainActor [weak webView = tab.webView] in
                try? await webView?.callAsyncJavaScript(
                    "globalThis.__locusWalletEvent && globalThis.__locusWalletEvent(eventName, value)",
                    arguments: ["eventName": event, "value": value],
                    in: nil,
                    contentWorld: .page
                )
            }
        }
    }

    private func emitWalletRevocation(origin: String?) {
        emitWalletEvent("accountsChanged", value: [String](), origin: origin)
    }

    private static func walletOrigin(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        let isStandardPort = (scheme == "https" && url.port == 443)
            || (scheme == "http" && url.port == 80)
        let port = url.port.map { isStandardPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func walletOrigin(for securityOrigin: WKSecurityOrigin) -> String? {
        let scheme = securityOrigin.protocol.lowercased()
        guard ["http", "https"].contains(scheme), !securityOrigin.host.isEmpty else { return nil }
        let standard = (scheme == "https" && securityOrigin.port == 443)
            || (scheme == "http" && securityOrigin.port == 80) || securityOrigin.port == 0
        return "\(scheme)://\(securityOrigin.host.lowercased())\(standard ? "" : ":\(securityOrigin.port)")"
    }

    private func handleAutofillMessage(
        _ payload: [String: Any],
        tab: Tab,
        webView: WKWebView
    ) {
        // Real agent input is trusted by WebKit; this native activity marker is
        // the independent boundary that prevents it from surfacing or saving
        // credentials through the user-only bridge.
        guard tab.agentInteractionUntil <= Date() else { return }
        let origin = (payload["origin"] as? String)
            .map(BrowserAutofillVault.normalizedOrigin) ?? ""
        switch payload["event"] as? String {
        case "focus":
            guard let raw = payload["category"] as? String,
                  let category = BrowserAutofillCategory(rawValue: raw)
            else { return }
            let rect = (payload["rect"] as? [Double]) ?? []
            autofillPrompt = .init(
                sessionID: tab.ownerSessionID,
                origin: origin,
                category: category,
                fieldName: (payload["name"] as? String) ?? "",
                fieldRect: rect.count == 4
                    ? CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
                    : .zero
            )
        case "passwordSubmit":
            guard let password = payload["password"] as? String, !password.isEmpty else { return }
            pendingPasswordSave = .init(
                sessionID: tab.ownerSessionID,
                origin: origin,
                username: (payload["username"] as? String) ?? "",
                password: password
            )
        default:
            break
        }
    }

    private func record(_ entry: [String: Any], into log: BrowserCaptureLog) {
        let now = Date()
        switch entry["kind"] as? String {
        case "console":
            log.append(console: BrowserConsoleEntry(
                level: (entry["level"] as? String) ?? "log",
                message: (entry["message"] as? String) ?? "",
                url: (entry["url"] as? String) ?? "",
                at: now
            ))
        case "network":
            log.append(network: BrowserNetworkEntry(
                id: (entry["id"] as? String) ?? UUID().uuidString,
                method: (entry["method"] as? String) ?? "GET",
                url: (entry["url"] as? String) ?? "",
                status: entry["status"] as? Int,
                ok: (entry["ok"] as? Bool) ?? false,
                durationMS: (entry["duration_ms"] as? Int) ?? 0,
                contentType: (entry["content_type"] as? String) ?? "",
                source: (entry["source"] as? String) ?? "",
                size: (entry["size"] as? Int) ?? 0,
                at: now,
                body: (entry["body"] as? String) ?? ""
            ))
        default:
            break
        }
    }
}

struct BrowserToolError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

private extension String {
    /// The bridge's stale-ref literal is phrased as a complete error so the
    /// model sees exactly one wording; the broker adds its own `Error: ` prefix.
    var droppingErrorPrefix: String {
        hasPrefix("Error: ") ? String(dropFirst("Error: ".count)) : self
    }
}
