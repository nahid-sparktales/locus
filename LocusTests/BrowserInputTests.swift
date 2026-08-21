import AppKit
import WebKit
import XCTest
@testable import Locus

/// Real input: the half of the browser that the bridge cannot fake.
///
/// Every assertion here is about something a synthetic `MouseEvent` gets wrong
/// — `isTrusted`, a coordinate with no element behind it, a drag with travel —
/// so a regression that quietly fell back to the bridge would fail these rather
/// than pass them by a different route.
@MainActor
final class BrowserInputTests: XCTestCase {
    private var host: OffscreenWebHost!
    private var waiter: LoadWaiter!

    override func setUp() async throws {
        try await super.setUp()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(BrowserBridge.readerScript())
        let webView = WKWebView(frame: .zero, configuration: configuration)
        waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        host = OffscreenWebHost(webView: webView, viewport: CGSize(width: 800, height: 600))
    }

    override func tearDown() async throws {
        host = nil
        waiter = nil
        try await super.tearDown()
    }

    private func load(_ html: String) async throws {
        waiter.reset()
        host.webView.loadHTMLString(html, baseURL: URL(string: "https://example.test"))
        try await waiter.wait()
    }

    /// Poll rather than sleep: WebKit hands events to the web process
    /// asynchronously, and a fixed wait is either flaky or slow.
    ///
    /// The expression must evaluate to null until the state under test has
    /// fully arrived. Returning on the first non-null value would accept a
    /// half-typed field — which is exactly the intermediate state a slower
    /// machine catches and a fast one hides.
    private func settled(
        _ expression: String,
        timeout: Duration = .seconds(5)
    ) async throws -> Any? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let value = try? await host.webView.evaluateJavaScript(expression),
               !(value is NSNull)
            {
                return value
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        return try? await host.webView.evaluateJavaScript(expression)
    }

    // MARK: - Trust

    func testAClickArrivesAsTrustedInputAtTheCoordinateAsked() async throws {
        try await load("""
        <body style="margin:0">
          <button id="b" style="position:absolute;left:100px;top:100px;width:200px;height:80px">Go</button>
          <script>
            window.seen = null;
            document.getElementById('b').addEventListener('click', (e) => {
              window.seen = { trusted: e.isTrusted, x: Math.round(e.clientX), y: Math.round(e.clientY) };
            });
          </script>
        </body>
        """)

        let delivered = await host.deliverClick(at: CGPoint(x: 200, y: 140))
        XCTAssertTrue(delivered)

        let raw = try await settled("window.seen") as? [String: Any]
        let seen = try XCTUnwrap(raw, "the click never reached the page")
        // The whole point of the NSEvent path: a page may gate on this.
        XCTAssertEqual(seen["trusted"] as? Bool, true)
        XCTAssertEqual(seen["x"] as? Int, 200)
        XCTAssertEqual(seen["y"] as? Int, 140)
    }

    func testTypingArrivesAsTrustedKeystrokesAndBecomesText() async throws {
        try await load("""
        <body style="margin:0">
          <input id="f" style="position:absolute;left:0;top:0;width:300px;height:40px">
          <script>
            window.keys = [];
            document.getElementById('f').addEventListener('keydown', (e) => {
              window.keys.push({ key: e.key, trusted: e.isTrusted });
            });
            document.getElementById('f').focus();
          </script>
        </body>
        """)

        let typed = await host.deliverText("hi")
        XCTAssertTrue(typed)

        let value = try await settled(
            "document.getElementById('f').value === 'hi' ? 'hi' : null"
        ) as? String
        XCTAssertEqual(value, "hi", "the keystrokes never became text")
        let rawKeys = try await settled("window.keys.length === 2 ? window.keys : null")
            as? [[String: Any]]
        let keys = try XCTUnwrap(rawKeys)
        XCTAssertEqual(keys.map { $0["key"] as? String }, ["h", "i"])
        XCTAssertEqual(keys.first?["trusted"] as? Bool, true)
    }

    func testNamedKeysResolveToTheKeyThePageExpects() async throws {
        try await load("""
        <body style="margin:0">
          <input id="f" style="position:absolute;left:0;top:0;width:300px;height:40px">
          <script>
            window.keys = [];
            document.getElementById('f').addEventListener('keydown', (e) => window.keys.push(e.key));
            document.getElementById('f').focus();
          </script>
        </body>
        """)

        let down = try XCTUnwrap(BrowserInput.Key(name: "ArrowDown"))
        let pressedDown = await host.deliverKey(down, repeatCount: 3)
        XCTAssertTrue(pressedDown)
        let enter = try XCTUnwrap(BrowserInput.Key(name: "Enter"))
        let pressedEnter = await host.deliverKey(enter)
        XCTAssertTrue(pressedEnter)

        let rawKeys = try await settled("window.keys.length === 4 ? window.keys : null") as? [String]
        let keys = try XCTUnwrap(rawKeys)
        // `repeat` really repeats, rather than pressing once and reporting three.
        XCTAssertEqual(keys, ["ArrowDown", "ArrowDown", "ArrowDown", "Enter"])
    }

    func testAnUnknownKeyNameIsRefusedRatherThanGuessed() {
        XCTAssertNil(BrowserInput.Key(name: "Meta+Frobnicate"))
        XCTAssertNil(BrowserInput.Key(name: ""))
        // A capital arrives as shift plus the unshifted key, not as a bare key
        // claiming to be uppercase.
        let capital = BrowserInput.Key(character: "A")
        XCTAssertEqual(capital.characters, "A")
        XCTAssertEqual(capital.charactersIgnoringModifiers, "a")
        XCTAssertTrue(capital.impliedModifiers.contains(.shift))
    }

