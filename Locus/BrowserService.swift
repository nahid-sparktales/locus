import AppKit
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
}

/// How a navigation ended. A slow page returns `stillLoading` rather than an
/// error: the load is genuinely still running, and telling the model it failed
/// would desynchronise its picture of the page from the real one.
enum BrowserLoadOutcome {
    case finished
    case failed(String)
    case stillLoading
    case cancelled
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
    /// One tab: a web view parked off-screen, plus the delegate state that
    /// drives it.
    @MainActor
    final class Tab: NSObject {
        let id: String
        let host: OffscreenWebHost
        /// The agent session that opened this tab. Concurrent team workers each
        /// drive their own so one cannot navigate another's out from under it.
        let ownerSessionID: String
        let log = BrowserCaptureLog()
        fileprivate var gate: NavigationGate?
        fileprivate weak var service: BrowserService?

        init(id: String, host: OffscreenWebHost, ownerSessionID: String) {
            self.id = id
            self.host = host
            self.ownerSessionID = ownerSessionID
        }

        var webView: WKWebView { host.webView }
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
    }

    @Published private(set) var tabs: [TabSnapshot] = []
    @Published private(set) var isExecuting = false

    private var openTabs: [Tab] = []
    private var activeTabBySession: [String: String] = [:]
    private var tabCounter = 0
    private var cancellationGeneration = 0
    private var currentSessionID: String?
    private var proxyGeneration: Int?

