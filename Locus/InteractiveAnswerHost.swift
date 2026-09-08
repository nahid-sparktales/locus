import AppKit
import SwiftUI
import WebKit

// MARK: - Rule list

/// Compiles the interactive-answer rule list once per process and hands the
/// compiled list to every host.
///
/// Fails closed: a host that cannot obtain the list never creates a web view,
/// so a WebKit that rejects the JSON degrades to the written summary instead
/// of running model script with one sandbox layer missing. Resource-type
/// tokens differ across macOS releases; a token the compiler rejects is
/// dropped and recorded rather than taking the whole list down with it.
@MainActor
final class InteractiveAnswerRuleListStore {
    enum Outcome {
        case ready(WKContentRuleList, droppedResourceTypes: [String])
        case failed(String)
    }

    static let shared = InteractiveAnswerRuleListStore()

    private let store: WKContentRuleListStore?
    private let identifier: String
    private let encodedRuleList: (_ blockedTypes: [String]) -> String
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private var compiling = false

    /// `store` nil means WebKit offered no rule-list store at all; every host
    /// then refuses to load.
    init(
        store: WKContentRuleListStore? = .default(),
        identifier: String = InteractiveAnswerDocument.ruleListIdentifier,
        encodedRuleList: @escaping (_ blockedTypes: [String]) -> String = {
            InteractiveAnswerDocument.ruleListJSON(blockedTypes: $0)
        }
    ) {
        self.store = store
        self.identifier = identifier
        self.encodedRuleList = encodedRuleList
    }

    /// The compiled list, or the reason there is none. Concurrent callers
    /// share one compilation.
    func resolve() async -> Outcome {
        if let outcome { return outcome }
        if compiling {
            return await withCheckedContinuation { waiters.append($0) }
        }
        compiling = true
        let result = await compile()
        outcome = result
        compiling = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: result) }
        return result
    }

    func ruleList() async -> WKContentRuleList? {
        if case .ready(let list, _) = await resolve() { return list }
        return nil
    }

    var droppedResourceTypes: [String] {
        if case .ready(_, let dropped) = outcome { return dropped }
        return []
    }

    private func compile() async -> Outcome {
        guard let store else { return .failed("WebKit offers no content rule list store") }
        let allTypes = InteractiveAnswerDocument.blockedResourceTypes
        switch await compile(blockedTypes: allTypes, in: store) {
        case .success(let list):
            return .ready(list, droppedResourceTypes: [])
        case .failure(let firstError):
            // Find the tokens this OS rejects one at a time; anything else
            // that fails is a real error and the store stays failed.
            var accepted: [String] = []
            var dropped: [String] = []
            for type in allTypes {
                switch await compile(blockedTypes: [type], in: store, suffix: ".probe") {
                case .success: accepted.append(type)
                case .failure: dropped.append(type)
                }
            }
            guard !dropped.isEmpty, !accepted.isEmpty else {
                return .failed(firstError.localizedDescription)
            }
            switch await compile(blockedTypes: accepted, in: store) {
            case .success(let list):
                return .ready(list, droppedResourceTypes: dropped)
            case .failure(let error):
                return .failed(error.localizedDescription)
            }
        }
    }

    private func compile(
        blockedTypes: [String],
        in store: WKContentRuleListStore,
        suffix: String = ""
    ) async -> Result<WKContentRuleList, Error> {
        let json = encodedRuleList(blockedTypes)
        return await withCheckedContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier + suffix,
                encodedContentRuleList: json
            ) { list, error in
                if let list {
                    continuation.resume(returning: .success(list))
                } else {
                    continuation.resume(returning: .failure(
                        error ?? InteractiveAnswerHostError.ruleListUnavailable
                    ))
                }
            }
        }
    }
}

enum InteractiveAnswerHostError: LocalizedError {
    case ruleListUnavailable

    var errorDescription: String? {
        switch self {
        case .ruleListUnavailable: "the content rule list did not compile"
        }
    }
}

// MARK: - Watchdog policy

/// How often a live host pings its page and how long a ping may take before
/// the page is judged hung. A `while (true) {}` widget never answers the
/// first ping, so it is torn down after `pingInterval + deadline` seconds.
struct InteractiveAnswerWatchdogPolicy: Equatable {
    var pingInterval: TimeInterval
    var deadline: TimeInterval

    static let `default` = InteractiveAnswerWatchdogPolicy(pingInterval: 2, deadline: 3)
}

// MARK: - Registry

/// Keeps at most `budget` web content hosts alive at once. The transcript can
/// hold any number of interactive answers; each live one is a web content
/// process, so the oldest is torn down when a newer one starts and offers a
/// button to come back.
@MainActor
final class InteractiveAnswerRegistry {
    static let shared = InteractiveAnswerRegistry(budget: 4)

