import AppKit
import SwiftUI
import XCTest
@testable import Locus

/// The transcript keeps the newest output on screen while a reply streams in.
/// The pin lives in `TranscriptScrollCoordinator`, which can only work if its
/// bridge resolves the transcript's platform scroll view — a resolution that
/// silently fails when the anchor sits outside the scroll content, leaving the
/// reader to chase generated text by hand.
private struct FollowProbeRoot: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RootView()
            .preferredColorScheme(model.effectiveAppearance.colorScheme)
            .environment(\.locusAccent, model.effectiveAccent)
    }
}

@MainActor
final class TranscriptFollowTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    func testTranscriptFollowsGeneratedOutputUntilTheReaderScrollsAway() throws {
        let model = makeModel()
        let host = mount(model, size: NSSize(width: 1_000, height: 640))
        let scroll = try XCTUnwrap(
            transcriptScrollView(in: host),
            "The transcript's scroll view was not found from the selection scope"
        )
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(
            document.bounds.height, scroll.contentView.bounds.height,
            "The transcript has to overflow the viewport for following to be observable"
        )

        // Mounting attaches the coordinator, and an attached coordinator opens
        // the conversation at its newest content.
        XCTAssertLessThanOrEqual(waitForBottomDistance(scroll, below: 2), 2,
            "An attached transcript opens pinned to its newest content")

        // New output grows the document; the viewport has to go with it.
        model.blocks.append(ChatBlock(kind: .assistant, text: Self.reply))
        pump()
        XCTAssertLessThanOrEqual(waitForBottomDistance(scroll, below: 2), 2,
            "The transcript did not follow newly generated output")

        // A reader who scrolls up is reading; more output must not yank the
        // viewport back down.
        simulateUserScrollUp(scroll, by: 300)
        let parked = scroll.contentView.bounds.origin.y
        model.blocks.append(ChatBlock(kind: .assistant, text: Self.reply))
        pump()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, parked, accuracy: 1,
            "Output arriving while detached moved the parked viewport")

        // Sending a message is a return to the conversation's leading edge:
        // following re-engages so the reply streams into view.
        model.blocks.append(ChatBlock(kind: .user, text: "One more question"))
        pump()
        XCTAssertLessThanOrEqual(waitForBottomDistance(scroll, below: 2), 2,
            "Sending a message did not re-engage following")
    }

    // MARK: - Harness

    private func makeModel() -> AppModel {
        let model = AppModel(startImmediately: false)
        var blocks: [ChatBlock] = []
        for index in 0..<6 {
            blocks.append(ChatBlock(kind: .user, text: "Request \(index)"))
            blocks.append(ChatBlock(kind: .assistant, text: Self.reply))
        }
        model.blocks = blocks
        pump()
        return model
    }

    /// Tall enough that six of them overflow the mounted window.
    private static let reply = """
    A reply long enough to occupy real vertical space in the transcript, so \
    that the pinned viewport and a parked one land measurably far apart.

    A second paragraph, because a single line could fit inside the slack the \
    near-bottom threshold allows and hide a failure to follow.
    """

    private func mount(_ model: AppModel, size: NSSize) -> NSView {
        let host = NSHostingView(rootView: FollowProbeRoot()
            .environmentObject(model)
            .environmentObject(AppUpdateController(startImmediately: false)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        pump()
        return host
    }

    private func pump(_ rounds: Int = 40) {
        for _ in 0..<rounds {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func bottomDistance(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .greatestFiniteMagnitude }
        return TranscriptScrollMetrics.bottomDistance(
            documentBounds: document.bounds,
            visibleRect: scroll.documentVisibleRect,
            isFlipped: document.isFlipped
        )
    }

    /// The pin lands on a display-link tick, not synchronously; poll the run
    /// loop until it does or the deadline passes, and hand back the distance
    /// either way so the assertion carries the number.
    private func waitForBottomDistance(
        _ scroll: NSScrollView,
        below target: CGFloat,
        timeout: TimeInterval = 3
    ) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if bottomDistance(scroll) <= target { break }
            pump(2)
        }
        return bottomDistance(scroll)
    }

    private func simulateUserScrollUp(_ scroll: NSScrollView, by delta: CGFloat) {
        simulateUserScroll(scroll, pump: pump) { origin, document in
            NSPoint(
                x: origin.x,
                y: document?.isFlipped == false
                    ? origin.y + delta
                    : max(origin.y - delta, 0)
            )
        }
    }
}

/// The transcript is the scroll view whose content carries the selection
/// scope — the same containment the app itself relies on. Shared with the
/// relayout tests, which need to address the same scroll view.
@MainActor
func transcriptScrollView(in root: NSView) -> NSScrollView? {
    func containsSelectionScope(_ view: NSView) -> Bool {
        if view is TranscriptSelectionScopeView { return true }
        return view.subviews.contains(where: containsSelectionScope)
    }
    var stack: [NSView] = [root]
    while let view = stack.popLast() {
        if let scroll = view as? NSScrollView, containsSelectionScope(scroll) {
            return scroll
        }
        stack.append(contentsOf: view.subviews)
    }
    return nil
}

/// Reproduces what a trackpad gesture looks like to the scroll coordinator: a
/// live-scroll span around a viewport move. Moving away from the bottom
/// detaches following, which is also what lets a test park a transcript at a
/// deterministic offset.
@MainActor
func simulateUserScroll(
    _ scroll: NSScrollView,
    pump: (Int) -> Void,
    to destination: (NSPoint, NSView?) -> NSPoint
) {
    let center = NotificationCenter.default
    center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    pump(2)
    let origin = scroll.contentView.bounds.origin
    scroll.contentView.scroll(to: destination(origin, scroll.documentView))
    scroll.reflectScrolledClipView(scroll.contentView)
    pump(2)
    center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    pump(2)
    center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    pump(2)
}
