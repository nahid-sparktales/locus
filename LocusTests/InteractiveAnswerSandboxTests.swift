import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Locus

/// The sandbox an interactive answer runs in, proved against a real WKWebView.
///
/// "Blocked" is never inferred from a load error: every remote resource points
/// at a loopback server the test owns, so a blocked request is one the server
/// never received, and a control load without the sandbox proves the server
/// would have seen it. Pages report what happened by writing into
/// `document.body.dataset`, which the test reads from the isolated world.
@MainActor
final class InteractiveAnswerSandboxTests: XCTestCase {
    private var hosts: [InteractiveAnswerHost] = []
    private var controlWebViews: [WKWebView] = []
    private var server: LoopbackFixtureServer!

    override func setUp() async throws {
        try await super.setUp()
        server = try LoopbackFixtureServer()
    }

    override func tearDown() async throws {
        hosts.forEach { $0.tearDown() }
        hosts.removeAll()
        controlWebViews.forEach { $0.stopLoading() }
        controlWebViews.removeAll()
        server.stop()
        server = nil
        try await super.tearDown()
    }

    // MARK: - Phase 3

    func testCSPMetaPrecedesModelContentEvenForAFullDocumentWithALeadingScript() async throws {
        let fragment = """
        <!doctype html><html><head><script>
        fetch('\(server.url("/early.json"))').then(
          () => { document.body.dataset.net = 'allowed'; },
          () => { document.body.dataset.net = 'blocked'; });
        document.body.dataset.inline = 'ran';
        </script></head><body><p>model body</p></body></html>
        """
        let document = InteractiveAnswerDocument.wrap(html: fragment, themeCSS: ":root{}")
        let policy = try XCTUnwrap(document.range(of: InteractiveAnswerDocument.cspMetaTag))
        let content = try XCTUnwrap(document.range(of: fragment))
        XCTAssertLessThan(policy.lowerBound, content.lowerBound, "the policy must be parsed before any model content")
        let shell = String(document[..<content.lowerBound])
        XCTAssertEqual(shell.components(separatedBy: "<body>").count, 2, "the shell opens the body exactly once before the fragment")
        XCTAssertTrue(document.hasSuffix("</body></html>"))

        let host = try await loadHost(fragment)
        try await expectDataset(host, "net", "blocked")
        try await expectDataset(host, "inline", "ran")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.paths, [], "the leading script reached the network")
    }

    func testRuleListCompilesOnThisOSOrTheHostRefusesToLoad() async throws {
        let outcome = await InteractiveAnswerRuleListStore.shared.resolve()
        switch outcome {
        case .ready(_, let dropped):
            // Record the tokens this OS rejected; the sandbox still holds
            // without them because the CSP covers every type, but a drop is
            // worth noticing on a new macOS.
            XCTAssertTrue(dropped.isEmpty, "this OS rejected resource types: \(dropped)")
        case .failed(let reason):
            XCTFail("the rule list did not compile on this OS: \(reason)")
        }

        let broken = InteractiveAnswerRuleListStore(
            identifier: "locus.interactive.test-broken",
            encodedRuleList: { _ in "this is not a rule list" }
        )
        let host = makeHost("<p>sealed</p>", ruleListStore: broken)
        host.start()
        try await poll("host refused without a rule list") {
            if case .unavailable = host.state { return true }
            return false
        }
        XCTAssertNil(host.webView, "a host without a rule list must never create a web view")
        XCTAssertEqual(InteractiveAnswerPresentation.mode(isEnabled: true, state: host.state), .unavailable)
    }

    func testInlineScriptRunsWhileNetworkAPIsAreBlocked() async throws {
        let base = server.url("")
        let host = try await loadHost("""
        <p id="p">widget</p>
        <script>
        const out = document.body.dataset;
        out.inline = document.getElementById('p') ? 'ran' : 'missing';
        fetch('\(base)/fetch.json').then(() => { out.fetch = 'allowed'; }, () => { out.fetch = 'blocked'; });
        try {
          const xhr = new XMLHttpRequest();
          xhr.open('GET', '\(base)/xhr.json');
          xhr.onerror = () => { out.xhr = 'blocked'; };
          xhr.onload = () => { out.xhr = 'allowed'; };
          xhr.send();
        } catch (e) { out.xhr = 'blocked'; }
        try {
          const ws = new WebSocket('\(server.wsURL("/socket"))');
          ws.onerror = () => { out.ws = 'blocked'; };
          ws.onopen = () => { out.ws = 'allowed'; };
        } catch (e) { out.ws = 'blocked'; }
        out.beacon = navigator.sendBeacon('\(base)/beacon', 'x') ? 'queued' : 'refused';
        import('\(base)/module.js').then(() => { out.dyn = 'allowed'; }, () => { out.dyn = 'blocked'; });
        import('data:text/javascript,export default 1').then(() => { out.dynData = 'allowed'; }, () => { out.dynData = 'blocked'; });
        </script>
        """)
        try await expectDataset(host, "inline", "ran")
        for key in ["fetch", "xhr", "ws", "dyn", "dynData"] {
            try await expectDataset(host, key, "blocked", key)
        }
        // `sendBeacon` may report the request as queued; what matters is that
        // the policy drops it before it leaves the page.
        let beacon = try await settled(host, key: "beacon")
        XCTAssertNotNil(beacon)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(server.paths, [], "a network API reached the loopback server")
    }

    func testRuleListAloneBlocksRemoteSubresourcesWithoutTheCSP() async throws {
        let base = server.url("")
        let html = """
        <link rel="stylesheet" href="\(base)/style.css">
        <style>@font-face{font-family:LocusFixture;src:url(\(base)/font.woff)}</style>
        <span style="font-family:LocusFixture">text in the remote font</span>
        <img src="\(base)/picture.png" alt="">
        <iframe src="\(base)/frame.html" title="frame"></iframe>
        <script src="\(base)/remote.js"></script>
        <script>
        document.body.dataset.inline = 'ran';
        fetch('\(base)/fetch.json').then(() => { document.body.dataset.fetch = 'allowed'; },
                                         () => { document.body.dataset.fetch = 'blocked'; });
        </script>
        """

        // Control: the same document with neither layer reaches the server,
        // so an empty request log below means blocked, not broken.
        let control = try await loadControl(html)
        try await poll("the control page never fetched its picture and frame: \(server.paths)") {
            let seen = self.server.paths
            return seen.contains("/picture.png") && seen.contains("/frame.html") && seen.contains("/remote.js")
        }
        control.stopLoading()
        server.clear()

        let host = try await loadHost(html, includeCSP: false)
        try await expectDataset(host, "inline", "ran")
        try await expectDataset(host, "fetch", "blocked")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(server.paths, [], "the rule list let a subresource through")
        try await expectDataset(host, "remoteScript", nil, timeout: .milliseconds(200))
    }

    func testDataAndBlobImagesRender() async throws {
        let png = Self.onePixelPNGBase64
        let host = try await loadHost("""
        <script>
        const out = document.body.dataset;
        const d = new Image();
        d.onload = () => { out.dataImage = 'loaded:' + d.naturalWidth; };
        d.onerror = () => { out.dataImage = 'error'; };
        d.src = 'data:image/png;base64,\(png)';
        document.body.appendChild(d);
        const bytes = Uint8Array.from(atob('\(png)'), c => c.charCodeAt(0));
        const url = URL.createObjectURL(new Blob([bytes], { type: 'image/png' }));
        const b = new Image();
        b.onload = () => { out.blobImage = 'loaded:' + b.naturalWidth; };
        b.onerror = () => { out.blobImage = 'error'; };
        b.src = url;
        document.body.appendChild(b);
        </script>
        """)
        try await expectDataset(host, "dataImage", "loaded:1")
        try await expectDataset(host, "blobImage", "loaded:1")
    }

    func testPostLoadNavigationIsCancelledAndWindowOpenIsNull() async throws {
        let base = server.url("")
        let host = try await loadHost("""
        <script>
        const out = document.body.dataset;
        out.marker = 'alive';
        out.open = String(window.open('\(base)/popup.html'));
        const a = document.createElement('a');
        a.href = '\(base)/link.html';
        document.body.appendChild(a);
        a.click();
        setTimeout(() => { location.href = '\(base)/location.html'; }, 0);
        setTimeout(() => { location.assign('\(base)/assign.html'); }, 10);
        </script>
        """)
        try await expectDataset(host, "open", "null")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(host.state, .ready)
        try await expectDataset(host, "marker", "alive", "the page was replaced")
        let location = try await host.evaluateInIsolatedWorld("location.href") as? String
        XCTAssertEqual(location, "about:blank")
        XCTAssertGreaterThanOrEqual(host.cancelledNavigations, 1)
        XCTAssertEqual(server.paths, [])
    }

    func testFormSubmitBaseAndFileChooserAreInert() async throws {
        let base = server.url("")
        let host = try await loadHost("""
        <base href="\(base)/base/">
        <form id="f" action="\(base)/submit" method="post">
          <input name="x" value="1">
          <input type="file" id="file">
        </form>
        <script>
        const out = document.body.dataset;
        out.marker = 'alive';
        out.baseURI = document.baseURI;
        document.getElementById('file').click();
        document.getElementById('f').submit();
        out.afterSubmit = 'still-here';
        </script>
        """)
        try await expectDataset(host, "afterSubmit", "still-here")
        try await expectDataset(host, "baseURI", "about:blank", "<base> took effect")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(host.state, .ready)
        try await expectDataset(host, "marker", "alive", "the form navigated the page")
        XCTAssertEqual(server.paths, [])
        // WebKit only opens a chooser for a real user gesture, and the
        // delegate answers every request with nil; neither path ran a panel.
        XCTAssertEqual(host.openPanelRequests, 0)
        XCTAssertTrue(NSApp.windows.allSatisfy { !($0 is NSOpenPanel) }, "a file chooser was presented")
    }

    func testAlertConfirmAndPromptReturnImmediately() async throws {
        let host = try await loadHost("""
        <script>
        const out = document.body.dataset;
        const started = performance.now();
        alert('hello');
        const confirmed = confirm('sure?');
        const typed = prompt('name?', 'default');
        out.dialogs = [performance.now() - started < 2000, confirmed, typed === null].join(',');
        </script>
        """)
        try await expectDataset(host, "dialogs", "true,false,true")
        XCTAssertEqual(host.state, .ready)
        XCTAssertTrue(NSApp.windows.allSatisfy { !($0 is NSAlert) && !($0 is NSPanel && $0.isVisible && $0.title == "hello") })
    }

    func testThemeVariablesFollowAppearanceWithoutAReload() async throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let host = try await loadHost("<script>document.body.dataset.marker = 'alive';</script>", appearance: { light })
        try await expectDataset(host, "marker", "alive")

        let lightInk = LocusTheme.cssHex(LocusTheme.lightPalette.ink, fallback: LocusTheme.lightPalette.ink)
        let darkInk = LocusTheme.cssHex(LocusTheme.darkPalette.ink, fallback: LocusTheme.darkPalette.ink)
        XCTAssertNotEqual(lightInk, darkInk)
        let observed_lightInk = try await computedVariable(host, "--locus-ink")
        XCTAssertEqual(observed_lightInk, lightInk)
        let scheme = try await computedStyle(host, "colorScheme")
        XCTAssertEqual(scheme, "light")

        let cssBefore = LocusTheme.cssVariables(for: light)
        XCTAssertTrue(cssBefore.hasPrefix(":root{"))
        for name in LocusTheme.cssVariableNames {
            XCTAssertTrue(cssBefore.contains(name + ":"), "missing \(name)")
        }
        XCTAssertTrue(cssBefore.contains("--locus-accent:#"))

        host.applyTheme(for: dark)
        try await poll("the ink variable never switched to dark") {
            try await self.computedVariable(host, "--locus-ink") == darkInk
        }
        let darkScheme = try await computedStyle(host, "colorScheme")
        XCTAssertEqual(darkScheme, "dark")
        try await expectDataset(host, "marker", "alive", "the theme change reloaded the page")
        XCTAssertEqual(host.state, .ready)

        host.applyTheme(for: light)
        try await poll("the ink variable never switched back to light") {
            try await self.computedVariable(host, "--locus-ink") == lightInk
        }
    }

    func testSavedDocumentKeepsTheCSPMeta() throws {
        let fragment = "<p>saved</p><script>document.body.dataset.saved = '1';</script>"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("interactive-answer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(InteractiveAnswerDocument.suggestedFileName(title: "Binary search: step through it!"))
        XCTAssertEqual(url.lastPathComponent, "binary-search-step-through-it.html")

        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        try InteractiveAnswerDocument.write(html: fragment, to: url, appearance: appearance)
        let saved = try String(contentsOf: url, encoding: .utf8)
        let policy = try XCTUnwrap(saved.range(of: InteractiveAnswerDocument.cspMetaTag))
        let content = try XCTUnwrap(saved.range(of: fragment))
        XCTAssertLessThan(policy.lowerBound, content.lowerBound)
        XCTAssertTrue(saved.hasPrefix("<!doctype html><html><head><meta charset=\"utf-8\">"))
        XCTAssertTrue(saved.hasSuffix("</body></html>"))
        XCTAssertTrue(saved.contains("<style id=\"locus-theme\">:root{"))
        XCTAssertTrue(saved.contains("color-scheme:dark"))
        XCTAssertEqual(saved, InteractiveAnswerDocument.savedDocument(html: fragment, appearance: appearance))

        // A theme rule can never close the style element early.
        let wrapped = InteractiveAnswerDocument.wrap(html: "<p></p>", themeCSS: ":root{}</style><script>1</script>")
        XCTAssertEqual(wrapped.components(separatedBy: "</style>").count, 3)
        XCTAssertEqual(InteractiveAnswerDocument.suggestedFileName(title: "   "), "interactive-answer.html")
    }

    func testSizeThatFitsIsSynchronousAndClamped() throws {
        let width = ProposedViewSize(width: 500, height: nil)
        XCTAssertEqual(InteractiveAnswerWebView.fittingSize(proposal: width, bounds: .zero, height: 360), CGSize(width: 500, height: 360))
        XCTAssertEqual(InteractiveAnswerWebView.fittingSize(proposal: width, bounds: .zero, height: 5_000).height, 720)
        XCTAssertEqual(InteractiveAnswerWebView.fittingSize(proposal: width, bounds: .zero, height: 10).height, 160)
        XCTAssertEqual(
            InteractiveAnswerWebView.fittingSize(
                proposal: .unspecified, bounds: CGRect(x: 0, y: 0, width: 333, height: 1), height: 300
            ),
            CGSize(width: 333, height: 300)
        )
        XCTAssertEqual(
            InteractiveAnswerWebView.fittingSize(proposal: ProposedViewSize(width: .infinity, height: nil), bounds: .zero, height: 300),
            CGSize(width: 1, height: 300)
        )

        // Through SwiftUI, before any page exists: the answer comes from the
        // proposal, not from a layout the web view has yet to do.
        let host = makeHost("<p></p>")
        let hosting = NSHostingView(rootView: InteractiveAnswerWebView(host: host, height: 360).frame(width: 400))
        XCTAssertEqual(hosting.fittingSize.height, 360)
        XCTAssertEqual(hosting.fittingSize.width, 400)
        XCTAssertEqual(host.state, .idle)
    }

    // MARK: - Phase 4

    func testHostBudgetTearsDownTheOldestHost() async throws {
        let registry = InteractiveAnswerRegistry(budget: 2)
        let first = try await loadHost("<p>1</p>", registry: registry)
        let second = try await loadHost("<p>2</p>", registry: registry)
        XCTAssertEqual(registry.liveHostCount, 2)
        let third = try await loadHost("<p>3</p>", registry: registry)

        XCTAssertEqual(first.state, .stopped(.budgetExceeded))
        XCTAssertNil(first.webView)
        XCTAssertEqual(second.state, .ready)
        XCTAssertEqual(third.state, .ready)
        XCTAssertEqual(registry.liveHostCount, 2)
        XCTAssertFalse(registry.contains(first))
        XCTAssertEqual(InteractiveAnswerPresentation.mode(isEnabled: true, state: first.state), .budgetExceeded)

        // "Show interactive content" brings the oldest back and evicts the next
        // oldest. WebKit may still be closing the evicted view's process; a
        // reload racing that is the person's problem to retry, not this test's.
        try await Task.sleep(for: .milliseconds(400))
        first.reload()
        try await poll("the evicted host did not come back: \(first.state), web view \(first.webView == nil ? "absent" : "present")") { first.state == .ready }
        XCTAssertEqual(second.state, .stopped(.budgetExceeded))
        XCTAssertEqual(third.state, .ready)
        XCTAssertEqual(InteractiveAnswerRegistry.shared.budget, 4)
    }

    func testProcessTerminationShowsStoppedStateAndNeverAutoReloads() async throws {
        let host = try await loadHost("<p>alive</p>")
        let webView = try XCTUnwrap(host.webView)
        host.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(host.state, .stopped(.terminated))
        XCTAssertNil(host.webView)
        XCTAssertEqual(InteractiveAnswerPresentation.mode(isEnabled: true, state: host.state), .stopped)

        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(host.state, .stopped(.terminated), "the host reloaded on its own")
        XCTAssertNil(host.webView)
        host.start()
        XCTAssertEqual(host.state, .stopped(.terminated), "start() must not revive a stopped host")
        host.detach()
        XCTAssertEqual(host.state, .stopped(.terminated), "a dismantled view must not revive a stopped host")

        host.reload()
        try await poll("reload did not bring the page back") { host.state == .ready }
        XCTAssertNotNil(host.webView)
    }

    func testKillSwitchRendersSummaryOnly() async throws {
        XCTAssertEqual(InteractiveAnswerPresentation.mode(isEnabled: false, state: .ready), .summaryOnly)
        XCTAssertEqual(InteractiveAnswerPresentation.mode(isEnabled: false, state: .idle), .summaryOnly)
        XCTAssertEqual(InteractiveAnswerPresentation.mode(isEnabled: true, state: .idle), .loading)
        XCTAssertEqual(InteractiveAnswerPresentation.mode(isEnabled: true, state: .ready), .web)

        let before = InteractiveAnswerRegistry.shared.liveHostCount
        let disabled = mountCard(isEnabled: false)
        defer { disabled.window.orderOut(nil); disabled.window.contentView = nil }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(Self.firstWebView(in: disabled.window.contentView), "the kill switch still mounted a web view")
        XCTAssertEqual(InteractiveAnswerRegistry.shared.liveHostCount, before)

        let enabled = mountCard(isEnabled: true)
        defer { enabled.window.orderOut(nil); enabled.window.contentView = nil }
        try await poll("the enabled card never mounted its web view") {
            Self.firstWebView(in: enabled.window.contentView) != nil
        }
        XCTAssertEqual(InteractiveAnswerRegistry.shared.liveHostCount, before + 1)
    }

    func testWatchdogTearsDownAHungScript() async throws {
        XCTAssertEqual(InteractiveAnswerWatchdogPolicy.default, InteractiveAnswerWatchdogPolicy(pingInterval: 2, deadline: 3))

        let host = makeHost(
            "<p>hung</p><script>while (true) {}</script>",
            watchdog: InteractiveAnswerWatchdogPolicy(pingInterval: 0.3, deadline: 0.6)
        )
        host.start()
        try await poll("the watchdog never fired", timeout: .seconds(8)) {
            host.state == .stopped(.unresponsive)
        }
        XCTAssertNil(host.webView)
        XCTAssertEqual(InteractiveAnswerPresentation.mode(isEnabled: true, state: host.state), .stopped)

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(host.state, .stopped(.unresponsive), "a hung page must not be reloaded automatically")
        XCTAssertNil(host.webView)
    }

    // MARK: - Review fixes

    func testACardThatDisappearsBeforeItsPageMountsReleasesItsHost() async throws {
        let before = InteractiveAnswerRegistry.shared.liveHostCount
        // The page holds its load event for long enough that the card is
        // guaranteed to be caught in the loading window: admitted to the
        // registry, web view created, nothing mounted yet.
        let mounted = mountCard(
            isEnabled: true,
            html: "<p>slow</p><script>const t = performance.now(); while (performance.now() - t < 1500) {}</script>"
        )
        defer { mounted.window.orderOut(nil); mounted.window.contentView = nil }
        try await poll("the card never admitted its host") {
            InteractiveAnswerRegistry.shared.liveHostCount == before + 1
        }
        XCTAssertNil(
            Self.firstWebView(in: mounted.window.contentView),
            "the page mounted before the card could leave; the loading window this test needs closed too early"
        )

        // The card leaves the transcript — a scroll past it, a session
        // switch — while the page is still loading.
        mounted.hosting.rootView = AnyView(EmptyView())
        try await poll("the card left but its host kept its registry slot", timeout: .seconds(4)) {
            InteractiveAnswerRegistry.shared.liveHostCount == before
        }
        // Nothing that was in flight may admit it again later.
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(InteractiveAnswerRegistry.shared.liveHostCount, before)
    }

    func testDetachDuringLoadingReleasesTheHostAndTheWebView() async throws {
        let registry = InteractiveAnswerRegistry(budget: 2)
        weak var weakHost: InteractiveAnswerHost?
        // Every strong reference lives inside this closure so the host's
        // survival afterwards can only be a leak.
        try await { @MainActor in
            let host = makeHost(
                "<p>loading</p><script>const t = performance.now(); while (performance.now() - t < 1500) {}</script>",
                registry: registry
            )
            weakHost = host
            host.start()
            try await poll("the host was never admitted") { registry.liveHostCount == 1 }
            XCTAssertEqual(host.state, .loading)
            XCTAssertNotNil(host.webView)

            host.detach()
            XCTAssertFalse(registry.contains(host))
            XCTAssertNil(host.webView)
            XCTAssertEqual(registry.liveHostCount, 0)
            try await poll("a detached loading host did not return to idle") { host.state == .idle }
            hosts.removeAll { $0 === host }
        }()
        try await poll("the detached host is still retained by something") { weakHost == nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(registry.liveHostCount, 0)
    }

    func testTheSealedWebViewHasNoContextMenuAndCancelsDownloads() async throws {
        let base = server.url("")
        let host = try await loadHost("""
        <a id="link" href="\(base)/leak.bin" download="leak.bin">a link the model wrote</a>
        <img id="picture" src="data:image/png;base64,\(Self.onePixelPNGBase64)" alt="">
        """)
        let webView = try XCTUnwrap(host.webView as? InteractiveAnswerSealedWebView, "the host lends a plain WKWebView")
        XCTAssertFalse(webView.isInspectable)
        webView.isInspectable = true
        XCTAssertFalse(webView.isInspectable, "the inspector could be switched on after construction")

        // WebKit fills the menu with its own items and then asks the view
        // (`willOpenMenu`) before it pops up: this is the menu a right-click on
        // the link would produce.
        let menu = NSMenu(title: "context")
        for title in ["Open Link", "Open Link in New Window", "Download Linked File", "Copy Link", "Copy Image", "Reload"] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        let point = NSPoint(x: 10, y: 10)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        webView.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.map(\.title), [], "the context menu still offers items")
        XCTAssertEqual(webView.suppressedContextMenus, 1)
        XCTAssertNil(webView.menu(for: event), "the view offers a menu of its own")

        // And a download WebKit hands over by any other route is cancelled
        // before a destination is chosen.
        XCTAssertEqual(host.cancelledDownloads, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.paths, [], "the sealed page reached the loopback server")
    }

    func testWatchdogSurvivesAMainThreadStallLongerThanTheDeadline() async throws {
        let policy = InteractiveAnswerWatchdogPolicy(pingInterval: 0.3, deadline: 0.6)
        let host = makeHost(
            "<p>healthy</p><script>document.body.dataset.marker = 'alive';</script>",
            watchdog: policy
        )
        host.start()
        try await poll("the host never became ready") { host.state == .ready }
        try await expectDataset(host, "marker", "alive")

        // The app's main thread blocks for deadline + 1 s right after a ping
        // goes out: the page answers at once, but its answer cannot be
        // delivered until the stall ends. Once is enough to reproduce the
        // false verdict; the closure disarms itself.
        var stalls = 0
        host.watchdogDidSendPing = {
            guard stalls == 0 else { return }
            stalls += 1
            Thread.sleep(forTimeInterval: policy.deadline + 1)
        }
        try await poll("the watchdog never pinged", timeout: .seconds(4)) { stalls == 1 }
        // Long enough for the stalled ping to be judged and for several
        // ordinary pings to follow it.
        try await Task.sleep(for: .seconds(policy.pingInterval + policy.deadline + 1))
        XCTAssertEqual(host.state, .ready, "a healthy page was torn down because the app stalled")
        XCTAssertNotNil(host.webView)
        try await expectDataset(host, "marker", "alive")
        XCTAssertEqual(stalls, 1)
        XCTAssertLessThan(InteractiveAnswerHost.watchdogTurnCredit, .seconds(policy.deadline))
    }

    func testCSSHexFallsBackToTheInkForAColourWithoutAnSRGBValue() throws {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2)))
        XCTAssertNil(LocusAccentSelection.hexString(for: pattern), "a pattern colour converted to sRGB; pick another unconvertible colour")
        let light = LocusTheme.lightPalette.ink
        let dark = LocusTheme.darkPalette.ink
        XCTAssertEqual(LocusTheme.cssHex(pattern, fallback: light), LocusTheme.cssHex(light, fallback: dark))
        XCTAssertEqual(LocusTheme.cssHex(pattern, fallback: dark), LocusTheme.cssHex(dark, fallback: light))
        XCTAssertNotEqual(LocusTheme.cssHex(pattern, fallback: light), LocusTheme.cssHex(pattern, fallback: dark))
        XCTAssertFalse(LocusTheme.cssHex(pattern, fallback: light).contains("808080"))
        XCTAssertEqual(LocusTheme.cssHex(pattern, fallback: pattern), "#000000")
    }

    // MARK: - Helpers

    private func makeHost(
        _ html: String,
        height: CGFloat = 360,
        ruleListStore: InteractiveAnswerRuleListStore = .shared,
        registry: InteractiveAnswerRegistry? = nil,
        watchdog: InteractiveAnswerWatchdogPolicy = .default,
        appearance: @escaping () -> NSAppearance = { NSAppearance(named: .aqua)! },
        includeCSP: Bool = true
    ) -> InteractiveAnswerHost {
        let host = InteractiveAnswerHost(
            html: html,
            height: height,
            ruleListStore: ruleListStore,
            registry: registry ?? InteractiveAnswerRegistry(budget: 8),
            watchdog: watchdog,
            appearance: appearance,
            includeContentSecurityPolicy: includeCSP
        )
        hosts.append(host)
        return host
    }

    private func loadHost(
        _ html: String,
        registry: InteractiveAnswerRegistry? = nil,
        appearance: @escaping () -> NSAppearance = { NSAppearance(named: .aqua)! },
        includeCSP: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> InteractiveAnswerHost {
        let host = makeHost(html, registry: registry, appearance: appearance, includeCSP: includeCSP)
        host.start()
        try await poll("the host never became ready: \(host.state)", file: file, line: line) {
            host.state == .ready
        }
        return host
    }

    /// The same wrapped document in a plain web view: no rule list, no policy.
    private func loadControl(_ html: String) async throws -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 360), configuration: WKWebViewConfiguration())
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        controlWebViews.append(webView)
        webView.loadHTMLString(
            InteractiveAnswerDocument.wrap(html: html, themeCSS: ":root{}", includeCSP: false),
            baseURL: nil
        )
        try await waiter.wait()
        webView.navigationDelegate = nil
        return webView
    }

    private func dataset(_ host: InteractiveAnswerHost) async throws -> [String: String] {
        let raw = try await host.evaluateInIsolatedWorld("JSON.stringify(Object.assign({}, document.body.dataset))")
        let data = Data((raw as? String ?? "{}").utf8)
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Poll until the page has written `key`; nil when it never does.
    private func settled(
        _ host: InteractiveAnswerHost,
        key: String,
        timeout: Duration = .seconds(5)
    ) async throws -> String? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let value = try await dataset(host)[key] { return value }
            try await Task.sleep(for: .milliseconds(40))
        }
        return try await dataset(host)[key]
    }

    private func expectDataset(
        _ host: InteractiveAnswerHost,
        _ key: String,
        _ expected: String?,
        _ message: String = "",
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let value = try await settled(host, key: key, timeout: timeout)
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }

    private func computedVariable(_ host: InteractiveAnswerHost, _ name: String) async throws -> String? {
        let value = try await host.evaluateInIsolatedWorld(
            "getComputedStyle(document.documentElement).getPropertyValue('\(name)').trim()"
        )
        return value as? String
    }

    private func computedStyle(_ host: InteractiveAnswerHost, _ property: String) async throws -> String? {
        try await host.evaluateInIsolatedWorld("getComputedStyle(document.documentElement).\(property)") as? String
    }

    private func poll(
        _ failure: @autoclosure () -> String,
        timeout: Duration = .seconds(8),
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail(failure(), file: file, line: line)
        throw LoadWaiterError.timedOut
    }

    private func mountCard(
        isEnabled: Bool,
        html: String = "<p>widget</p><script>document.body.dataset.inline = 'ran';</script>"
    ) -> (window: NSWindow, hosting: NSHostingView<AnyView>) {
        let card = InteractiveAnswerView(
            title: "Binary search",
            summary: "Seven elements, three steps.",
            html: html,
            height: 200,
            isEnabled: isEnabled,
            identity: "test-\(isEnabled)-\(html.hashValue)"
        ) {
            Text("Binary search — seven elements, three steps.")
        }
        let hosting = NSHostingView(rootView: AnyView(card.frame(width: 480)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private static func firstWebView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let found = firstWebView(in: child) { return found }
        }
        return nil
    }

    /// A 1×1 opaque PNG.
    private static var onePixelPNGBase64: String {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        bitmap.setColor(.red, atX: 0, y: 0)
        return bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
    }
}

