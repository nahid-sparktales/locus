import AppKit
import WebKit
import XCTest
@testable import Locus

/// Driving the page: the parts that fail silently if they are wrong.
@MainActor
final class BrowserInteractionTests: XCTestCase {
    private var host: OffscreenWebHost!
    private var waiter: LoadWaiter!

    override func setUp() async throws {
        try await super.setUp()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(BrowserBridge.readerScript())
        let webView = WKWebView(frame: .zero, configuration: configuration)
        waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        host = OffscreenWebHost(webView: webView)
    }

    override func tearDown() async throws {
        host = nil
        waiter = nil
        try await super.tearDown()
    }

    private func load(_ html: String) async throws {
        waiter.reset()
        host.webView.loadHTMLString(html, baseURL: nil)
        try await waiter.wait()
        // Mint refs so the fixtures below can address elements.
        _ = try await evaluate("return __locus.readPage({ filter: 'interactive' })")
    }

    @discardableResult
    private func evaluate(
        _ body: String,
        _ arguments: [String: Any] = [:]
    ) async throws -> Any? {
        try await host.webView.callAsyncJavaScript(
            body,
            arguments: arguments,
            in: nil,
            contentWorld: BrowserBridge.readerWorld
        )
    }

    private func object(
        _ body: String,
        _ arguments: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let raw = try await evaluate(body, arguments)
        return try XCTUnwrap(raw as? [String: Any])
    }

    func testClickingDispatchesARealEventSequence() async throws {
        try await load("""
        <body>
          <button id="target">Press</button>
          <script>
            window.seen = [];
            document.getElementById('target').addEventListener('click', () => window.seen.push('click'));
            document.getElementById('target').addEventListener('mousedown', () => window.seen.push('mousedown'));
          </script>
        </body>
        """)

        let result = try await object("return __locus.click(ref, {})", ["ref": "ref_1"])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["name"] as? String, "Press")

