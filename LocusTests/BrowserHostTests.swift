import AppKit
import WebKit
import XCTest
@testable import Locus

/// Proves the one assumption the whole browser feature rests on: a web view the
/// user cannot see still lays out, renders, and can be captured. If these fail,
/// the agent cannot screenshot a page unless the inspector happens to be open
/// on the Browser tab, and the design has to change.
@MainActor
final class BrowserHostTests: XCTestCase {
    private func makeHost(
        viewport: CGSize = BrowserViewport.desktop.size
    ) -> (OffscreenWebHost, LoadWaiter) {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        return (OffscreenWebHost(webView: webView, viewport: viewport), waiter)
    }

    func testParkedWebViewRendersAndCaptures() async throws {
        let (host, waiter) = makeHost()
        XCTAssertTrue(host.isParked)

        host.webView.loadHTMLString(
            "<body style=\"margin:0;background:#ff0000\"></body>",
            baseURL: nil
        )
        try await waiter.wait()

        let data = try await host.snapshotPNG()
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(data: data),
            "the snapshot did not decode as an image"
        )
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)

        let centre = try XCTUnwrap(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2),
            "the snapshot had no pixel at its centre"
        )
        let rgb = try XCTUnwrap(centre.usingColorSpace(.sRGB))
        // A blank drawing area comes back white or transparent; red proves the
        // off-screen panel really composited the page.
        XCTAssertGreaterThan(rgb.redComponent, 0.8, "expected a rendered red page")
        XCTAssertLessThan(rgb.greenComponent, 0.2, "expected a rendered red page")
        XCTAssertLessThan(rgb.blueComponent, 0.2, "expected a rendered red page")
    }

    func testViewportSizeReachesThePage() async throws {
        let (host, waiter) = makeHost(viewport: BrowserViewport.mobile.size)
        host.webView.loadHTMLString("<body></body>", baseURL: nil)
        try await waiter.wait()

        let width = try await host.webView.evaluateJavaScript("window.innerWidth")
        XCTAssertEqual(width as? Int, Int(BrowserViewport.mobile.size.width))

        host.setViewport(BrowserViewport.desktop.size)
        XCTAssertEqual(host.viewport, BrowserViewport.desktop.size)
        // Layout is asynchronous; give WebKit one runloop turn to re-measure.
        try await Task.sleep(for: .milliseconds(200))
        let resized = try await host.webView.evaluateJavaScript("window.innerWidth")
        XCTAssertEqual(resized as? Int, Int(BrowserViewport.desktop.size.width))
    }

    func testLendingMovesTheViewAndParkingReturnsIt() throws {
        let (host, _) = makeHost()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        host.lend(to: container)
        XCTAssertFalse(host.isParked)
        XCTAssertTrue(host.webView.superview === container)
        XCTAssertEqual(host.webView.bounds.size, container.bounds.size)

        host.park()
        XCTAssertTrue(host.isParked)
        XCTAssertFalse(host.webView.superview === container)
        XCTAssertEqual(host.webView.bounds.size, host.viewport)
    }

    func testFixedCanvasLendingPreservesViewportAcrossInspectorResizes() {
        let (host, _) = makeHost(viewport: BrowserViewport.desktop.size)
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))

        host.lend(to: canvas, preservingViewport: true)
        XCTAssertEqual(canvas.frame.size, BrowserViewport.desktop.size)
        XCTAssertEqual(host.webView.frame.size, BrowserViewport.desktop.size)
        XCTAssertTrue(host.webView.autoresizingMask.isEmpty)

        canvas.frame.size = CGSize(width: 520, height: 400)
        XCTAssertEqual(
            host.webView.frame.size,
            BrowserViewport.desktop.size,
            "Presentation resizing must never change page layout or agent coordinates"
        )
    }

    func testViewportIsClampedToSaneBounds() {
        let (host, _) = makeHost()
        host.setViewport(CGSize(width: 1, height: 1))
        XCTAssertEqual(host.viewport, CGSize(width: 120, height: 120))
        host.setViewport(CGSize(width: 99_999, height: 99_999))
        XCTAssertEqual(host.viewport, CGSize(width: 4_000, height: 4_000))
    }

    func testBackgroundedHostStillCaptures() async throws {
        // A background tab gives up its "visible" activity state so it stops
        // competing with the loading page — but a capture must still work,
        // because snapshotPNG restores the drawing area for the moment.
        let (host, waiter) = makeHost()
        host.webView.loadHTMLString(
            "<body style=\"margin:0;background:#0000ff\"></body>",
            baseURL: nil
        )
        try await waiter.wait()

        host.setKeptLive(false)
        XCTAssertFalse(host.isKeptLive)

        let data = try await host.snapshotPNG()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let centre = try XCTUnwrap(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        )
        let rgb = try XCTUnwrap(centre.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(rgb.blueComponent, 0.8, "expected a rendered blue page")
        XCTAssertFalse(host.isKeptLive, "the capture must not leave the tab live")

        host.setKeptLive(true)
        XCTAssertTrue(host.isKeptLive)
    }
}
