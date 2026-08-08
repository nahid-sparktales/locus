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

    /// A PNG of the current viewport.
    ///
    /// Viewport-only by construction: `WKSnapshotConfiguration.rect` is in view
    /// coordinates and clipped to what is laid out, and WebKit has no
    /// capture-beyond-viewport equivalent.
    func snapshotPNG(maximumWidth: CGFloat = 1_600) async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let width = min(webView.bounds.width, maximumWidth)
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
        guard let data = image.pngData else { throw BrowserHostError.snapshotUnavailable }
        return data
    }
}

enum BrowserHostError: LocalizedError {
    case snapshotUnavailable

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable: "the page could not be captured"
        }
    }
}

extension NSImage {
    /// PNG bytes at the image's own pixel dimensions.
    var pngData: Data? {
        guard let tiff = tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff)
        else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}
