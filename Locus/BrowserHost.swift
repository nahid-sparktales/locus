import AppKit
import WebKit

/// Fixed viewport shapes the agent and the interface can both name.
enum BrowserViewport: String, CaseIterable, Codable, Identifiable {
    case mobile
    case tablet
    case desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mobile: "Mobile"
        case .tablet: "Tablet"
        case .desktop: "Desktop"
        }
    }

    var size: CGSize {
        switch self {
        case .mobile: CGSize(width: 390, height: 844)
        case .tablet: CGSize(width: 834, height: 1_112)
        case .desktop: CGSize(width: 1_280, height: 800)
        }
    }
}

/// A panel that refuses to be pulled back onto a display.
///
/// `NSWindow` constrains a frame to whichever screen it lands on, which would
/// drag the parked panel into view the moment it is ordered front. Returning
/// the proposed rect unchanged is the supported way to decline that.
private final class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Off-screen home for one browser web view.
///
/// A `WKWebView` outside a *visible* window sits in WebKit's "not visible"
/// activity state: `requestAnimationFrame` stops, timers throttle,
/// `document.visibilityState` reads `hidden`, compositing is suppressed, and
/// `takeSnapshot` returns nothing useful because the drawing area is only
/// created in `viewDidMoveToWindow`. The agent has to read and screenshot a
/// page while the inspector sits on another tab — or is collapsed outright —
/// so the web view lives here for the life of the session and the SwiftUI
/// panes borrow it.
///
/// `alphaValue = 0` and `isHidden` both put the window back into that
/// not-visible state, so the panel is genuinely visible and simply parked far
/// beyond every screen.
@MainActor
final class OffscreenWebHost {
    /// Far enough out that no arrangement of displays reaches it.
    private static let parkingOrigin = CGPoint(x: -32_000, y: -32_000)

    let webView: WKWebView
    private let panel: UnconstrainedPanel
    private(set) var viewport: CGSize

    /// Whether the web view is currently back in the off-screen panel rather
    /// than lent to a visible container.
    var isParked: Bool { webView.superview === panel.contentView }

    /// Whether the parked panel is ordered front, keeping WebKit's "visible"
    /// activity state. Background tabs give this up so a dozen parked pages
    /// don't run rAF and unthrottled timers against the tab actually loading.
    private(set) var isKeptLive = true

