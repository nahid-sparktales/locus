import AppKit
import SwiftUI

struct TranscriptMeasurementCache<Key: Hashable> {
    private let capacity: Int
    private var values: [Key: NSSize] = [:]
    private var recency: [Key] = []

    init(capacity: Int = 4) {
        self.capacity = max(capacity, 1)
    }

    var count: Int { values.count }

    mutating func value(for key: Key) -> NSSize? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: NSSize, for key: Key) {
        values[key] = value
        touch(key)
        while values.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ key: Key) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}

private final class WeakResponseSelectableTextView {
    weak var value: ResponseSelectableTextView?

    init(_ value: ResponseSelectableTextView) {
        self.value = value
    }
}

/// Owns the transcript's logical text selection while its visible leaves stay
/// separate native controls.
///
/// One store for the whole conversation, held above the lazy list. Two things
/// follow from that, and both were the reported bug:
///
/// 1. **A drag is not confined to one answer.** Each visible assistant segment
///    used to own a coordinator of its own, and starting a drag in one cleared
///    any other, so a selection could not span two segments — let alone a
///    question and its answer.
/// 2. **Scrolling does not destroy a selection.** Leaves are `NSViewRepresentable`s
///    inside a `LazyVStack`, so they are torn down as they scroll away. Losing
///    the *view* now only stops the highlight being painted; the span's text,
///    and therefore Copy, survives.
///
/// Rows that were never realized are filled from `spanProvider`, so copying
/// across a long scroll returns the whole passage rather than the part that
/// happened to be on screen.
@MainActor
final class TranscriptSelectionStore: ObservableObject {
    /// Rows a live selection touches. The only thing published, and only at the
    /// start and end of a drag: a streaming answer freezes its text while its
    /// own row is being selected, and republishing per mouse-move would
    /// re-render — and therefore re-register — every leaf in it.
    @Published private(set) var activeRowIDs: Set<String> = []

    /// Supplies a row's spans when no leaf of it is currently on screen.
    var spanProvider: ((String) -> [TranscriptSelectionSpan])?
    /// Told when a drag starts and stops, so the transcript can stop
    /// auto-pinning to the bottom underneath it.
    var onDragActiveChange: ((Bool) -> Void)?

    private(set) var selection: TranscriptSelection?

    private var spans: [String: TranscriptSelectionSpan] = [:]
    private var views: [String: WeakResponseSelectableTextView] = [:]
    private var rowRank: [String: Int] = [:]
    private var rowSpanIDs: [String: Set<String>] = [:]
    private var providedSpans: [String: [TranscriptSelectionSpan]] = [:]

    private var orderCache: [TranscriptSelectionSpan]?
    private var currentRanges: [String: NSRange] = [:]
    private var appliedRanges: [String: NSRange] = [:]
    private var selectedTextCache: String?
    private var needsProjection = true

    private var dragOrigin: NSPoint?
    private var dragExceededThreshold = false
    private var pendingLink: URL?
    private var autoscrollTimer: Timer?
    private var lastDragPoint: NSPoint?
    private weak var dragView: ResponseSelectableTextView?

    // MARK: - Transcript membership

