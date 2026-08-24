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

    func testOrdinaryBrowsingUsesTheCacheAndLoopbackHardReloads() {
        // The hard-reload policy came from the dev-server Preview pane, where
        // stale assets hide the user's edit; WebKit propagates it to every
        // subresource, so applying it to the open web refetched everything on
        // every navigation.
        XCTAssertEqual(
            BrowserScheme.cachePolicy(for: URL(string: "https://example.com")!),
            .useProtocolCachePolicy
        )
        for loopback in [
            "http://localhost:3000/app", "http://127.0.0.1:8080",
            "http://app.localhost:5173", "http://[::1]:9000",
        ] {
            XCTAssertEqual(
                BrowserScheme.cachePolicy(for: URL(string: loopback)!),
                .reloadIgnoringLocalCacheData,
                loopback
            )
        }
    }

    func testTabsIdentifyAsSafariToAvoidBotInterstitials() async {
        let tab = service.tab(for: "session-ua")
        let userAgent = try? await tab.webView.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertTrue(
            userAgent?.contains("Safari/") == true && userAgent?.contains("Version/") == true,
            userAgent ?? "no user agent"
        )
    }

    func testUnchangedProfileIdentityKeepsTheSameStore() {
        let tab = service.tab(for: "session-store")
        let store = tab.webView.configuration.websiteDataStore

        // This runs on every session_info; an ephemeral→ephemeral rebuild
        // used to throw away the in-memory cache each time.
        service.configureProfile(workspacePath: "/tmp/ws", persistent: false)

        XCTAssertTrue(
            service.tab(for: "session-store").webView.configuration.websiteDataStore === store
        )
        XCTAssertFalse(service.snapshots(for: "session-store").isEmpty)
    }

    func testClosedTabsActuallyDeallocate() {
        // The associated object made the web view retain its Tab, the Tab its
        // host, the host its web view — closing a tab freed nothing until
        // retire() started breaking the cycle.
        weak var closedTab: BrowserService.Tab?
        autoreleasepool {
            let tab = service.tab(for: "session-retire")
            closedTab = tab
            service.userCloseTab(tab.id, sessionID: "session-retire")
        }
        XCTAssertNil(closedTab, "closing a tab must break the webView→Tab retain cycle")
    }

    func testPrewarmSurfacesNoTabs() {
        service.prewarm()
        XCTAssertTrue(service.tabs.isEmpty, "prewarming must not publish a tab")

        // Once a real tab exists the processes are up; prewarm stands down.
        _ = service.tab(for: "session-warm")
        service.prewarm()
        XCTAssertEqual(service.snapshots(for: "session-warm").count, 1)
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

    // MARK: - Parity with what a browser pane can do

    /// Load a fixture into a tab and hand navigation back to the service.
    private func load(_ html: String, into tab: BrowserService.Tab) async throws {
        let waiter = LoadWaiter()
        tab.webView.navigationDelegate = waiter
        tab.webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.test"))
        try await waiter.wait()
        tab.webView.navigationDelegate = service
    }

    func testANewTabOpensInTheBackgroundWithoutStealingTheView() async throws {
        let first = service.tab(for: "session-tabs")
        try await load("<title>First</title><body>one</body>", into: first)

        let opened = await service.perform(
            tool: "browser_tabs",
            arguments: ["action": "new"],
            sessionID: "session-tabs",
            timeoutMilliseconds: 5_000
        )
        let text = try XCTUnwrap(opened["text"] as? String)
        // The id has to come back: a background tab nothing can name is useless.
        XCTAssertTrue(text.contains("tab_"), text)
        XCTAssertTrue(text.contains("background"), text)
        XCTAssertEqual(service.activeSnapshot(for: "session-tabs")?.id, first.id)
        XCTAssertEqual(service.snapshots(for: "session-tabs").count, 2)
    }

    func testAToolCanDriveANamedTabWithoutMakingItActive() async throws {
        let first = service.tab(for: "session-target")
        try await load("<title>First</title><body><h1>one</h1></body>", into: first)
        let second = try service.tab(for: "session-target", tabID: nil)
        XCTAssertEqual(first.id, second.id)

        let opened = await service.perform(
            tool: "browser_tabs",
            arguments: ["action": "new"],
            sessionID: "session-target",
            timeoutMilliseconds: 5_000
        )
        let openedText = try XCTUnwrap(opened["text"] as? String)
        let backgroundID = try XCTUnwrap(
            openedText.split(separator: " ").first(where: { $0.hasPrefix("tab_") }).map(String.init)
        )
        let background = try service.tab(for: "session-target", tabID: backgroundID)
        try await load("<title>Second</title><body><h1>two</h1></body>", into: background)

        let read = await service.perform(
            tool: "browser_read_page",
            arguments: ["tab_id": backgroundID],
            sessionID: "session-target",
            timeoutMilliseconds: 10_000
        )
        let text = try XCTUnwrap(read["text"] as? String)
        XCTAssertTrue(text.contains("two"), text)
        // Reading a background tab must not pull the view onto it.
        XCTAssertEqual(service.activeSnapshot(for: "session-target")?.id, first.id)
    }

    func testAnotherSessionsTabIdIsRefusedRatherThanBorrowed() async throws {
        let mine = service.tab(for: "session-mine")
        try await load("<body>mine</body>", into: mine)
        let theirs = service.tab(for: "session-theirs")
        try await load("<body>theirs</body>", into: theirs)

        let result = await service.perform(
            tool: "browser_read_page",
            arguments: ["tab_id": theirs.id],
            sessionID: "session-mine",
            timeoutMilliseconds: 5_000
        )
        // Concurrent workers share this service; one steering another's tab
        // would be indistinguishable from the page navigating itself.
        XCTAssertNil(result["text"])
        XCTAssertTrue(
            (result["error"] as? String)?.contains(theirs.id) == true,
            result.description
        )
    }

    func testScreenshotSaysWhichCoordinateFrameTheImageIsIn() async throws {
        let tab = service.tab(for: "session-shot")
        try await load("<body style='margin:0'><div style='height:900px'>tall</div></body>", into: tab)

        let full = await service.perform(
            tool: "browser_screenshot",
            arguments: [:],
            sessionID: "session-shot",
            timeoutMilliseconds: 15_000
        )
        let fullText = try XCTUnwrap(full["text"] as? String)
        XCTAssertNotNil(full["screenshot"])
        // Without the frame, a coordinate read off the picture is a guess.
        XCTAssertTrue(fullText.contains("pixels covering"), fullText)
        XCTAssertTrue(fullText.contains("browser_input"), fullText)

        let region = await service.perform(
            tool: "browser_screenshot",
            arguments: ["region": [10, 20, 200, 100]],
            sessionID: "session-shot",
            timeoutMilliseconds: 15_000
        )
        let regionText = try XCTUnwrap(region["text"] as? String)
        XCTAssertNotNil(region["screenshot"])
        XCTAssertTrue(regionText.contains("200×100"), regionText)
        XCTAssertTrue(regionText.contains("(10, 20)"), regionText)
    }

    func testAMalformedRegionIsExplainedRatherThanCaptured() async throws {
        let tab = service.tab(for: "session-region")
        try await load("<body>x</body>", into: tab)
        let result = await service.perform(
            tool: "browser_screenshot",
            arguments: ["region": [10, 20, 0, 100]],
            sessionID: "session-region",
            timeoutMilliseconds: 10_000
        )
        XCTAssertNil(result["screenshot"])
        XCTAssertTrue(
            (result["error"] as? String)?.contains("width and height") == true,
            result.description
        )
    }

    func testTheMobilePresetPresentsAPhoneAndSaysToReload() async throws {
        let tab = service.tab(for: "session-device")
        try await load("<body>x</body>", into: tab)

        let result = await service.perform(
            tool: "browser_resize",
            arguments: ["preset": "mobile"],
            sessionID: "session-device",
            timeoutMilliseconds: 5_000
        )
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertTrue(text.contains("390×844"), text)
        XCTAssertTrue(text.contains("mobile user agent"), text)
        // A site chooses what to serve at load time, so a profile change that
        // did not say this would leave the model reading the desktop document.
        XCTAssertTrue(text.contains("Reload"), text)

        try await load("<body>reloaded</body>", into: tab)
        let agent = try await tab.webView.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertTrue(agent?.contains("iPhone") == true, agent ?? "no user agent")
        let touch = try await tab.webView.evaluateJavaScript("navigator.maxTouchPoints") as? Int
        XCTAssertEqual(touch, 5)
        let coarse = try await tab.webView.evaluateJavaScript(
            "matchMedia('(pointer: coarse)').matches"
        ) as? Bool
        XCTAssertEqual(coarse, true, "feature detection still sees a desktop pointer")
        let hover = try await tab.webView.evaluateJavaScript(
            "matchMedia('(hover: hover)').matches"
        ) as? Bool
        XCTAssertEqual(hover, false)
    }

    func testGoingBackToDesktopStopsPretendingToBeAPhone() async throws {
        let tab = service.tab(for: "session-undevice")
        try await load("<body>x</body>", into: tab)
        _ = await service.perform(
            tool: "browser_resize",
            arguments: ["preset": "mobile"],
            sessionID: "session-undevice",
            timeoutMilliseconds: 5_000
        )
        _ = await service.perform(
            tool: "browser_resize",
            arguments: ["preset": "desktop"],
            sessionID: "session-undevice",
            timeoutMilliseconds: 5_000
        )
        try await load("<body>x</body>", into: tab)
        let agent = try await tab.webView.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertFalse(agent?.contains("iPhone") == true, agent ?? "no user agent")
        let coarse = try await tab.webView.evaluateJavaScript(
            "matchMedia('(pointer: coarse)').matches"
        ) as? Bool
        XCTAssertEqual(coarse, false)
    }

    func testDeviceEmulationCanBeTurnedOffEntirely() async throws {
        service.deviceEmulationEnabled = false
        let tab = service.tab(for: "session-nodevice")
        try await load("<body>x</body>", into: tab)
        let result = await service.perform(
            tool: "browser_resize",
            arguments: ["preset": "mobile"],
            sessionID: "session-nodevice",
            timeoutMilliseconds: 5_000
        )
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertTrue(text.contains("390×844"), text)
        XCTAssertFalse(text.contains("mobile user agent"), text)
        XCTAssertFalse(tab.emulatesDevice)
    }

    func testTypingIntoAFocusedPasswordFieldIsRefusedWithoutARef() async throws {
        let tab = service.tab(for: "session-secure")
        try await load("""
        <body>
          <form>
            <input id="p" type="password">
          </form>
          <script>document.getElementById('p').focus();</script>
        </body>
        """, into: tab)

        // Aiming by coordinate rather than by ref must not route around the
        // credential gate: with no ref there is no element in the arguments to
        // vet, so the focused element is what gets checked.
        let result = await service.perform(
            tool: "browser_input",
            arguments: ["action": "type", "text": "hunter2"],
            sessionID: "session-secure",
            timeoutMilliseconds: 10_000
        )
        XCTAssertNil(result["text"])
        XCTAssertTrue(
            (result["error"] as? String)?.contains("password") == true,
            result.description
        )
        let value = try await tab.webView.evaluateJavaScript("document.getElementById('p').value") as? String
        XCTAssertEqual(value, "")
    }

    func testCoordinatesStillWorkWithRealInputTurnedOff() async throws {
        service.realInputEnabled = false
        let tab = service.tab(for: "session-synthetic")
        try await load("""
        <body style="margin:0">
          <button id="b" style="position:absolute;left:0;top:0;width:300px;height:120px">Go</button>
          <script>
            window.hits = 0;
            document.getElementById('b').addEventListener('click', () => { window.hits += 1; });
          </script>
        </body>
        """, into: tab)

        let result = await service.perform(
            tool: "browser_input",
            arguments: ["action": "click", "at": [100, 60]],
            sessionID: "session-synthetic",
            timeoutMilliseconds: 10_000
        )
        XCTAssertNotNil(result["text"], result.description)
        let hits = try await tab.webView.evaluateJavaScript("window.hits") as? Int
        XCTAssertEqual(hits, 1, "the synthetic fallback did not reach the element under the point")
    }

    func testAClickOnNothingIsReportedRatherThanCountedAsSuccess() async throws {
        service.realInputEnabled = false
        let tab = service.tab(for: "session-empty")
        try await load("<body style='margin:0'></body>", into: tab)
        let result = await service.perform(
            tool: "browser_input",
            arguments: ["action": "click", "at": [50, 50_000]],
            sessionID: "session-empty",
            timeoutMilliseconds: 10_000
        )
        XCTAssertNil(result["text"], result.description)
        XCTAssertNotNil(result["error"])
    }

    func testWaitingForNothingInParticularJustWaits() async {
        let started = ContinuousClock.now
        let result = await service.perform(
            tool: "browser_wait_for",
            arguments: ["seconds": 0.2],
            sessionID: "session-wait",
            timeoutMilliseconds: 10_000
        )
        // No page needed: asking the model to navigate somewhere before it may
        // pause would be absurd.
        XCTAssertTrue((result["text"] as? String)?.contains("Waited") == true, result.description)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(150))
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

    func testCloseOtherTabsClosesOnlyTheSessionsOwnAndActivatesTheKeeper() {
        _ = service.tab(for: "session-1")
        service.userNewTab(sessionID: "session-1")
        service.userNewTab(sessionID: "session-1")
        _ = service.tab(for: "session-2")
        let keeper = service.snapshots(for: "session-1")[1]

        service.userCloseOtherTabs(keeping: keeper.id, sessionID: "session-1")

        XCTAssertEqual(service.snapshots(for: "session-1").map(\.id), [keeper.id])
        XCTAssertEqual(service.activeSnapshot(for: "session-1")?.id, keeper.id)
        XCTAssertEqual(service.snapshots(for: "session-2").count, 1)
    }

    func testCloseOtherTabsRefusesAForeignKeeper() {
        _ = service.tab(for: "session-1")
        service.userNewTab(sessionID: "session-1")
        let foreign = service.tab(for: "session-2")

        // A keeper the session does not own must be a no-op, never a partial
        // close of the session's own tabs.
        service.userCloseOtherTabs(keeping: foreign.id, sessionID: "session-1")

        XCTAssertEqual(service.snapshots(for: "session-1").count, 2)
        XCTAssertEqual(service.snapshots(for: "session-2").count, 1)
    }

    func testCycleTabWrapsAndStaysInsideTheSession() {
        _ = service.tab(for: "session-1")
        service.userNewTab(sessionID: "session-1")
        service.userNewTab(sessionID: "session-1")
        _ = service.tab(for: "session-2")
        let mine = service.snapshots(for: "session-1").map(\.id)
        service.userSelectTab(mine[2], sessionID: "session-1")

        service.userCycleTab(sessionID: "session-1", forward: true)
        XCTAssertEqual(service.activeSnapshot(for: "session-1")?.id, mine[0], "forward wraps")
        service.userCycleTab(sessionID: "session-1", forward: false)
        XCTAssertEqual(service.activeSnapshot(for: "session-1")?.id, mine[2], "backward wraps")

        let visited = (0..<6).map { _ -> String? in
            service.userCycleTab(sessionID: "session-1", forward: true)
            return service.activeSnapshot(for: "session-1")?.ownerSessionID
        }
        XCTAssertTrue(visited.allSatisfy { $0 == "session-1" }, "the ring never leaves the session")
    }

    func testFaviconIsFetchedOncePerHostAndFailureNeverRetries() async {
        var fetches = 0
        service.faviconFetcher = { _ in
            fetches += 1
            return nil  // a failed fetch
        }
        let tab = service.tab(for: "session-fav")
        // The probe path needs a live page URL; drive the cache directly the
        // way didFinish does, twice, with the JS hop bypassed by an
        // about-blank page that declares nothing.
        tab.webView.loadHTMLString("<title>x</title>", baseURL: URL(string: "https://icons.example"))
        // Wait for the load so webView.url is set.
        for _ in 0..<200 where tab.webView.url == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        service.noteFaviconOpportunity(for: tab.webView)
        service.noteFaviconOpportunity(for: tab.webView)
        // Let the fetch tasks drain.
        for _ in 0..<100 where fetches == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(fetches, 1, "one attempt per origin, in-flight and failed never retry")
        XCTAssertNil(service.favicon(forPageURL: URL(string: "https://icons.example")))
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
        model.selectInspectorTab(.files)
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
        XCTAssertEqual(model.inspectorTab, .files, "background workers must not pull focus")
    }

    func testForegroundAgentBrowserActionOpensTheBrowserPanel() async {
        let model = AppModel(startImmediately: false)
        model.currentSessionID = "foreground"
        model.selectInspectorTab(.files)

        let task = model.runBrowserAction([
            "request_id": "req-foreground",
            "tool": "browser_read_page",
            "arguments": [:],
            "session_id": "foreground",
        ]) { _ in }
        await task?.value

        XCTAssertEqual(model.inspectorTab, .preview)
        XCTAssertFalse(model.inspectorCollapsed)
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

@MainActor
final class NotesStoreTests: XCTestCase {
    private func temporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocusNotesTests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    func testWorkspaceIsTheDefaultAndScopeSettingsRoundTripSafely() throws {
        XCTAssertEqual(AppSettings().resolvedNotesScope, .workspace)
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).resolvedNotesScope,
            .workspace
        )

        var settings = AppSettings()
        settings.notesScopeRaw = NotesScope.chat.rawValue
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.resolvedNotesScope, .chat)

        let future = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"notesScopeRaw":"account"}"#.utf8)
        )
        XCTAssertEqual(future.resolvedNotesScope, .workspace)
    }

    func testWorkspaceNotesAreSharedWhileChatNotesRemainSeparateAndLegacyCompatible() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Project", isDirectory: true)
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let workspaceOne = NotesStore.testingStore(
            workspacePath: workspace.path,
            sessionID: "chat-one",
            scope: .workspace,
            applicationSupport: support
        )
        XCTAssertNil(workspaceOne.perform(
            tool: "notes_update",
            arguments: ["action": "replace", "text": "Shared project facts"]
        )["error"])
        let workspaceTwo = NotesStore.testingStore(
            workspacePath: workspace.path,
            sessionID: "chat-two",
            scope: .workspace,
            applicationSupport: support
        )
        XCTAssertEqual(workspaceTwo.text, "Shared project facts")
        XCTAssertEqual(workspaceOne.fileURL, workspaceTwo.fileURL)
        XCTAssertEqual(workspaceOne.fileURL.deletingLastPathComponent().lastPathComponent, "Workspace Notes")

        let chatOne = NotesStore.testingStore(
            workspacePath: workspace.path,
            sessionID: "chat-one",
            scope: .chat,
            applicationSupport: support
        )
        _ = chatOne.perform(
            tool: "notes_update",
            arguments: ["action": "replace", "text": "Private scratchpad"]
        )
        let chatTwo = NotesStore.testingStore(
            workspacePath: workspace.path,
            sessionID: "chat-two",
            scope: .chat,
            applicationSupport: support
        )
        XCTAssertEqual(chatTwo.text, "")
        XCTAssertNotEqual(chatOne.fileURL, chatTwo.fileURL)
        XCTAssertEqual(chatOne.fileURL.deletingLastPathComponent().lastPathComponent, "Chat Notes")
    }

    func testGlobalScopeSharesOneDocumentAcrossWorkspacesAndChats() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)

        let fromProjectA = NotesStore.testingStore(
            workspacePath: root.appendingPathComponent("project-a").path,
            sessionID: "chat-one",
            scope: .global,
            applicationSupport: support
        )
        XCTAssertNil(fromProjectA.perform(
            tool: "notes_update",
            arguments: ["action": "replace", "text": "Everywhere note"]
        )["error"])

        // A different workspace and a different chat open the same document.
        let fromProjectB = NotesStore.testingStore(
            workspacePath: root.appendingPathComponent("project-b").path,
            sessionID: "chat-two",
            scope: .global,
            applicationSupport: support
        )
        XCTAssertEqual(fromProjectB.text, "Everywhere note")
        XCTAssertEqual(fromProjectA.fileURL, fromProjectB.fileURL)
        XCTAssertEqual(
            fromProjectA.fileURL.deletingLastPathComponent().lastPathComponent,
            "Shared Notes"
        )

        // And it is a document of its own, not either scoped one.
        let identities = Set([NotesScope.workspace, .chat, .global].map {
            NotesStore.storageIdentity(
                workspacePath: root.path,
                sessionID: "chat-one",
                scope: $0
            )
        })
        XCTAssertEqual(identities.count, 3)
    }

    func testModelNotesActionsAppendReadAndEnforceBounds() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore.testingStore(
            workspacePath: root.path,
            sessionID: "chat",
            scope: .workspace,
            applicationSupport: root
        )

        _ = store.perform(
            tool: "notes_update",
            arguments: ["action": "replace", "text": "First"]
        )
        let appended = store.perform(
            tool: "notes_update",
            arguments: ["action": "append", "text": "Second"]
        )
        XCTAssertEqual(store.text, "First\nSecond")
        XCTAssertEqual(appended["character_count"] as? Int, 12)

        let read = store.perform(tool: "notes_read", arguments: ["max_chars": 5])
        XCTAssertEqual(read["truncated"] as? Bool, true)
        XCTAssertTrue((read["text"] as? String)?.hasPrefix("First") == true)

        let tooLarge = store.perform(
            tool: "notes_update",
            arguments: [
                "action": "replace",
                "text": String(repeating: "x", count: NotesStore.maximumCharacters + 1),
            ]
        )
        XCTAssertNotNil(tooLarge["error"])
        XCTAssertEqual(store.text, "First\nSecond")
    }

    private func boldDefaultFont() -> NSFont {
        NSFontManager.shared.convert(NotesTextStyle.defaultFont, toHaveTrait: .boldFontMask)
    }

    private func isBold(_ attributed: NSAttributedString, at location: Int) throws -> Bool {
        let font = try XCTUnwrap(
            attributed.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        )
        return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    func testRichFormattingPersistsAcrossStoresAndKeepsThePlainMirror() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = NotesStore.testingStore(
            workspacePath: root.path,
            sessionID: "chat",
            scope: .workspace,
            applicationSupport: root
        )
        let styled = NSMutableAttributedString(attributedString: NotesTextStyle.plain("Bold plan"))
        styled.addAttribute(.font, value: boldDefaultFont(), range: NSRange(location: 0, length: 4))
        store.updateAttributed(styled)
        store.flushForTesting()

        XCTAssertEqual(store.text, "Bold plan")
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "Bold plan")

        let restored = NotesStore.testingStore(
            workspacePath: root.path,
            sessionID: "chat",
            scope: .workspace,
            applicationSupport: root
        )
        XCTAssertEqual(restored.text, "Bold plan")
        XCTAssertEqual(restored.attributedText.string, restored.text)
        XCTAssertTrue(try isBold(restored.attributedText, at: 0))
        XCTAssertFalse(try isBold(restored.attributedText, at: 6))
    }

    func testAgentAppendKeepsUserStylingWhileReplaceResetsIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore.testingStore(
            workspacePath: root.path,
            sessionID: "chat",
            scope: .workspace,
            applicationSupport: root
        )

        let styled = NSMutableAttributedString(attributedString: NotesTextStyle.plain("Keep"))
        styled.addAttribute(.font, value: boldDefaultFont(), range: NSRange(location: 0, length: 4))
        store.updateAttributed(styled)

        let appended = store.perform(
            tool: "notes_update",
            arguments: ["action": "append", "text": "agent line"]
        )
        XCTAssertNil(appended["error"])
        XCTAssertEqual(store.text, "Keep\nagent line")
        XCTAssertEqual(store.attributedText.string, store.text)
        XCTAssertTrue(try isBold(store.attributedText, at: 0))
        XCTAssertFalse(try isBold(store.attributedText, at: 6))

        _ = store.perform(
            tool: "notes_update",
            arguments: ["action": "replace", "text": "Fresh start"]
        )
        XCTAssertEqual(store.text, "Fresh start")
        XCTAssertEqual(store.attributedText.string, store.text)
        XCTAssertFalse(try isBold(store.attributedText, at: 0))
    }

    func testAgentAppendKeepsTheMirrorAlignedAfterABareCarriageReturn() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore.testingStore(
            workspacePath: root.path,
            sessionID: "chat",
            scope: .workspace,
            applicationSupport: root
        )

        // The separator "\n" merges with a trailing "\r" into one "\r\n"
        // grapheme; the mirror must stay aligned by construction rather than
        // by character-count arithmetic.
        store.update("ends in cr\r")
        let appended = store.perform(
            tool: "notes_update",
            arguments: ["action": "append", "text": "next"]
        )
        XCTAssertNil(appended["error"])
        XCTAssertEqual(store.text, "ends in cr\r\nnext")
        XCTAssertEqual(store.attributedText.string, store.text)
    }

    func testStyledArchiveIsIgnoredWhenThePlainFileChangedUnderneath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore.testingStore(
            workspacePath: root.path,
            sessionID: "chat",
            scope: .workspace,
            applicationSupport: root
        )
        let styled = NSMutableAttributedString(attributedString: NotesTextStyle.plain("Styled text"))
        styled.addAttribute(.font, value: boldDefaultFont(), range: NSRange(location: 0, length: 6))
        store.updateAttributed(styled)
        store.flushForTesting()

        // An older build (or the agent CLI) rewrites only the plain mirror;
        // the stale styling archive must not resurrect the old content.
        try "Plain rewrite".write(to: store.fileURL, atomically: true, encoding: .utf8)

        let reloaded = NotesStore.testingStore(
            workspacePath: root.path,
            sessionID: "chat",
            scope: .workspace,
            applicationSupport: root
        )
        XCTAssertEqual(reloaded.text, "Plain rewrite")
        XCTAssertEqual(reloaded.attributedText.string, "Plain rewrite")
        XCTAssertFalse(try isBold(reloaded.attributedText, at: 0))
    }

    func testExportWritesPlainTextAndRichTextFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore.testingStore(
            workspacePath: root.path,
            sessionID: "chat",
            scope: .workspace,
            applicationSupport: root
        )
        store.update("Export me")

        let plainURL = root.appendingPathComponent("Notes.txt")
        try store.exportPlainText(to: plainURL)
        XCTAssertEqual(try String(contentsOf: plainURL, encoding: .utf8), "Export me")

        let richURL = root.appendingPathComponent("Notes.rtf")
        try store.exportRichText(to: richURL)
        let rich = try Data(contentsOf: richURL)
        XCTAssertTrue(String(decoding: rich.prefix(5), as: UTF8.self).hasPrefix("{\\rtf"))
    }
}