        // The page's own listeners are in the page world; check from there.
        let seen = try await host.webView.evaluateJavaScript("window.seen.join(',')")
        XCTAssertEqual(seen as? String, "mousedown,click")
    }

    /// A modal or cookie banner over the control is invisible to the model, and
    /// dispatching anyway means clicking the overlay while reporting success.
    func testClickingThroughAnOverlayIsRefusedRatherThanMisdirected() async throws {
        try await load("""
        <body style="margin:0">
          <button id="target" style="position:absolute;top:40px;left:40px">Underneath</button>
          <div id="veil" style="position:fixed;inset:0;background:rgba(0,0,0,.5)"></div>
        </body>
        """)

        let result = try await object("return __locus.click(ref, {})", ["ref": "ref_1"])
        XCTAssertEqual(result["blocked"] as? Bool, true)
        XCTAssertEqual(result["by"] as? String, "DIV#veil")
    }

    /// Frameworks track input values behind the property. A plain assignment is
    /// reverted on the next render and the field silently keeps its old value —
    /// which is exactly the "look at what I built" case.
    func testSetValueSurvivesAFrameworkStyleValueTracker() async throws {
        try await load("""
        <body>
          <input id="field" value="">
          <script>
            const field = document.getElementById('field');
            let tracked = '';
            Object.defineProperty(field, 'value', {
              get: () => tracked,
              set: (next) => { tracked = next; },
            });
            window.events = [];
            field.addEventListener('input', () => window.events.push('input'));
            field.addEventListener('change', () => window.events.push('change'));
          </script>
        </body>
        """)

        let result = try await object(
            "return __locus.setValue(ref, value)",
            ["ref": "ref_1", "value": "hello"]
        )
        XCTAssertEqual(result["ok"] as? Bool, true)

        let events = try await host.webView.evaluateJavaScript("window.events.join(',')")
        XCTAssertEqual(events as? String, "input,change")
    }

    func testCheckboxesAreToggledRatherThanAssigned() async throws {
        try await load("<body><input id=\"box\" type=\"checkbox\"></body>")
        let result = try await object(
            "return __locus.setValue(ref, value)",
            ["ref": "ref_1", "value": true]
        )
        XCTAssertEqual(result["checked"] as? Bool, true)
    }

    func testASelectIsMatchedByItsVisibleLabelAsWellAsItsValue() async throws {
        try await load("""
        <body>
          <select id="s">
            <option value="ca">Canada</option>
            <option value="uk">United Kingdom</option>
          </select>
        </body>
        """)
        // A model reads options off the page by their labels; matching only the
        // value attribute fails on every select whose values are codes.
        let byLabel = try await object(
            "return __locus.setValue(ref, value)",
            ["ref": "ref_1", "value": "United Kingdom"]
        )
        XCTAssertEqual(byLabel["ok"] as? Bool, true)
        let chosen = try await evaluate("return document.getElementById('s').value") as? String
        XCTAssertEqual(chosen, "uk")

        let byValue = try await object(
            "return __locus.setValue(ref, value)", ["ref": "ref_1", "value": "ca"]
        )
        XCTAssertEqual(byValue["ok"] as? Bool, true)

        let missing = try await object(
            "return __locus.setValue(ref, value)", ["ref": "ref_1", "value": "Atlantis"]
        )
        XCTAssertEqual(missing["blocked"] as? Bool, true)
        // The reply lists what was actually on offer, so the next attempt is
        // informed rather than another guess.
        XCTAssertEqual(missing["options"] as? [String], ["Canada", "United Kingdom"])
    }

    func testWhatSitsAtAPointCanBeDescribedForTheCredentialGate() async throws {
        try await load("""
        <body style="margin:0">
          <form>
            <input id="p" type="password"
                   style="position:absolute;left:0;top:0;width:200px;height:40px">
          </form>
        </body>
        """)
        let described = try await object(
            "return __locus.describeAt(x, y)", ["x": 100, "y": 20]
        )
        // A click carrying pixels names no element, so this is the only way to
        // know those pixels are a password field.
        XCTAssertEqual(described["secure"] as? Bool, true)
        // Plain page furniture is described, not refused — only the field
        // itself is secure.
        let body = try await object("return __locus.describeAt(x, y)", ["x": 100, "y": 300])
        XCTAssertEqual(body["secure"] as? Bool, false)
        // Past the viewport there is nothing to describe, which the caller has
        // to be able to tell apart from "nothing sensitive here".
        let empty = try await object("return __locus.describeAt(x, y)", ["x": 100, "y": 50_000])
        XCTAssertEqual(empty["missing"] as? Bool, true)
    }

    func testLocatingARefReportsThePointAndWhatIsCoveringIt() async throws {
        try await load("""
        <body style="margin:0">
          <button id="b" style="position:absolute;left:100px;top:50px;width:200px;height:100px">Go</button>
        </body>
        """)
        let located = try await object("return __locus.locate(ref)", ["ref": "ref_1"])
        XCTAssertEqual(located["ok"] as? Bool, true)
        XCTAssertEqual(located["x"] as? Double, 200)
        XCTAssertEqual(located["y"] as? Double, 100)

        try await evaluate("""
        const cover = document.createElement('div');
        cover.id = 'cover';
        cover.style.cssText = 'position:absolute;left:0;top:0;width:400px;height:400px';
        document.body.appendChild(cover);
        return true;
        """)
        let blocked = try await object("return __locus.locate(ref)", ["ref": "ref_1"])
        // The hit test is the one thing a coordinate cannot do for itself: it
        // is what catches a cookie banner over the control.
        XCTAssertEqual(blocked["blocked"] as? Bool, true)
        XCTAssertEqual(blocked["by"] as? String, "DIV#cover")
    }

    func testFindNarrowsTheSnapshotWithoutRewalking() async throws {
        try await load("""
        <body>
          <button>Save draft</button>
          <button>Publish</button>
          <a href="/help">Help</a>
        </body>
        """)

        let result = try await object("return __locus.find(query, limit)", ["query": "publish", "limit": 5])
        let matches = try XCTUnwrap(result["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?["name"] as? String, "Publish")
        XCTAssertEqual(matches.first?["ref"] as? String, "ref_2")
    }

    func testGetTextPrefersTheMainRegion() async throws {
        try await load("""
        <body>
          <nav>Site navigation everywhere</nav>
          <main>The actual article body.</main>
        </body>
        """)

        let result = try await object("return __locus.getText(limit)", ["limit": 5_000])
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertTrue(text.contains("actual article body"), text)
        XCTAssertFalse(text.contains("Site navigation"), text)
    }

    func testWaitForResolvesWhenTheTextArrives() async throws {
        try await load("""
        <body><div id="slot"></div>
        <script>setTimeout(() => { document.getElementById('slot').textContent = 'Ready now'; }, 150);</script>
        </body>
        """)

        let result = try await object(
            "return await __locus.waitFor(options)",
            ["options": ["text": "Ready now", "timeout_ms": 5_000]]
        )
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["reason"] as? String, "text")
    }

    func testWaitForGivesUpRatherThanHanging() async throws {
        try await load("<body>Nothing happens here.</body>")
        let result = try await object(
            "return await __locus.waitFor(options)",
            ["options": ["text": "never appears", "timeout_ms": 300]]
        )
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["reason"] as? String, "timeout")
    }

    func testActingOnARetiredRefIsRefusedEverywhere() async throws {
        try await load("<body><button>A</button><button>B</button></body>")
        _ = try await evaluate("document.querySelector('button').remove(); return true;")
        _ = try await evaluate("return true;")

        for body in [
            "return __locus.click(ref, {})",
            "return __locus.hover(ref)",
            "return __locus.scrollTo(ref)",
            "return __locus.setValue(ref, 'x')",
            "return __locus.describe(ref)",
        ] {
            let result = try await object(body, ["ref": "ref_2"])
            XCTAssertEqual(result["stale"] as? Bool, true, body)
        }
    }
}