    /// Declares the transcript's rows, newest last. Ranks come from here rather
    /// than from a leaf's tree path, which cannot order two different rows.
    ///
    /// Rows that register no spans — reasoning cards, tool activity — still
    /// take a rank, so a drag passes over them without their private text
    /// joining the selection. That is what keeps the boundary the old
    /// per-segment split enforced structurally.
    func syncRows(_ orderedRowIDs: [String]) {
        let next = Dictionary(
            orderedRowIDs.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard next != rowRank else { return }
        let removed = Set(rowRank.keys).subtracting(next.keys)
        rowRank = next
        for rowID in removed {
            for spanID in rowSpanIDs.removeValue(forKey: rowID) ?? [] {
                spans.removeValue(forKey: spanID)
                views.removeValue(forKey: spanID)
                appliedRanges.removeValue(forKey: spanID)
            }
            providedSpans.removeValue(forKey: rowID)
        }
        invalidateOrder()
    }

    func reset() {
        stopAutoscroll()
        selection = nil
        spans.removeAll()
        views.removeAll()
        rowSpanIDs.removeAll()
        providedSpans.removeAll()
        currentRanges.removeAll()
        appliedRanges.removeAll()
        activeRowIDs = []
        invalidateOrder()
        TranscriptSelectionMenu.shared.storeDidClearSelection(self)
    }

    // MARK: - Leaf registration

    /// Attaches a live view to a span, and records the span's content.
    ///
    /// Called on every SwiftUI update pass, so it must stay cheap: it applies
    /// the range to *this* view only. Broadcasting to every registered view
    /// here — which is what it used to do, alongside a full re-sort — made each
    /// render quadratic in the number of leaves in a message.
    func register(_ span: TranscriptSelectionSpan, view: ResponseSelectableTextView) {
        let existing = spans[span.id]
        if existing != span {
            spans[span.id] = span
            rowSpanIDs[span.rowID, default: []].insert(span.id)
            invalidateOrder()
        }
        views[span.id] = WeakResponseSelectableTextView(view)
        view.selectionStore = self
        view.selectionSpanID = span.id
        apply(range(for: span.id), to: view, spanID: span.id)
    }

    /// Drops the view, never the span.
    ///
    /// A leaf is torn down whenever its row scrolls out of the lazy list. That
    /// used to clear the whole selection, which made any drag longer than the
    /// window impossible.
    func unregister(spanID: String, view: ResponseSelectableTextView) {
        guard views[spanID]?.value === view else { return }
        views.removeValue(forKey: spanID)
        appliedRanges.removeValue(forKey: spanID)
    }

    // MARK: - Reading the selection

    var selectedText: String {
        projectIfNeeded()
        return selectedTextCache ?? ""
    }

    /// Whether anything is selected, answered without building the text — this
    /// is asked from view bodies and from every mouse-up.
    var hasLiveSelection: Bool {
        projectIfNeeded()
        return !currentRanges.isEmpty
    }

    func copySelection() {
        let text = selectedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearSelection() {
        let had = selection != nil
        selection = nil
        stopAutoscroll()
        setDragActive(false)
        invalidateProjection()
        applySelectionDiff()
        if had { TranscriptSelectionMenu.shared.storeDidClearSelection(self) }
    }

    // MARK: - Mouse

    func mouseDown(in view: ResponseSelectableTextView, event: NSEvent) {
        guard let spanID = view.selectionSpanID else { return }
        TranscriptSelectionMenu.shared.attach(store: self)
        view.window?.makeFirstResponder(view)
        dragView = view
        dragOrigin = event.locationInWindow
        lastDragPoint = event.locationInWindow
        pendingLink = view.linkURL(atWindowPoint: event.locationInWindow)
        // A double- or shift-click is a selection gesture outright; only a
        // plain click has to earn the distinction from a link activation.
        dragExceededThreshold = event.clickCount >= 2
            || event.modifierFlags.contains(.shift)

        let index = view.characterIndex(atWindowPoint: event.locationInWindow)
        let point = TranscriptSelectionPosition(spanID: spanID, utf16Offset: index)

        if event.clickCount >= 3 {
            selectGranular(in: view, spanID: spanID, at: index, granularity: .selectByParagraph)
        } else if event.clickCount == 2 {
            selectGranular(in: view, spanID: spanID, at: index, granularity: .selectByWord)
        } else if event.modifierFlags.contains(.shift), let current = selection {
            selection = TranscriptSelection(anchor: current.anchor, focus: point)
        } else {
            selection = TranscriptSelection(anchor: point, focus: point)
        }
        invalidateProjection()
        applySelectionDiff()
    }

    func mouseDragged(event: NSEvent) {
        guard let origin = dragOrigin else { return }
        if !dragExceededThreshold {
            guard TranscriptSelectionDrag.exceedsThreshold(
                from: origin,
                to: event.locationInWindow
            ) else { return }
            dragExceededThreshold = true
            setDragActive(true)
        }
        lastDragPoint = event.locationInWindow
        extend(to: event.locationInWindow)
        startAutoscrollIfNeeded(event: event)
    }

    func mouseUp(in view: ResponseSelectableTextView, event: NSEvent) {
        stopAutoscroll()
        defer {
            dragOrigin = nil
            pendingLink = nil
            dragExceededThreshold = false
            dragView = nil
        }
        // A click that never became a drag opens the link under it. Requiring
        // an empty selection instead let a one-pixel wobble swallow the click.
        if !dragExceededThreshold, let link = pendingLink,
           view.linkURL(atWindowPoint: event.locationInWindow) == link {
            clearSelection()
            view.open(link)
            return
        }
        setDragActive(false)
    }

    func rightMouseDown(in view: ResponseSelectableTextView, event: NSEvent) {
        guard let spanID = view.selectionSpanID else { return }
        let point = view.characterIndex(atWindowPoint: event.locationInWindow)
        let inSelection = currentRangesContain(spanID: spanID, offset: point)
        if !inSelection {
            // Nothing selected under the pointer: take the word, the way a
            // right-click in native text does, so the menu has something to
            // act on instead of doing nothing at all.
            TranscriptSelectionMenu.shared.attach(store: self)
            view.window?.makeFirstResponder(view)
            selectGranular(in: view, spanID: spanID, at: point, granularity: .selectByWord)
            invalidateProjection()
            applySelectionDiff()
        }
        guard hasLiveSelection else { return }
        TranscriptSelectionMenu.shared.presentResponseContextMenu(
            text: selectedText,
            from: view,
            at: view.convert(event.locationInWindow, from: nil)
        )
    }

    // MARK: - Keyboard

    /// First press covers the row under the cursor; a second widens to the
    /// whole transcript. Selecting every message at once is rarely what
    /// Command-A is reaching for.
    func selectAll(from view: ResponseSelectableTextView?) {
        let ordered = orderedSpans
        guard let first = ordered.first, let last = ordered.last else { return }
        let rowID = view.flatMap(\.selectionSpanID).map(Self.rowID(ofSpanID:))
        if let rowID, let rowSpans = rowSpans(rowID), let rowFirst = rowSpans.first,
           let rowLast = rowSpans.last {
            let rowWide = TranscriptSelection(
                anchor: .init(spanID: rowFirst.id, utf16Offset: 0),
                focus: .init(spanID: rowLast.id, utf16Offset: rowLast.utf16Length)
            )
            if selection != rowWide {
                selection = rowWide
                invalidateProjection()
                applySelectionDiff()
                return
            }
        }
        selection = TranscriptSelection(
            anchor: .init(spanID: first.id, utf16Offset: 0),
            focus: .init(spanID: last.id, utf16Offset: last.utf16Length)
        )
        invalidateProjection()
        applySelectionDiff()
    }

    func moveFocus(by delta: Int) {
        guard delta != 0, let current = selection else { return }
        let ordered = orderedSpans
        guard let index = ordered.firstIndex(where: { $0.id == current.focus.spanID }) else {
            return
        }
        var nextIndex = index
        var offset = current.focus.utf16Offset + delta
        if offset < 0, index > 0 {
            nextIndex -= 1
            offset = ordered[nextIndex].utf16Length
        } else if offset > ordered[index].utf16Length, index + 1 < ordered.count {
            nextIndex += 1
            offset = 0
        }
        offset = min(max(offset, 0), ordered[nextIndex].utf16Length)
        selection = TranscriptSelection(
            anchor: current.anchor,
            focus: .init(spanID: ordered[nextIndex].id, utf16Offset: offset)
        )
        invalidateProjection()
        applySelectionDiff()
    }

    /// Testing seam: sets a selection without synthesizing mouse events, so
    /// the projection and lifetime rules can be exercised headlessly.
    func selectForTesting(
        from anchor: TranscriptSelectionPosition,
        to focus: TranscriptSelectionPosition,
        dragging: Bool = false
    ) {
        selection = TranscriptSelection(anchor: anchor, focus: focus)
        invalidateProjection()
        applySelectionDiff()
        if dragging { setDragActive(true) }
    }

    // MARK: - Extension

    private func extend(to windowPoint: NSPoint) {
        guard let current = selection,
              let resolution = TranscriptSelectionGeometry.resolve(
                point: windowPoint,
                in: liveFrames()
              )
        else { return }

        let focus: TranscriptSelectionPosition
        switch resolution {
        case .inside(let spanID, let point):
            guard let view = views[spanID]?.value else { return }
            focus = .init(spanID: spanID, utf16Offset: view.characterIndex(atWindowPoint: point))
        case .start(let spanID):
            focus = .init(spanID: spanID, utf16Offset: 0)
        case .end(let spanID):
            guard let span = spans[spanID] else { return }
            focus = .init(spanID: spanID, utf16Offset: span.utf16Length)
        }

        selection = TranscriptSelection(anchor: current.anchor, focus: focus)
        invalidateProjection()
        applySelectionDiff()
    }

    private func selectGranular(
        in view: ResponseSelectableTextView,
        spanID: String,
        at index: Int,
        granularity: NSSelectionGranularity
    ) {
        let range = view.selectionRange(
            forProposedRange: NSRange(location: index, length: 0),
            granularity: granularity
        )
        selection = TranscriptSelection(
            anchor: .init(spanID: spanID, utf16Offset: range.location),
            focus: .init(spanID: spanID, utf16Offset: NSMaxRange(range))
        )
    }

    // MARK: - Autoscroll

    /// `autoscroll(with:)` advances one step per event, so edge-scrolling used
    /// to progress only while the mouse kept moving. A ticker keeps it going
    /// and re-extends to the pointer as the content slides past.
    private func startAutoscrollIfNeeded(event: NSEvent) {
        guard autoscrollTimer == nil else { return }
        guard let scrollView = TranscriptSelectionMenu.shared.transcriptScrollView(
            containing: dragView
        ) else { return }
        let clip = scrollView.contentView
        guard !clip.visibleRect.contains(clip.convert(event.locationInWindow, from: nil)) else {
            return
        }
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.tickAutoscroll(event) }
        }
    }

