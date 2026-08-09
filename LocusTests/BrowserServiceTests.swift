import AppKit
import WebKit
import XCTest
@testable import Locus

@MainActor
final class BrowserServiceTests: XCTestCase {
    private var service: BrowserService!

    override func setUp() async throws {
        try await super.setUp()
        service = BrowserService()
    }

    override func tearDown() async throws {
        service.cancelPendingActions()
        service = nil
        try await super.tearDown()
    }

    // MARK: - What the browser will open

    func testOnlyWebSchemesAreAllowed() {
        XCTAssertTrue(BrowserScheme.permits(URL(string: "https://example.com")!))
        XCTAssertTrue(BrowserScheme.permits(URL(string: "http://localhost:3000/app")!))
        XCTAssertTrue(BrowserScheme.permits(URL(string: "about:blank")!))
        // A file URL here would be an unscoped file reader that never passes
        // through read_file's workspace scoping or its permission prompt.
        XCTAssertFalse(BrowserScheme.permits(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(BrowserScheme.permits(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(BrowserScheme.permits(URL(string: "data:text/html,<b>x")!))
        // Locus's own scheme is the MCP OAuth redirect; a page must not reach it.
        XCTAssertFalse(BrowserScheme.permits(URL(string: "locus://callback")!))
    }

    func testBareHostsBecomeHTTPTheWayThePreviewAlwaysDid() {
        XCTAssertEqual(BrowserScheme.normalize("localhost:3000")?.host, "localhost")
        XCTAssertEqual(BrowserScheme.normalize("localhost:3000")?.scheme, "http")
        XCTAssertEqual(BrowserScheme.normalize("  example.com  ")?.host, "example.com")
        XCTAssertEqual(BrowserScheme.normalize("about:blank")?.absoluteString, "about:blank")
        XCTAssertNil(BrowserScheme.normalize(""))
        XCTAssertNil(BrowserScheme.normalize("   "))
    }

    func testNavigatingToARefusedSchemeExplainsItselfAndOpensNothing() async {
        let result = await service.perform(
            tool: "browser_navigate",
            arguments: ["url": "file:///etc/passwd"],
            sessionID: "session-1",
            timeoutMilliseconds: 5_000
        )
        let message = try? XCTUnwrap(result["error"] as? String)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("file") == true, result.description)
        XCTAssertNil(result["text"])
    }

    func testUnknownToolsAreReportedRatherThanIgnored() async {
        let result = await service.perform(
            tool: "browser_teleport",
            arguments: [:],
            sessionID: "session-1",
            timeoutMilliseconds: 5_000
        )
        XCTAssertEqual(result["error"] as? String, "unsupported browser tool 'browser_teleport'")
    }

    func testReadingBeforeOpeningAnythingSaysSo() async {
        let result = await service.perform(
            tool: "browser_read_page",
            arguments: [:],
            sessionID: "session-1",
            timeoutMilliseconds: 5_000
        )
        XCTAssertEqual(result["error"] as? String, "no page is open; call browser_navigate first")
    }

    // MARK: - The real round trip

    func testNavigateThenReadPageDescribesTheDocument() async throws {
        let tab = service.tab(for: "session-1")
        let waiter = LoadWaiter()
        tab.webView.navigationDelegate = waiter
        tab.webView.loadHTMLString(
            "<title>Fixture</title><body><h1>Hello</h1><button>Press me</button></body>",
            baseURL: nil
        )
        try await waiter.wait()
        // Hand the delegate back so the service owns navigation again.
        tab.webView.navigationDelegate = service

        let result = await service.perform(
            tool: "browser_read_page",
            arguments: [:],
            sessionID: "session-1",
            timeoutMilliseconds: 10_000
        )
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertTrue(text.contains("Fixture"), text)
        XCTAssertTrue(text.contains("heading \"Hello\""), text)
        XCTAssertTrue(text.contains("button \"Press me\" [ref_1]"), text)
        XCTAssertTrue(text.contains("addressable as ref_N"), text)
    }

    /// Several agent workers share one service. Queueing rather than refusing
    /// is what keeps a background worker's call from being dropped because the
    /// foreground one happened to be mid-navigation.
    func testConcurrentCallersAreQueuedRatherThanRefused() async {
        async let first = service.perform(
            tool: "browser_read_page",
            arguments: [:],
            sessionID: "session-1",
            timeoutMilliseconds: 5_000
        )
        async let second = service.perform(
            tool: "browser_read_page",
            arguments: [:],
            sessionID: "session-2",
            timeoutMilliseconds: 5_000
        )
        let results = await [first, second]
        // Both ran and got the same honest answer; neither was refused as busy.
        for result in results {
            XCTAssertEqual(
                result["error"] as? String,
                "no page is open; call browser_navigate first"
            )
        }
        XCTAssertFalse(service.isExecuting, "the queue slot must always be released")
    }

    func testEachSessionGetsItsOwnTab() {
        let mine = service.tab(for: "session-1")
        let theirs = service.tab(for: "session-2")
        XCTAssertNotEqual(mine.id, theirs.id)
        XCTAssertEqual(mine.ownerSessionID, "session-1")
        XCTAssertEqual(theirs.ownerSessionID, "session-2")
        // Asking twice returns the same tab rather than piling up new ones.
        XCTAssertTrue(service.tab(for: "session-1") === mine)
        XCTAssertEqual(service.tabs.count, 2)
    }

    /// Switching the foreground conversation must not destroy anything: tabs
    /// belong to the session that opened them, and a background team worker
    /// keeps browsing while the user reads another chat.
    func testSwitchingSessionsKeepsEverySessionsTabs() {
        _ = service.tab(for: "session-1")
        _ = service.tab(for: "session-2")
        XCTAssertEqual(service.tabs.count, 2)
        service.beginSession("session-2")
        XCTAssertEqual(service.tabs.count, 2)
        service.beginSession("session-1")
        XCTAssertEqual(service.tabs.count, 2)
    }

    func testClosingASessionsTabsLeavesTheOthersAlone() {
        _ = service.tab(for: "session-1")
        _ = service.tab(for: "session-2")
        service.closeTabs(ownedBy: "session-1")
        XCTAssertEqual(service.tabs.count, 1)
        XCTAssertEqual(service.tabs.first?.ownerSessionID, "session-2")
    }

    /// A stop in one conversation must not relabel another conversation's
    /// result as cancelled — generations are per session.
    func testScopedCancelDoesNotDisturbOtherSessions() async {
        _ = service.tab(for: "session-1")
        _ = service.tab(for: "session-2")
        service.cancelPendingActions(ownedBy: "session-1")

        // session-2's next action reports its own honest error, not a
        // cancellation echo from session-1's stop.
        let result = await service.perform(
            tool: "browser_read_page",
            arguments: [:],
            sessionID: "session-2",
            timeoutMilliseconds: 5_000
        )
        XCTAssertEqual(
            result["error"] as? String,
            "no page is open; call browser_navigate first"
        )
    }

    func testUserNavigationSharesTheAgentsSchemeRules() {
        XCTAssertFalse(service.userNavigate("file:///etc/passwd", sessionID: "session-1"))
        XCTAssertFalse(service.userNavigate("javascript:alert(1)", sessionID: "session-1"))
        XCTAssertFalse(service.userNavigate("   ", sessionID: "session-1"))
        // A bare host is coerced the way the preview always did it.
        XCTAssertTrue(service.userNavigate("localhost:3000", sessionID: "session-1"))
        XCTAssertEqual(service.tabs.count, 1)
    }

    func testSnapshotsCarryTheChromeState() {
        _ = service.tab(for: "session-1")
        let snapshot = service.activeSnapshot(for: "session-1")
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.canGoBack, false)
        XCTAssertEqual(snapshot?.canGoForward, false)
        XCTAssertEqual(snapshot?.ownerSessionID, "session-1")
        XCTAssertEqual(service.snapshots(for: "session-1").count, 1)
        XCTAssertTrue(service.snapshots(for: "elsewhere").isEmpty)
    }

    func testTabCapEvictsDormantSessionsFirst() {
        service.beginSession("current")
        service.setProtectedSessions(["worker-1"])
        _ = service.tab(for: "dormant")
        _ = service.tab(for: "worker-1")
        _ = service.tab(for: "current")
        for index in 0..<BrowserService.maximumLiveTabs {
            service.userNewTab(sessionID: index % 2 == 0 ? "current" : "worker-1")
        }

        let owners = Set(service.tabs.map(\.ownerSessionID))
        // The dormant conversation's tab was the sacrifice; the foreground
        // session and the live worker kept every one of theirs.
        XCTAssertFalse(owners.contains("dormant"))
        XCTAssertTrue(owners.contains("current"))
        XCTAssertTrue(owners.contains("worker-1"))
    }

    func testUserTabManagementStaysInsideTheSession() {
        _ = service.tab(for: "session-1")
        _ = service.tab(for: "session-2")
        let foreign = service.tabs.first { $0.ownerSessionID == "session-2" }!

        // Another session's tab is not selectable or closable from here.
        service.userSelectTab(foreign.id, sessionID: "session-1")
        XCTAssertNotEqual(service.activeSnapshot(for: "session-1")?.id, foreign.id)
        service.userCloseTab(foreign.id, sessionID: "session-1")
        XCTAssertEqual(service.tabs.count, 2)

        service.userNewTab(sessionID: "session-1")
        XCTAssertEqual(service.snapshots(for: "session-1").count, 2)
        let mine = service.snapshots(for: "session-1")
        service.userSelectTab(mine[0].id, sessionID: "session-1")
        XCTAssertEqual(service.activeSnapshot(for: "session-1")?.id, mine[0].id)
        service.userCloseTab(mine[0].id, sessionID: "session-1")
        XCTAssertEqual(service.snapshots(for: "session-1").count, 1)
    }
}

@MainActor
final class BrowserActionRoutingTests: XCTestCase {
    /// A background worker's request must be served straight away and answered
    /// on the socket that raised it. Parking it the way a computer action is
    /// parked would block that worker until somebody opened its conversation,
    /// and answering on `conversationBackend` would send the result to whichever
    /// session happens to be in front.
    func testBrowserActionsAnswerImmediatelyOnTheAskingTransport() async throws {
        let model = AppModel()
        var replies: [[String: Any]] = []

        let task = model.runBrowserAction([
            "request_id": "req-1",
            "tool": "browser_read_page",
            "arguments": [:],
            "session_id": "background-worker",
            "timeout_ms": 5_000,
        ]) { payload in
            replies.append(payload)
        }
        await task?.value

        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?["type"] as? String, "browser_action_result")
        XCTAssertEqual(replies.first?["request_id"] as? String, "req-1")
        let result = try XCTUnwrap(replies.first?["result"] as? [String: Any])
        XCTAssertNotNil(result["error"], "an unopened tab is an error, not silence")
    }

    func testMalformedRequestsAreIgnoredRatherThanCrashing() {
        let model = AppModel()
        var replies: [[String: Any]] = []
        let task = model.runBrowserAction(["tool": "browser_read_page"]) { payload in
            replies.append(payload)
        }
        XCTAssertNil(task)
        XCTAssertTrue(replies.isEmpty)
    }
}

@MainActor
final class BrowserSettingsTests: XCTestCase {
    func testBrowserSettingsRoundTripAndDefaultOn() throws {
        var settings = AppSettings()
        XCTAssertTrue(settings.browserEnabled, "the browser ships on")
        XCTAssertEqual(settings.resolvedBrowserViewport, .desktop)

        settings.browserEnabled = false
        settings.browserViewportRaw = BrowserViewport.mobile.rawValue
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.browserEnabled)
        XCTAssertEqual(decoded.resolvedBrowserViewport, .mobile)
    }

    func testAnUnknownViewportFallsBackInsteadOfFailingTheWholeDecode() throws {
        var settings = AppSettings()
        settings.browserViewportRaw = "holographic"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.resolvedBrowserViewport, .desktop)
        XCTAssertTrue(decoded.browserEnabled)
    }
}
