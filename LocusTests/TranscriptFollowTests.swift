import AppKit
import ApplicationServices
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

/// One synchronous main-actor observation: no run-loop pumping, scrolling, or
/// forced layout occurs between the glyph and control observations. These are
/// geometry/ownership diagnostics, never text, accessibility labels, or IDs.
private struct TranscriptVisibilityObservation: Encodable {
    var windowVisible = false
    var documentBounds = "unavailable"
    var viewportBounds = "unavailable"
    var viewportOnScreen = "unavailable"
    var nativeNodeCount = 0
    var accessibilityNodeCount = 0
    var traversalTruncated = false
    var textMatchCount = 0
    var visibleTextMatchCount = 0
    var glyphBoundsInDocument: [String] = []
    var clippedGlyphBoundsInDocument: [String] = []
    var controlMatchCount = 0
    var rejectedControlOwnershipCount = 0
    var visibleControlMatchCount = 0
    var controlBoundsOnScreen: [String] = []
    var controlRoles: [String] = []
    var ownedControlBoundsOnScreen: [String] = []
    var scopeDiscoveryNodeCount = 0
    var verifiedVirtualScrollScopes = 0
    var rejectedVirtualScrollScopes = 0
    var candidateScrollRoles: [String] = []
    var candidateScrollBoundsOnScreen: [String] = []

    var textVisible: Bool { visibleTextMatchCount > 0 && !traversalTruncated }
    var controlVisible: Bool { visibleControlMatchCount > 0 && !traversalTruncated }
}

/// SwiftUI's virtual accessibility nodes implement the public selectors without
/// declaring conformance to the complete NSAccessibilityProtocol. Optional
/// Objective-C dispatch preserves those real nodes without requiring a cast or
/// manufacturing a role, frame, or identifier.
@MainActor
struct TranscriptAccessibilityNode {
    let object: NSObject

    init?(_ value: Any) {
        guard let object = value as? NSObject else { return nil }
        self.object = object
    }

    private var dynamic: AnyObject { object }

    var identifier: String? {
        if let identifier = dynamic.accessibilityIdentifier?() { return identifier }
        // AppKit exposes the button's role through its cell, while retaining
        // the control's identifier on the containing NSButton (AXUnknown).
        // Bind the two only through AppKit's exact cell/control ownership.
        if let cell = object as? NSButtonCell, let button = cell.controlView as? NSButton,
           button.cell === cell {
            return button.accessibilityIdentifier()
        }
        return nil
    }

    var role: NSAccessibility.Role? { dynamic.accessibilityRole?() }
    var frame: NSRect { dynamic.accessibilityFrame?() ?? .zero }
    var children: [Any] {
        (dynamic.accessibilityChildren?() ?? []) + (dynamic.accessibilityContents?() ?? [])
    }
    var parent: Any? { dynamic.accessibilityParent?() }
    var isHidden: Bool { dynamic.isAccessibilityHidden?() ?? false }
}