@MainActor
final class NotesActionRoutingTests: XCTestCase {
    func testNotesActionsUseTheRequestingWorkspaceWithoutPullingBackgroundFocus() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocusNotesRouting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let model = AppModel(startImmediately: false)
        model.settings.notesScopeRaw = NotesScope.workspace.rawValue
        model.currentSessionID = "foreground"
        model.selectInspectorTab(.files)
        var replies: [[String: Any]] = []

        let foreground = model.runNotesAction([
            "request_id": "notes-write",
            "tool": "notes_update",
            "arguments": ["action": "replace", "text": "Release on Friday"],
            "session_id": "foreground",
        ], workspacePath: workspace.path) { replies.append($0) }
        await foreground?.value

        XCTAssertEqual(model.inspectorTab, .notes)
        XCTAssertEqual(replies.first?["type"] as? String, "notes_action_result")
        let liveStore = NotesStore.shared(
            workspacePath: workspace.path,
            sessionID: "foreground",
            scope: .workspace
        )
        defer {
            try? FileManager.default.removeItem(at: liveStore.fileURL)
            try? FileManager.default.removeItem(at: liveStore.styledFileURL)
        }
        XCTAssertEqual(liveStore.text, "Release on Friday")

        model.selectInspectorTab(.files)
        replies.removeAll()
        let background = model.runNotesAction([
            "request_id": "notes-read",
            "tool": "notes_read",
            "arguments": [:],
            "session_id": "background",
        ], workspacePath: workspace.path) { replies.append($0) }
        await background?.value