    private func tickAutoscroll(_ event: NSEvent) {
        guard let point = lastDragPoint,
              let scrollView = TranscriptSelectionMenu.shared.transcriptScrollView(
                containing: dragView
              )
        else {
            stopAutoscroll()
            return
        }
        let clip = scrollView.contentView
        guard !clip.visibleRect.contains(clip.convert(point, from: nil)) else {
            stopAutoscroll()
            return
        }
        clip.autoscroll(with: event)
        extend(to: point)
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    private func setDragActive(_ active: Bool) {
        let rows: Set<String>
        if active, let selection {
            rows = [
                Self.rowID(ofSpanID: selection.anchor.spanID),
                Self.rowID(ofSpanID: selection.focus.spanID),
            ]
        } else {
            rows = []
        }
        if activeRowIDs != rows { activeRowIDs = rows }
        onDragActiveChange?(active)
    }

    // MARK: - Projection

    nonisolated static func rowID(ofSpanID spanID: String) -> String {
        guard let hash = spanID.firstIndex(of: "#") else { return "" }
        return String(spanID[spanID.startIndex..<hash])
    }

    private var orderedSpans: [TranscriptSelectionSpan] {
        if let orderCache { return orderCache }
        let ordered = spans.values.sorted(by: Self.precedes(rank: rowRank))
        orderCache = ordered
        return ordered
    }

    private func rowSpans(_ rowID: String) -> [TranscriptSelectionSpan]? {
        let ids = rowSpanIDs[rowID] ?? []
        guard !ids.isEmpty else { return nil }
        return ids.compactMap { spans[$0] }.sorted(by: Self.precedes(rank: rowRank))
    }

    private static func precedes(
        rank: [String: Int]
    ) -> (TranscriptSelectionSpan, TranscriptSelectionSpan) -> Bool {
        { lhs, rhs in
            let left = rank[lhs.rowID] ?? Int.max
            let right = rank[rhs.rowID] ?? Int.max
            if left != right { return left < right }
            return TranscriptSelectionProjection.pathIsBefore(lhs.treePath, rhs.treePath)
        }
    }

    private func invalidateOrder() {
        orderCache = nil
        invalidateProjection()
    }

    private func invalidateProjection() {
        needsProjection = true
    }

    /// Registered spans plus, for any row between the endpoints that has no
    /// live leaf, the spans the transcript can supply. Without this, copying
    /// across a fast scroll returns only what happened to be realized.
    private func projectionSpans(for selection: TranscriptSelection) -> [TranscriptSelectionSpan] {
        var merged = spans
        let anchorRank = rowRank[Self.rowID(ofSpanID: selection.anchor.spanID)]
        let focusRank = rowRank[Self.rowID(ofSpanID: selection.focus.spanID)]
        if let anchorRank, let focusRank, let provider = spanProvider {
            let range = min(anchorRank, focusRank)...max(anchorRank, focusRank)
            for (rowID, rank) in rowRank where range.contains(rank) {
                guard rowSpanIDs[rowID]?.isEmpty != false else { continue }
                let supplied = providedSpans[rowID] ?? provider(rowID)
                providedSpans[rowID] = supplied
                for span in supplied where merged[span.id] == nil {
                    merged[span.id] = span
                }
            }
        }
        return merged.values.sorted(by: Self.precedes(rank: rowRank))
    }

    private func projectIfNeeded() {
        guard needsProjection else { return }
        needsProjection = false
        guard let selection else {
            currentRanges = [:]
            selectedTextCache = nil
            return
        }
        let ordered = projectionSpans(for: selection)
        guard let resolved = TranscriptSelectionProjection.resolve(selection, in: ordered) else {
            currentRanges = [:]
            selectedTextCache = nil
            return
        }
        currentRanges = TranscriptSelectionProjection.ranges(
            for: resolved,
            orderedSpans: ordered
        )
        selectedTextCache = TranscriptSelectionProjection.text(
            for: resolved,
            orderedSpans: ordered
        )
    }

    private func range(for spanID: String) -> NSRange {
        projectIfNeeded()
        return currentRanges[spanID] ?? NSRange(location: 0, length: 0)
    }

    private func currentRangesContain(spanID: String, offset: Int) -> Bool {
        projectIfNeeded()
        guard let range = currentRanges[spanID] else { return false }
        return NSLocationInRange(offset, range)
    }

    /// Repaints only the leaves whose range actually changed.
    private func applySelectionDiff() {
        projectIfNeeded()
        var next: [String: NSRange] = [:]
        for (spanID, box) in views {
            guard let view = box.value else { continue }
            let range = currentRanges[spanID] ?? NSRange(location: 0, length: 0)
            next[spanID] = range
            guard appliedRanges[spanID] != range else { continue }
            apply(range, to: view, spanID: spanID)
        }
        appliedRanges = next
    }

    private func apply(_ range: NSRange, to view: ResponseSelectableTextView, spanID: String) {
        appliedRanges[spanID] = range
        view.setResponseSelectedRange(range)
    }

    private func liveFrames() -> [TranscriptSpanFrame] {
        orderedSpans.enumerated().compactMap { index, span in
            guard let view = views[span.id]?.value, view.window != nil, !view.isHidden else {
                return nil
            }
            return TranscriptSpanFrame(
                spanID: span.id,
                order: index,
                frame: view.convert(view.bounds, to: nil),
                utf16Length: span.utf16Length
            )
        }
    }
}

/// NSTextView leaf used only inside a transcript selection store. It
/// deliberately handles selection itself instead of letting AppKit clamp a drag
/// to this view's own text storage.
final class ResponseSelectableTextView: LocusSelectionTextView {
    private struct MeasurementKey: Hashable {
        let contentRevision: UInt
        let wraps: Bool
        let effectiveWidth: CGFloat
    }

