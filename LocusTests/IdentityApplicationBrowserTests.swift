import AppKit
import WebKit
import XCTest
@testable import Locus

@MainActor
final class IdentityApplicationBrowserTests: XCTestCase {
    private var browser: BrowserService!

    override func setUp() async throws {
        try await super.setUp()
        browser = BrowserService(autofillVault: BrowserAutofillVault(inMemory: ()))
    }

    override func tearDown() async throws {
        browser.closeAllIdentityApplications()
        browser.closeTabs(ownedBy: "ordinary")
        browser = nil
        try await super.tearDown()
    }

    /// No external server: replace the initial loopback request with an inline
    /// page while the native opener waits for its first settled document.
    private func open(_ html: String, sessionID: String = "private") async throws -> IdentityBrowserSnapshot {
        let service = try XCTUnwrap(browser)
        let task = Task { @MainActor in
            try await service.openIdentityApplication(sessionID: sessionID, url: URL(string: "http://127.0.0.1:1/application")!)
        }
        for _ in 0..<100 {
            if service.isIdentityApplication(sessionID: sessionID) { break }
            await Task.yield()
        }
        XCTAssertTrue(service.isIdentityApplication(sessionID: sessionID))
        service.tab(for: sessionID).webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.invalid/application"))
        return try await task.value
    }

    func testPrivateContextPreventsGenericObservationAndCapturesBeforeAnyFill() async throws {
        _ = try await open("""
        <title>private-title-marker</title><body>private-body-marker
        <label>Email <input type="email" value="private-value-marker"></label>
        <script>console.log('private-log-marker'); history.replaceState({},'', '/private-route-marker');</script>
        </body>
        """)
        let tools = ["browser_navigate", "browser_read_page", "browser_get_text", "browser_find",
                     "browser_screenshot", "browser_wait_for", "browser_input", "browser_javascript",
                     "browser_resize", "browser_console", "browser_network", "browser_tabs",
                     "browser_history", "browser_autofill"]
        for tool in tools {
            let result = await browser.perform(tool: tool, arguments: [:], sessionID: "private", timeoutMilliseconds: 1_000)
            let error = try XCTUnwrap(result["error"] as? String)
            XCTAssertFalse(error.contains("marker"), tool)
            XCTAssertNil(result["text"], tool)
        }
        let published = try XCTUnwrap(browser.activeSnapshot(for: "private"))
        XCTAssertEqual(published.title, "Identity application")
        XCTAssertEqual(published.url, "")
        XCTAssertNil(browser.activeLog(for: "private"))
        let host = try XCTUnwrap(browser.activeHost(for: "private"))
        do {
            _ = try await host.snapshotPNG()
            XCTFail("Private pages must not be captured")
        } catch { XCTAssertEqual(error as? IdentityBrowserError, .unsupported) }
    }

