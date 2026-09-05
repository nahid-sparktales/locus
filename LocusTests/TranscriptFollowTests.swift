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

    func testCompactDispatcherTranscriptRealizesVisibleContentAtLogicalBottom() throws {
        let model = AppModel(startImmediately: false)
        model.sidebarCollapsed = true
        model.inspectorCollapsed = false
        model.setInspectorWidth(360)
        model.currentSessionID = "dispatcher-follow-regression"
        model.orchestrationRunID = "dispatcher-follow-run"
        model.turnDispatchedTeamRunID = "dispatcher-follow-run"
        model.orchestrationState = .dispatching
        model.isBusy = true
        model.teamRunLive.apply("dispatcher_started", [
            "run_id": "dispatcher-follow-run", "agent_name": "Dispatcher",
            "provider": "Fixture", "model": "Fixture", "goal": "Creating the team plan",
        ])
        model.teamRunLive.apply("dispatcher_plan_rejected", [
            "reason": "dispatcher plan has no jobs", "message": "Correcting dispatcher plan…",
        ])
        var request = ChatBlock(kind: .user, text: "Build a stock checker")
        request.runID = "dispatcher-follow-run"
        let suffix = "Visible dispatcher transcript suffix"
        // A tall, live TimelineView followed by short rows reproduces the
        // lazy-height estimate that left the compact viewport completely blank.
        model.blocks = [request, ChatBlock(kind: .assistant, text: suffix), ChatBlock(
            kind: .note,
            completion: TurnCompletion(outcome: .complete, mode: .work, durationMilliseconds: 84_000)
        )]
        let host = mount(model, size: NSSize(width: 720, height: 588))
        let scroll = try XCTUnwrap(transcriptScrollView(in: host))
        XCTAssertTrue(waitForVisibleText(suffix, in: scroll),
            "A bottom flag is insufficient: the actual final text must be realized inside the viewport")
        XCTAssertTrue(waitForVisibleAccessibilityIdentifier("teamDispatch.stop", in: scroll),
            "The real dispatcher card's control must remain visible, not an empty estimated document")
    }

    func testVariableHeightTranscriptKeepsActualNewestTextVisibleAfterReplacement() throws {
        let model = AppModel(startImmediately: false)
        model.sidebarCollapsed = true
        model.inspectorCollapsed = true
        model.blocks = [
            ChatBlock(kind: .user, text: String(repeating: Self.reply + "\n\n", count: 12)),
            ChatBlock(kind: .assistant, text: "Initial visible suffix"),
        ]
        let host = mount(model, size: NSSize(width: 360, height: 588))
        let scroll = try XCTUnwrap(transcriptScrollView(in: host))
        XCTAssertTrue(waitForVisibleText("Initial visible suffix", in: scroll))

        model.blocks.append(ChatBlock(kind: .assistant, text: Self.reply + "\n\nUpdated visible suffix"))
        XCTAssertTrue(waitForVisibleText("Updated visible suffix", in: scroll))

        simulateUserScrollUp(scroll, by: 250)
        model.currentSessionID = "replacement-session"
        model.blocks = [
            ChatBlock(kind: .user, text: String(repeating: Self.reply + "\n\n", count: 8)),
            ChatBlock(kind: .assistant, text: "Replacement visible suffix"),
        ]
        XCTAssertTrue(waitForVisibleText("Replacement visible suffix", in: scroll),
            "A new session must invalidate old scroll intent and realize its own final row")
    }

    func testLogicalPinCoalescesAndRespectsSelectionDetachAndBridgeLifecycle() {
        let scroll = mountNativeScroll()
        let anchor = NSView(frame: .zero)
        scroll.documentView?.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        var requests = 0
        coordinator.setBottomTarget { requests += 1 }
        coordinator.attach(from: anchor)
        pump()
        XCTAssertGreaterThan(requests, 0)
        let initial = requests
        for _ in 0..<100 { coordinator.contentMayHaveChanged() }
        pump()
        XCTAssertEqual(requests, initial + 1, "One display request must coalesce repeated content changes")

        coordinator.setSelectionDragActive(true)
        coordinator.contentMayHaveChanged()
        coordinator.jumpToLatest(animated: true)
        pump()
        XCTAssertEqual(requests, initial + 1, "Selection must not be moved by a pending pin")
        coordinator.setSelectionDragActive(false)
        coordinator.detach()
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertEqual(requests, initial + 1, "Detached readers own their viewport")

        coordinator.resetForSession()
        pump()
        XCTAssertEqual(requests, initial + 2)
        coordinator.contentMayHaveChanged()
        coordinator.detachAll()
        coordinator.jumpToLatest(animated: true)
        pump()
        XCTAssertEqual(requests, initial + 2, "Queued work must not invoke a dismantled bridge's proxy")
    }

    func testWheelRoutingRejectsCoveringViewsAndOtherWindowsButKeepsNestedResponders() throws {
        let scroll = mountNativeScroll()
        let window = try XCTUnwrap(scroll.window)
        let root = try XCTUnwrap(window.contentView)
        let point = scroll.convert(NSPoint(x: 100, y: 100), to: nil)
        XCTAssertTrue(TranscriptScrollMetrics.ownsWheelLocation(
            point, eventWindow: window, scrollView: scroll
        ))

        let nested = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        nested.documentView = NSTextView(frame: nested.bounds)
        scroll.documentView?.addSubview(nested)
        XCTAssertTrue(TranscriptScrollMetrics.ownsWheelLocation(
            point, eventWindow: window, scrollView: scroll
        ), "Nested text/code responders still belong to the transcript")

        let overlay = NSView(frame: scroll.frame)
        let overlayScroll = NSScrollView(frame: overlay.bounds)
        overlayScroll.documentView = NSView(frame: overlay.bounds)
        overlay.addSubview(overlayScroll)
        root.addSubview(overlay, positioned: .above, relativeTo: scroll)
        XCTAssertFalse(TranscriptScrollMetrics.ownsWheelLocation(
            point, eventWindow: window, scrollView: scroll
        ), "An overlapping compact sidebar or panel owns the gesture")
        overlay.isHidden = true
        XCTAssertTrue(TranscriptScrollMetrics.ownsWheelLocation(
            point, eventWindow: window, scrollView: scroll
        ))
        XCTAssertFalse(TranscriptScrollMetrics.ownsWheelLocation(
            point, eventWindow: nil, scrollView: scroll
        ))
        let popoverWindow = NSWindow(
            contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        windows.append(popoverWindow)
        XCTAssertFalse(TranscriptScrollMetrics.ownsWheelLocation(
            point, eventWindow: popoverWindow, scrollView: scroll
        ), "A popover window can overlap geometrically without belonging to this transcript")
        XCTAssertFalse(TranscriptScrollMetrics.ownsWheelLocation(
            scroll.convert(NSPoint(x: -10, y: -10), to: nil),
            eventWindow: window, scrollView: scroll
        ))
    }

    // MARK: - Harness

    private func mountNativeScroll() -> NSScrollView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 397))
        let scroll = NSScrollView(frame: root.bounds)
        scroll.documentView = NSView(frame: root.bounds)
        root.addSubview(scroll)
        let window = NSWindow(
            contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = root
        window.orderFront(nil)
        windows.append(window)
        return scroll
    }

    private func waitForVisibleText(_ text: String, in scroll: NSScrollView) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            var views = scroll.documentView.map { [$0] } ?? []
            while let view = views.popLast() {
                if let leaf = view as? ResponseSelectableTextView,
                   let layout = leaf.layoutManager, let container = leaf.textContainer,
                   let document = scroll.documentView {
                    let characters = (leaf.string as NSString).range(of: text)
                    if characters.location != NSNotFound {
                        let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                        let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
                            .offsetBy(dx: leaf.textContainerOrigin.x, dy: leaf.textContainerOrigin.y)
                        if !bounds.isEmpty, bounds.intersects(leaf.visibleRect),
                           leaf.convert(bounds, to: document).intersects(scroll.documentVisibleRect) {
                            return true
                        }
                    }
                }
                views.append(contentsOf: view.subviews)
            }
            pump(2)
        } while Date() < deadline
        return false
    }

    private func waitForVisibleAccessibilityIdentifier(_ identifier: String, in scroll: NSScrollView) -> Bool {
        guard let window = scroll.window else { return false }
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let viewport = window.convertToScreen(scroll.convert(scroll.contentView.frame, to: nil))
            var elements: [Any] = [scroll]
            var visited: Set<ObjectIdentifier> = []
            while let next = elements.popLast() {
                guard let element = next as? any NSAccessibilityProtocol,
                      visited.insert(ObjectIdentifier(element)).inserted else { continue }
                if element.accessibilityIdentifier() == identifier {
                    let frame = element.accessibilityFrame()
                    if !frame.isEmpty, frame.intersects(viewport) { return true }
                }
                elements.append(contentsOf: element.accessibilityChildren() ?? [])
            }
            pump(2)
        } while Date() < deadline
        return false
    }

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
            .appFeatureEnvironment(from: model)
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
