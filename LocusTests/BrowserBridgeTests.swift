import AppKit
import WebKit
import XCTest
@testable import Locus

/// The ref contract, which is the part of the browser most likely to regress
/// silently.
///
/// Going stale across a navigation is the easy case — navigation discards the
/// registry and any implementation gets it right. The dangerous one is an
/// in-place removal: a fresh walk hands the same id to a different control, the
/// click lands on the wrong thing, and the agent reports success.
@MainActor
final class BrowserBridgeTests: XCTestCase {
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
    }

    private func evaluate(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await host.webView.callAsyncJavaScript(
            body,
            arguments: arguments,
            in: nil,
            contentWorld: BrowserBridge.readerWorld
        )
    }

    private func readPage(filter: String = "interactive") async throws -> [String: Any] {
        let raw = try await evaluate(
            "return __locus.readPage({ filter: filter })",
            ["filter": filter]
        )
        return try XCTUnwrap(raw as? [String: Any])
    }

    // MARK: - Staleness

    func testRemovingOneElementRetiresEveryRefFromThatSnapshot() async throws {
        try await load("""
        <body><button id="a">A</button><button id="b">B</button><button id="c">C</button></body>
        """)

        let first = try await readPage()
        let tree = try XCTUnwrap(first["tree"] as? String)
        XCTAssertTrue(tree.contains("button \"A\" [ref_1]"), tree)
        XCTAssertTrue(tree.contains("button \"B\" [ref_2]"), tree)
        XCTAssertTrue(tree.contains("button \"C\" [ref_3]"), tree)
        let firstToken = try XCTUnwrap(first["token"] as? Int)

        // B is still on the page. A is not — and that is enough: the snapshot
        // no longer describes the document it was taken from.
        _ = try await evaluate("document.getElementById('a').remove(); return true;")
        // Let the MutationObserver microtask run.
        _ = try await evaluate("return true;")

        let describedRaw = try await evaluate("return __locus.describe('ref_2')")
        let described = try XCTUnwrap(describedRaw as? [String: Any])
        XCTAssertTrue(
            described["stale"] as? Bool == true,
            "ref_2 must be refused after the DOM changed, not silently re-bound"
        )

        let tokenRaw = try await evaluate("return __locus.currentToken()")
        let token = try XCTUnwrap(tokenRaw as? Int)
        XCTAssertGreaterThan(token, firstToken, "the snapshot token must move on")
    }

    func testASnapshotRetiresThePreviousOne() async throws {
        try await load("<body><button>Only</button></body>")

        let first = try await readPage()
        let firstToken = try XCTUnwrap(first["token"] as? Int)
        let liveRaw = try await evaluate("return __locus.describe('ref_1')")
        let live = try XCTUnwrap(liveRaw as? [String: Any])
        XCTAssertFalse(live["stale"] as? Bool == true)

        let second = try await readPage()
        let secondToken = try XCTUnwrap(second["token"] as? Int)
        XCTAssertGreaterThan(secondToken, firstToken)
        // The new walk minted ref_1 again for the same element, so it resolves —
        // what must not happen is a *stale* id resolving to a different element.
        XCTAssertEqual(second["count"] as? Int, 1)
    }

    func testRefsDoNotSurviveNavigation() async throws {
        try await load("<body><button>Before</button></body>")
        _ = try await readPage()
        try await load("<body><button>After</button></body>")

        let describedRaw = try await evaluate("return __locus.describe('ref_1')")
        let described = try XCTUnwrap(describedRaw as? [String: Any])
        XCTAssertTrue(described["stale"] as? Bool == true)
    }

    /// The runtime's wording and the wording the model is taught must be one
    /// string, or the model learns to look for a message it will never see.
    func testStaleMessageIsASingleLiteral() {
        XCTAssertEqual(
            BrowserBridge.staleReferenceMessage,
            "Error: page changed; call browser_read_page again."
        )
        // The broker reports it without doubling the prefix the agent adds.
        XCTAssertTrue(BrowserBridge.staleReferenceMessage.hasPrefix("Error: "))
    }

    // MARK: - The tree itself

    func testAccessibleNamesFollowTheUsualPrecedence() async throws {
        try await load("""
        <body>
          <button aria-label="Explicit">Ignored</button>
          <label for="email">Email address</label><input id="email" placeholder="you@example.com">
          <input id="bare" placeholder="Just a placeholder">
          <a href="/docs">Docs</a>
        </body>
        """)

        let page = try await readPage()
        let tree = try XCTUnwrap(page["tree"] as? String)
        XCTAssertTrue(tree.contains("button \"Explicit\""), tree)
        XCTAssertTrue(tree.contains("textbox \"Email address\""), tree)
        XCTAssertTrue(tree.contains("textbox \"Just a placeholder\""), tree)
        XCTAssertTrue(tree.contains("link \"Docs\""), tree)
        XCTAssertTrue(tree.contains("href=/docs"), tree)
    }

    func testHiddenElementsAreLeftOut() async throws {
        try await load("""
        <body>
          <button>Visible</button>
          <button style="display:none">Display none</button>
          <button style="visibility:hidden">Invisible</button>
          <button hidden>Hidden attribute</button>
          <button aria-hidden="true">Aria hidden</button>
        </body>
        """)

        let page = try await readPage()
        let tree = try XCTUnwrap(page["tree"] as? String)
        XCTAssertTrue(tree.contains("Visible"), tree)
        XCTAssertFalse(tree.contains("Display none"), tree)
        XCTAssertFalse(tree.contains("Invisible"), tree)
        XCTAssertFalse(tree.contains("Hidden attribute"), tree)
        XCTAssertFalse(tree.contains("Aria hidden"), tree)
    }

    func testSecureFieldsAreMarkedForTheSwiftGate() async throws {
        try await load("""
        <body><form>
          <input id="user" autocomplete="username">
          <input id="pass" type="password" autocomplete="current-password">
        </form></body>
        """)

        let page = try await readPage()
        let tree = try XCTUnwrap(page["tree"] as? String)
        XCTAssertTrue(tree.contains("secure"), tree)

        let userRaw = try await evaluate("return __locus.describe('ref_1')")
        let user = try XCTUnwrap(userRaw as? [String: Any])
        XCTAssertEqual(user["secure"] as? Bool, false)
        // The username field is not itself secure, but it shares a form with a
        // password — which is what a credential gate has to notice.
        XCTAssertEqual(user["formHasSecure"] as? Bool, true)

        let passwordRaw = try await evaluate("return __locus.describe('ref_2')")
        let password = try XCTUnwrap(passwordRaw as? [String: Any])
        XCTAssertEqual(password["secure"] as? Bool, true)
    }

    func testInteractiveFilterKeepsHeadingsAndDropsProse() async throws {
        try await load("""
        <body>
          <h1>Title</h1>
          <p>Some prose that is not actionable.</p>
          <button>Act</button>
        </body>
        """)

        let page = try await readPage()
        let tree = try XCTUnwrap(page["tree"] as? String)
        XCTAssertTrue(tree.contains("heading \"Title\" level=1"), tree)
        XCTAssertTrue(tree.contains("button \"Act\""), tree)
        XCTAssertFalse(tree.contains("Some prose"), tree)
    }

    func testTruncationReportsWhatItLeftOut() async throws {
        let buttons = (1...200).map { "<button>Button \($0)</button>" }.joined()
        try await load("<body>\(buttons)</body>")

        let raw = try await evaluate(
            "return __locus.readPage({ filter: 'interactive', max_chars: 500 })"
        )
        let payload = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        let omitted = try XCTUnwrap(payload["omitted"] as? Int)
        XCTAssertGreaterThan(omitted, 0)
    }

    func testCrossOriginFramesAreNamedRatherThanSilentlyMissing() async throws {
        try await load("""
        <body><iframe title="Payment" src="about:blank"></iframe></body>
        """)

        let page = try await readPage(filter: "all")
        let tree = try XCTUnwrap(page["tree"] as? String)
        XCTAssertTrue(tree.contains("iframe \"Payment\" (contents not readable)"), tree)
    }
}