    /// Set while the store writes a range, so the app-wide selection observer
    /// can tell our own painting from a user editing somewhere else.
    static private(set) var isApplyingProgrammaticSelection = false

    weak var selectionStore: TranscriptSelectionStore?
    var selectionSpanID: String?
    var onOpenURL: ((URL) -> Void)?

    private var contentRevision: UInt = 0
    private var configuredWraps: Bool?
    private var measurementCache = TranscriptMeasurementCache<MeasurementKey>(capacity: 4)
    private var liveResizeMeasurementActive = false
    private var lastIntrinsicInvalidationWidth: CGFloat?

    /// Deterministic diagnostic used by relayout tests. Cache hits deliberately
    /// do not advance it, so the tests count actual TextKit measurement passes
    /// rather than SwiftUI proposals.
    private(set) var textLayoutMeasurementCount = 0
    var measurementCacheEntryCount: Int { measurementCache.count }

    static func effectiveMeasurementWidth(
        _ width: CGFloat,
        wraps: Bool,
        isLiveResizing: Bool
    ) -> CGFloat {
        guard wraps else { return .greatestFiniteMagnitude }
        let exact = max(width, 1)
        guard isLiveResizing else { return exact }
        // Floor rather than round: a slightly narrower container can be a
        // little taller, but can never underestimate height and clip a line.
        return max(floor(exact / 4) * 4, 1)
    }

