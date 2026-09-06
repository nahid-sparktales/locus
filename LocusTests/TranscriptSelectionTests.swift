import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import Locus

/// Coverage for the transcript-wide selection store and the geometry behind
/// dragging through it.
final class TranscriptSelectionTests: XCTestCase {
    @MainActor
    func testDecoratedLocusCardKeepsItsMeasuredButtonCenterAccessible() throws {
        let identifier = "fixture.card.button"
        let content = VStack(spacing: 0) {
            Button {} label: {
                HStack {
                    Image(systemName: "chevron.right")
                    Text("Expand tool")
                    Spacer()
                    Text("DONE")
                }
                .padding(.horizontal, 12)
                .frame(width: 240, height: 39)
            }
            .buttonStyle(.locus())
            .accessibilityIdentifier(identifier)
        }
        .locusCard(radius: 9)
        .padding(20)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 280, height: 79),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.isVisible)

        // Activate SwiftUI's public accessibility tree without depending on
        // another test class having queried it first. This reads only our own
        // synthetic process and never requests permissions or changes settings.
        let ready = expectation(description: "Card fixture accessibility client is ready")
        DispatchQueue.global(qos: .userInitiated).async {
            let application = AXUIElementCreateApplication(getpid())
            let timeout = AXUIElementSetMessagingTimeout(application, 0.2)
            XCTAssertEqual(timeout, .success)
            if timeout == .success {
                var windows: CFTypeRef?
                XCTAssertEqual(AXUIElementCopyAttributeValue(
                    application, kAXWindowsAttribute as CFString, &windows
                ), .success)
            }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 1)
        var traversalTruncated = false
        func findButton() -> TranscriptAccessibilityNode? {
            var queue: [(Any, Int)] = [(host, 0)]
            var visited: Set<ObjectIdentifier> = []
            var match: TranscriptAccessibilityNode?
            while !queue.isEmpty {
                let (value, depth) = queue.removeFirst()
                guard let node = TranscriptAccessibilityNode(value),
                      visited.insert(ObjectIdentifier(node.object)).inserted else { continue }
                guard visited.count <= 256, depth <= 16 else {
                    traversalTruncated = true
                    return nil
                }
                if node.identifier == identifier, node.role == .button {
                    XCTAssertNil(match, "The fixture must expose exactly one button identity")
                    match = node
                }
                let children = node.children
                guard children.count <= 256 else {
                    traversalTruncated = true
                    return nil
                }
                queue += children.map { ($0, depth + 1) }
            }
            return match
        }
        let deadline = Date().addingTimeInterval(3)
        var button = findButton()
        while button == nil, !traversalTruncated, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
            button = findButton()
        }
        XCTAssertFalse(traversalTruncated)
        let target = try XCTUnwrap(button)
        XCTAssertEqual(target.role, .button)
        let frame = target.frame
        XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite))
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let windowPoint = window.convertPoint(fromScreen: center)
        XCTAssertTrue(host.bounds.contains(host.convert(windowPoint, from: nil)))
        let rootPoint = host.superview?.convert(windowPoint, from: nil) ?? windowPoint
        let nativeHit = try XCTUnwrap(host.hitTest(rootPoint))
        let hit = try XCTUnwrap(nativeHit.accessibilityHitTest(center))
        let accessibleHit = try XCTUnwrap(TranscriptAccessibilityNode(hit))
        XCTAssertEqual(accessibleHit.role, .button)
        XCTAssertEqual(accessibleHit.identifier, identifier,
            "The visible button, not an outer decorative card shape, must own its measured center")
    }

    // MARK: - Noninteractive scope

    @MainActor
    func testTranscriptSelectionScopeNeverOwnsPointerOrAccessibilityHits() {
        let scope = TranscriptSelectionScopeView(
            frame: NSRect(x: 20, y: 30, width: 400, height: 200)
        )
        for point in [NSPoint(x: 30, y: 40), NSPoint(x: 200, y: 130), NSPoint(x: 410, y: 220)] {
            XCTAssertNil(scope.hitTest(point))
            XCTAssertNil(scope.accessibilityHitTest(point))
        }
        XCTAssertFalse(scope.isAccessibilityElement())
        XCTAssertTrue(scope.isAccessibilityHidden())
    }

    @MainActor
    func testOverlaidTranscriptScopePreservesButtonAndSelectedTextHitTargets() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 50, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let document = NSView(frame: scroll.bounds)
        scroll.documentView = document
        window.contentView = scroll

        let button = NSButton(title: "Expand tool", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 30, width: 180, height: 40)
        document.addSubview(button)
        let text = ResponseSelectableTextView.make()
        text.frame = NSRect(x: 20, y: 110, width: 300, height: 40)
        text.isEditable = false
        text.textStorage?.setAttributedString(NSAttributedString(string: "selected text"))
        document.addSubview(text)
        let store = TranscriptSelectionStore()
        defer { store.reset() }
        store.syncRows(["scope-fixture"])
        let selectedSpan = span(row: "scope-fixture", path: [0], text: "selected text")
        store.register(selectedSpan, view: text)
        store.selectForTesting(
            from: .init(spanID: selectedSpan.id, utf16Offset: 0),
            to: .init(spanID: selectedSpan.id, utf16Offset: 8)
        )

        window.makeKeyAndOrderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.isVisible)

        let buttonPoint = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let textPoint = NSPoint(x: text.frame.minX + 10, y: text.frame.midY)
        func accessibilityTarget(at point: NSPoint) -> NSObject? {
            // A plain ignored document view's accessibilityHitTest resolves
            // its unignored scroll ancestor, not the frontmost native child.
            // AppKit first narrows the native hit, then lets that receiver
            // resolve any finer accessibility target (for example, a cell).
            guard let root = window.contentView else { return nil }
            let windowPoint = document.convert(point, to: nil)
            let rootPoint = root.superview?.convert(windowPoint, from: nil) ?? windowPoint
            guard let hit = root.hitTest(rootPoint) else { return nil }
            return hit.accessibilityHitTest(window.convertPoint(toScreen: windowPoint)) as? NSObject
        }
        let originalButtonTarget = try XCTUnwrap(accessibilityTarget(at: buttonPoint))
        let originalTextTarget = try XCTUnwrap(accessibilityTarget(at: textPoint))
        XCTAssertEqual(
            (originalButtonTarget as? any NSAccessibilityProtocol)?.accessibilityRole(), .button
        )
        XCTAssertEqual(
            (originalTextTarget as? any NSAccessibilityProtocol)?.accessibilityRole(), .textArea
        )
        XCTAssertTrue(document.hitTest(buttonPoint) === button)
        XCTAssertTrue(document.hitTest(textPoint) === text)

        // Deliberately put the registration-only view above real controls.
        // Neither SwiftUI hosting order nor a future background refactor may
        // turn this full-size invisible view into an input shield.
        let scope = TranscriptSelectionScopeView(frame: document.bounds)
        document.addSubview(scope, positioned: .above, relativeTo: nil)
        scope.registerScope()
        XCTAssertTrue(document.subviews.last === scope)
        XCTAssertTrue(document.hitTest(buttonPoint) === button)
        XCTAssertTrue(document.hitTest(textPoint) === text)
        XCTAssertTrue(accessibilityTarget(at: buttonPoint) === originalButtonTarget)
        XCTAssertTrue(accessibilityTarget(at: textPoint) === originalTextTarget)
        XCTAssertTrue(
            TranscriptSelectionMenu.shared.transcriptScrollView(containing: text) === scroll,
            "Pass-through behavior must preserve the selection menu's scroll ownership"
        )
        XCTAssertEqual(store.selectedText, "selected")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 8))
    }

    // MARK: - Identity

    func testSpanIdentityIsScopedToItsRow() {
        let first = TranscriptSelectionSpan(
            treePath: [0],
            displayedText: "one",
            separatorBefore: "",
            copyPrefix: "",
            rowID: "block:A"
        )
        let second = TranscriptSelectionSpan(
            treePath: [0],
            displayedText: "two",
            separatorBefore: "",
            copyPrefix: "",
            rowID: "block:B"
        )
        XCTAssertNotEqual(first.id, second.id, "identical paths in different rows must not collide")
        XCTAssertEqual(TranscriptSelectionStore.rowID(ofSpanID: first.id), "block:A")

        // A projection with no row — a single document — keeps the old shape,
        // so existing callers and their tests are unaffected.
        let unscoped = TranscriptSelectionSpan(
            treePath: [1, 2],
            displayedText: "x",
            separatorBefore: "",
            copyPrefix: ""
        )
        XCTAssertEqual(unscoped.id, "1.2")
    }

    func testPresentationRowKeysAreDistinctAndStable() {
        let block = UUID()
        let ids: [TranscriptPresentationItem.ID] = [
            .block(block),
            .assistantSegment(.init(sourceBlockID: block, ordinal: 0)),
            .assistantSegment(.init(sourceBlockID: block, ordinal: 1)),
            .toolGroup(block),
            .thinkingGroup(.init(sourceBlockID: block, ordinal: 0)),
        ]
        let keys = ids.map(\.stableKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(
            TranscriptPresentationItem.ID.block(block).stableKey,
            TranscriptPresentationItem.ID.block(block).stableKey
        )
    }

    // MARK: - Projection

    func testAMissingEndpointResolvesInsteadOfCopyingNothing() {
        // A selected leaf's row can be re-parsed or dropped mid-drag. Returning
        // an empty projection made Command-C silently copy nothing.
        let spans = [
            span(row: "r1", path: [0], text: "first"),
            span(row: "r2", path: [0], text: "second"),
        ]
        let selection = TranscriptSelection(
            anchor: .init(spanID: spans[0].id, utf16Offset: 0),
            focus: .init(spanID: "gone#9", utf16Offset: 3)
        )
        guard let resolved = TranscriptSelectionProjection.resolve(selection, in: spans) else {
            return XCTFail("a live anchor should always resolve")
        }
        XCTAssertEqual(resolved.focus.spanID, spans[1].id)
        XCTAssertEqual(resolved.focus.utf16Offset, 6)
        XCTAssertEqual(
            TranscriptSelectionProjection.text(for: resolved, orderedSpans: spans),
            "first\n\nsecond"
        )
    }

    // MARK: - Store

    @MainActor
    func testScrollingARowAwayKeepsItsTextInTheSelection() {
        // Leaves are torn down by the lazy list as they scroll off. That used
        // to clear the selection outright, which made any drag longer than the
        // window impossible.
        //
        // Covered here rather than as a UI test: forcing real recycling needs a
        // transcript large enough that every XCUITest query against it timed
        // out before it could assert anything.
        let store = TranscriptSelectionStore()
        store.syncRows(["r1", "r2"])
        let first = span(row: "r1", path: [0], text: "first")
        let second = span(row: "r2", path: [0], text: "second")
        let firstView = ResponseSelectableTextView.make()
        let secondView = ResponseSelectableTextView.make()
        store.register(first, view: firstView)
        store.register(second, view: secondView)

        store.selectForTesting(
            from: .init(spanID: first.id, utf16Offset: 0),
            to: .init(spanID: second.id, utf16Offset: 6)
        )
        XCTAssertEqual(store.selectedText, "first\n\nsecond")

        store.unregister(spanID: first.id, view: firstView)
        XCTAssertTrue(store.hasLiveSelection)
        XCTAssertEqual(
            store.selectedText,
            "first\n\nsecond",
            "losing the view must not lose the text"
        )
    }

    @MainActor
    func testARowLeavingTheTranscriptDropsItsSpans() {
        let store = TranscriptSelectionStore()
        store.syncRows(["r1", "r2"])
        let first = span(row: "r1", path: [0], text: "first")
        let second = span(row: "r2", path: [0], text: "second")
        store.register(first, view: .make())
        store.register(second, view: .make())
        store.selectForTesting(
            from: .init(spanID: first.id, utf16Offset: 0),
            to: .init(spanID: second.id, utf16Offset: 6)
        )

        store.syncRows(["r2"])
        XCTAssertEqual(store.selectedText, "second", "the surviving row still copies")
    }

    @MainActor
    func testARowNeverRenderedIsFilledInSoCopySpansTheWholePassage() {
        // Realization lags a fast autoscroll, so the middle of a long drag may
        // never have had a live view.
        let store = TranscriptSelectionStore()
        store.syncRows(["r1", "r2", "r3"])
        let middle = span(row: "r2", path: [0], text: "middle")
        store.spanProvider = { rowID in rowID == "r2" ? [middle] : [] }

        let first = span(row: "r1", path: [0], text: "first")
        let last = span(row: "r3", path: [0], text: "last")
        store.register(first, view: .make())
        store.register(last, view: .make())
        store.selectForTesting(
            from: .init(spanID: first.id, utf16Offset: 0),
            to: .init(spanID: last.id, utf16Offset: 4)
        )

        XCTAssertEqual(store.selectedText, "first\n\nmiddle\n\nlast")
    }

    @MainActor
    func testClearingASelectionAlwaysReleasesTheStreamingFreeze() {
        // A streaming answer stops updating its rendered text while its row is
        // being selected. Missing a clear path would freeze it permanently.
        let store = TranscriptSelectionStore()
        store.syncRows(["r1"])
        let only = span(row: "r1", path: [0], text: "text")
        store.register(only, view: .make())

        store.selectForTesting(
            from: .init(spanID: only.id, utf16Offset: 0),
            to: .init(spanID: only.id, utf16Offset: 4),
            dragging: true
        )
        XCTAssertEqual(store.activeRowIDs, ["r1"])
        store.clearSelection()
        XCTAssertTrue(store.activeRowIDs.isEmpty)

        store.selectForTesting(
            from: .init(spanID: only.id, utf16Offset: 0),
            to: .init(spanID: only.id, utf16Offset: 4),
            dragging: true
        )
        store.reset()
        XCTAssertTrue(store.activeRowIDs.isEmpty)
    }

    @MainActor
    func testADragThatLeavesItsOwnRowStillExtendsIntoTheNext() throws {
        // Cross-row is the whole point of one store: a drag that starts in a
        // question has to reach the answer.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let content = try XCTUnwrap(window.contentView)

        let store = TranscriptSelectionStore()
        store.syncRows(["r1", "r2"])

        // Window coordinates put the earlier row higher up.
        let upper = ResponseSelectableTextView.make()
        upper.frame = NSRect(x: 0, y: 140, width: 400, height: 20)
        upper.textStorage?.setAttributedString(NSAttributedString(string: "first row"))
        content.addSubview(upper)

        let lower = ResponseSelectableTextView.make()
        lower.frame = NSRect(x: 0, y: 40, width: 400, height: 20)
        lower.textStorage?.setAttributedString(NSAttributedString(string: "second row"))
        content.addSubview(lower)

        let first = span(row: "r1", path: [0], text: "first row")
        let second = span(row: "r2", path: [0], text: "second row")
        store.register(first, view: upper)
        store.register(second, view: lower)

        store.mouseDown(in: upper, event: mouseEvent(.leftMouseDown, at: NSPoint(x: 1, y: 150), in: window))
        store.mouseDragged(event: mouseEvent(.leftMouseDragged, at: NSPoint(x: 399, y: 50), in: window))
        store.mouseUp(in: upper, event: mouseEvent(.leftMouseUp, at: NSPoint(x: 399, y: 50), in: window))

        XCTAssertTrue(store.hasLiveSelection, "the drag must leave a selection behind")
        XCTAssertEqual(store.selectedText, "first row\n\nsecond row")
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in window: NSWindow
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    // MARK: - Geometry

    func testADragBesideALineStaysOnThatLineInsteadOfSwallowingTheBlock() {
        // The regression this replaced: leaves are laid out `.leading`, so a
        // drag spends most of its time in the empty right margin. Resolving
        // that by nearest rectangle snapped the offset to 0 or the whole leaf,
        // so dragging past one line selected the entire paragraph.
        let paragraph = TranscriptSpanFrame(
            spanID: "r1#0",
            order: 0,
            frame: CGRect(x: 0, y: 100, width: 400, height: 60),
            utf16Length: 120
        )
        let resolution = TranscriptSelectionGeometry.resolve(
            point: CGPoint(x: 520, y: 118),
            in: [paragraph]
        )
        guard case .inside(let spanID, let point) = resolution else {
            return XCTFail("a point beside the text belongs to that text")
        }
        XCTAssertEqual(spanID, "r1#0")
        XCTAssertEqual(point.x, 400, "clamped onto the leaf")
        XCTAssertEqual(point.y, 118, "but the line is preserved")
    }

    func testPointsBeyondEveryLeafResolveByDocumentOrderNotDistance() {
        // Window coordinates: earlier in the transcript means higher on screen.
        let top = TranscriptSpanFrame(
            spanID: "r1#0",
            order: 0,
            frame: CGRect(x: 0, y: 200, width: 400, height: 60),
            utf16Length: 10
        )
        let bottom = TranscriptSpanFrame(
            spanID: "r2#0",
            order: 1,
            frame: CGRect(x: 0, y: 100, width: 400, height: 60),
            utf16Length: 20
        )
        XCTAssertEqual(
            TranscriptSelectionGeometry.resolve(point: CGPoint(x: 10, y: 400), in: [bottom, top]),
            .start(spanID: "r1#0")
        )
        XCTAssertEqual(
            TranscriptSelectionGeometry.resolve(point: CGPoint(x: 10, y: 10), in: [bottom, top]),
            .end(spanID: "r2#0")
        )

        // In the gap between two rows, attach to the nearer one and keep the x.
        guard case .inside(let spanID, _) = TranscriptSelectionGeometry.resolve(
            point: CGPoint(x: 10, y: 175),
            in: [top, bottom]
        ) else {
            return XCTFail("a point between rows still belongs to one of them")
        }
        XCTAssertEqual(spanID, "r2#0")
        XCTAssertNil(TranscriptSelectionGeometry.resolve(point: .zero, in: []))
    }

    func testAClickWithASteadyHandIsStillAClick() {
        // A one-pixel wobble used to count as a drag, and the mouse-up handler
        // only follows a link when nothing is selected — so links in assistant
        // prose were unreliable.
        XCTAssertFalse(
            TranscriptSelectionDrag.exceedsThreshold(
                from: CGPoint(x: 100, y: 100),
                to: CGPoint(x: 101, y: 101)
            )
        )
        XCTAssertTrue(
            TranscriptSelectionDrag.exceedsThreshold(
                from: CGPoint(x: 100, y: 100),
                to: CGPoint(x: 120, y: 100)
            )
        )
    }

    // MARK: - Helpers

    private func span(row: String, path: [Int], text: String) -> TranscriptSelectionSpan {
        TranscriptSelectionSpan(
            treePath: path,
            displayedText: text,
            separatorBefore: path == [0] ? "\n\n" : "\n\n",
            copyPrefix: "",
            rowID: row
        )
    }
}