        let result = try XCTUnwrap(replies.first?["result"] as? [String: Any])
        XCTAssertEqual(result["text"] as? String, "Release on Friday")
        XCTAssertEqual(model.inspectorTab, .files, "background Notes access must not pull focus")
    }
}

@MainActor
final class NotesEditorProxyTests: XCTestCase {
    private func proxy(text: String, selecting range: NSRange) -> (NotesEditorProxy, NSTextView) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.string = text
        textView.setSelectedRange(range)
        let proxy = NotesEditorProxy()
        proxy.textView = textView
        return (proxy, textView)
    }

    func testBulletsApplyToEveryTouchedLineAndToggleBackOff() {
        let (proxy, textView) = proxy(text: "alpha\nbeta", selecting: NSRange(location: 0, length: 10))

        proxy.toggleList(.bullet)
        XCTAssertEqual(textView.string, "- alpha\n- beta")

        // Every line already carries the marker, so the same action strips it.
        proxy.toggleList(.bullet)
        XCTAssertEqual(textView.string, "alpha\nbeta")
    }

    func testNumberedListReplacesBulletsAndCountsUp() {
        let (proxy, textView) = proxy(
            text: "- alpha\n- beta",
            selecting: NSRange(location: 0, length: 14)
        )

        proxy.toggleList(.numbered)
        XCTAssertEqual(textView.string, "1. alpha\n2. beta")

        // Existing numbering is recognised at any width, so this strips it.
        proxy.toggleList(.numbered)
        XCTAssertEqual(textView.string, "alpha\nbeta")
    }

    func testChecklistMarkersAreNotMistakenForBullets() {
        let (proxy, textView) = proxy(text: "- [x] done", selecting: NSRange(location: 0, length: 0))

        proxy.toggleList(.bullet)
        XCTAssertEqual(textView.string, "- done", "the checkbox marker should be replaced, not kept")
    }

    func testChecklistCyclesUncheckedThenCheckedThenPlain() {
        let (proxy, textView) = proxy(text: "ship it", selecting: NSRange(location: 0, length: 0))

        proxy.toggleChecklist()
        XCTAssertEqual(textView.string, "- [ ] ship it")

        proxy.toggleChecklist()
        XCTAssertEqual(textView.string, "- [x] ship it")

        proxy.toggleChecklist()
        XCTAssertEqual(textView.string, "ship it")
    }

    func testMarkerParsingIgnoresPunctuationSoWordCountsStayHonest() {
        XCTAssertEqual(NotesMarkers.strippingMarker("- [ ] cut the branch").rest, "cut the branch")
        XCTAssertEqual(NotesMarkers.strippingMarker("- [x] cut the branch").rest, "cut the branch")
        XCTAssertEqual(NotesMarkers.strippingMarker("12. cut the branch").rest, "cut the branch")
        XCTAssertEqual(NotesMarkers.strippingMarker("plain line").rest, "plain line")
        XCTAssertNil(NotesMarkers.strippingMarker("plain line").kind)
    }

    func testInsertPlacesTextAtTheCursor() {
        let (proxy, textView) = proxy(text: "before after", selecting: NSRange(location: 7, length: 0))

        proxy.insert("NOW ")
        XCTAssertEqual(textView.string, "before NOW after")
    }
}
