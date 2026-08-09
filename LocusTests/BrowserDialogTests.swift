import AppKit
import WebKit
import XCTest
@testable import Locus

/// JavaScript dialogs through the real delegate path: armed answers, safe
/// defaults, and the notice that tells the model what happened to its click.
@MainActor
final class BrowserDialogTests: XCTestCase {
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

    private func loadFixture(_ html: String, sessionID: String = "session-1") async throws {
        let tab = service.tab(for: sessionID)
        let waiter = LoadWaiter()
        tab.webView.navigationDelegate = waiter
        tab.webView.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1/fixture"))
        try await waiter.wait()
        tab.webView.navigationDelegate = service
    }

    private func act(_ arguments: [String: Any]) async -> [String: Any] {
        await service.perform(
            tool: "browser_input",
            arguments: arguments,
            sessionID: "session-1",
            timeoutMilliseconds: 10_000
        )
    }

    func testUnarmedConfirmTakesTheSafeBranchAndSaysSo() async throws {
        try await loadFixture("""
        <body><button onclick="window.outcome = confirm('Delete everything?')">Go</button></body>
        """)
        _ = await service.perform(
            tool: "browser_read_page", arguments: [:],
            sessionID: "session-1", timeoutMilliseconds: 10_000
        )

        let result = await act(["action": "click", "ref": "ref_1"])
        let text = try XCTUnwrap(result["text"] as? String)
        // The click's own result explains the dialog — the model must not have
        // to guess why the page "did nothing".
        XCTAssertTrue(text.contains("auto-dismissed"), text)
        XCTAssertTrue(text.contains("Delete everything?"), text)

        let tab = service.tab(for: "session-1")
        let outcome = try await tab.webView.evaluateJavaScript("window.outcome")
        XCTAssertEqual(outcome as? Bool, false, "unarmed confirm() must take the safe branch")
    }

    func testArmedConfirmIsAcceptedOnce() async throws {
        try await loadFixture("""
        <body><button onclick="window.outcome = confirm('Proceed?')">Go</button></body>
        """)
        _ = await service.perform(
            tool: "browser_read_page", arguments: [:],
            sessionID: "session-1", timeoutMilliseconds: 10_000
        )

        let armed = await act(["action": "dialog", "response": "accept"])
        XCTAssertTrue((armed["text"] as? String)?.contains("accepted") == true)

        let click = await act(["action": "click", "ref": "ref_1"])
        XCTAssertTrue((click["text"] as? String)?.contains("accepted as armed") == true)
        let tab = service.tab(for: "session-1")
        let outcome = try await tab.webView.evaluateJavaScript("window.outcome")
        XCTAssertEqual(outcome as? Bool, true)

        // One-shot: the next dialog is back to the safe default.
        let second = await act(["action": "click", "ref": "ref_1"])
        XCTAssertTrue((second["text"] as? String)?.contains("auto-dismissed") == true)
        let after = try await tab.webView.evaluateJavaScript("window.outcome")
        XCTAssertEqual(after as? Bool, false)
    }

    func testArmedPromptDeliversTheText() async throws {
        try await loadFixture("""
        <body><button onclick="window.answer = prompt('Name?')">Go</button></body>
        """)
        _ = await service.perform(
            tool: "browser_read_page", arguments: [:],
            sessionID: "session-1", timeoutMilliseconds: 10_000
        )

        _ = await act(["action": "dialog", "response": "accept", "text": "Ada"])
        _ = await act(["action": "click", "ref": "ref_1"])
        let tab = service.tab(for: "session-1")
        let answer = try await tab.webView.evaluateJavaScript("window.answer")
        XCTAssertEqual(answer as? String, "Ada")
    }

    func testAlertsNeverBlockAndAreRecorded() async throws {
        try await loadFixture("""
        <body><button onclick="alert('Heads up'); window.after = true">Go</button></body>
        """)
        _ = await service.perform(
            tool: "browser_read_page", arguments: [:],
            sessionID: "session-1", timeoutMilliseconds: 10_000
        )

        let result = await act(["action": "click", "ref": "ref_1"])
        XCTAssertTrue((result["text"] as? String)?.contains("Heads up") == true)
        let tab = service.tab(for: "session-1")
        let after = try await tab.webView.evaluateJavaScript("window.after")
        XCTAssertEqual(after as? Bool, true, "the alert must not wedge the page")
        XCTAssertTrue(tab.log.console.contains { $0.level == "dialog" })
    }

    func testDialogArmRejectsNonsenseResponses() async throws {
        try await loadFixture("<body><p>page</p></body>")
        let result = await act(["action": "dialog", "response": "maybe"])
        XCTAssertEqual(result["error"] as? String, "'response' must be accept or dismiss")
    }
}

@MainActor
final class BrowserProfileTests: XCTestCase {
    func testProfileIdentityIsStablePerWorkspaceAndDistinctAcrossThem() {
        let one = BrowserService.profileIdentifier(for: "/Users/someone/projects/app")
        let again = BrowserService.profileIdentifier(for: "/Users/someone/projects/app/")
        let other = BrowserService.profileIdentifier(for: "/Users/someone/projects/site")
        // Stable across launches and path spelling; distinct per project.
        XCTAssertEqual(one, again)
        XCTAssertNotEqual(one, other)
    }

    func testSwitchingProfilesClosesTabsOnce() {
        let service = BrowserService()
        _ = service.tab(for: "session-1")
        XCTAssertEqual(service.tabs.count, 1)

        service.configureProfile(workspacePath: "/tmp/workspace-a", persistent: true)
        XCTAssertTrue(service.tabs.isEmpty, "a cookie jar cannot be swapped under a live page")

        // Same profile again: no churn.
        _ = service.tab(for: "session-1")
        service.configureProfile(workspacePath: "/tmp/workspace-a", persistent: true)
        XCTAssertEqual(service.tabs.count, 1)
    }
}