    let budget: Int
    private var live: [InteractiveAnswerHost] = []

    init(budget: Int) {
        self.budget = max(1, budget)
    }

    var liveHostCount: Int { live.count }

    func contains(_ host: InteractiveAnswerHost) -> Bool {
        live.contains { $0 === host }
    }

    /// Admit a host that is about to create a web view, evicting the oldest
    /// live hosts beyond the budget.
    func admit(_ host: InteractiveAnswerHost) {
        release(host)
        live.append(host)
        while live.count > budget, let oldest = live.first {
            oldest.stop(reason: .budgetExceeded)
            // `stop` releases the host; guard against a host that did not.
            if live.first === oldest { live.removeFirst() }
        }
    }

    func release(_ host: InteractiveAnswerHost) {
        live.removeAll { $0 === host }
    }
}

// MARK: - Host

/// One sealed web view for one interactive answer.
///
/// Owns the configuration, the delegates and the lifecycle. The view layer
/// only ever borrows `webView`; every decision about what the page may do is
/// made here so the sandbox cannot be weakened by a presentation change.
@MainActor
final class InteractiveAnswerHost: NSObject, ObservableObject {
    enum StopReason: Equatable {
        case unresponsive
        case terminated
        case budgetExceeded
    }

    enum State: Equatable {
        case idle
        case loading
        case ready
        case unavailable(String)
        case stopped(StopReason)
    }

    /// One pool for every host: process assignment is WebKit's, and a
    /// per-host pool buys no isolation the opaque origin does not already give.
    static let processPool = WKProcessPool()

    /// The world theme updates and watchdog pings run in. Isolated from the
    /// page's own scripts: they see neither the functions nor the results.
    static let themeWorld = WKContentWorld.world(name: "locus.interactive.theme")

    let html: String
    let height: CGFloat

    @Published private(set) var state: State = .idle
    private(set) var webView: WKWebView?

    /// How many times the page asked for a file chooser; always answered nil.
    private(set) var openPanelRequests = 0
    /// How many navigations were cancelled after the initial load.
    private(set) var cancelledNavigations = 0
    /// How many downloads WebKit offered and were cancelled unstarted.
    private(set) var cancelledDownloads = 0
    /// Runs on the main thread right after each watchdog ping is issued. A
    /// test seam: a closure that blocks here stalls the app in exactly the
    /// window where the page's answer cannot be delivered.
    var watchdogDidSendPing: (() -> Void)?
    /// The appearance the page was last themed for.
    private(set) var appliedAppearance: NSAppearance?

    private let ruleListStore: InteractiveAnswerRuleListStore
    private let registry: InteractiveAnswerRegistry
    private let watchdogPolicy: InteractiveAnswerWatchdogPolicy
    private let currentAppearance: () -> NSAppearance
    private let includeContentSecurityPolicy: Bool
    private var initialLoadAllowed = false
    private var generation = 0
    private var watchdogTask: Task<Void, Never>?
    private var pendingPing: UUID?
    private var appearanceObservation: NSKeyValueObservation?