/// A loopback HTTP server that answers every path and remembers which paths
/// were asked for. The only network any sandbox test may touch. Plain BSD
/// sockets: an accept loop on its own thread, one thread and one request per
/// connection.
final class LoopbackFixtureServer: @unchecked Sendable {
    private let socketDescriptor: Int32
    private let lock = NSLock()
    private var recorded: [String] = []
    private var stopped = false
    let port: UInt16

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LoadWaiterError.timedOut }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            close(descriptor)
            throw LoadWaiterError.timedOut
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        socketDescriptor = descriptor
        port = UInt16(bigEndian: assigned.sin_port)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "locus.tests.loopback-fixture"
        thread.start()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func clear() {
        lock.lock()
        recorded.removeAll()
        lock.unlock()
    }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }
    func wsURL(_ path: String) -> String { "ws://127.0.0.1:\(port)\(path)" }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        // Shutting the listening socket wakes the blocked accept().
        shutdown(socketDescriptor, SHUT_RDWR)
        close(socketDescriptor)
    }

    private func acceptLoop() {
        while true {
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(socketDescriptor, $0, &length) }
            }
            guard client >= 0 else { return }
            // One thread per connection: WebKit opens speculative connections
            // that never carry a request, and a serial loop would block on
            // one of those while real requests queued behind it.
            let worker = Thread { [weak self] in self?.serve(client) }
            worker.name = "locus.tests.loopback-fixture.connection"
            worker.start()
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var receiveTimeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        let received = recv(client, &buffer, buffer.count, 0)
        guard received > 0 else { return }
        let text = String(decoding: buffer[0..<received], as: UTF8.self)
        let requestLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        lock.lock()
        recorded.append(path)
        lock.unlock()
        let (type, body) = Self.response(for: path)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        let payload = Data(head.utf8) + body
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = send(client, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }

    private static func response(for path: String) -> (String, Data) {
        switch true {
        case path.hasSuffix(".png"):
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            return ("image/png", bitmap.representation(using: .png, properties: [:]) ?? Data())
        case path.hasSuffix(".js"):
            return ("text/javascript", Data("document.body.dataset.remoteScript = 'ran';".utf8))
        case path.hasSuffix(".css"):
            return ("text/css", Data("body{outline:1px solid red}".utf8))
        case path.hasSuffix(".html"):
            return ("text/html", Data("<p>fixture</p>".utf8))
        case path.hasSuffix(".json"):
            return ("application/json", Data("{}".utf8))
        default:
            return ("application/octet-stream", Data([0, 1, 2, 3]))
        }
    }
}

