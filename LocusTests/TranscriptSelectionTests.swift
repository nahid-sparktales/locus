import AppKit
import XCTest
@testable import Locus

/// Coverage for the transcript-wide selection store and the geometry behind
/// dragging through it.
final class TranscriptSelectionTests: XCTestCase {
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