    init(
        html: String,
        height: CGFloat,
        ruleListStore: InteractiveAnswerRuleListStore = .shared,
        registry: InteractiveAnswerRegistry = .shared,
        watchdog: InteractiveAnswerWatchdogPolicy = .default,
        appearance: @escaping () -> NSAppearance = { InteractiveAnswerHost.applicationAppearance() },
        includeContentSecurityPolicy: Bool = true
    ) {
        self.html = html
        self.height = height
        self.ruleListStore = ruleListStore
        self.registry = registry
        self.watchdogPolicy = watchdog
        self.currentAppearance = appearance
        // Tests turn the meta policy off to prove the rule list holds alone;
        // the app never does.
        self.includeContentSecurityPolicy = includeContentSecurityPolicy
        super.init()
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyTheme(for: self.currentAppearance())
            }
        }
    }

    deinit {
        watchdogTask?.cancel()
    }

    nonisolated static func applicationAppearance() -> NSAppearance {
        NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
    }

    /// Begin loading. A no-op unless the host is idle: a torn-down host waits
    /// for an explicit `reload()` from the person, never from a re-appearing
    /// view.
    func start() {
        guard state == .idle else { return }
        state = .loading
        generation += 1
        let attempt = generation
        // The compile is awaited without holding the host: a card that leaves
        // the transcript during it lets the host deinit, and the registry
        // never hears of it.
        Task { @MainActor [weak self, ruleListStore] in
            let outcome = await ruleListStore.resolve()
            guard let self, self.generation == attempt, self.state == .loading else { return }
            switch outcome {
            case .failed(let reason):
                self.state = .unavailable(reason)
            case .ready(let ruleList, _):
                self.registry.admit(self)
                guard self.generation == attempt, self.state == .loading else { return }
                let webView = self.makeWebView(ruleList: ruleList)
                self.webView = webView
                self.initialLoadAllowed = false
                self.startWatchdog()
                webView.loadHTMLString(
                    InteractiveAnswerDocument.wrap(
                        html: self.html,
                        themeCSS: LocusTheme.cssVariables(for: self.currentAppearance()),
                        includeCSP: self.includeContentSecurityPolicy
                    ),
                    baseURL: nil
                )
            }
        }
    }

    /// The person asked for the content back after a stop.
    func reload() {
        tearDown()
        state = .idle
        start()
    }

    /// Stop with a visible reason: the view shows the matching placeholder.
    func stop(reason: StopReason) {
        tearDown()
        state = .stopped(reason)
    }

    /// The view lending out the web view is being dismantled. A live page is
    /// dropped and the host returns to idle so a re-appearing view can start
    /// it again; a stopped host stays stopped — only the person reloads it.
    func detach() {
        let wasLive = state == .loading || state == .ready
        tearDown()
        guard wasLive else { return }
        // Dismantling happens inside SwiftUI's own graph update; publishing a
        // state change from there is an exclusivity violation, so the reset
        // lands on the next turn — and only if nothing else moved the host.
        let attempt = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == attempt, self.webView == nil,
                  self.state == .loading || self.state == .ready
            else { return }
            self.state = .idle
        }
    }

    /// Drop the web view and everything attached to it without changing the
    /// published state.
    func tearDown() {
        generation += 1
        watchdogTask?.cancel()
        watchdogTask = nil
        pendingPing = nil
        registry.release(self)
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
    }

    /// Rewrite the theme rule inside the running page. Runs in the isolated
    /// world, touches only the `#locus-theme` element, and never reloads.
    func applyTheme(for appearance: NSAppearance) {
        appliedAppearance = appearance
        guard let webView else { return }
        webView.appearance = appearance
        let css = LocusTheme.cssVariables(for: appearance)
        let encoded = (try? JSONSerialization.data(withJSONObject: [css]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        let script = """
        (function () {
          var style = document.getElementById(\(jsString(InteractiveAnswerDocument.themeStyleID)));
          if (style) { style.textContent = \(encoded)[0]; }
        })();
        """
        webView.evaluateJavaScript(script, in: nil, in: Self.themeWorld) { _ in }
    }

    /// Evaluate in the isolated world; used by tests to read outcomes the page
    /// wrote into `document.body.dataset`.
    func evaluateInIsolatedWorld(_ script: String) async throws -> Any? {
        guard let webView else { throw InteractiveAnswerHostError.ruleListUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: Self.themeWorld) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Configuration

    private func makeWebView(ruleList: WKContentRuleList) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = Self.processPool
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(ruleList)
        // No message handlers, no user scripts: the page has no channel back
        // into the app, in either world.
        let webView = InteractiveAnswerSealedWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: height),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = false
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.allowsLinkPreview = false
        let appearance = currentAppearance()
        webView.appearance = appearance
        appliedAppearance = appearance
        webView.autoresizingMask = [.width, .height]
        return webView
    }

    private func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    // MARK: Watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        let policy = watchdogPolicy
        let attempt = generation
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(policy.pingInterval))
                guard !Task.isCancelled, let self, self.generation == attempt, self.webView != nil else { return }
                let alive = await self.ping(deadline: policy.deadline)
                guard !Task.isCancelled, self.generation == attempt else { return }
                if !alive {
                    self.stop(reason: .unresponsive)
                    return
                }
            }
        }
    }

    /// The most main-thread time one poll turn is credited with. A turn that
    /// took longer was the app stalling — a relayout, a modal, a synchronous
    /// export — not the page thinking, and the page must not pay for it.
    static let watchdogTurnCredit: Duration = .milliseconds(250)

    /// True when the page answered within `deadline` of main-thread time. A
    /// hung web content process never completes the evaluation; the
    /// completion is left to arrive (or not) and is ignored once its token
    /// is stale.
    ///
    /// The completion can only be delivered on the main thread, so the
    /// deadline is measured in time the main thread was actually free: each
    /// poll turn counts for at most `watchdogTurnCredit`, and once the budget
    /// is spent the run loop gets one more turn, because a queued answer and
    /// the poll's own resumption land in unspecified order.
    private func ping(deadline: TimeInterval) async -> Bool {
        guard let webView else { return false }
        let token = UUID()
        pendingPing = token
        var lastTurn = ContinuousClock.now
        webView.evaluateJavaScript("1", in: nil, in: Self.themeWorld) { [weak self] _ in
            guard let self, self.pendingPing == token else { return }
            self.pendingPing = nil
        }
        watchdogDidSendPing?()
        var responsive: Duration = .zero
        while pendingPing == token, !Task.isCancelled, responsive < .seconds(deadline) {
            try? await Task.sleep(for: .milliseconds(50))
            let now = ContinuousClock.now
            responsive += min(now - lastTurn, Self.watchdogTurnCredit)
            lastTurn = now
        }
        if pendingPing == token, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return pendingPing != token
    }
}