    func setLiveResizeMeasurementActive(_ active: Bool) {
        guard active != liveResizeMeasurementActive else { return }
        let wasActive = liveResizeMeasurementActive
        liveResizeMeasurementActive = active
        lastIntrinsicInvalidationWidth = nil
        if wasActive, !active {
            // Approximate answers are gesture-local. The next proposal must
            // perform one authoritative exact-width measurement.
            invalidateMeasurementCache()
            invalidateIntrinsicContentSize()
        }
    }

    /// Built against a hand-made TextKit 1 stack so inline-code runs can be
    /// drawn as rounded pills by `LocusMarkdownLayoutManager`.
    static func make() -> ResponseSelectableTextView {
        let stack = LocusSelectionTextView.makeTextKit1Stack()
        let view = ResponseSelectableTextView(frame: .zero, textContainer: stack.container)
        view.adoptTextKit1(storage: stack.storage)
        return view
    }

    override var acceptsFirstResponder: Bool { true }

    /// Configures the native view only when its wrapping behavior really
    /// changes. Reassigning these TextKit properties invalidates layout, even
    /// when the new values equal the old ones.
    @discardableResult
    func configureWrapping(_ wraps: Bool) -> Bool {
        guard configuredWraps != wraps else { return false }
        configuredWraps = wraps
        isHorizontallyResizable = !wraps
        textContainer?.widthTracksTextView = wraps
        autoresizingMask = wraps ? [.width] : []
        if !wraps {
            setTextContainerWidthIfNeeded(.greatestFiniteMagnitude)
        }
        invalidateMeasurementCache()
        return true
    }