    // MARK: - What coordinates buy

    func testACanvasIsReachableByCoordinateAndTracksADrag() async throws {
        try await load("""
        <body style="margin:0">
          <canvas id="c" style="position:absolute;left:0;top:0;width:400px;height:300px"></canvas>
          <script>
            window.path = [];
            const c = document.getElementById('c');
            for (const type of ['pointerdown', 'pointermove', 'pointerup']) {
              c.addEventListener(type, (e) => window.path.push({
                type: type, x: Math.round(e.clientX), y: Math.round(e.clientY), trusted: e.isTrusted,
              }));
            }
          </script>
        </body>
        """)

        // A canvas mints no ref, so this is the case the element tree cannot
        // express at all.
        let dragged = await host.deliverDrag(
            from: CGPoint(x: 40, y: 40),
            to: CGPoint(x: 300, y: 220),
            steps: 4
        )
        XCTAssertTrue(dragged)

        // Press, the moves, and the release: anything less is a partial drag.
        let rawPath = try await settled(
            "window.path.some(e => e.type === 'pointerup') ? window.path : null"
        ) as? [[String: Any]]
        let path = try XCTUnwrap(rawPath)
        XCTAssertEqual(path.first?["type"] as? String, "pointerdown")
        XCTAssertEqual(path.first?["x"] as? Int, 40)
        XCTAssertEqual(path.last?["type"] as? String, "pointerup")
        XCTAssertEqual(path.last?["x"] as? Int, 300)
        XCTAssertEqual(path.last?["y"] as? Int, 220)
        // Travel between press and release is what a sortable list or a drawing
        // tool actually listens for.
        XCTAssertGreaterThan(path.filter { $0["type"] as? String == "pointermove" }.count, 1)
        XCTAssertTrue(path.allSatisfy { $0["trusted"] as? Bool == true })
    }

    func testScrollingAtAPointMovesTheContainerUnderIt() async throws {
        try await load("""
        <body style="margin:0">
          <div id="box" style="position:absolute;left:0;top:0;width:400px;height:200px;overflow:auto">
            <div style="height:3000px">tall</div>
          </div>
          <div style="height:3000px"></div>
        </body>
        """)

        let scrolled = await host.deliverScroll(
            at: CGPoint(x: 200, y: 100), deltaX: 0, deltaY: 120
        )
        XCTAssertTrue(scrolled)

        let inner = try await settled(
            "document.getElementById('box').scrollTop || null"
        ) as? Int
        // A range, not an equality: WebKit is free to round a pixel delta, and
        // what this test is about is *which* thing scrolled.
        let moved = try XCTUnwrap(inner, "the inner container did not scroll")
        XCTAssertGreaterThan(moved, 0)
        XCTAssertLessThanOrEqual(moved, 240)
        // The document itself must stay put — scrolling the page instead of the
        // container under the pointer is the bug this replaces.
        let page = try await host.webView.evaluateJavaScript("window.scrollY") as? Int
        XCTAssertEqual(page, 0)
    }

    // MARK: - Where events can and cannot go

    func testInputIsRefusedRatherThanDroppedWhenThereIsNoWindow() async {
        let orphan = WKWebView(frame: .zero)
        XCTAssertNil(orphan.window)
        // No window means no coordinate frame; the service reads this as its
        // signal to fall back to the bridge instead of reporting a click that
        // never happened.
        let host = OffscreenWebHost(webView: orphan)
        host.webView.removeFromSuperview()
        XCTAssertFalse(host.canDeliverRealInput)
        XCTAssertNil(host.windowPoint(forPageCSS: CGPoint(x: 10, y: 10)))
    }

    func testAThrottledBackgroundTabStillReceivesInput() async throws {
        try await load("""
        <body style="margin:0">
          <button id="b" style="position:absolute;left:0;top:0;width:400px;height:200px">Go</button>
          <script>
            window.seen = null;
            document.getElementById('b').addEventListener('click', () => { window.seen = true; });
          </script>
        </body>
        """)
        // A background tab is ordered out and has no drawing area. Delivery has
        // to bring the panel forward and put it back, exactly as capture does.
        host.setKeptLive(false)
        XCTAssertFalse(host.isKeptLive)

        let clicked = await host.deliverClick(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(clicked)

        let seen = try await settled("window.seen") as? Bool
        XCTAssertEqual(seen, true)
        XCTAssertFalse(host.isKeptLive, "the tab was left un-throttled after the click")
    }

    func testTypingDoesNotStealFocusFromTheKeyWindow() async throws {
        // Stand in for the app window the panel's view gets lent to while the
        // person is looking at it.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        defer { window.orderOut(nil) }

        try await load("<body><input id='f'></body>")
        host.lend(to: try XCTUnwrap(window.contentView))
        let composer = window.firstResponder

        _ = await host.deliverText("x")

        if window.isKeyWindow {
            // Identity is the wrong test: a focused NSTextField is represented
            // by its field editor, and AppKit is free to install or swap that
            // between capture and restore. What has to hold is that focus came
            // back to the person's control rather than staying on the page.
            let responder = window.firstResponder
            let edits = (responder as? NSTextView)?.delegate as? NSResponder
            let landed = responder.map { String(describing: type(of: $0)) } ?? "nothing"
            XCTAssertTrue(
                responder !== host.webView
                    && (responder === composer || responder === field || edits === field),
                "the agent typing left focus on \(landed), not the text field; "
                    + "the next thing the user typed would go to the page"
            )
        }
        host.park()
    }
}