@MainActor
final class TranscriptFollowTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var visibilityDiagnosticCount = 0
    private var lastTextQuery: String?
    private weak var lastTextQueryScroll: NSScrollView?

    override func setUp() {
        super.setUp()
        // A real public client query enables SwiftUI to vend its accessibility
        // tree. Merely calling NSView's in-process getters leaves it dormant.
        // Query only this synthetic test process; never request permissions,
        // inspect another app, change accessibility settings, or retain values.
        let ready = expectation(description: "Own-process accessibility client is ready")
        DispatchQueue.global(qos: .userInitiated).async {
            let application = AXUIElementCreateApplication(getpid())
            let timeout = AXUIElementSetMessagingTimeout(application, 0.2)
            XCTAssertEqual(timeout, .success)
            if timeout == .success {
                var windows: CFTypeRef?
                XCTAssertEqual(AXUIElementCopyAttributeValue(
                    application, kAXWindowsAttribute as CFString, &windows
                ), .success, "The fixture must expose its own public accessibility tree")
            }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 1)
    }

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

    func testCompactDispatchPlanRealizesItsActualTailAndTranscriptOwnedActions() throws {
        let model = AppModel(startImmediately: false)
        // Reuse the exact UI fixture, including the tall three-job approval
        // card, short reply, completion row and open Runs inspector. Do not
        // mutate process environment or substitute a shorter progress card.
        model.seedUITestState(runFixture: "dispatch-plan")
        model.sidebarCollapsed = true
        model.inspectorCollapsed = false
        model.setInspectorWidth(360)
        XCTAssertEqual(model.pendingDispatchPlan?.jobs.count, 3)
        XCTAssertEqual(model.blocks.count, 3)
        let suffix = try XCTUnwrap(model.blocks.first(where: { $0.kind == .assistant })?.text)
        let host = mount(model, size: NSSize(width: 720, height: 588))
        let scroll = try XCTUnwrap(transcriptScrollView(in: host))
        XCTAssertEqual(scroll.contentView.bounds.width, 360, accuracy: 1)
        XCTAssertTrue(waitForVisibleText(suffix, in: scroll),
            "The tall plan must not strand the actual reply in an empty estimated document")

        let identifiers = ["teamDispatch.approval", "teamDispatch.run",
                           "teamDispatch.redispatch", "teamDispatch.cancel"]
        let deadline = Date().addingTimeInterval(3)
        var observations: [TranscriptVisibilityObservation] = []
        repeat {
            observations = identifiers.map { observeVisibility(text: suffix, identifier: $0, in: scroll) }
            if let approval = observations.first,
               approval.controlMatchCount > approval.rejectedControlOwnershipCount,
               !approval.traversalTruncated,
               observations.dropFirst().allSatisfy({ $0.textVisible && $0.controlVisible }) {
                break
            }
            pump(2)
        } while Date() < deadline
        observations.forEach(attachVisibility)
        let approval = try XCTUnwrap(observations.first)
        // The header may be above the viewport on a tall card. Match the UI
        // test's existence contract without accepting its inspector copy.
        XCTAssertGreaterThan(approval.controlMatchCount, approval.rejectedControlOwnershipCount,
            "The approval header must exist in the transcript's own accessibility subtree")
        XCTAssertFalse(approval.traversalTruncated)
        for (identifier, observation) in zip(identifiers.dropFirst(), observations.dropFirst()) {
            XCTAssertTrue(observation.textVisible && observation.controlVisible,
                "The actual reply and transcript-owned \(identifier) must be visible together")
        }
    }

    func testDiagnosticPlainTallFirstRowRealizesTheUnchangedDispatchPlanSuffix() throws {
        // Diagnostic only: this is not acceptance of the real approval card.
        // Its measured height is retained while only its rendered subtree is
        // substituted; the exact UI seed, trailing rows and coordinator stay.
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
        let model = AppModel(startImmediately: false)
        model.seedUITestState(runFixture: "dispatch-plan")
        model.sidebarCollapsed = true
        model.inspectorCollapsed = false
        model.setInspectorWidth(360)
        let committedSnapshot = model.transcriptPresentation.snapshot
        XCTAssertEqual(model.pendingDispatchPlan?.jobs.count, 3)
        XCTAssertEqual(model.blocks.count, 3)
        XCTAssertEqual(committedSnapshot.items.count, 3)
        XCTAssertEqual(Set(committedSnapshot.items.map(\.id)).count, 3,
            "Every lazy row must have a unique presentation identity")
        XCTAssertEqual(committedSnapshot.renderToken.tailID, committedSnapshot.items.last?.id)
        let suffix = try XCTUnwrap(model.blocks.first(where: { $0.kind == .assistant })?.text)
        let host = mount(
            model, size: NSSize(width: 720, height: 588),
            firstRowDiagnosticReplacement: .measuredTallPlanPlaceholder
        )
        let scroll = try XCTUnwrap(transcriptScrollView(in: host))
        XCTAssertEqual(scroll.contentView.bounds.width, 360, accuracy: 1)
        XCTAssertTrue(waitForVisibleText(suffix, in: scroll),
            "A finite plain first row must allow the actual unchanged suffix to be realized")
        XCTAssertEqual(model.transcriptPresentation.snapshot, committedSnapshot,
            "A render-only diagnostic must not change the real conversation or its render token")
    }

    func testTranscriptAppendStillRealizesGlyphsAfterAnOwnedAccessibilityRead() throws {
        let model = AppModel(startImmediately: false)
        model.sidebarCollapsed = true
        model.inspectorCollapsed = false
        model.setInspectorWidth(360)
        model.currentSessionID = "accessibility-append-regression"
        model.orchestrationRunID = "accessibility-append-run"
        model.turnDispatchedTeamRunID = "accessibility-append-run"
        model.orchestrationState = .dispatching
        model.isBusy = true
        model.teamRunLive.apply("dispatcher_started", [
            "run_id": "accessibility-append-run", "agent_name": "Dispatcher",
            "provider": "Fixture", "model": "Fixture", "goal": "Creating the team plan",
        ])
        model.teamRunLive.apply("dispatcher_plan_rejected", [
            "reason": "dispatcher plan has no jobs", "message": "Correcting dispatcher plan…",
        ])
        var request = ChatBlock(kind: .user, text: "Prepare this synthetic plan")
        request.runID = "accessibility-append-run"
        model.blocks = [request, ChatBlock(kind: .assistant, text: "Before accessibility append")]
        let host = mount(model, size: NSSize(width: 720, height: 588))
        let scroll = try XCTUnwrap(transcriptScrollView(in: host))
        XCTAssertTrue(waitForVisibleText("Before accessibility append", in: scroll))
        XCTAssertTrue(waitForVisibleAccessibilityIdentifier("teamDispatch.stop", in: scroll))
        let observation = observeVisibility(text: "Before accessibility append", in: scroll)
        attachVisibility(observation)
        // SwiftUI may vend the real control directly from the owning native
        // scroll, or through its verified virtual container. Require the
        // actual uniquely owned button, not one particular discovery route.
        XCTAssertEqual(observation.controlMatchCount, 1)
        XCTAssertEqual(observation.rejectedControlOwnershipCount, 0)
        XCTAssertEqual(observation.controlRoles, [NSAccessibility.Role.button.rawValue])
        XCTAssertTrue(observation.textVisible && observation.controlVisible,
            "The append must follow a real, owned control read, not just native glyph observation")

        model.blocks.append(ChatBlock(kind: .assistant, text: Self.reply + "\n\nAfter accessibility append"))
        XCTAssertTrue(waitForVisibleText("After accessibility append", in: scroll),
            "Reading the real accessibility subtree must not prevent subsequent native rendering")
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

    func testNativeLiveScrollNotificationsSynchronouslyAdmitAndReleaseReaderOwnership() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        document.setFrameSize(NSSize(width: 360, height: 1_000))
        scroll.contentView.scroll(to: .zero)
        let anchor = NSView(frame: .zero)
        document.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        var requests = 0
        coordinator.setBottomTarget { requests += 1 }
        coordinator.attach(from: anchor)
        pump()
        let initial = requests
        XCTAssertGreaterThan(initial, 0)

        // No run-loop drain is allowed between these native notifications
        // and their assertions: user input must beat an already eligible pin.
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        coordinator.jumpToLatest(animated: true)
        XCTAssertEqual(requests, initial,
            "A native gesture must cancel pin admission before its notification returns")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        XCTAssertFalse(coordinator.followState.isFollowingOutput,
            "An actual move away from the bottom must detach synchronously")
        coordinator.contentMayHaveChanged()
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        XCTAssertFalse(coordinator.followState.isFollowingOutput,
            "Ending the gesture must preserve the reader's detached state")

        coordinator.jumpToLatest(animated: true)
        XCTAssertEqual(requests, initial + 1,
            "A completed native gesture must release its hold before an explicit jump")
    }

    func testSelectedGlyphViewportRestorationUsesCurrentLayoutAndSurvivesMouseUp() throws {
        let fixture = try makeSelectionViewportFixture()
        defer { fixture.coordinator.detachAll() }
        let scroll = fixture.scroll
        let originalGlyph = try XCTUnwrap(fixture.glyph.measuredGlyph(in: scroll))
        let originalOffset = originalGlyph.minY - scroll.contentView.bounds.minY
        let up = try selectionMouseEvent(.leftMouseUp, at: fixture.leaf.convert(.zero, to: nil), in: scroll)
        fixture.store.mouseUp(in: fixture.leaf, event: up)
        XCTAssertTrue(fixture.store.hasLiveSelection)
        XCTAssertTrue(fixture.store.activeRowIDs.isEmpty)
        XCTAssertFalse(fixture.coordinator.followState.permitsAutomaticScroll)

        let current = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: fixture.token.tailID)
        fixture.coordinator.installRenderTarget(current, realizeTail: {})
        fixture.leaf.needsLayout = true
        scroll.documentView?.setFrameSize(NSSize(width: 360, height: 1_200))
        fixture.leaf.setFrameOrigin(NSPoint(x: fixture.leaf.frame.minX, y: fixture.leaf.frame.minY + 37))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 67))
        let displaced = scroll.contentView.bounds.origin
        let attachment = fixture.coordinator.layoutAttachmentRevision
        fixture.coordinator.renderContainerDidLayout(token: fixture.token, attachment: attachment, from: fixture.bridge)
        fixture.coordinator.renderContainerDidLayout(token: current, attachment: attachment &+ 1, from: fixture.bridge)
        XCTAssertEqual(scroll.contentView.bounds.origin, displaced, "Stale token/attachment evidence cannot restore a selection")

        fixture.leaf.layoutSubtreeIfNeeded()
        acknowledgeContainerLayout(fixture.coordinator, token: current, anchor: fixture.bridge)
        let currentGlyph = try XCTUnwrap(fixture.glyph.measuredGlyph(in: scroll))
        XCTAssertEqual(currentGlyph.minY - scroll.contentView.bounds.minY, originalOffset, accuracy: 1,
            "Keep the actual selected glyph fixed even when its document position also changes")
        XCTAssertNotEqual(scroll.contentView.bounds.origin, displaced)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 20))
        let repeatedOrigin = scroll.contentView.bounds.origin
        acknowledgeContainerLayout(fixture.coordinator, token: current, anchor: fixture.bridge)
        XCTAssertEqual(scroll.contentView.bounds.origin, repeatedOrigin,
            "The same layout geometry must not create a scroll-origin feedback loop")
    }

    func testSelectedGlyphViewportRestorationWaitsForSelectedLeafLayout() throws {
        let fixture = try makeSelectionViewportFixture()
        defer { fixture.coordinator.detachAll() }
        let scroll = fixture.scroll
        let originalGlyph = try XCTUnwrap(fixture.glyph.measuredGlyph(in: scroll))
        let originalOffset = originalGlyph.minY - scroll.contentView.bounds.minY
        let current = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: fixture.token.tailID)
        fixture.coordinator.installRenderTarget(current, realizeTail: {})
        fixture.leaf.needsLayout = true
        scroll.documentView?.setFrameSize(NSSize(width: 360, height: 1_200))
        fixture.leaf.setFrameOrigin(NSPoint(x: fixture.leaf.frame.minX, y: fixture.leaf.frame.minY + 37))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 67))
        let displaced = scroll.contentView.bounds.origin

        acknowledgeContainerLayout(fixture.coordinator, token: current, anchor: fixture.bridge)
        XCTAssertTrue(fixture.leaf.needsLayout, "The bridge acknowledgement must precede the selected leaf's layout")
        XCTAssertEqual(scroll.contentView.bounds.origin, displaced, "Incomplete glyph geometry cannot authorize a correction")
        XCTAssertNil(fixture.glyph.measuredGlyph(in: scroll))

        fixture.leaf.layoutSubtreeIfNeeded()
        XCTAssertFalse(fixture.leaf.needsLayout)
        acknowledgeContainerLayout(fixture.coordinator, token: current, anchor: fixture.bridge)
        let currentGlyph = try XCTUnwrap(fixture.glyph.measuredGlyph(in: scroll))
        XCTAssertEqual(currentGlyph.minY - scroll.contentView.bounds.minY, originalOffset, accuracy: 1,
            "Finishing real layout must preserve the still-valid selected glyph lease")
        XCTAssertNotEqual(scroll.contentView.bounds.origin, displaced)
    }

    func testSelectedGlyphWaitingForLayoutCannotSurviveContentReplacement() throws {
        let fixture = try makeSelectionViewportFixture()
        defer { fixture.coordinator.detachAll() }
        let scroll = fixture.scroll
        let current = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: fixture.token.tailID)
        fixture.coordinator.installRenderTarget(current, realizeTail: {})
        fixture.leaf.needsLayout = true
        scroll.documentView?.setFrameSize(NSSize(width: 360, height: 1_200))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        acknowledgeContainerLayout(fixture.coordinator, token: current, anchor: fixture.bridge)
        let ownedOrigin = scroll.contentView.bounds.origin

        fixture.leaf.replaceAttributedTextIfNeeded(NSAttributedString(string: "Changed selected native text"))
        acknowledgeContainerLayout(fixture.coordinator, token: current, anchor: fixture.bridge)
        guard case .invalid = fixture.glyph.measureGlyph(in: scroll) else {
            return XCTFail("Changed text invalidates the lease even while its layout remains pending")
        }
        fixture.leaf.layoutSubtreeIfNeeded()
        acknowledgeContainerLayout(fixture.coordinator, token: current, anchor: fixture.bridge)
        XCTAssertEqual(scroll.contentView.bounds.origin, ownedOrigin,
            "A stale selected glyph must not regain authority when replacement layout finishes")
    }

    func testSelectedGlyphViewportRestorationCannotOverrideNewerReaderOrNativeOwnership() throws {
        for invalidation in ["clear", "detach", "jump", "liveScroll", "leafReplacement", "textReplacement", "session", "attachment"] {
            let fixture = try makeSelectionViewportFixture()
            defer { fixture.coordinator.detachAll() }
            let scroll = fixture.scroll
            var current = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: fixture.token.tailID)
            fixture.coordinator.installRenderTarget(current, realizeTail: {})
            fixture.leaf.needsLayout = true
            scroll.documentView?.setFrameSize(NSSize(width: 360, height: 1_200))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
            var bridge = fixture.bridge
            switch invalidation {
            case "clear": fixture.store.clearSelection()
            case "detach": fixture.coordinator.detach()
            case "jump": fixture.coordinator.jumpToLatest()
            case "liveScroll":
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            case "leafReplacement":
                fixture.store.register(fixture.span, view: ResponseSelectableTextView.make())
            case "textReplacement":
                fixture.leaf.replaceAttributedTextIfNeeded(NSAttributedString(string: "Different native glyph content"))
            case "session":
                current = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 1, tailID: .block(UUID()))
                fixture.coordinator.installRenderTarget(current, realizeTail: {})
            default:
                bridge = NSView(frame: fixture.bridge.bounds)
                scroll.documentView?.addSubview(bridge)
                fixture.coordinator.attach(from: bridge)
            }
            let ownedOrigin = scroll.contentView.bounds.origin
            fixture.leaf.layoutSubtreeIfNeeded()
            acknowledgeContainerLayout(fixture.coordinator, token: current, anchor: bridge)
            XCTAssertEqual(scroll.contentView.bounds.origin, ownedOrigin,
                "A selection anchor must not survive \(invalidation)")
        }
    }

    func testSelectedGlyphCorrectionFinishesInsideNativeBoundsNotificationWithoutPublishing() throws {
        let fixture = try makeSelectionViewportFixture()
        defer { fixture.coordinator.detachAll() }
        let scroll = fixture.scroll
        let originalGlyph = try XCTUnwrap(fixture.glyph.measuredGlyph(in: scroll))
        let originalOffset = originalGlyph.minY - scroll.contentView.bounds.minY
        let current = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: fixture.token.tailID)
        fixture.coordinator.installRenderTarget(current, realizeTail: {})
        scroll.documentView?.setFrameSize(NSSize(width: 360, height: 1_200))
        fixture.leaf.setFrameOrigin(NSPoint(x: fixture.leaf.frame.minX, y: fixture.leaf.frame.minY + 37))
        fixture.leaf.layoutSubtreeIfNeeded()
        let currentGlyph = try XCTUnwrap(fixture.glyph.measuredGlyph(in: scroll))
        let expectedOrigin = currentGlyph.minY - originalOffset
        var publications = 0
        let observation = fixture.coordinator.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY - 67))
        // No run-loop pumping or container acknowledgement: the selected
        // glyph must already be restored when native bounds mutation returns.
        XCTAssertEqual(scroll.contentView.bounds.minY, expectedOrigin, accuracy: 1)
        XCTAssertEqual(publications, 0, "The synchronous native correction must not publish SwiftUI state")
        XCTAssertTrue(fixture.store.hasLiveSelection)
        XCTAssertFalse(fixture.coordinator.followState.permitsAutomaticScroll)

        let repeatedOrigin = expectedOrigin - 20
        scroll.contentView.scroll(to: NSPoint(x: 0, y: repeatedOrigin))
        XCTAssertEqual(scroll.contentView.bounds.minY, repeatedOrigin, accuracy: 1,
            "Identical layout geometry must not cause recursive or repeated scroll correction")
        XCTAssertEqual(publications, 0)
    }

    func testSelectionEdgeDragReleasesViewportAnchorWithoutDiscardingSelection() throws {
        let fixture = try makeSelectionViewportFixture()
        defer { fixture.coordinator.detachAll() }
        let scroll = fixture.scroll
        let start = fixture.leaf.convert(NSPoint(x: 4, y: 8), to: nil)
        fixture.store.mouseDown(in: fixture.leaf, event: try selectionMouseEvent(.leftMouseDown, at: start, in: scroll))
        let inside = NSPoint(x: start.x + 40, y: start.y)
        fixture.store.mouseDragged(event: try selectionMouseEvent(.leftMouseDragged, at: inside, in: scroll))
        XCTAssertTrue(fixture.store.hasLiveSelection)
        let clip = scroll.contentView
        let outside = clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.maxY + 20), to: nil)
        XCTAssertFalse(clip.visibleRect.contains(clip.convert(outside, from: nil)))
        let up = try selectionMouseEvent(.leftMouseUp, at: outside, in: scroll)
        fixture.store.mouseDragged(event: try selectionMouseEvent(.leftMouseDragged, at: outside, in: scroll))
        defer {
            fixture.store.mouseUp(in: fixture.leaf, event: up)
        }
        let current = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: fixture.token.tailID)
        fixture.coordinator.installRenderTarget(current, realizeTail: {})
        scroll.documentView?.setFrameSize(NSSize(width: 360, height: 1_200))
        clip.scroll(to: NSPoint(x: 0, y: 300))
        let readerOrigin = clip.bounds.origin
        acknowledgeContainerLayout(fixture.coordinator, token: current, anchor: fixture.bridge)
        XCTAssertEqual(clip.bounds.origin, readerOrigin, "Layout must not counter the user's edge-autoscroll gesture")
        XCTAssertTrue(fixture.store.hasLiveSelection, "Releasing viewport anchoring must retain the logical selection")
    }

    func testQueuedContentInvalidationSurvivesAnOrdinaryPin() {
        let scroll = mountNativeScroll()
        let anchor = NSView(frame: .zero)
        scroll.documentView?.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        var requests = 0
        coordinator.setBottomTarget { requests += 1 }
        coordinator.attach(from: anchor)
        pump()
        let initial = requests
        XCTAssertGreaterThan(initial, 0)

        // The content callback is queued; the explicit jump executes its
        // target synchronously before that callback can reach the main queue.
        // A normal pin is not a lifecycle cancellation of the pending update.
        coordinator.contentMayHaveChanged()
        coordinator.jumpToLatest(animated: true)
        XCTAssertEqual(requests, initial + 1)
        pump()
        XCTAssertEqual(requests, initial + 2,
            "Content queued before a pin still needs its coalesced post-layout target request")
        coordinator.detachAll()
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

    func testVisibilityProbeRequiresExactVisibleGlyphsThroughAncestorClipping() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        let leaf = ResponseSelectableTextView.make()
        leaf.textContainerInset = NSSize(width: 7, height: 5)
        leaf.textContainer?.lineFragmentPadding = 0
        leaf.textContainer?.heightTracksTextView = false
        leaf.isVerticallyResizable = true
        _ = leaf.configureWrapping(true)
        _ = leaf.replaceAttributedTextIfNeeded(NSAttributedString(
            string: "Synthetic prefix\nSynthetic exact suffix",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ))
        let size = leaf.measuredSize(for: 290, wraps: true)
        leaf.frame = NSRect(x: 0, y: 0, width: 304, height: size.height + 10)
        let clip = NSClipView(frame: NSRect(x: 20, y: 90, width: 304, height: leaf.frame.height))
        clip.documentView = leaf
        document.addSubview(clip)
        let control = NSButton(title: "Stop", target: nil, action: nil)
        control.setAccessibilityIdentifier("teamDispatch.stop")
        control.frame = NSRect(x: 20, y: 20, width: 80, height: 28)
        document.addSubview(control)
        pump()

        let simultaneous = observeVisibility(text: "Synthetic exact suffix", in: scroll)
        attachVisibility(simultaneous)
        XCTAssertTrue(simultaneous.textVisible)
        XCTAssertTrue(simultaneous.controlVisible, "Glyphs and control must be observed in the same sample")
        assertObservedText(false, text: "Absent suffix", in: scroll)
        leaf.isHidden = true
        assertObservedText(false, text: "Synthetic exact suffix", in: scroll)
        leaf.isHidden = false
        clip.alphaValue = 0
        assertObservedText(false, text: "Synthetic exact suffix", in: scroll)
        clip.alphaValue = 1

        // The text view still contains the suffix and intersects the viewport,
        // but its ancestor clips away the suffix's actual glyphs.
        clip.setFrameSize(NSSize(width: 304, height: 16))
        clip.scroll(to: .zero)
        assertObservedText(false, text: "Synthetic exact suffix", in: scroll)
        clip.scroll(to: NSPoint(x: 0, y: max(leaf.bounds.height - 16, 0)))
        assertObservedText(true, text: "Synthetic exact suffix", in: scroll)
        clip.frame.origin.y = document.bounds.maxY + 20
        assertObservedText(false, text: "Synthetic exact suffix", in: scroll)
    }

    func testVisibilityProbeRejectsHiddenClippedAndOutsideTranscriptStopDuplicates() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        let root = try XCTUnwrap(scroll.window?.contentView)
        let control = NSButton(title: "Stop", target: nil, action: nil)
        control.setAccessibilityIdentifier("teamDispatch.stop")
        control.frame = NSRect(x: 20, y: 20, width: 80, height: 28)
        document.addSubview(control)
        assertObservedControl(true, in: scroll)
        control.isHidden = true
        assertObservedControl(false, in: scroll)
        control.isHidden = false
        control.setAccessibilityHidden(true)
        assertObservedControl(false, in: scroll)
        control.setAccessibilityHidden(false)
        control.frame.origin.y = document.bounds.maxY + 20
        assertObservedControl(false, in: scroll)
        control.removeFromSuperview()

        // A sibling/inspector control deliberately overlaps the transcript in
        // screen coordinates. Matching ID plus intersecting frame is not proof
        // that the control belongs to the transcript.
        let duplicate = NSButton(title: "Stop", target: nil, action: nil)
        duplicate.setAccessibilityIdentifier("teamDispatch.stop")
        duplicate.frame = NSRect(x: 20, y: 20, width: 80, height: 28)
        root.addSubview(duplicate)
        assertObservedControl(false, in: scroll)
    }

    func testVisibilityProbeFindsTheRealEagerDispatcherStopInsideItsTranscript() throws {
        let model = AppModel(startImmediately: false)
        model.orchestrationRunID = "eager-dispatcher-calibration"
        model.turnDispatchedTeamRunID = model.orchestrationRunID
        model.orchestrationState = .dispatching
        model.isBusy = true
        model.teamRunLive.apply("dispatcher_started", [
            "run_id": "eager-dispatcher-calibration", "agent_name": "Dispatcher",
            "provider": "Fixture", "model": "Fixture", "goal": "Creating the team plan",
        ])
        model.teamRunLive.apply("dispatcher_plan_rejected", [
            "reason": "dispatcher plan has no jobs", "message": "Correcting dispatcher plan…",
        ])
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        let host = NSHostingView(rootView: TeamRunBoardView(
            runID: "eager-dispatcher-calibration", request: "Build a stock checker"
        ).appFeatureEnvironment(from: model).frame(width: 312).fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 24, y: 20, width: 312, height: 350)
        document.addSubview(host)
        pump()
        host.setFrameSize(NSSize(width: 312, height: host.fittingSize.height))
        XCTAssertLessThanOrEqual(host.frame.maxY, document.bounds.maxY,
            "The calibrated real board must actually fit before testing its control")
        XCTAssertTrue(waitForVisibleAccessibilityIdentifier("teamDispatch.stop", in: scroll),
            "The native/AX probe must find a known-visible real SwiftUI control before it judges lazy rendering")
        host.isHidden = true
        assertObservedControl(false, in: scroll)
    }

    func testVisibilityProbeOwnsTheVirtualSwiftUIScrollButNotAnOverlappingSibling() throws {
        let host = NSHostingView(rootView: virtualScrollCalibration(includeTranscriptButton: true))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 397)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        pump()
        let scroll = try XCTUnwrap(transcriptScrollView(in: host))
        XCTAssertTrue(waitForVisibleAccessibilityIdentifier("teamDispatch.stop", in: scroll))

        // The remaining, equally identified SwiftUI button overlaps the native
        // viewport but is a sibling of its virtual accessibility container.
        host.rootView = virtualScrollCalibration(includeTranscriptButton: false)
        pump()
        assertObservedControl(false, in: scroll)
    }

    private func virtualScrollCalibration(includeTranscriptButton: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 150)
                    if includeTranscriptButton {
                        Button("Inside", action: {}).accessibilityIdentifier("teamDispatch.stop")
                    }
                    Color.clear.frame(height: 100)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .background { TranscriptSelectionScope() }
            }
            .accessibilityIdentifier("conversation.scroll")
            Button("Outside", action: {}).accessibilityIdentifier("teamDispatch.stop").padding(12)
        }
        .frame(width: 360, height: 397)
    }

    func testRenderPinRequiresCurrentGeometryAndCoalescesUnchangedRequests() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        document.setFrameSize(NSSize(width: 360, height: 1_000))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let anchor = NSView(frame: .zero)
        document.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        var realizations = 0
        var alignments = 0
        coordinator.installRenderTarget(token, realizeTail: { realizations += 1 }, scrollToBottom: { alignments += 1 })
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        XCTAssertEqual(realizations, 1)
        XCTAssertEqual(alignments, 0)
        XCTAssertFalse(coordinator.followState.isNearBottom, "A request is not layout acknowledgment")
        for _ in 0..<100 { coordinator.contentMayHaveChanged() }
        pump()
        XCTAssertEqual(realizations, 1, "No new geometry means no duplicate realization request")

        let content = NSRect(x: 0, y: 800, width: 300, height: 40)
        let end = NSRect(x: 0, y: 759, width: 300, height: 41)
        coordinator.tailDidLayout(token: token, kind: .content, rect: content, in: scroll)
        coordinator.tailDidLayout(token: token, kind: .end, rect: end, in: scroll)
        pump()
        XCTAssertEqual(alignments, 1)
        XCTAssertFalse(coordinator.followState.isNearBottom, "An alignment request did not move this fixture")
        for _ in 0..<100 {
            coordinator.tailDidLayout(token: token, kind: .content, rect: content, in: scroll)
            coordinator.tailDidLayout(token: token, kind: .end, rect: end, in: scroll)
            coordinator.contentMayHaveChanged()
        }
        pump()
        XCTAssertEqual(alignments, 1, "Identical geometry cannot manufacture more alignment work")
        coordinator.tailDidLayout(token: token, kind: .content, rect: NSRect(x: 0, y: 41, width: 300, height: 40), in: scroll)
        coordinator.tailDidLayout(token: token, kind: .end, rect: NSRect(x: 0, y: 0, width: 300, height: 41), in: scroll)
        XCTAssertTrue(coordinator.followState.isNearBottom)
    }

    func testRenderPinApproachesPredecessorThenTailOnlyOnNewMeasuredGeometry() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        document.setFrameSize(NSSize(width: 360, height: 1_000))
        scroll.contentView.scroll(to: .zero)
        let anchor = NSView(frame: document.bounds)
        document.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        var requests: [String] = []
        var alignments = 0
        coordinator.installRenderTarget(
            token, realizeTail: { requests.append("tail") },
            realizePredecessor: { requests.append("predecessor") },
            scrollToBottom: { alignments += 1 }
        )
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        XCTAssertEqual(requests, ["predecessor"])
        for _ in 0..<100 { coordinator.contentMayHaveChanged() }
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        XCTAssertEqual(requests, ["predecessor"], "A request alone cannot advance the discovery stage")

        let viewport = scroll.contentView.bounds
        let documentBounds = document.bounds
        let predecessor = TranscriptTailLayoutView(frame: NSRect(x: 0, y: 600, width: 300, height: 40))
        predecessor.token = token
        predecessor.kind = .predecessor
        document.addSubview(predecessor)
        coordinator.registerTailProbe(predecessor)
        predecessor.layoutSubtreeIfNeeded()
        XCTAssertFalse(predecessor.needsLayout)
        coordinator.tailProbesDidLayout(token: token, attachment: coordinator.layoutAttachmentRevision, in: scroll)
        pump()
        XCTAssertEqual(scroll.contentView.bounds, viewport)
        XCTAssertEqual(document.bounds, documentBounds)
        XCTAssertEqual(requests, ["predecessor", "tail"],
            "A real predecessor measurement advances discovery even when the overall estimate is unchanged")
        XCTAssertFalse(coordinator.followState.isNearBottom)
        XCTAssertEqual(alignments, 0, "Predecessor geometry is not terminal-content evidence")
        for _ in 0..<100 {
            coordinator.tailProbesDidLayout(token: token, attachment: coordinator.layoutAttachmentRevision, in: scroll)
            coordinator.contentMayHaveChanged()
        }
        pump()
        XCTAssertEqual(requests, ["predecessor", "tail"], "Repeated measurements cannot create another request")

        coordinator.tailDidLayout(
            token: token, kind: .content, rect: NSRect(x: 0, y: 800, width: 300, height: 40), in: scroll
        )
        pump()
        XCTAssertEqual(alignments, 0, "The predecessor must never substitute for the end probe")
        coordinator.tailDidLayout(
            token: token, kind: .end, rect: NSRect(x: 0, y: 759, width: 300, height: 41), in: scroll
        )
        pump()
        XCTAssertEqual(alignments, 1, "Only the actual content and end enable measured alignment")
    }

    func testRenderPinPredecessorProgressRejectsStaleEvidenceAndReaderCancellation() throws {
        for selecting in [false, true] {
            let scroll = mountNativeScroll()
            let otherScroll = mountNativeScroll()
            let document = try XCTUnwrap(scroll.documentView)
            document.setFrameSize(NSSize(width: 360, height: 1_000))
            scroll.contentView.scroll(to: .zero)
            let anchor = NSView(frame: document.bounds)
            document.addSubview(anchor)
            let coordinator = TranscriptScrollCoordinator()
            defer { coordinator.detachAll() }
            let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: .block(UUID()))
            let old = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: token.tailID)
            var requests: [String] = []
            coordinator.installRenderTarget(
                token, realizeTail: { requests.append("tail") },
                realizePredecessor: { requests.append("predecessor") }
            )
            coordinator.attach(from: anchor)
            acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
            pump()
            XCTAssertEqual(requests, ["predecessor"])
            let rect = NSRect(x: 0, y: 600, width: 300, height: 40)
            coordinator.tailDidLayout(token: old, kind: .predecessor, rect: rect, in: scroll)
            coordinator.tailDidLayout(token: token, kind: .predecessor, rect: rect, in: otherScroll)
            pump()
            XCTAssertEqual(requests, ["predecessor"], "Neither a stale row nor a different scroll may advance discovery")

            if selecting { coordinator.setSelectionDragActive(true) } else { coordinator.detach() }
            coordinator.tailDidLayout(token: token, kind: .predecessor, rect: rect, in: scroll)
            acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
            pump()
            XCTAssertEqual(requests, ["predecessor"], "Reader intent cancels the pending terminal-row request")
            XCTAssertFalse(coordinator.followState.isFollowingOutput)
            if selecting { coordinator.setSelectionDragActive(false) }
            coordinator.contentMayHaveChanged()
            pump()
            XCTAssertEqual(requests, ["predecessor"], "Ending selection does not restore following")
            coordinator.jumpToLatest()
            pump()
            XCTAssertEqual(requests, ["predecessor", "tail"],
                "Explicit Jump may use the already measured predecessor without requesting it again")
            coordinator.contentMayHaveChanged()
            pump()
            XCTAssertEqual(requests, ["predecessor", "tail"])
            XCTAssertFalse(coordinator.followState.isNearBottom, "Neither stage certifies actual terminal visibility")
        }
    }

    func testRenderPinRejectsStaleRevisionAndWrongScrollGeometry() throws {
        let scroll = mountNativeScroll()
        let otherScroll = mountNativeScroll()
        let anchor = NSView(frame: .zero)
        try XCTUnwrap(scroll.documentView).addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let tail = TranscriptPresentationItem.ID.block(UUID())
        let old = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: tail)
        let current = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: tail)
        coordinator.installRenderTarget(old, realizeTail: {}, scrollToBottom: {})
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: old, anchor: anchor)
        pump()
        coordinator.installRenderTarget(current, realizeTail: {}, scrollToBottom: {})
        acknowledgeContainerLayout(coordinator, token: current, anchor: anchor)
        pump()
        let content = NSRect(x: 0, y: 41, width: 300, height: 40)
        let end = NSRect(x: 0, y: 0, width: 300, height: 41)
        for kind in [TranscriptTailLayoutKind.content, .end] {
            let rect = kind == .content ? content : end
            coordinator.tailDidLayout(token: old, kind: kind, rect: rect, in: scroll)
            coordinator.tailDidLayout(token: current, kind: kind, rect: rect, in: otherScroll)
        }
        XCTAssertFalse(coordinator.followState.isNearBottom)
        coordinator.tailDidLayout(token: current, kind: .content, rect: content, in: scroll)
        coordinator.tailDidLayout(token: current, kind: .end, rect: end, in: scroll)
        XCTAssertTrue(coordinator.followState.isNearBottom)
        let next = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 3, tailID: tail)
        coordinator.installRenderTarget(next, realizeTail: {}, scrollToBottom: {})
        pump()
        XCTAssertFalse(coordinator.followState.isNearBottom,
            "A previously settled projection cannot certify a new revision without its layout")
    }

    func testRenderTargetRejectsOlderAndConflictingInstallsWithoutChangingCurrentOwnership() throws {
        let scroll = mountNativeScroll()
        let otherScroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        document.setFrameSize(NSSize(width: 360, height: 1_000))
        scroll.contentView.scroll(to: .zero)
        let anchor = NSView(frame: .zero)
        let staleAnchor = NSView(frame: .zero)
        document.addSubview(anchor)
        try XCTUnwrap(otherScroll.documentView).addSubview(staleAnchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 3, tailID: .block(UUID()))
        var currentAlignments = 0
        var rejectedCallbacks = 0
        XCTAssertTrue(coordinator.installRenderTarget(
            token, realizeTail: {}, scrollToBottom: { currentAlignments += 1 }
        ))
        coordinator.attach(from: anchor, expectedToken: token)
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        coordinator.tailDidLayout(token: token, kind: .content, rect: NSRect(x: 0, y: 41, width: 300, height: 40), in: scroll)
        coordinator.tailDidLayout(token: token, kind: .end, rect: NSRect(x: 0, y: 0, width: 300, height: 41), in: scroll)
        XCTAssertTrue(coordinator.followState.isNearBottom)
        coordinator.detach()
        let attachment = coordinator.layoutAttachmentRevision
        let invalid = [
            TranscriptRenderToken(sessionGeneration: 1, contentRevision: 99, tailID: token.tailID),
            TranscriptRenderToken(sessionGeneration: 2, contentRevision: 2, tailID: token.tailID),
            TranscriptRenderToken(sessionGeneration: 2, contentRevision: 3, tailID: .block(UUID())),
            TranscriptRenderToken(sessionGeneration: 2, contentRevision: 3, tailID: nil),
        ]
        for stale in invalid {
            XCTAssertFalse(coordinator.installRenderTarget(
                stale, realizeTail: { rejectedCallbacks += 1 },
                realizePredecessor: { rejectedCallbacks += 1 },
                scrollToBottom: { rejectedCallbacks += 1 }
            ))
            coordinator.attach(from: staleAnchor, expectedToken: stale)
            XCTAssertEqual(coordinator.layoutAttachmentRevision, attachment)
            XCTAssertTrue(coordinator.followState.isNearBottom, "A rejected install cannot erase measured current geometry")
        }
        pump()
        XCTAssertFalse(coordinator.followState.isFollowingOutput, "A stale generation must not re-arm default following")
        coordinator.tailDidLayout(token: token, kind: .content, rect: NSRect(x: 0, y: 200, width: 300, height: 40), in: scroll)
        coordinator.tailDidLayout(token: token, kind: .end, rect: NSRect(x: 0, y: 159, width: 300, height: 41), in: scroll)
        coordinator.jumpToLatest()
        pump()
        XCTAssertEqual(currentAlignments, 1, "The current callback must survive every rejected replacement")
        XCTAssertEqual(rejectedCallbacks, 0)
    }

    func testRenderTargetSameTokenRefreshesAllCallbacksWithoutResettingReaderOrGeometry() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        document.setFrameSize(NSSize(width: 360, height: 1_000))
        scroll.contentView.scroll(to: .zero)
        let anchor = NSView(frame: document.bounds)
        document.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        var oldCalls = 0
        var refreshed: [String] = []
        XCTAssertTrue(coordinator.installRenderTarget(
            token, realizeTail: { oldCalls += 1 }, realizePredecessor: { oldCalls += 1 },
            scrollToBottom: { oldCalls += 1 }
        ))
        coordinator.attach(from: anchor, expectedToken: token)
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        let attachment = coordinator.layoutAttachmentRevision
        XCTAssertTrue(coordinator.installRenderTarget(
            token, realizeTail: { refreshed.append("tail") },
            realizePredecessor: { refreshed.append("predecessor") },
            scrollToBottom: { refreshed.append("align") }
        ))
        pump()
        XCTAssertEqual(refreshed, ["predecessor"], "An equal-token refresh retains current native readiness")
        coordinator.tailDidLayout(token: token, kind: .predecessor, rect: NSRect(x: 0, y: 600, width: 300, height: 40), in: scroll)
        pump()
        XCTAssertEqual(refreshed, ["predecessor", "tail"])
        coordinator.tailDidLayout(token: token, kind: .content, rect: NSRect(x: 0, y: 800, width: 300, height: 40), in: scroll)
        coordinator.tailDidLayout(token: token, kind: .end, rect: NSRect(x: 0, y: 759, width: 300, height: 41), in: scroll)
        pump()
        XCTAssertEqual(refreshed, ["predecessor", "tail", "align"])
        XCTAssertEqual(oldCalls, 0)
        coordinator.detach()
        coordinator.tailDidLayout(token: token, kind: .content, rect: NSRect(x: 0, y: 41, width: 300, height: 40), in: scroll)
        coordinator.tailDidLayout(token: token, kind: .end, rect: NSRect(x: 0, y: 0, width: 300, height: 41), in: scroll)
        XCTAssertTrue(coordinator.followState.isNearBottom)
        XCTAssertTrue(coordinator.installRenderTarget(token, realizeTail: { oldCalls += 1 }))
        pump()
        XCTAssertEqual(coordinator.layoutAttachmentRevision, attachment)
        XCTAssertTrue(coordinator.followState.isNearBottom)
        XCTAssertFalse(coordinator.followState.isFollowingOutput, "Refreshing a proxy is not a new conversation")
        XCTAssertEqual(oldCalls, 0)
    }

    func testRenderTargetAdmitsNewRevisionsGenerationsAndExactTokenReattachment() throws {
        let scroll = mountNativeScroll()
        let anchor = NSView(frame: .zero)
        try XCTUnwrap(scroll.documentView).addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let current = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 3, tailID: .block(UUID()))
        XCTAssertTrue(coordinator.installRenderTarget(current, realizeTail: {}))
        coordinator.attach(from: anchor, expectedToken: current)
        acknowledgeContainerLayout(coordinator, token: current, anchor: anchor)
        pump()
        coordinator.detach()
        let attachment = coordinator.layoutAttachmentRevision
        let revised = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 4, tailID: .block(UUID()))
        XCTAssertTrue(coordinator.installRenderTarget(revised, realizeTail: {}))
        pump()
        XCTAssertEqual(coordinator.layoutAttachmentRevision, attachment)
        XCTAssertFalse(coordinator.followState.isFollowingOutput)
        coordinator.detachAll()
        let detachedAttachment = coordinator.layoutAttachmentRevision
        XCTAssertTrue(coordinator.installRenderTarget(revised, realizeTail: {}))
        coordinator.attach(from: anchor, expectedToken: revised)
        acknowledgeContainerLayout(coordinator, token: revised, anchor: anchor)
        pump()
        XCTAssertGreaterThan(coordinator.layoutAttachmentRevision, detachedAttachment)
        XCTAssertFalse(coordinator.followState.isFollowingOutput, "Exact-token native reattachment preserves reading state")

        // Generation is the primary identity; revision ordering is scoped to
        // an unchanged generation, not used to reject a new conversation.
        let replacement = TranscriptRenderToken(sessionGeneration: 3, contentRevision: 1, tailID: nil)
        XCTAssertTrue(coordinator.installRenderTarget(replacement, realizeTail: {}))
        coordinator.attach(from: anchor, expectedToken: replacement)
        acknowledgeContainerLayout(coordinator, token: replacement, anchor: anchor)
        pump()
        XCTAssertTrue(coordinator.followState.isFollowingOutput)
        XCTAssertFalse(coordinator.installRenderTarget(revised, realizeTail: {}))
    }

    func testTailProbeLateOlderRegistrationCannotReplaceCurrentGeometry() throws {
        let scroll = mountNativeScroll()
        let anchor = NSView(frame: .zero)
        try XCTUnwrap(scroll.documentView).addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let tail = TranscriptPresentationItem.ID.block(UUID())
        let current = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 3, tailID: tail)
        coordinator.installRenderTarget(current, realizeTail: {})
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: current, anchor: anchor)
        _ = try makeRegisteredTailProbes(coordinator, token: current, in: scroll)
        coordinator.tailProbesDidLayout(token: current, attachment: coordinator.layoutAttachmentRevision, in: scroll)
        XCTAssertTrue(coordinator.followState.isNearBottom)

        let invalidTokens = [
            TranscriptRenderToken(sessionGeneration: 1, contentRevision: 99, tailID: tail),
            TranscriptRenderToken(sessionGeneration: 2, contentRevision: 2, tailID: tail),
            TranscriptRenderToken(sessionGeneration: 2, contentRevision: 3, tailID: .block(UUID())),
        ]
        for stale in invalidTokens {
            let staleProbes = try makeRegisteredTailProbes(coordinator, token: stale, in: scroll)
            coordinator.tailProbesDidLayout(token: current, attachment: coordinator.layoutAttachmentRevision, in: scroll)
            XCTAssertTrue(coordinator.followState.isNearBottom,
                "A late old-row registration cannot erase the current row's measured end")
            coordinator.unregisterTailProbe(staleProbes.content)
            coordinator.unregisterTailProbe(staleProbes.end)
            coordinator.tailProbesDidLayout(token: current, attachment: coordinator.layoutAttachmentRevision, in: scroll)
            XCTAssertTrue(coordinator.followState.isNearBottom,
                "Dismantling an older row cannot clear a newer row's registered probes")
        }
    }

    func testTailProbesRegisteredBeforeTheirBridgeTokenRemainAvailable() throws {
        let scroll = mountNativeScroll()
        let anchor = NSView(frame: .zero)
        try XCTUnwrap(scroll.documentView).addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let tail = TranscriptPresentationItem.ID.block(UUID())
        let current = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: tail)
        let next = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 2, tailID: tail)
        // SwiftUI may construct the new rows before updating their bridge.
        _ = try makeRegisteredTailProbes(coordinator, token: next, in: scroll)
        coordinator.installRenderTarget(current, realizeTail: {})
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: current, anchor: anchor)
        let oldProbes = try makeRegisteredTailProbes(coordinator, token: current, in: scroll)
        coordinator.tailProbesDidLayout(token: current, attachment: coordinator.layoutAttachmentRevision, in: scroll)
        XCTAssertTrue(coordinator.followState.isNearBottom)
        coordinator.installRenderTarget(next, realizeTail: {})
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: next, anchor: anchor)
        // Attaching requests native observation; finish that actual layout
        // before sampling rather than manufacturing a layout acknowledgment.
        try XCTUnwrap(scroll.documentView).layoutSubtreeIfNeeded()
        coordinator.unregisterTailProbe(oldProbes.content)
        coordinator.unregisterTailProbe(oldProbes.end)
        coordinator.tailProbesDidLayout(token: next, attachment: coordinator.layoutAttachmentRevision, in: scroll)
        XCTAssertTrue(coordinator.followState.isNearBottom,
            "Installing a bridge must select its pre-registered probes without another representable update")
    }

    func testTailProbeReplacementCleanupIsExactAndRegistrationsStayWeak() throws {
        let scroll = mountNativeScroll()
        let anchor = NSView(frame: .zero)
        try XCTUnwrap(scroll.documentView).addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        coordinator.installRenderTarget(token, realizeTail: {})
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        let replaced = try makeRegisteredTailProbes(coordinator, token: token, in: scroll)
        let replacement = try makeRegisteredTailProbes(coordinator, token: token, in: scroll)
        coordinator.unregisterTailProbe(replaced.content)
        coordinator.unregisterTailProbe(replaced.end)
        coordinator.tailProbesDidLayout(token: token, attachment: coordinator.layoutAttachmentRevision, in: scroll)
        XCTAssertTrue(coordinator.followState.isNearBottom)
        coordinator.unregisterTailProbe(replacement.content)
        coordinator.tailProbesDidLayout(token: token, attachment: coordinator.layoutAttachmentRevision, in: scroll)
        XCTAssertFalse(coordinator.followState.isNearBottom,
            "Removing the selected current probe must invalidate its geometry")

        weak var released: TranscriptTailLayoutView?
        autoreleasepool {
            let transient = TranscriptTailLayoutView(frame: .zero)
            transient.token = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 2, tailID: token.tailID)
            released = transient
            coordinator.registerTailProbe(transient)
        }
        XCTAssertNil(released, "Future registrations must not retain a recycled native row")
    }

    func testRenderPinAdvancesOnlyForNewNativeGeometryAndPreservesReaderOwnership() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        document.setFrameSize(NSSize(width: 360, height: 1_000))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let anchor = NSView(frame: document.bounds)
        document.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        var realizations = 0
        var alignments = 0
        coordinator.installRenderTarget(
            token, realizeTail: { realizations += 1 }, scrollToBottom: { alignments += 1 }
        )
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        XCTAssertEqual(realizations, 1)

        let originalViewport = scroll.contentView.bounds
        let originalDocument = document.bounds
        func moveViewport(to y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: originalViewport.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        moveViewport(to: 120)
        XCTAssertNotEqual(scroll.contentView.bounds, originalViewport)
        XCTAssertEqual(document.bounds, originalDocument)
        pump()
        XCTAssertEqual(realizations, 2,
            "A changed native viewport must advance a still-unrealized logical row once")

        for _ in 0..<100 {
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            coordinator.contentMayHaveChanged()
        }
        pump()
        XCTAssertEqual(realizations, 2, "Unchanged notifications cannot manufacture new layout evidence")
        moveViewport(to: originalViewport.minY)
        pump()
        XCTAssertEqual(realizations, 2, "Returning to previously consumed geometry must not repeat discovery")
        document.setFrameSize(NSSize(width: 360, height: 1_200))
        pump()
        XCTAssertEqual(realizations, 2, "Changed document bounds are not a settled container acknowledgment")
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        XCTAssertEqual(realizations, 3, "A distinct native document measurement can advance pending realization")

        coordinator.detach()
        moveViewport(to: 180)
        document.setFrameSize(NSSize(width: 360, height: 1_300))
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertFalse(coordinator.followState.isFollowingOutput)
        XCTAssertEqual(realizations, 3, "New geometry cannot take ownership from a detached reader")

        coordinator.jumpToLatest()
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        XCTAssertEqual(realizations, 4, "An explicit jump starts a fresh bounded realization attempt")
        coordinator.setSelectionDragActive(true)
        moveViewport(to: 220)
        document.setFrameSize(NSSize(width: 360, height: 1_400))
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertFalse(coordinator.followState.isFollowingOutput)
        XCTAssertEqual(realizations, 4, "Selection owns the viewport even when layout evidence changes")
        coordinator.setSelectionDragActive(false)
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertFalse(coordinator.followState.isFollowingOutput)
        XCTAssertEqual(realizations, 4, "Ending selection is not permission to resume automatic following")

        coordinator.jumpToLatest()
        pump()
        XCTAssertEqual(realizations, 5)
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertEqual(realizations, 5, "The fresh attempt must still deduplicate unchanged geometry")
        XCTAssertEqual(alignments, 0, "Native container progress is not actual terminal-content geometry")
        XCTAssertFalse(coordinator.followState.isNearBottom)
    }

    func testRenderPinOldBridgeDetachCannotClearNewAttachment() throws {
        let oldScroll = mountNativeScroll()
        let currentScroll = mountNativeScroll()
        let oldAnchor = NSView(frame: .zero)
        let currentAnchor = NSView(frame: .zero)
        try XCTUnwrap(oldScroll.documentView).addSubview(oldAnchor)
        try XCTUnwrap(currentScroll.documentView).addSubview(currentAnchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        var realizations = 0
        coordinator.installRenderTarget(token, realizeTail: { realizations += 1 }, scrollToBottom: {})
        coordinator.attach(from: oldAnchor)
        acknowledgeContainerLayout(coordinator, token: token, anchor: oldAnchor)
        pump()
        coordinator.attach(from: currentAnchor)
        acknowledgeContainerLayout(coordinator, token: token, anchor: currentAnchor)
        coordinator.detach(from: oldAnchor)
        pump()
        XCTAssertEqual(realizations, 2)
        coordinator.tailDidLayout(token: token, kind: .content, rect: NSRect(x: 0, y: 41, width: 300, height: 40), in: currentScroll)
        coordinator.tailDidLayout(token: token, kind: .end, rect: NSRect(x: 0, y: 0, width: 300, height: 41), in: currentScroll)
        XCTAssertTrue(coordinator.followState.isNearBottom,
            "The new bridge must still receive authoritative layout after old-bridge teardown")
    }

    func testNativeMeasuredAlignmentRequiresMatchingTailAndPreservesReaderOwnershipInBothOrientations() throws {
        final class FlippedDocument: NSView {
            override var isFlipped: Bool { true }
        }

        for flipped in [false, true] {
            let scroll = mountNativeScroll()
            let document: NSView = flipped ? FlippedDocument() : NSView()
            document.frame = NSRect(x: 0, y: 0, width: 360, height: 1_600)
            scroll.documentView = document
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            let anchor = NSView(frame: document.bounds)
            document.addSubview(anchor)
            let coordinator = TranscriptScrollCoordinator()
            defer { coordinator.detachAll() }
            let tailID = TranscriptPresentationItem.ID.block(UUID())
            let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: tailID)
            var realizations = 0
            // No injected alignment closure: exercise the production native
            // path, measuring its actual resulting document-visible rectangle.
            coordinator.installRenderTarget(token, realizeTail: { realizations += 1 })
            coordinator.attach(from: anchor)
            acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
            pump()
            let initialViewport = scroll.contentView.bounds
            XCTAssertEqual(realizations, 1)
            XCTAssertFalse(coordinator.followState.isNearBottom)

            let end = NSRect(x: 0, y: flipped ? 1_320 : 260, width: 300, height: 41)
            let content = NSRect(x: 0, y: flipped ? 1_260 : 301, width: 300, height: 60)
            let stale = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: tailID)
            coordinator.tailDidLayout(token: stale, kind: .content, rect: content, in: scroll)
            coordinator.tailDidLayout(token: stale, kind: .end, rect: end, in: scroll)
            pump()
            XCTAssertEqual(scroll.contentView.bounds, initialViewport)
            XCTAssertFalse(coordinator.followState.isNearBottom)
            coordinator.tailDidLayout(token: token, kind: .content, rect: content, in: scroll)
            pump()
            XCTAssertEqual(scroll.contentView.bounds, initialViewport,
                "One current content measurement without its matching end cannot move the viewport")
            XCTAssertFalse(coordinator.followState.isNearBottom)

            func assertAligned(content: NSRect, end: NSRect) {
                let visible = scroll.documentVisibleRect
                let distance = flipped ? end.maxY - visible.maxY : visible.minY - end.minY
                XCTAssertEqual(distance, 0, accuracy: 2, "Measured end alignment must respect document orientation")
                XCTAssertTrue(content.intersects(visible))
                XCTAssertTrue(end.intersects(visible))
                XCTAssertTrue(coordinator.followState.isNearBottom)
            }
            coordinator.tailDidLayout(token: token, kind: .end, rect: end, in: scroll)
            pump()
            assertAligned(content: content, end: end)
            XCTAssertNotEqual(scroll.contentView.bounds.origin, initialViewport.origin)

            coordinator.detach()
            scroll.contentView.scroll(to: initialViewport.origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            let detachedContent = content.offsetBy(dx: 0, dy: 50)
            let detachedEnd = end.offsetBy(dx: 0, dy: 50)
            coordinator.tailDidLayout(token: token, kind: .content, rect: detachedContent, in: scroll)
            coordinator.tailDidLayout(token: token, kind: .end, rect: detachedEnd, in: scroll)
            coordinator.contentMayHaveChanged()
            pump()
            XCTAssertEqual(scroll.contentView.bounds.origin, initialViewport.origin)
            XCTAssertFalse(coordinator.followState.isFollowingOutput)
            coordinator.jumpToLatest()
            pump()
            assertAligned(content: detachedContent, end: detachedEnd)

            coordinator.setSelectionDragActive(true)
            scroll.contentView.scroll(to: initialViewport.origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            let selectionContent = content.offsetBy(dx: 0, dy: 100)
            let selectionEnd = end.offsetBy(dx: 0, dy: 100)
            coordinator.tailDidLayout(token: token, kind: .content, rect: selectionContent, in: scroll)
            coordinator.tailDidLayout(token: token, kind: .end, rect: selectionEnd, in: scroll)
            pump()
            XCTAssertEqual(scroll.contentView.bounds.origin, initialViewport.origin)
            coordinator.setSelectionDragActive(false)
            coordinator.contentMayHaveChanged()
            pump()
            XCTAssertEqual(scroll.contentView.bounds.origin, initialViewport.origin)
            XCTAssertFalse(coordinator.followState.isFollowingOutput)
            coordinator.jumpToLatest()
            pump()
            assertAligned(content: selectionContent, end: selectionEnd)
        }
    }

    func testRenderPinContentRevisionPreservesReadingButSessionGenerationReengages() throws {
        let scroll = mountNativeScroll()
        let anchor = NSView(frame: .zero)
        try XCTUnwrap(scroll.documentView).addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let tail = TranscriptPresentationItem.ID.block(UUID())
        var realizations = 0
        let initial = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: tail)
        coordinator.installRenderTarget(initial, realizeTail: { realizations += 1 }, scrollToBottom: {})
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: initial, anchor: anchor)
        pump()
        coordinator.detach()
        let parked = scroll.contentView.bounds.origin
        let updated = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: tail)
        coordinator.installRenderTarget(updated, realizeTail: { realizations += 1 }, scrollToBottom: {})
        acknowledgeContainerLayout(coordinator, token: updated, anchor: anchor)
        pump()
        XCTAssertFalse(coordinator.followState.isFollowingOutput)
        XCTAssertEqual(realizations, 1)
        XCTAssertEqual(scroll.contentView.bounds.origin, parked)

        let replacement = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 3, tailID: tail)
        coordinator.installRenderTarget(replacement, realizeTail: { realizations += 1 }, scrollToBottom: {})
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: replacement, anchor: anchor)
        pump()
        XCTAssertTrue(coordinator.followState.isFollowingOutput)
        XCTAssertEqual(realizations, 2)
        XCTAssertFalse(coordinator.followState.isNearBottom, "A session reset still requires fresh layout")
    }

    func testPendingNewSessionResetCannotOverrideReaderDetachOrSelection() throws {
        for selection in [false, true] {
            let scroll = mountNativeScroll()
            let anchor = NSView(frame: .zero)
            try XCTUnwrap(scroll.documentView).addSubview(anchor)
            let coordinator = TranscriptScrollCoordinator()
            defer { coordinator.detachAll() }
            let tail = TranscriptPresentationItem.ID.block(UUID())
            var realizations = 0
            let initial = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: tail)
            coordinator.installRenderTarget(initial, realizeTail: { realizations += 1 })
            coordinator.attach(from: anchor)
            acknowledgeContainerLayout(coordinator, token: initial, anchor: anchor)
            pump()
            XCTAssertEqual(realizations, 1)

            let replacement = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 2, tailID: tail)
            coordinator.installRenderTarget(replacement, realizeTail: { realizations += 1 })
            coordinator.attach(from: anchor)
            acknowledgeContainerLayout(coordinator, token: replacement, anchor: anchor)
            // The generation's default has been enqueued, but has not run.
            // Later reader input must win even though its render token matches.
            if selection { coordinator.setSelectionDragActive(true) }
            else { coordinator.detach() }
            let parked = scroll.contentView.bounds
            pump()
            XCTAssertFalse(coordinator.followState.isFollowingOutput)
            XCTAssertEqual(realizations, 1)
            XCTAssertEqual(scroll.contentView.bounds, parked)
            if selection { coordinator.setSelectionDragActive(false) }
            coordinator.contentMayHaveChanged()
            pump()
            XCTAssertFalse(coordinator.followState.isFollowingOutput)
            XCTAssertEqual(realizations, 1)
            coordinator.jumpToLatest()
            pump()
            XCTAssertTrue(coordinator.followState.isFollowingOutput)
            XCTAssertEqual(realizations, 2)
        }
    }

    func testPendingNewSessionResetSurvivesContentCoalescingWithoutRearmingCancelledReaderLease() throws {
        for cancelReset in [false, true] {
            let scroll = mountNativeScroll()
            let anchor = NSView(frame: .zero)
            try XCTUnwrap(scroll.documentView).addSubview(anchor)
            let coordinator = TranscriptScrollCoordinator()
            defer { coordinator.detachAll() }
            let tail = TranscriptPresentationItem.ID.block(UUID())
            var realizations = 0
            let initial = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: tail)
            coordinator.installRenderTarget(initial, realizeTail: { realizations += 1 })
            coordinator.attach(from: anchor)
            acknowledgeContainerLayout(coordinator, token: initial, anchor: anchor)
            pump()
            coordinator.detach()

            let first = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 2, tailID: tail)
            let latest = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 3, tailID: tail)
            coordinator.installRenderTarget(first, realizeTail: { realizations += 1 })
            if cancelReset { coordinator.detach() }
            coordinator.installRenderTarget(latest, realizeTail: { realizations += 1 })
            // Native attachment also advances callback generations, but is
            // not reader input and cannot consume the pending follow reset.
            coordinator.attach(from: anchor)
            acknowledgeContainerLayout(coordinator, token: latest, anchor: anchor)
            pump()
            XCTAssertEqual(coordinator.followState.isFollowingOutput, !cancelReset)
            XCTAssertEqual(realizations, cancelReset ? 1 : 2)

            if cancelReset {
                let subsequent = TranscriptRenderToken(sessionGeneration: 2, contentRevision: 4, tailID: tail)
                coordinator.installRenderTarget(subsequent, realizeTail: { realizations += 1 })
                acknowledgeContainerLayout(coordinator, token: subsequent, anchor: anchor)
                pump()
                XCTAssertFalse(coordinator.followState.isFollowingOutput,
                    "A consumed cancelled session default cannot be re-armed by later content")
                XCTAssertEqual(realizations, 1)
            }
        }
    }

    func testDismantlingBridgeDiscardsItsPendingSessionFollowReset() {
        let coordinator = TranscriptScrollCoordinator()
        coordinator.detach()
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        var realizations = 0
        coordinator.installRenderTarget(token, realizeTail: { realizations += 1 })
        coordinator.detachAll()
        pump()
        XCTAssertFalse(coordinator.followState.isFollowingOutput,
            "A queued default cannot restore state after the owning bridge was dismantled")
        XCTAssertEqual(realizations, 0)
    }

    func testNativeMeasuredAlignmentRetriesAfterDocumentGrowthReleasesAnActualConstraint() throws {
        final class FlippedDocument: NSView {
            override var isFlipped: Bool { true }
        }
        let scroll = mountNativeScroll()
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 360, height: 800))
        scroll.documentView = document
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let anchor = NSView(frame: document.bounds)
        document.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        coordinator.installRenderTarget(token, realizeTail: {})
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        let content = NSRect(x: 0, y: 1_160, width: 300, height: 40)
        let end = NSRect(x: 0, y: 1_200, width: 300, height: 41)
        coordinator.tailDidLayout(token: token, kind: .content, rect: content, in: scroll)
        coordinator.tailDidLayout(token: token, kind: .end, rect: end, in: scroll)
        pump()
        XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 2)
        XCTAssertFalse(coordinator.followState.isNearBottom,
            "The native document currently constrains the viewport before the measured end")
        let constrainedViewport = scroll.contentView.bounds
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertEqual(scroll.contentView.bounds, constrainedViewport)

        // Only document bounds change. The matching token, measured content,
        // measured end and pre-alignment viewport remain exactly the same.
        document.setFrameSize(NSSize(width: 360, height: 1_600))
        XCTAssertEqual(scroll.contentView.bounds, constrainedViewport)
        pump()
        XCTAssertEqual(scroll.documentVisibleRect.maxY, end.maxY, accuracy: 2,
            "A newly relaxed native constraint must not be suppressed by the old alignment key")
        XCTAssertTrue(content.intersects(scroll.documentVisibleRect))
        XCTAssertTrue(end.intersects(scroll.documentVisibleRect))
        XCTAssertTrue(coordinator.followState.isNearBottom)
    }

    func testRenderPinDoesNotConfuseInteriorTailWithAlignedScrollableEnd() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        document.setFrameSize(NSSize(width: 360, height: 1_000))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let anchor = NSView(frame: .zero)
        document.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        coordinator.installRenderTarget(token, realizeTail: {}, scrollToBottom: {})
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        coordinator.tailDidLayout(token: token, kind: .content, rect: NSRect(x: 0, y: 181, width: 300, height: 40), in: scroll)
        coordinator.tailDidLayout(token: token, kind: .end, rect: NSRect(x: 0, y: 140, width: 300, height: 41), in: scroll)
        XCTAssertFalse(coordinator.followState.isNearBottom,
            "An interior marker in a scrollable document is not aligned with the viewport's end")
    }

    func testRenderPinWaitsForCurrentContainerLayoutAndRejectsStaleAcknowledgements() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        let anchor = NSView(frame: document.bounds)
        let otherAnchor = NSView(frame: document.bounds)
        document.addSubview(anchor)
        document.addSubview(otherAnchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let tail = TranscriptPresentationItem.ID.block(UUID())
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: tail)
        var realizations = 0
        coordinator.installRenderTarget(token, realizeTail: { realizations += 1 }, scrollToBottom: {})
        coordinator.attach(from: anchor)
        pump()
        XCTAssertEqual(realizations, 0, "A bridge update or display tick is not native container layout")
        let attachment = coordinator.layoutAttachmentRevision
        let stale = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 0, tailID: tail)
        anchor.layoutSubtreeIfNeeded()
        otherAnchor.layoutSubtreeIfNeeded()
        coordinator.renderContainerDidLayout(token: stale, attachment: attachment, from: anchor)
        coordinator.renderContainerDidLayout(token: token, attachment: attachment - 1, from: anchor)
        coordinator.renderContainerDidLayout(token: token, attachment: attachment, from: otherAnchor)
        pump()
        XCTAssertEqual(realizations, 0)
        coordinator.renderContainerDidLayout(token: token, attachment: attachment, from: anchor)
        pump()
        XCTAssertEqual(realizations, 1)
        XCTAssertFalse(coordinator.followState.isNearBottom, "Container readiness does not certify final-row visibility")
        for _ in 0..<100 {
            coordinator.renderContainerDidLayout(token: token, attachment: attachment, from: anchor)
            coordinator.contentMayHaveChanged()
        }
        pump()
        XCTAssertEqual(realizations, 1)

        let next = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 2, tailID: tail)
        coordinator.installRenderTarget(next, realizeTail: { realizations += 1 }, scrollToBottom: {})
        coordinator.renderContainerDidLayout(token: token, attachment: attachment, from: anchor)
        pump()
        XCTAssertEqual(realizations, 1, "Old container layout cannot unlock a new content revision")
        coordinator.setSelectionDragActive(true)
        acknowledgeContainerLayout(coordinator, token: next, anchor: anchor)
        pump()
        XCTAssertEqual(realizations, 1, "Native readiness does not override active selection")
        coordinator.setSelectionDragActive(false)
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertEqual(realizations, 1, "Ending selection does not reauthorize automatic following")
        XCTAssertFalse(coordinator.followState.isFollowingOutput)
        coordinator.jumpToLatest()
        pump()
        XCTAssertEqual(realizations, 2)
    }

    func testDiscoveryRequiresSettledContainerDocumentAndViewportSizeAcknowledgments() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        document.setFrameSize(NSSize(width: 360, height: 1_000))
        let anchor = NSView(frame: document.bounds)
        document.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        var realizations = 0
        coordinator.installRenderTarget(token, realizeTail: { realizations += 1 })
        coordinator.attach(from: anchor)
        func acknowledgeActualFrame() {
            anchor.layoutSubtreeIfNeeded()
            XCTAssertFalse(anchor.needsLayout)
            coordinator.renderContainerDidLayout(
                token: token, attachment: coordinator.layoutAttachmentRevision, from: anchor
            )
        }
        acknowledgeActualFrame()
        pump()
        XCTAssertEqual(realizations, 1)

        // The document/viewport are unchanged, but the actual native content
        // container has completed a different layout than the recorded ACK.
        let firstFrame = anchor.frame
        anchor.setFrameSize(NSSize(width: 360, height: 900))
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertEqual(realizations, 1)
        acknowledgeActualFrame()
        pump()
        XCTAssertEqual(realizations, 2, "New container-only evidence must advance discovery exactly once")
        for _ in 0..<100 { acknowledgeActualFrame(); coordinator.contentMayHaveChanged() }
        pump()
        XCTAssertEqual(realizations, 2)
        anchor.frame = firstFrame
        acknowledgeActualFrame()
        pump()
        XCTAssertEqual(realizations, 2, "An already consumed geometry cannot create an oscillating retry")

        document.setFrameSize(NSSize(width: 360, height: 1_200))
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertEqual(realizations, 2, "A stale document extent cannot authorize discovery")
        acknowledgeActualFrame()
        pump()
        XCTAssertEqual(realizations, 3)

        scroll.setFrameSize(NSSize(width: 360, height: 340))
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertEqual(realizations, 3, "A stale viewport size cannot authorize discovery")
        acknowledgeActualFrame()
        pump()
        XCTAssertEqual(realizations, 4)

        coordinator.detach()
        anchor.setFrameSize(NSSize(width: 360, height: 800))
        acknowledgeActualFrame()
        pump()
        XCTAssertEqual(realizations, 4)
        XCTAssertFalse(coordinator.followState.isFollowingOutput)
    }

    func testDiscoveryPendingNativeLayoutRetiresReadinessUntilTheNextActualAcknowledgment() throws {
        let scroll = mountNativeScroll()
        let document = try XCTUnwrap(scroll.documentView)
        document.setFrameSize(NSSize(width: 360, height: 1_000))
        let anchor = NSView(frame: document.bounds)
        document.addSubview(anchor)
        let coordinator = TranscriptScrollCoordinator()
        defer { coordinator.detachAll() }
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        var realizations = 0
        coordinator.installRenderTarget(token, realizeTail: { realizations += 1 })
        coordinator.attach(from: anchor)
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        XCTAssertEqual(realizations, 1)

        // No geometry has changed yet. Explicit Jump starts its discovery
        // synchronously, before the pending native layout can run.
        anchor.needsLayout = true
        coordinator.jumpToLatest(animated: true)
        XCTAssertEqual(realizations, 1, "An unfinished container cannot reuse a previous readiness record")
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        XCTAssertEqual(realizations, 2,
            "The real layout acknowledgment must resume the explicit request even at the same final size")

        anchor.needsLayout = true
        coordinator.jumpToLatest(animated: true)
        XCTAssertEqual(realizations, 2)
        coordinator.setSelectionDragActive(true)
        acknowledgeContainerLayout(coordinator, token: token, anchor: anchor)
        pump()
        XCTAssertEqual(realizations, 2, "Later selection cancels the earlier pending Jump")
        coordinator.setSelectionDragActive(false)
        coordinator.contentMayHaveChanged()
        pump()
        XCTAssertEqual(realizations, 2)
        coordinator.jumpToLatest()
        pump()
        XCTAssertEqual(realizations, 3)
    }

    private func acknowledgeContainerLayout(
        _ coordinator: TranscriptScrollCoordinator, token: TranscriptRenderToken, anchor: NSView
    ) {
        anchor.frame = anchor.superview?.bounds ?? NSRect(x: 0, y: 0, width: 300, height: 100)
        anchor.needsLayout = true
        anchor.layoutSubtreeIfNeeded()
        XCTAssertFalse(anchor.needsLayout, "The fixture must actually finish native layout before acknowledging it")
        coordinator.renderContainerDidLayout(
            token: token, attachment: coordinator.layoutAttachmentRevision, from: anchor
        )
    }

    private func makeRegisteredTailProbes(
        _ coordinator: TranscriptScrollCoordinator, token: TranscriptRenderToken, in scroll: NSScrollView
    ) throws -> (content: TranscriptTailLayoutView, end: TranscriptTailLayoutView) {
        let document = try XCTUnwrap(scroll.documentView)
        func make(_ kind: TranscriptTailLayoutKind, y: CGFloat) -> TranscriptTailLayoutView {
            let view = TranscriptTailLayoutView(frame: NSRect(x: 0, y: y, width: 300, height: 41))
            view.token = token
            view.kind = kind
            document.addSubview(view)
            coordinator.registerTailProbe(view)
            view.layoutSubtreeIfNeeded()
            XCTAssertFalse(view.needsLayout)
            return view
        }
        return (make(.content, y: 41), make(.end, y: 0))
    }

    // MARK: - Harness

    private struct SelectionViewportFixture {
        let scroll: NSScrollView
        let bridge: NSView
        let leaf: ResponseSelectableTextView
        let store: TranscriptSelectionStore
        let span: TranscriptSelectionSpan
        let glyph: TranscriptSelectionViewportAnchor
        let coordinator: TranscriptScrollCoordinator
        let token: TranscriptRenderToken
    }

    private func makeSelectionViewportFixture() throws -> SelectionViewportFixture {
        final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
        let scroll = mountNativeScroll()
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 360, height: 1_000))
        scroll.documentView = document
        let bridge = NSView(frame: document.bounds)
        document.addSubview(bridge)
        let coordinator = TranscriptScrollCoordinator()
        let token = TranscriptRenderToken(sessionGeneration: 1, contentRevision: 1, tailID: .block(UUID()))
        coordinator.installRenderTarget(token, realizeTail: {})
        coordinator.attach(from: bridge)
        acknowledgeContainerLayout(coordinator, token: token, anchor: bridge)
        pump()
        coordinator.detach()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        let leaf = ResponseSelectableTextView.make()
        leaf.textContainerInset = .zero
        leaf.textContainer?.lineFragmentPadding = 0
        leaf.configureWrapping(true)
        leaf.replaceAttributedTextIfNeeded(NSAttributedString(
            string: "Selected glyph remains readable", attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ))
        leaf.frame = NSRect(x: 20, y: 550, width: 300, height: 40)
        document.addSubview(leaf)
        leaf.layoutSubtreeIfNeeded()
        let store = TranscriptSelectionStore()
        let span = TranscriptSelectionSpan(treePath: [0], displayedText: leaf.string, separatorBefore: "", copyPrefix: "", rowID: "selected-row")
        store.syncRows([span.rowID])
        store.register(span, view: leaf)
        var glyph: TranscriptSelectionViewportAnchor?
        store.onDragActiveChange = { coordinator.setSelectionDragActive($0) }
        store.onViewportAnchorChange = { anchor in
            glyph = anchor
            coordinator.setSelectionViewportAnchor(anchor)
        }
        store.selectForTesting(
            from: .init(spanID: span.id, utf16Offset: 0),
            to: .init(spanID: span.id, utf16Offset: 8), dragging: true
        )
        return SelectionViewportFixture(
            scroll: scroll, bridge: bridge, leaf: leaf, store: store, span: span,
            glyph: try XCTUnwrap(glyph, "The fixture must capture a real visible selected glyph"),
            coordinator: coordinator, token: token
        )
    }

    private func selectionMouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in scroll: NSScrollView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: try XCTUnwrap(scroll.window).windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
    }

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
        lastTextQuery = text
        lastTextQueryScroll = scroll
        let deadline = Date().addingTimeInterval(3)
        var observation = TranscriptVisibilityObservation()
        repeat {
            observation = observeVisibility(text: text, identifier: nil, in: scroll)
            if observation.textVisible {
                attachVisibility(observation)
                return true
            }
            pump(2)
        } while Date() < deadline
        attachVisibility(observation)
        return false
    }

    private func waitForVisibleAccessibilityIdentifier(_ identifier: String, in scroll: NSScrollView) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        var observation = TranscriptVisibilityObservation()
        repeat {
            observation = observeVisibility(
                text: lastTextQueryScroll === scroll ? lastTextQuery : nil,
                identifier: identifier, in: scroll
            )
            if observation.controlVisible {
                attachVisibility(observation)
                return true
            }
            pump(2)
        } while Date() < deadline
        attachVisibility(observation)
        return false
    }

    private func observeVisibility(
        text: String? = nil,
        identifier: String? = "teamDispatch.stop",
        in scroll: NSScrollView
    ) -> TranscriptVisibilityObservation {
        var result = TranscriptVisibilityObservation()
        guard let document = scroll.documentView, let window = scroll.window else { return result }
        result.windowVisible = window.isVisible
        result.documentBounds = NSStringFromRect(document.bounds)
        let viewport = scroll.documentVisibleRect
        let screenViewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
        result.viewportBounds = NSStringFromRect(viewport)
        result.viewportOnScreen = NSStringFromRect(screenViewport)
        let nodeLimit = 8_192
        var nativeViews: [NSView] = []
        var pending = [document]
        while let view = pending.popLast() {
            guard nativeViews.count < nodeLimit else { result.traversalTruncated = true; break }
            nativeViews.append(view)
            pending.append(contentsOf: view.subviews)
            if let text, let leaf = view as? ResponseSelectableTextView,
               let layout = leaf.layoutManager, let container = leaf.textContainer {
                let characters = (leaf.string as NSString).range(of: text)
                guard characters.location != NSNotFound else { continue }
                result.textMatchCount += 1
                let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: leaf.textContainerOrigin.x, dy: leaf.textContainerOrigin.y)
                let inDocument = leaf.convert(bounds, to: document)
                let visibleGlyphs = bounds.intersection(leaf.visibleRect)
                let clipped = visibleGlyphs.isEmpty ? NSRect.zero
                    : leaf.convert(visibleGlyphs, to: document).intersection(viewport)
                if result.glyphBoundsInDocument.count < 8 {
                    result.glyphBoundsInDocument.append(NSStringFromRect(inDocument))
                    result.clippedGlyphBoundsInDocument.append(NSStringFromRect(clipped))
                }
                if nativeViewIsVisible(leaf, in: scroll), !bounds.isEmpty, !clipped.isEmpty {
                    result.visibleTextMatchCount += 1
                }
            }
        }
        result.nativeNodeCount = nativeViews.count
        // Text-only polling must not activate or traverse SwiftUI's separate
        // virtual accessibility graph. Control observations still collect the
        // latest exact glyph query synchronously in the same metadata sample.
        guard let identifier else { return result }

        // A real SwiftUI scroll view vends virtual content from the known
        // NSScrollView, not necessarily from native document descendants. Also
        // visit embedded hosting views, but never search the whole window: the
        // inspector can vend another copy of the same team's controls.
        let owners = [scroll] + nativeViews
        var elements: [(Any, NSView, NSObject?)] = owners.reversed().map { ($0, $0, nil) }
        if let scope = virtualTranscriptScope(in: scroll, observation: &result, nodeLimit: nodeLimit) {
            elements.append((scope, scroll, scope))
        }
        var visited: Set<ObjectIdentifier> = []
        while let (next, owner, virtualScope) = elements.popLast() {
            guard visited.count < nodeLimit else { result.traversalTruncated = true; break }
            guard let element = TranscriptAccessibilityNode(next),
                  visited.insert(ObjectIdentifier(element.object)).inserted else { continue }
            if element.identifier == identifier {
                result.controlMatchCount += 1
                let frame = element.frame
                if result.controlBoundsOnScreen.count < 8 {
                    result.controlBoundsOnScreen.append(NSStringFromRect(frame))
                    result.controlRoles.append(element.role?.rawValue ?? "unavailable")
                }
                if let ownedVisibleRect = accessibilityVisibleRect(
                    element, nativeOwner: owner, virtualScope: virtualScope, in: scroll
                ) {
                    if result.ownedControlBoundsOnScreen.count < 8 {
                        result.ownedControlBoundsOnScreen.append(NSStringFromRect(ownedVisibleRect))
                    }
                    if element.role == .button,
                       !frame.isEmpty, !frame.intersection(ownedVisibleRect).intersection(screenViewport).isEmpty {
                        result.visibleControlMatchCount += 1
                    }
                } else {
                    result.rejectedControlOwnershipCount += 1
                }
            }
            elements.append(contentsOf: element.children.prefix(nodeLimit).map { ($0, owner, virtualScope) })
        }
        result.accessibilityNodeCount = visited.count
        return result
    }

    /// SwiftUI can vend the virtual scroll container from an enclosing hosting
    /// view instead of the native scroll's document. Discover only that exact
    /// container here, never a requested control in the surrounding interface.
    private func virtualTranscriptScope(
        in scroll: NSScrollView, observation: inout TranscriptVisibilityObservation, nodeLimit: Int
    ) -> NSObject? {
        guard let window = scroll.window, nativeViewIsVisible(scroll, in: scroll) else { return nil }
        let expected = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
        var ancestor = scroll.superview
        var depth = 0
        while let owner = ancestor, owner.window === window, depth < 32 {
            var pending: [Any] = [owner]
            var visited: Set<ObjectIdentifier> = []
            var candidates: [TranscriptAccessibilityNode] = []
            while let value = pending.popLast() {
                guard observation.scopeDiscoveryNodeCount < nodeLimit else {
                    observation.traversalTruncated = true
                    return nil
                }
                guard let node = TranscriptAccessibilityNode(value),
                      visited.insert(ObjectIdentifier(node.object)).inserted else { continue }
                observation.scopeDiscoveryNodeCount += 1
                if !(node.object is NSView), node.identifier == "conversation.scroll" {
                    candidates.append(node)
                }
                pending.append(contentsOf: node.children.prefix(nodeLimit))
            }
            if !candidates.isEmpty {
                for candidate in candidates.prefix(8) {
                    observation.candidateScrollRoles.append(candidate.role?.rawValue ?? "unavailable")
                    observation.candidateScrollBoundsOnScreen.append(NSStringFromRect(candidate.frame))
                }
                guard candidates.count == 1, let candidate = candidates.first,
                      candidate.role == .scrollArea, !candidate.isHidden,
                      !candidate.frame.isEmpty,
                      abs(candidate.frame.minX - expected.minX) <= 1,
                      abs(candidate.frame.minY - expected.minY) <= 1,
                      abs(candidate.frame.width - expected.width) <= 1,
                      abs(candidate.frame.height - expected.height) <= 1 else {
                    observation.rejectedVirtualScrollScopes += candidates.count
                    return nil
                }
                observation.verifiedVirtualScrollScopes += 1
                return candidate.object
            }
            ancestor = owner.superview
            depth += 1
        }
        return nil
    }

    private func nativeViewIsVisible(_ view: NSView, in scroll: NSScrollView) -> Bool {
        guard view.window === scroll.window, scroll.window?.isVisible == true,
              view === scroll || view.isDescendant(of: scroll),
              !view.isHiddenOrHasHiddenAncestor else { return false }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current.alphaValue <= 0 { return false }
            ancestor = current.superview
        }
        return !view.visibleRect.isEmpty
    }

    private func accessibilityVisibleRect(
        _ element: TranscriptAccessibilityNode,
        nativeOwner: NSView,
        virtualScope: NSObject? = nil,
        in scroll: NSScrollView
    ) -> NSRect? {
        guard nativeViewIsVisible(nativeOwner, in: scroll), let window = scroll.window else { return nil }
        var visible = window.convertToScreen(nativeOwner.convert(nativeOwner.visibleRect, to: nil))
        if let cell = element.object as? NSButtonCell {
            guard let button = cell.controlView as? NSButton, button.cell === cell,
                  nativeViewIsVisible(button, in: scroll), !button.isAccessibilityHidden() else { return nil }
            visible = visible.intersection(window.convertToScreen(button.convert(button.visibleRect, to: nil)))
        }
        var current: Any? = element.object
        var visited: Set<ObjectIdentifier> = []
        while let value = current, let next = TranscriptAccessibilityNode(value) {
            guard visited.count < 128, visited.insert(ObjectIdentifier(next.object)).inserted,
                  !next.isHidden else { return nil }
            if let virtualScope, next.object === virtualScope {
                visible = visible.intersection(next.frame)
                return visible.isEmpty ? nil : visible
            }
            if let view = next.object as? NSView {
                guard nativeViewIsVisible(view, in: scroll) else { return nil }
                var ancestor: NSView? = view
                while let current = ancestor {
                    guard !current.isAccessibilityHidden() else { return nil }
                    ancestor = current.superview
                }
                visible = visible.intersection(window.convertToScreen(view.convert(view.visibleRect, to: nil)))
                if virtualScope == nil { return visible.isEmpty ? nil : visible }
            }
            if let ownerWindow = next.object as? NSWindow {
                return virtualScope == nil && ownerWindow === window && !visible.isEmpty ? visible : nil
            }
            current = next.parent
        }
        // Virtual ancestry can end at the window without a backing NSView;
        // ownership still comes from the native transcript descendant that
        // actually vended this subtree, never from frame overlap alone.
        return virtualScope == nil && !visible.isEmpty ? visible : nil
    }

    private func attachVisibility(_ observation: TranscriptVisibilityObservation) {
        guard visibilityDiagnosticCount < 12, let data = try? JSONEncoder().encode(observation) else { return }
        visibilityDiagnosticCount += 1
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Transcript visibility geometry \(visibilityDiagnosticCount)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertObservedText(
        _ expected: Bool, text: String, in scroll: NSScrollView,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let observation = observeVisibility(text: text, in: scroll)
        attachVisibility(observation)
        XCTAssertEqual(observation.textVisible, expected, file: file, line: line)
    }

    private func assertObservedControl(
        _ expected: Bool, in scroll: NSScrollView,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let observation = observeVisibility(in: scroll)
        attachVisibility(observation)
        XCTAssertEqual(observation.controlVisible, expected, file: file, line: line)
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

    private func mount(
        _ model: AppModel, size: NSSize,
        firstRowDiagnosticReplacement: TranscriptFirstRowDiagnosticReplacement? = nil
    ) -> NSView {
        let host = NSHostingView(rootView: FollowProbeRoot()
            .environment(\.transcriptFirstRowDiagnosticReplacement, firstRowDiagnosticReplacement)
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