    /// Keeps the existing NSTextView, NSTextStorage, and NSLayoutManager alive
    /// across SwiftUI updates. The content revision changes only when the
    /// rendered attributed value changes.
    @discardableResult
    func replaceAttributedTextIfNeeded(_ attributedText: NSAttributedString) -> Bool {
        guard !attributedString().isEqual(to: attributedText) else { return false }
        textStorage?.setAttributedString(attributedText)
        contentRevision &+= 1
        invalidateMeasurementCache()
        return true
    }

    /// Native size this text needs for a proposal. Wrapped text is keyed by
    /// effective width; unwrapped program output always uses the same infinite
    /// container width, so viewport resizing reuses its invariant measurement.
    func measuredSize(
        for width: CGFloat,
        wraps: Bool,
        isLiveResizing: Bool? = nil
    ) -> NSSize {
        let effectiveWidth = Self.effectiveMeasurementWidth(
            width,
            wraps: wraps,
            isLiveResizing: isLiveResizing ?? liveResizeMeasurementActive
        )
        let key = MeasurementKey(
            contentRevision: contentRevision,
            wraps: wraps,
            effectiveWidth: effectiveWidth
        )
        if let cached = measurementCache.value(for: key) { return cached }

        guard let container = textContainer, let layoutManager else {
            return NSSize(width: max(effectiveWidth, 1), height: 1)
        }
        let signpostID = locusPerformanceSignposter.makeSignpostID()
        let interval = locusPerformanceSignposter.beginInterval(
            "Measure Text Leaf",
            id: signpostID,
            "width=\(effectiveWidth, format: .fixed(precision: 1))"
        )
        setTextContainerWidthIfNeeded(effectiveWidth)
        layoutManager.ensureLayout(for: container)
        let usedRect = layoutManager.usedRect(for: container)
        locusPerformanceSignposter.endInterval("Measure Text Leaf", interval)
        let measured = NSSize(
            width: wraps
                ? effectiveWidth
                : max(attributedString().size().width.rounded(.up) + 2, 1),
            height: max(usedRect.height.rounded(.up), 1)
        )
        measurementCache.insert(measured, for: key)
        textLayoutMeasurementCount += 1
        return measured
    }