    func testNewTabsInheritOnlyTheirApplicationsEphemeralStore() async throws {
        let ordinary = browser.tab(for: "ordinary")
        let first = try await open("<body><input aria-label='First'></body>")
        let privateTab = try browser.tab(for: "private", tabID: first.tabID)
        _ = try await open("<body><input aria-label='Second'></body>", sessionID: "second")
        let second = browser.tab(for: "second")
        XCTAssertFalse(privateTab.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(privateTab.webView.configuration.websiteDataStore === ordinary.webView.configuration.websiteDataStore)
        XCTAssertFalse(privateTab.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
        browser.userNewTab(sessionID: "private")
        let child = browser.tab(for: "private")
        XCTAssertTrue(child.webView.configuration.websiteDataStore === privateTab.webView.configuration.websiteDataStore)
        XCTAssertFalse(child.webView.isInspectable)
        child.webView.isInspectable = true
        XCTAssertFalse(child.webView.isInspectable, "A generic Web Inspector preference must not weaken private pages")
        XCTAssertNotNil(child.identityPage)
        XCTAssertEqual(child.webView.configuration.userContentController.userScripts.count, 1)
        XCTAssertTrue(child.host.identityProtected)
        XCTAssertFalse(browser.userNavigate("file:///tmp/private", sessionID: "private"))
        XCTAssertFalse(browser.userNavigate("https://person:secret@fixture.invalid", sessionID: "private"))
    }

    func testNativeFillReturnsOnlyStatusAndConsumesSnapshot() async throws {
        let snapshot = try await open("""
        <body><label>Email <input id="email" type="email"></label>
        <label>Consent <input id="consent" type="checkbox"></label>
        <input type="password" aria-label="Password"><input type="hidden" name="csrf"></body>
        """)
        XCTAssertEqual(snapshot.fields.count, 2)
        let email = try XCTUnwrap(snapshot.fields.first { $0.type == "email" })
        let consent = try XCTUnwrap(snapshot.fields.first { $0.type == "checkbox" })
        let bindings = [IdentityBrowserBinding(fieldID: email.id, value: "private@example.invalid"),
                        IdentityBrowserBinding(fieldID: consent.id, value: "true")]
        let result = try await browser.fillIdentityApplication(snapshot: snapshot, bindings: bindings)
        XCTAssertEqual(result, "Approved fields filled locally.")
        let values = try await browser.tab(for: "private").webView.evaluateJavaScript("[document.getElementById('email').value,document.getElementById('consent').checked]") as? [Any]
        XCTAssertEqual(values?.first as? String, "private@example.invalid")
        XCTAssertEqual(values?.last as? Bool, true)
        do {
            _ = try await browser.fillIdentityApplication(snapshot: snapshot, bindings: bindings)
            XCTFail("A consumed approval must not be reusable")
        } catch { XCTAssertEqual(error as? IdentityBrowserError, .changed) }
    }

    func testPageMutationRejectsAllBindingsBeforeAnyValueIsShared() async throws {
        let snapshot = try await open("""
        <body><form action="/apply"><input id="first" aria-label="First">
        <input id="second" aria-label="Second"></form></body>
        """)
        let webView = browser.tab(for: "private").webView
        _ = try await webView.evaluateJavaScript("document.querySelector('form').action = '/different-destination'")
        do {
            _ = try await browser.fillIdentityApplication(snapshot: snapshot, bindings: snapshot.fields.map {
                IdentityBrowserBinding(fieldID: $0.id, value: "never-share")
            })
            XCTFail("Changing the form destination must invalidate approval")
        } catch { XCTAssertEqual(error as? IdentityBrowserError, .changed) }
        let values = try await webView.evaluateJavaScript("Array.from(document.querySelectorAll('input')).map(x=>x.value).join(',')")
        XCTAssertEqual(values as? String, ",")
    }

    func testReviewedClickUsesExactActionAndCannotBeRepeated() async throws {
        let snapshot = try await open("""
        <body><button id="next" onclick="document.body.dataset.clicked='yes'">Continue</button></body>
        """)
        let action = try XCTUnwrap(snapshot.actions.first)
        XCTAssertEqual(action.label, "Continue")
        let result = try await browser.clickIdentityApplication(snapshot: snapshot, actionID: action.id)
        XCTAssertEqual(result, "Approved application action performed.")
        let clicked = try await browser.tab(for: "private").webView.evaluateJavaScript("document.body.dataset.clicked")
        XCTAssertEqual(clicked as? String, "yes")
        do {
            _ = try await browser.clickIdentityApplication(snapshot: snapshot, actionID: action.id)
            XCTFail("Click approval is single use")
        } catch { XCTAssertEqual(error as? IdentityBrowserError, .changed) }
    }

    func testApprovedUploadMaterializesBytesAndRemovesPickerTemporaryFile() async throws {
        let root = FileManager.default.temporaryDirectory
        let previous = Set(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("Locus-Identity-") })
        let snapshot = try await open("<body><label>Resume <input id='resume' type='file'></label></body>")
        let field = try XCTUnwrap(snapshot.fields.first)
        let bytes = Data("Synthetic resume for the native upload test".utf8)
        let result = try await browser.uploadIdentityApplication(snapshot: snapshot, fieldID: field.id, data: bytes, filename: "resume.txt")
        XCTAssertEqual(result, "Approved document attached locally.")
        let text = try await browser.tab(for: "private").webView.callAsyncJavaScript(
            "return await document.getElementById('resume').files[0].text()",
            arguments: [:], in: nil, contentWorld: .page
        )
        XCTAssertEqual(text as? String, String(data: bytes, encoding: .utf8))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("Locus-Identity-") })
        XCTAssertTrue(after.subtracting(previous).isEmpty)
    }

    func testPageCannotAccessNativeBridgeAndSubframeFieldsAreExcluded() async throws {
        let snapshot = try await open("""
        <body><input aria-label="Main frame"><iframe srcdoc="<input aria-label='Subframe'>"></iframe></body>
        """)
        XCTAssertEqual(snapshot.fields.map(\.label), ["Main frame"])
        let exposed = try await browser.tab(for: "private").webView.evaluateJavaScript("typeof globalThis.__locusIdentity")
        XCTAssertEqual(exposed as? String, "undefined")
    }

    func testStopRevokesAnOutstandingApprovedFilePickerBeforeSupplyingBytes() async throws {
        let root = FileManager.default.temporaryDirectory
        let previous = Set(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("Locus-Identity-") })
        let snapshot = try await open("<body><label>Resume <input id='resume' type='file'></label></body>")
        let field = try XCTUnwrap(snapshot.fields.first)
        let tab = browser.tab(for: "private")
        let page = try XCTUnwrap(tab.identityPage)
        let picker = DeferredIdentityUploadDelegate(page: page)
        tab.webView.uiDelegate = picker
        defer {
            picker.finish()
            tab.webView.uiDelegate = page
        }
        let service = try XCTUnwrap(browser)
        let pending = Task { @MainActor in
            try await service.uploadIdentityApplication(
                snapshot: snapshot, fieldID: field.id,
                data: Data("This document must never reach the page".utf8), filename: "resume.txt"
            )
        }
        for _ in 0..<100 {
            if picker.isWaiting { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(picker.isWaiting, "Exercise cancellation while the native picker callback is pending")
        browser.cancelPendingActions(ownedBy: "private")
        picker.finish()
        do {
            _ = try await pending.value
            XCTFail("Stopping the task must cancel the approved upload")
        } catch { XCTAssertEqual(error as? IdentityBrowserError, .cancelled) }
        let count = try await tab.webView.evaluateJavaScript("document.getElementById('resume').files.length")
        XCTAssertEqual(count as? Int, 0)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("Locus-Identity-") })
        XCTAssertTrue(after.subtracting(previous).isEmpty)
        do {
            _ = try await browser.uploadIdentityApplication(snapshot: snapshot, fieldID: field.id, data: Data("retry".utf8), filename: "resume.txt")
            XCTFail("Stop must also revoke the old approval snapshot")
        } catch { XCTAssertEqual(error as? IdentityBrowserError, .changed) }
    }

    func testClosingApplicationDestroysContextAndRejectsOldSnapshot() async throws {
        let snapshot = try await open("<body><input aria-label='Name'></body>")
        browser.closeIdentityApplication(sessionID: "private")
        XCTAssertFalse(browser.hasIdentityApplications)
        XCTAssertTrue(browser.snapshots(for: "private").isEmpty)
        XCTAssertFalse(browser.canReopenClosedTab(sessionID: "private"))
        do {
            _ = try await browser.fillIdentityApplication(snapshot: snapshot, bindings: [IdentityBrowserBinding(fieldID: snapshot.fields[0].id, value: "secret")])
            XCTFail("Closed contexts cannot be filled")
        } catch { XCTAssertEqual(error as? IdentityBrowserError, .changed) }
    }
}

/// Hold only the native callback, rather than racing a timed Stop against a
/// fast local file upload. Resuming after Stop exercises the stale callback.
@MainActor
private final class DeferredIdentityUploadDelegate: NSObject, WKUIDelegate {
    private let page: IdentityApplicationPage
    private var pending: (() -> Void)?
    var isWaiting: Bool { pending != nil }

    init(page: IdentityApplicationPage) { self.page = page }

    func finish() {
        let completion = pending
        pending = nil
        completion?()
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        pending = { [page] in
            page.webView(webView, runOpenPanelWith: parameters, initiatedByFrame: frame, completionHandler: completionHandler)
        }
    }
}