    /// Order the parked panel in or out. The session's active tab stays live —
    /// the agent reads and screenshots it while the inspector shows something
    /// else — and everything else throttles like a normal background tab.
    func setKeptLive(_ live: Bool) {
        guard live != isKeptLive else { return }
        isKeptLive = live
        if live {
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    init(webView: WKWebView, viewport: CGSize = BrowserViewport.desktop.size) {
        self.webView = webView
        self.viewport = viewport
        panel = UnconstrainedPanel(
            contentRect: NSRect(origin: Self.parkingOrigin, size: viewport),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        panel.backgroundColor = .white
        panel.contentView?.addSubview(webView)
        webView.frame = NSRect(origin: .zero, size: viewport)
        webView.autoresizingMask = [.width, .height]
        // Ordering front is what makes `isVisible` true, which is the whole
        // point of the panel. The non-activating style keeps focus where it is.
        panel.orderFront(nil)
    }

    deinit {
        // `close()` is main-actor bound; the panel holds no other resources and
        // is released with the host, so ordering out is enough here.
        MainActor.assumeIsolated {
            panel.orderOut(nil)
        }
    }

    /// Move the web view into a visible container. Only one container may hold
    /// it at a time — `NSView` has a single superview, so lending it twice
    /// takes it away from the first borrower.
    func lend(to container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    /// Return the web view to the off-screen panel, restoring the emulated
    /// viewport. Safe to call when it is already parked.
    func park() {
        guard !isParked else { return }
        webView.removeFromSuperview()
        webView.frame = NSRect(origin: .zero, size: viewport)
        webView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(webView)
        // The parked panel keeps WebKit's "visible" state so pages stay live,
        // which also means a background video keeps decoding at full rate
        // against whatever the user is actually loading. A one-shot pause —
        // deliberately not setAllMediaPlaybackSuspended, whose page-level veto
        // survives navigations and would make every page the agent loads in a
        // parked tab reject play(), reporting false media defects that vanish
        // the moment the user looks.
        webView.pauseAllMediaPlayback(completionHandler: nil)
    }

    /// Resize the emulated viewport. Takes effect immediately while parked;
    /// while the view is lent out its size follows the borrower, and the new
    /// viewport applies the next time it is parked.
    func setViewport(_ size: CGSize) {
        let clamped = CGSize(
            width: max(120, min(size.width, 4_000)),
            height: max(120, min(size.height, 4_000))
        )
        viewport = clamped
        panel.setFrame(
            NSRect(origin: Self.parkingOrigin, size: clamped),
            display: false
        )
        if isParked {
            webView.frame = NSRect(origin: .zero, size: clamped)
        }
    }

    // MARK: - Real input

    /// Run `body` with the web view in a state that can actually receive input.
    ///
    /// A throttled background tab is ordered out and has no drawing area, so
    /// events delivered to it land nowhere. Bring the parked panel forward for
    /// the duration and put it back after — re-reading `isKeptLive` rather than
    /// trusting the entry value, for the same reason `snapshotPNG` does: a tab
    /// switch mid-delivery flips it, and ordering out a tab that just became
    /// live again would strand it throttled.
    ///
    /// Returns nil when input cannot be delivered at all, which is the caller's
    /// signal to fall back to the bridge rather than report a click it never
    /// made.
    func withInputDelivery<T>(_ body: () async -> T) async -> T? {
        guard canDeliverRealInput else { return nil }
        let broughtForward = !isKeptLive && isParked
        if broughtForward { panel.orderFront(nil) }
        let result = await body()
        if broughtForward, !isKeptLive { panel.orderOut(nil) }
        return result
    }

    /// The same, plus first-responder status, which key events need and mouse
    /// events do not.
    func withKeyboardFocus<T>(_ body: () async -> T) async -> T? {
        await withInputDelivery { [self] () async -> T? in
            guard let window = webView.window else { return nil }
            let previous = window.firstResponder
            window.makeFirstResponder(webView)
            let result = await body()
            // Only hand focus back in a window the person is using. While the
            // view is lent to the app's key window, leaving focus parked on the
            // page would swallow the next thing they typed into the composer;
            // in the off-screen panel there is nothing to give it back to.
            if window.isKeyWindow, let previous, previous !== webView {
                // A focused text field is not itself the first responder — its
                // field editor is, and AppKit refuses to hand that back
                // directly. Aiming at the control the editor serves is what
                // actually restores the caret.
                let target = (previous as? NSTextView)?.delegate as? NSResponder ?? previous
                if !window.makeFirstResponder(target), target !== previous {
                    window.makeFirstResponder(previous)
                }
            }
            return result
        } ?? nil
    }

    /// A PNG of the current viewport.
    ///
    /// Viewport-only by construction: `WKSnapshotConfiguration.rect` is in view
    /// coordinates and clipped to what is laid out, and WebKit has no
    /// capture-beyond-viewport equivalent.
    func snapshotPNG(maximumWidth: CGFloat = 1_600) async throws -> Data {
        try await snapshotPNG(region: nil, maximumWidth: maximumWidth).data
    }

    /// A PNG of the viewport, or of one region of it, with the pixel size it
    /// actually came back at.
    ///
    /// The size is not a detail: a capture that was scaled down is a different
    /// coordinate frame from the page, and a model reading a position off the
    /// picture has to be told which frame it is looking at before it can aim
    /// input back at the page.
    ///
    /// `region` is in page CSS pixels, the frame the rest of the browser tools
    /// speak; `WKSnapshotConfiguration.rect` wants view points, which differ
    /// only by the page zoom because `WKWebView` is flipped.
    func snapshotPNG(
        region: CGRect?,
        maximumWidth: CGFloat = 1_600
    ) async throws -> (data: Data, pixels: CGSize) {
        // A backgrounded panel is ordered out and has no drawing area; bring
        // it back for the capture and restore the throttled state after. The
        // defer re-reads `isKeptLive` rather than trusting the entry value:
        // a tab switch during the awaits below flips it through setKeptLive,
        // and ordering out a tab that just became live again would strand it
        // throttled — with the flag claiming otherwise, so nothing would
        // ever order it back front.
        let broughtForward = !isKeptLive && isParked
        if broughtForward { panel.orderFront(nil) }
        defer { if broughtForward, !isKeptLive { panel.orderOut(nil) } }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true

        var sourceWidth = webView.bounds.width
        if let region {
            let zoom = webView.pageZoom
            let rect = CGRect(
                x: region.origin.x * zoom,
                y: region.origin.y * zoom,
                width: region.width * zoom,
                height: region.height * zoom
            ).intersection(webView.bounds)
            guard !rect.isEmpty else { throw BrowserHostError.regionOffscreen }
            configuration.rect = rect
            sourceWidth = rect.width
        }
        let width = min(sourceWidth, maximumWidth)
        if width > 0 {
            configuration.snapshotWidth = NSNumber(value: Double(width))
        }

        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(
                        throwing: error ?? BrowserHostError.snapshotUnavailable
                    )
                }
            }
        }
        guard let representation = image.bitmapRepresentation,
              let data = representation.representation(using: .png, properties: [:])
        else { throw BrowserHostError.snapshotUnavailable }
        return (
            data,
            CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        )
    }
}

enum BrowserHostError: LocalizedError {
    case snapshotUnavailable
    case regionOffscreen

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable: "the page could not be captured"
        case .regionOffscreen: "that region is outside the viewport"
        }
    }
}

extension NSImage {
    /// The image's own pixels, kept separate from the PNG encoding so callers
    /// that need the dimensions do not have to decode the bytes again.
    var bitmapRepresentation: NSBitmapImageRep? {
        guard let tiff = tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// PNG bytes at the image's own pixel dimensions.
    var pngData: Data? {
        bitmapRepresentation?.representation(using: .png, properties: [:])
    }
}