    override var intrinsicContentSize: NSSize {
        let wraps = configuredWraps ?? textContainer?.widthTracksTextView ?? true
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: measuredSize(for: max(bounds.width, 1), wraps: wraps).height
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        // A new width means new line breaks, so the height cached for the old
        // one no longer describes this text. Without this the row keeps the
        // height it had at the previous column width and its lines are drawn
        // over the row below it.
        let wraps = configuredWraps ?? textContainer?.widthTracksTextView ?? true
        let effectiveWidth = Self.effectiveMeasurementWidth(
            newSize.width,
            wraps: wraps,
            isLiveResizing: liveResizeMeasurementActive
        )
        if widthChanged, wraps, effectiveWidth != lastIntrinsicInvalidationWidth {
            lastIntrinsicInvalidationWidth = effectiveWidth
            locusPerformanceSignposter.emitEvent(
                "Invalidate Intrinsic Text Size",
                "width=\(effectiveWidth, format: .fixed(precision: 1))"
            )
            invalidateIntrinsicContentSize()
        }
    }

    private func setTextContainerWidthIfNeeded(_ width: CGFloat) {
        guard let textContainer else { return }
        let size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        guard textContainer.containerSize != size else { return }
        textContainer.containerSize = size
    }

    private func invalidateMeasurementCache() {
        measurementCache.removeAll()
        lastIntrinsicInvalidationWidth = nil
    }

    override func selectAll(_ sender: Any?) {
        selectionStore?.selectAll(from: self)
    }

    override func copy(_ sender: Any?) {
        selectionStore?.copySelection()
    }