    // FIFO admission. Concurrent workers queue instead of being refused, so a
    // background agent's call is never dropped just because the foreground one
    // is mid-navigation.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private lazy var dataStore: WKWebsiteDataStore = {
        // One store for the whole browser. `nonPersistent()` hands back a *new*
        // store on every call, so building one per tab would mean tabs silently
        // not sharing cookies — a login on one would not carry to the next.
        WKWebsiteDataStore.nonPersistent()
    }()

    // MARK: - Session lifecycle

    /// Drop everything tied to the previous conversation, mirroring
    /// `ComputerControlService.beginSession`.
    func beginSession(_ sessionID: String) {
        guard !sessionID.isEmpty, currentSessionID != sessionID else { return }
        currentSessionID = sessionID
        cancelPendingActions()
        closeAll()
    }

    func cancelPendingActions() {
        cancellationGeneration += 1
        for tab in openTabs {
            tab.webView.stopLoading()
            tab.gate?.settle(.cancelled)
            tab.gate = nil
        }
        isExecuting = false
    }

    private func closeAll() {
        openTabs.removeAll()
        activeTabBySession.removeAll()
        publishTabs()
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
        defer {
            isExecuting = false
            release()
        }

        let generation = cancellationGeneration
        let budget = Duration.milliseconds(max(1_000, min(timeoutMilliseconds, 120_000)))

        do {
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
            default:
                return ["error": "unsupported browser tool '\(tool)'"]
            }
        } catch let error as BrowserToolError {
            return ["error": error.message]
        } catch {
            guard generation == cancellationGeneration else {
                return ["error": "cancelled by the user"]
            }
            return ["error": error.localizedDescription]
        }
    }

    private func navigate(
        _ arguments: [String: Any],
        sessionID: String,
        budget: Duration
    ) async throws -> [String: Any] {
        let tab = tab(for: sessionID)
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
            tab.webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
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
        case .finished:
            let heading = title.isEmpty ? location : "\(title) — \(location)"
            return ["text": "Opened \(heading). Call browser_read_page to see the page."]
        }
    }

    private func readPage(
        _ arguments: [String: Any],
        sessionID: String
    ) async throws -> [String: Any] {
        let tab = try openTab(for: sessionID)

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
        let tab = try openTab(for: sessionID)
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
        let tab = try openTab(for: sessionID)
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
        let tab = try openTab(for: sessionID)
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
        let data = try await tab.host.snapshotPNG()
        guard data.count <= Self.maximumScreenshotBytes else {
            throw BrowserToolError(
                "the capture came back too large (\(data.count / 1_024) KB); "
                + "try a smaller viewport with browser_resize"
            )
        }
        let location = tab.webView.url?.absoluteString ?? "the page"
        return [
            "text": "Captured the visible viewport of \(location).",
            "screenshot": [
                "mime_type": "image/png",
                "data": data.base64EncodedString(),
                "description": "Newest browser viewport for \(location)",
            ],
        ]
    }

    private func waitFor(
        _ arguments: [String: Any],
        sessionID: String,
        budget: Duration
    ) async throws -> [String: Any] {
        let tab = try openTab(for: sessionID)
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

    private func input(
        _ arguments: [String: Any],
        sessionID: String
    ) async throws -> [String: Any] {
        let tab = try openTab(for: sessionID)
        let action = (arguments["action"] as? String)?.lowercased() ?? "click"
        let ref = (arguments["ref"] as? String)?.nilIfBlank

        switch action {
        case "click", "double_click", "right_click", "triple_click":
            guard let ref else {
                throw BrowserToolError("'ref' is required; call browser_read_page for one")
            }
            var options: [String: Any] = [:]
            if action == "double_click" { options["detail"] = 2 }
            if action == "triple_click" { options["detail"] = 3 }
            if action == "right_click" { options["button"] = "right" }
            applyModifiers(arguments, to: &options)
            let raw = try await callBridge(
                tab, "return __locus.click(ref, options)", ["ref": ref, "options": options]
            )
            return try describeAction(raw, verb: "Clicked")

        case "hover":
            guard let ref else { throw BrowserToolError("'ref' is required") }
            let raw = try await callBridge(tab, "return __locus.hover(ref)", ["ref": ref])
            return try describeAction(raw, verb: "Hovered")

        case "scroll_to":
            guard let ref else { throw BrowserToolError("'ref' is required") }
            let raw = try await callBridge(tab, "return __locus.scrollTo(ref)", ["ref": ref])
            return try describeAction(raw, verb: "Scrolled to")

        case "drag":
            guard let from = (arguments["from_ref"] as? String)?.nilIfBlank,
                  let to = (arguments["to_ref"] as? String)?.nilIfBlank
            else { throw BrowserToolError("'from_ref' and 'to_ref' are required for a drag") }
            let raw = try await callBridge(
                tab, "return __locus.drag(from, to)", ["from": from, "to": to]
            )
            return try describeAction(raw, verb: "Dragged")

        case "scroll":
            let raw = try await callBridge(
                tab,
                "return __locus.scrollBy(dx, dy)",
                ["dx": arguments["delta_x"] as? Int ?? 0, "dy": arguments["delta_y"] as? Int ?? 600]
            )
            let payload = (raw as? [String: Any]) ?? [:]
            let y = (payload["y"] as? Int) ?? Int((payload["y"] as? Double) ?? 0)
            return ["text": "Scrolled; the page is now at y=\(y)."]

        case "key":
            guard let key = (arguments["key"] as? String)?.nilIfBlank else {
                throw BrowserToolError("'key' is required")
            }
            var modifiers: [String: Any] = [:]
            applyModifiers(arguments, to: &modifiers)
            _ = try await callBridge(
                tab, "return __locus.pressKey(key, modifiers)", ["key": key, "modifiers": modifiers]
            )
            return ["text": "Pressed \(key). Call browser_read_page to see what changed."]

        case "type", "set_value":
            let value = (arguments["text"] as? String) ?? (arguments["value"] as? String) ?? ""
            if let ref {
                try await refuseSecureField(tab, ref: ref)
                let raw = try await callBridge(
                    tab, "return __locus.setValue(ref, value)", ["ref": ref, "value": value]
                )
                return try describeAction(raw, verb: "Set the value of")
            }
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
        guard let described = raw as? [String: Any] else { return }
        if described["stale"] as? Bool == true {
            throw BrowserToolError(BrowserBridge.staleReferenceMessage.droppingErrorPrefix)
        }
        if described["secure"] as? Bool == true {
            throw BrowserToolError(
                "that is a password or one-time-code field; the user has to type it themselves"
            )
        }
    }

    private func runJavaScript(
        _ arguments: [String: Any],
        sessionID: String
    ) async throws -> [String: Any] {
        let tab = try openTab(for: sessionID)
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
        let tab = tab(for: sessionID)
        var size = tab.host.viewport
        if let preset = (arguments["preset"] as? String).flatMap(BrowserViewport.init(rawValue:)) {
            size = preset.size
        }
        if let width = arguments["width"] as? Int { size.width = CGFloat(width) }
        if let height = arguments["height"] as? Int { size.height = CGFloat(height) }
        tab.host.setViewport(size)
        if let scheme = (arguments["color_scheme"] as? String)?.lowercased() {
            tab.webView.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
        }
        return ["text": """
        Viewport is now \(Int(tab.host.viewport.width))×\(Int(tab.host.viewport.height)) CSS pixels. \
        This resizes the view: device pixel ratio and touch support are not emulated.
        """]
    }

    private func consoleLog(
        _ arguments: [String: Any],
        sessionID: String
    ) -> [String: Any] {
        guard let tab = existingTab(for: sessionID) else {
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
        guard let tab = existingTab(for: sessionID) else {
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
            let tab = makeTab(ownerSessionID: sessionID)
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
                  let index = openTabs.firstIndex(where: {
                      $0.id == id && $0.ownerSessionID == sessionID
                  })
            else { return ["error": "no tab of yours has that id"] }
            let closed = openTabs.remove(at: index)
            if activeTabBySession[sessionID] == closed.id {
                activeTabBySession[sessionID] = openTabs
                    .first { $0.ownerSessionID == sessionID }?.id
            }
            publishTabs()
            return ["text": "Closed \(closed.id)."]
        default:
            // Only this session's tabs are listed, so concurrent team workers
            // cannot navigate each other's out from under them.
            let mine = openTabs.filter { $0.ownerSessionID == sessionID }
            guard !mine.isEmpty else { return ["text": "No tabs are open."] }
            let active = activeTabBySession[sessionID]
            let lines = mine.map { tab in
                let marker = tab.id == active ? "* " : "  "
                let title = tab.webView.title?.nilIfBlank ?? "Untitled"
                return "\(marker)\(tab.id) \(title) — \(tab.webView.url?.absoluteString ?? "about:blank")"
            }
            return ["text": lines.joined(separator: "\n")]
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

    private func openTab(for sessionID: String) throws -> Tab {
        let tab = tab(for: sessionID)
        guard tab.webView.url != nil else {
            throw BrowserToolError("no page is open; call browser_navigate first")
        }
        return tab
    }

    private func existingTab(for sessionID: String) -> Tab? {
        guard let id = activeTabBySession[sessionID] else { return nil }
        return openTabs.first { $0.id == id }
    }

    /// The session's active tab, opening one on first use. The inspector and
    /// the detached window use this to borrow the live web view.
    func tab(for sessionID: String) -> Tab {
        if let id = activeTabBySession[sessionID],
           let existing = openTabs.first(where: { $0.id == id })
        {
            return existing
        }
        return makeTab(ownerSessionID: sessionID)
    }

    @discardableResult
    private func makeTab(ownerSessionID: String) -> Tab {
        tabCounter += 1
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController.addUserScript(BrowserBridge.readerScript())
        configuration.userContentController.addUserScript(BrowserBridge.captureScript())
        // Weak, because the content controller retains its handlers strongly and
        // the cycle would keep every closed tab's buffers alive for good.
        configuration.userContentController.add(
            WeakScriptMessageHandler(self),
            name: BrowserBridge.captureHandlerName
        )
        // Agent clicks carry no user gesture, so this would block programmatic
        // window.open anyway; keeping the default off is the honest posture
        // until managed tabs land.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        #if DEBUG
        // Web Inspector lets any local process attach and read cookies and
        // localStorage for whatever the agent browsed, so it stays out of
        // shipping builds.
        webView.isInspectable = true
        #endif

        let host = OffscreenWebHost(webView: webView)
        let tab = Tab(
            id: "tab_\(tabCounter)",
            host: host,
            ownerSessionID: ownerSessionID
        )
        tab.service = self
        webView.navigationDelegate = self
        objc_setAssociatedObject(webView, &Self.tabKey, tab, .OBJC_ASSOCIATION_RETAIN)

        openTabs.append(tab)
        activeTabBySession[ownerSessionID] = tab.id
        applyProxyIfNeeded()
        publishTabs()
        return tab
    }

    private static var tabKey: UInt8 = 0

    fileprivate func tab(owning webView: WKWebView) -> Tab? {
        objc_getAssociatedObject(webView, &Self.tabKey) as? Tab
    }

    private func publishTabs() {
        let active = Set(activeTabBySession.values)
        tabs = openTabs.map { tab in
            TabSnapshot(
                id: tab.id,
                title: tab.webView.title ?? "",
                url: tab.webView.url?.absoluteString ?? "",
                isLoading: tab.webView.isLoading,
                isActive: active.contains(tab.id)
            )
        }
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
        if let proxy = ProxyRuntime.shared.current {
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
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Defence in depth: the tool refuses a disallowed scheme up front, and
        // this catches anything the page itself tries.
        decisionHandler(BrowserScheme.permits(url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab(owning: webView)?.gate?.settle(.finished)
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
        publishTabs()
    }

    /// A crashed content process leaves a permanently blank rectangle unless
    /// something reloads it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab(owning: webView)?.gate?.settle(.failed("the page's content process stopped"))
        webView.reload()
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
        tab.log.note(dropped: (payload["dropped"] as? Int) ?? 0)
        for entry in (payload["entries"] as? [[String: Any]]) ?? [] {
            record(entry, into: tab.log)
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