/// Console and network capture run in the page world, so they need the capture
/// script and a message handler rather than the reader world.
@MainActor
final class BrowserCaptureTests: XCTestCase {
    private final class Collector: NSObject, WKScriptMessageHandler {
        var batches: [[String: Any]] = []
        var onMessage: (() -> Void)?

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if let payload = message.body as? [String: Any] {
                batches.append(payload)
            }
            onMessage?()
        }

        var entries: [[String: Any]] {
            batches.flatMap { ($0["entries"] as? [[String: Any]]) ?? [] }
        }
    }

    private var host: OffscreenWebHost!
    private var waiter: LoadWaiter!
    private var collector: Collector!

    override func setUp() async throws {
        try await super.setUp()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(BrowserBridge.captureScript())
        collector = Collector()
        configuration.userContentController.add(collector, name: BrowserBridge.captureHandlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        host = OffscreenWebHost(webView: webView)
    }

    override func tearDown() async throws {
        host = nil
        waiter = nil
        collector = nil
        try await super.tearDown()
    }

    /// A real base URL matters here. A document with an opaque origin has its
    /// own scripts treated as cross-origin, and WebKit redacts uncaught error
    /// messages to "Script error." — the page's own listeners see the same
    /// thing, so a fixture without an origin cannot test error text at all.
    private func loadAndCollect(_ html: String) async throws {
        waiter.reset()
        host.webView.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1/fixture"))
        try await waiter.wait()
        // The page-world queue flushes on a 250ms timer, on purpose: a
        // hot-reload error loop would otherwise post thousands of messages a
        // second straight onto the main thread.
        try await Task.sleep(for: .milliseconds(700))
    }

    func testConsoleOutputIsCaptured() async throws {
        try await loadAndCollect("""
        <body><script>
          console.log('a plain message');
          console.error('something broke');
        </script></body>
        """)

        let console = collector.entries.filter { $0["kind"] as? String == "console" }
        let messages = console.compactMap { $0["message"] as? String }
        XCTAssertTrue(messages.contains("a plain message"), messages.description)
        XCTAssertTrue(messages.contains("something broke"), messages.description)
        XCTAssertEqual(
            console.first(where: { ($0["message"] as? String) == "something broke" })?["level"] as? String,
            "error"
        )
    }

    func testUncaughtErrorsAndRejectionsAreCaptured() async throws {
        try await loadAndCollect("""
        <body><script>
          setTimeout(() => { throw new Error('boom'); }, 0);
          Promise.reject(new Error('nope'));
        </script></body>
        """)

        let messages = collector.entries
            .filter { $0["kind"] as? String == "console" }
            .compactMap { $0["message"] as? String }
            .joined(separator: "\n")
        XCTAssertTrue(messages.contains("Error: boom"), messages)
        XCTAssertTrue(messages.contains("unhandled rejection: Error: nope"), messages)
    }

    /// Failed sub-resource loads never bubble, so only a capture-phase listener
    /// sees them — and a missing script or image is exactly what "tell me
    /// what's broken" is asking about.
    func testFailedSubresourceLoadsAreCaptured() async throws {
        try await loadAndCollect("""
        <body><img src="http://127.0.0.1:9/definitely-missing.png"></body>
        """)

        let messages = collector.entries
            .filter { $0["kind"] as? String == "console" }
            .compactMap { $0["message"] as? String }
            .joined(separator: "\n")
        XCTAssertTrue(messages.contains("failed to load"), messages)
    }

    func testBatchesCarryADroppedCountRatherThanSilentlyLosingEntries() async throws {
        try await loadAndCollect("""
        <body><script>
          for (let i = 0; i < 400; i += 1) { console.log('line ' + i); }
        </script></body>
        """)

        // The queue caps at 200 entries; the overflow has to be reported rather
        // than making the log look complete.
        let dropped = collector.batches.compactMap { $0["dropped"] as? Int }.reduce(0, +)
        XCTAssertGreaterThan(dropped, 0, "overflow must be counted, not hidden")
    }
}