    override func mouseDown(with event: NSEvent) {
        selectionStore?.mouseDown(in: self, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        selectionStore?.mouseDragged(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        selectionStore?.mouseUp(in: self, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        selectionStore?.rightMouseDown(in: self, event: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectionStore?.selectAll(from: self)
            return
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            selectionStore?.copySelection()
            return
        }
        if event.keyCode == 53 {
            selectionStore?.clearSelection()
            return
        }
        if flags.contains(.shift), event.keyCode == 123 || event.keyCode == 124 {
            selectionStore?.moveFocus(by: event.keyCode == 123 ? -1 : 1)
            return
        }
        super.keyDown(with: event)
    }

    func setResponseSelectedRange(_ range: NSRange) {
        guard selectedRange() != range else { return }
        Self.isApplyingProgrammaticSelection = true
        setSelectedRange(range)
        Self.isApplyingProgrammaticSelection = false
    }

    func characterIndex(atWindowPoint point: NSPoint) -> Int {
        guard let layoutManager, let textContainer else { return 0 }
        var local = convert(point, from: nil)
        local.x -= textContainerOrigin.x
        local.y -= textContainerOrigin.y
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: local,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let range = layoutManager.characterRange(
            forGlyphRange: NSRange(location: glyph, length: 1),
            actualGlyphRange: nil
        )
        let character = fraction > 0.5 ? NSMaxRange(range) : range.location
        return min(max(character, 0), (string as NSString).length)
    }

    /// The link under a window point, if any. Read at mouse-down as well as
    /// mouse-up so a click that drifts a pixel still resolves to the same one.
    func linkURL(atWindowPoint point: NSPoint) -> URL? {
        let index = characterIndex(atWindowPoint: point)
        guard index < textStorage?.length ?? 0,
              let value = textStorage?.attribute(.link, at: index, effectiveRange: nil)
        else { return nil }
        if let value = value as? URL { return value }
        if let value = value as? String { return URL(string: value) }
        return nil
    }

    func open(_ url: URL) {
        if let onOpenURL { onOpenURL(url) } else { NSWorkspace.shared.open(url) }
    }
}

struct ResponseSelectableText: NSViewRepresentable {
    @Environment(\.locusIsLiveResizing) private var isLiveResizing
    let attributedText: NSAttributedString
    let span: TranscriptSelectionSpan
    let store: TranscriptSelectionStore
    var wraps = true
    var onOpenURL: ((URL) -> Void)?

    func makeNSView(context: Context) -> ResponseSelectableTextView {
        let view = ResponseSelectableTextView.make()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.heightTracksTextView = false
        view.isVerticallyResizable = true
        update(view)
        return view
    }

    func updateNSView(_ nsView: ResponseSelectableTextView, context: Context) {
        nsView.setLiveResizeMeasurementActive(isLiveResizing)
        update(nsView)
    }

    static func dismantleNSView(_ nsView: ResponseSelectableTextView, coordinator: ()) {
        guard let owner = nsView.selectionStore, let spanID = nsView.selectionSpanID else { return }
        owner.unregister(spanID: spanID, view: nsView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ResponseSelectableTextView,
        context: Context
    ) -> CGSize? {
        let proposedWidth: CGFloat
        if wraps {
            // An unspecified proposal still has to be answered. Returning nil
            // handed SwiftUI the text view's own intrinsic size, and SwiftUI
            // asks for one during the same layout pass that is changing the
            // column width — so the row was sized for the width it had a
            // moment ago and its lines ran over the row beneath. Falling back
            // to the width the view currently has keeps every answer tied to a
            // width this text was actually laid out for.
            proposedWidth = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                ?? max(nsView.bounds.width, 1)
        } else {
            proposedWidth = .greatestFiniteMagnitude
        }
        nsView.setLiveResizeMeasurementActive(isLiveResizing)
        let measurement = nsView.measuredSize(
            for: proposedWidth,
            wraps: wraps,
            isLiveResizing: isLiveResizing
        )
        return CGSize(
            width: wraps ? proposedWidth : measurement.width,
            height: measurement.height
        )
    }

    private func update(_ view: ResponseSelectableTextView) {
        let wrappingChanged = view.configureWrapping(wraps)
        let contentChanged = view.replaceAttributedTextIfNeeded(attributedText)
        // The wash follows the accent, so it is re-resolved on every update
        // rather than only at construction.
        view.refreshSelectionWash()
        view.onOpenURL = onOpenURL
        store.register(span, view: view)
        if wrappingChanged || contentChanged {
            view.invalidateIntrinsicContentSize()
        }
    }
}