// MARK: - Sealed web view

/// The web view class every host creates.
///
/// WebKit's default context menu offers Open Link, Download Linked File, Copy
/// Link and friends for any `<a href>` the model wrote, and the download path
/// runs through the process pool rather than the navigation policy, so a
/// right-click was the one way sealed content could put a URL of its choosing
/// on the wire. The menu is emptied before it opens — an empty menu never
/// appears — and the inspector can never be switched on after construction.
@MainActor
final class InteractiveAnswerSealedWebView: WKWebView {
    /// How many context menus were suppressed; tests read it.
    private(set) var suppressedContextMenus = 0

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.removeAllItems()
        suppressedContextMenus += 1
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override var isInspectable: Bool {
        get { false }
        set { super.isInspectable = false }
    }
}

// MARK: - Navigation delegate

extension InteractiveAnswerHost: WKNavigationDelegate {
    /// Exactly one navigation is ever allowed: the main-frame `about:blank`
    /// load that carries the wrapped document. Links, form posts, `location`
    /// assignments and anything a frame tries are cancelled here; the
    /// `.download` policy is never returned, and a download WebKit offers by
    /// another route is cancelled below before it starts.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = true
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        let isBlank = navigationAction.request.url.map { $0.scheme?.lowercased() == "about" } ?? true
        if !initialLoadAllowed, isMainFrame, isBlank, webView === self.webView {
            initialLoadAllowed = true
            decisionHandler(.allow, preferences)
            return
        }
        cancelledNavigations += 1
        decisionHandler(.cancel, preferences)
    }

    /// A download reaches the delegate only by a route the policy does not
    /// see — a response WebKit cannot show, or a menu item — and is cancelled
    /// before a destination is ever chosen.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        cancelledDownloads += 1
        download.cancel(nil)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        cancelledDownloads += 1
        download.cancel(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, state == .loading else { return }
        state = .ready
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, state == .loading else { return }
        state = .unavailable(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView, state == .loading else { return }
        state = .unavailable(error.localizedDescription)
    }

    /// The web content process died or was killed. Show that, and wait for the
    /// person: an automatic reload of a page that just crashed (or was killed
    /// for memory) is a loop.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        stop(reason: .terminated)
    }
}

// MARK: - UI delegate

extension InteractiveAnswerHost: WKUIDelegate {
    /// No new windows, ever: `window.open` returns null to the page.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    /// Dialogs complete at once so the page's script never blocks on a modal
    /// nobody will see; the answers are the cancelling ones.
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        completionHandler(nil)
    }

    /// A widget has no business reading local files.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        openPanelRequests += 1
        completionHandler(nil)
    }
}

// MARK: - Representable

/// Lends the host's web view to SwiftUI at a fixed height.
///
/// The height is decided by the part, so `sizeThatFits` answers synchronously
/// from the proposal alone — the transcript's row layout contract
/// (`ResponseSelectableTextView`) — and never waits on the page.
struct InteractiveAnswerWebView: NSViewRepresentable {
    @ObservedObject var host: InteractiveAnswerHost
    let height: CGFloat

    static let heightRange: ClosedRange<CGFloat> = 160...720

    /// The pure layout answer: the proposed width (or the width the view has)
    /// at the clamped fixed height.
    static func fittingSize(proposal: ProposedViewSize, bounds: CGRect, height: CGFloat) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? max(bounds.width, 1)
        return CGSize(width: width, height: height.clamped(to: heightRange))
    }

    func makeNSView(context: Context) -> InteractiveAnswerContainerView {
        let view = InteractiveAnswerContainerView(host: host)
        view.attachIfNeeded()
        return view
    }

    func updateNSView(_ nsView: InteractiveAnswerContainerView, context: Context) {
        nsView.host = host
        nsView.attachIfNeeded()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InteractiveAnswerContainerView, context: Context) -> CGSize? {
        Self.fittingSize(proposal: proposal, bounds: nsView.bounds, height: height)
    }

    static func dismantleNSView(_ nsView: InteractiveAnswerContainerView, coordinator: ()) {
        nsView.host?.detach()
        nsView.host = nil
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Holds the borrowed web view and relays appearance changes into the page.
final class InteractiveAnswerContainerView: NSView {
    weak var host: InteractiveAnswerHost?

    init(host: InteractiveAnswerHost) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func attachIfNeeded() {
        guard let webView = host?.webView else {
            subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if webView.superview !== self {
            subviews.forEach { $0.removeFromSuperview() }
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
    }

    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        host?.applyTheme(for: effectiveAppearance)
    }
}
