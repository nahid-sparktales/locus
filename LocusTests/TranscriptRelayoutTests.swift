import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Locus

/// Dragging the inspector wider narrows the chat column, which changes where
/// every line of the transcript wraps. The AppKit text leaves have to be
/// re-measured at the new width; when they were not, each row kept the height
/// it had at the old width and its lines were drawn over the row below it.
private struct RelayoutProbeRoot: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RootView()
            .preferredColorScheme(model.effectiveAppearance.colorScheme)
            .environment(\.locusAccent, model.effectiveAccent)
    }
}

@MainActor
final class TranscriptRelayoutTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    func testRepeatedLongWrappedProposalsMeasureEachWidthOnce() {
        let view = makeTextView(text: Self.longProse, wraps: true)

        let wide = view.measuredSize(for: 520, wraps: true)
        XCTAssertEqual(view.textLayoutMeasurementCount, 1)

        for _ in 0..<100 {
            XCTAssertEqual(view.measuredSize(for: 520, wraps: true), wide)
        }
        XCTAssertEqual(
            view.textLayoutMeasurementCount, 1,
            "Repeated SwiftUI proposals repeated TextKit layout at the same width"
        )

        let narrow = view.measuredSize(for: 310, wraps: true)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertEqual(view.textLayoutMeasurementCount, 2)

        // A later proposal for a previously measured width should reuse that
        // width's layout answer rather than laying the long transcript out a
        // third time.
        XCTAssertEqual(view.measuredSize(for: 520, wraps: true), wide)
        XCTAssertEqual(view.textLayoutMeasurementCount, 2)
    }

    func testLongUnwrappedOutputReusesItsMeasurementAcrossViewportWidths() {
        let view = makeTextView(text: Self.longProgramOutput, wraps: false)
        let first = view.measuredSize(for: 240, wraps: false)
        XCTAssertEqual(view.textLayoutMeasurementCount, 1)

        for width in stride(from: CGFloat(260), through: 1_200, by: 7) {
            XCTAssertEqual(view.measuredSize(for: width, wraps: false), first)
        }
        XCTAssertEqual(
            view.textLayoutMeasurementCount, 1,
            "A viewport resize remeasured horizontally scrolling program output"
        )
    }

    func testLiveResizeUsesConservativeFourPointBucketsAndBoundedLRU() {
        let view = makeTextView(text: Self.longProse, wraps: true)
        view.setLiveResizeMeasurementActive(true)

        for width in stride(from: CGFloat(300), through: 319.75, by: 0.25) {
            _ = view.measuredSize(for: width, wraps: true, isLiveResizing: true)
        }

        XCTAssertEqual(view.textLayoutMeasurementCount, 5)
        XCTAssertEqual(view.measurementCacheEntryCount, 4)
        XCTAssertEqual(
            ResponseSelectableTextView.effectiveMeasurementWidth(
                307.99,
                wraps: true,
                isLiveResizing: true
            ),
            304,
            "Live resizing must round down so cached height never clips a line"
        )

        let bucketedCount = view.textLayoutMeasurementCount
        _ = view.measuredSize(for: 319.9, wraps: true, isLiveResizing: true)
        XCTAssertEqual(view.textLayoutMeasurementCount, bucketedCount)

        view.setLiveResizeMeasurementActive(false)
        let exact = view.measuredSize(for: 319.9, wraps: true, isLiveResizing: false)
        XCTAssertEqual(view.textLayoutMeasurementCount, bucketedCount + 1)
        XCTAssertEqual(exact.width, 319.9, accuracy: 0.001)
    }

    func testMeasurementCacheEvictsLeastRecentlyUsedEntry() {
        var cache = TranscriptMeasurementCache<Int>(capacity: 4)
        for value in 1...4 {
            cache.insert(NSSize(width: value, height: value), for: value)
        }
        _ = cache.value(for: 1)
        cache.insert(NSSize(width: 5, height: 5), for: 5)

        XCTAssertNil(cache.value(for: 2))
        XCTAssertNotNil(cache.value(for: 1))
        XCTAssertEqual(cache.count, 4)
    }

    func testLiveResizeCoordinatorPublishesOnlyGestureBoundaries() {
        let layout = WorkspaceLayoutModel()
        var publications = 0
        let subscription = layout.objectWillChange.sink { publications += 1 }

        layout.updateGeometry(WorkspaceGeometrySnapshot(windowSize: CGSize(width: 900, height: 700)))
        layout.liveResizeCoordinator.beginLiveResize()
        for width in stride(from: CGFloat(900), through: 1_100, by: 0.5) {
            layout.liveResizeCoordinator.update(width: width)
        }
        layout.liveResizeCoordinator.endLiveResize(finalWidth: 1_100)

        XCTAssertEqual(publications, 2)
        XCTAssertEqual(layout.geometry.windowSize.width, 900)
        withExtendedLifetime(subscription) {}
    }

    func testSharedWorkspaceHeightExcludesTheToolbarWithoutGoingNegative() {
        XCTAssertEqual(
            WorkspaceLayoutMetrics.contentHeight(forWindowHeight: 760),
            708
        )
        XCTAssertEqual(
            WorkspaceLayoutMetrics.contentHeight(
                forWindowHeight: WorkspaceLayoutMetrics.toolbarHeight
            ),
            0
        )
        XCTAssertEqual(
            WorkspaceLayoutMetrics.contentHeight(forWindowHeight: 24),
            0
        )
    }

    func testLiveResizePerformanceSummaryUsesNearestRankP95() async {
        let summary = await MainActor.run {
            LiveResizePerformanceMonitor.summarize(
                samples: Array(1...100).map(Double.init),
                finalWidth: 1_184
            )
        }

        XCTAssertEqual(summary.sampleCount, 100)
        XCTAssertEqual(summary.p95MainThreadWorkMillis, 95)
        XCTAssertEqual(summary.maximumMainThreadWorkMillis, 100)
        XCTAssertEqual(summary.finalWidth, 1_184)
    }

    func testContentAndWrappingChangesInvalidateNativeMeasurements() {
        let initial = MarkdownNativeText.plain(
            Self.longProse,
            font: .systemFont(ofSize: 13),
            color: .textColor,
            lineSpacing: 3
        )
        let view = makeTextView(attributedText: initial, wraps: true)

        _ = view.measuredSize(for: 420, wraps: true)
        XCTAssertEqual(view.textLayoutMeasurementCount, 1)
        XCTAssertFalse(view.configureWrapping(true))
        XCTAssertFalse(view.replaceAttributedTextIfNeeded(NSAttributedString(attributedString: initial)))
        _ = view.measuredSize(for: 420, wraps: true)
        XCTAssertEqual(view.textLayoutMeasurementCount, 1)

        let changed = NSMutableAttributedString(attributedString: initial)
        changed.append(NSAttributedString(string: "\nA genuinely new final line."))
        XCTAssertTrue(view.replaceAttributedTextIfNeeded(changed))
        _ = view.measuredSize(for: 420, wraps: true)
        XCTAssertEqual(view.textLayoutMeasurementCount, 2)

        XCTAssertTrue(view.configureWrapping(false))
        let unwrapped = view.measuredSize(for: 420, wraps: false)
        XCTAssertEqual(view.textLayoutMeasurementCount, 3)
        XCTAssertEqual(view.measuredSize(for: 900, wraps: false), unwrapped)
        XCTAssertEqual(view.textLayoutMeasurementCount, 3)
    }

    func testTranscriptRewrapsWhileTheInspectorIsDraggedWider() throws {
        let size = NSSize(width: 1_250, height: 760)
        let startWidth: CGFloat = 300
        let endWidth: CGFloat = 660

        let model = makeModel(inspectorWidth: startWidth)
        let live = mount(model, size: size)

        // A drag arrives as many small changes, not one jump — and it is the
        // repeated re-proposal that used to leave rows measured for a width
        // they no longer have.
        for step in stride(from: startWidth, through: endWidth, by: 15) {
            model.setInspectorWidth(step)
            pump(2)
        }
        pump()
        parkTranscriptAtTop(in: live)
        let dragged = try XCTUnwrap(snapshot(live))
        let draggedGeometry = snapshotGeometry(in: live, image: dragged)

        // The same model state, laid out from scratch, is the answer the
        // dragged transcript has to agree with.
        let rebuilt = mount(makeModel(inspectorWidth: endWidth), size: size)
        parkTranscriptAtTop(in: rebuilt)
        let reference = try XCTUnwrap(snapshot(rebuilt))
        let referenceGeometry = snapshotGeometry(in: rebuilt, image: reference)
        let difference = differingFraction(dragged, reference)
        let sameDimensions = dragged.pixelsWide == reference.pixelsWide
            && dragged.pixelsHigh == reference.pixelsHigh
        if !sameDimensions || difference >= 0.01 {
            attachSnapshot(dragged, name: "Dragged transcript")
            attachSnapshot(reference, name: "Rebuilt transcript")
            let geometry = XCTAttachment(string: """
                differingFraction=\(difference)
                Dragged snapshot:\n\(draggedGeometry)
                Rebuilt snapshot:\n\(referenceGeometry)
                """)
            geometry.name = "Transcript relayout geometry"
            geometry.lifetime = .keepAlways
            add(geometry)
        }
        XCTAssertEqual(dragged.pixelsWide, reference.pixelsWide, "Snapshot widths must match exactly")
        XCTAssertEqual(dragged.pixelsHigh, reference.pixelsHigh, "Snapshot heights must match exactly")

        // A few tenths of a percent of drift is the scroll anchor settling in
        // a different place between the two mounts. The defect this guards
        // against moves ~4.5% of the window, so the bar sits well between the
        // two rather than at either edge.
        XCTAssertLessThan(
            difference, 0.01,
            "The transcript kept row heights from the previous column width"
        )
    }

    // MARK: - Harness

    private func makeModel(inspectorWidth: CGFloat) -> AppModel {
        let model = AppModel(startImmediately: false)
        var blocks: [ChatBlock] = []
        for index in 0..<6 {
            blocks.append(ChatBlock(kind: .user, text: "Request \(index)"))
            blocks.append(ChatBlock(
                kind: .assistant,
                reasoningText: "Drafting a reply · Composing the body with placeholders"
            ))
            blocks.append(ChatBlock(kind: .assistant, text: Self.body))
        }
        model.blocks = blocks
        model.inspectorCollapsed = false
        model.setInspectorWidth(inspectorWidth)
        pump()
        return model
    }

    /// Long enough to wrap differently at every column width the drag passes
    /// through, and repeated so the transcript scrolls.
    private static let body = """
    Paragraphs have to rewrap as the column narrows, and each one has to be \
    given the height its new line count needs rather than the height its old \
    one did.

    A second paragraph, so a row that is measured too short is drawn over the \
    row beneath it instead of merely being clipped at its own edge.

    A third paragraph of ordinary prose, long enough that the number of lines \
    it occupies changes several times across the range of widths a divider \
    drag moves through.
    """

    private static let longProse = Array(repeating: body, count: 80)
        .joined(separator: "\n\n")

    private static let longProgramOutput = (0..<600).map { index in
        "[task \(index)] compiled /workspace/Sources/Feature\(index)/LongOutputFile.swift successfully"
    }.joined(separator: "\n")

    private func makeTextView(text: String, wraps: Bool) -> ResponseSelectableTextView {
        makeTextView(
            attributedText: MarkdownNativeText.plain(
                text,
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                color: .textColor,
                lineSpacing: 2
            ),
            wraps: wraps
        )
    }

    private func makeTextView(
        attributedText: NSAttributedString,
        wraps: Bool
    ) -> ResponseSelectableTextView {
        let view = ResponseSelectableTextView.make()
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.heightTracksTextView = false
        view.isVerticallyResizable = true
        XCTAssertTrue(view.configureWrapping(wraps))
        XCTAssertTrue(view.replaceAttributedTextIfNeeded(attributedText))
        return view
    }

    private func mount(_ model: AppModel, size: NSSize) -> NSView {
        let host = NSHostingView(rootView: RelayoutProbeRoot()
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

    /// The transcript follows output, so both mounts sit pinned at the bottom
    /// — at offsets that can disagree by a pixel of accumulated text
    /// measurement, which a pixel comparison reads as a whole-page diff.
    /// Layout quality wants a common origin, so park both viewports at the
    /// top the way a reader would; the gesture also detaches following.
    private func parkTranscriptAtTop(in root: NSView) {
        guard let scroll = transcriptScrollView(in: root) else { return }
        // Parking realizes the top rows, whose re-measurement at the final
        // width can shift the origin through lazy-stack scroll anchoring —
        // so park until the viewport actually rests at the top.
        for _ in 0..<4 {
            var target: CGFloat = 0
            simulateUserScroll(scroll, pump: pump) { origin, document in
                guard let document else { return origin }
                target = document.isFlipped
                    ? document.bounds.minY
                    : max(document.bounds.maxY - scroll.contentView.bounds.height,
                          document.bounds.minY)
                return NSPoint(x: origin.x, y: target)
            }
            pump()
            if abs(scroll.contentView.bounds.origin.y - target) < 0.5 { break }
        }
    }

    private func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Read immediately after each image, without forcing another layout or
    /// reading text, accessibility values, or responder descriptions. Bound
    /// traversal and row output so failures retain useful, finite diagnostics.
    private func snapshotGeometry(in root: NSView, image: NSBitmapImageRep) -> String {
        var lines = [
            "uptime=\(ProcessInfo.processInfo.systemUptime)",
            "imagePixels=\(image.pixelsWide)x\(image.pixelsHigh) rootBounds=\(NSStringFromRect(root.bounds))",
            "appActive=\(NSApp.isActive) appearance=\(root.effectiveAppearance.name.rawValue)"
        ]
        if let window = root.window {
            let responderType = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            lines.append("windowFrame=\(NSStringFromRect(window.frame)) contentLayout=\(NSStringFromRect(window.contentLayoutRect)) scale=\(window.backingScaleFactor)")
            lines.append("windowKey=\(window.isKeyWindow) main=\(window.isMainWindow) visible=\(window.isVisible) responderType=\(responderType.prefix(128)) mouse=\(NSStringFromPoint(window.mouseLocationOutsideOfEventStream))")
        } else {
            lines.append("window=nil")
        }
        guard let scroll = transcriptScrollView(in: root) else {
            return (lines + ["transcriptScrollView=nil"]).joined(separator: "\n")
        }
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: root)
        lines.append("scrollFrame=\(NSStringFromRect(scroll.convert(scroll.bounds, to: root))) clipBounds=\(NSStringFromRect(scroll.contentView.bounds)) viewport=\(NSStringFromRect(viewport))")
        if let document = scroll.documentView {
            lines.append("documentFrame=\(NSStringFromRect(document.frame)) documentBounds=\(NSStringFromRect(document.bounds)) flipped=\(document.isFlipped)")
        }
        var pending: [NSView] = [scroll]
        var visited = 0
        var rowCount = 0
        while visited < 512, rowCount < 24, let view = pending.popLast() {
            visited += 1
            if let text = view as? ResponseSelectableTextView {
                let frame = text.convert(text.bounds, to: root)
                if !text.isHiddenOrHasHiddenAncestor, frame.intersects(viewport) {
                    lines.append("visibleText[\(rowCount)] frame=\(NSStringFromRect(frame)) bounds=\(NSStringFromRect(text.bounds)) container=\(NSStringFromSize(text.textContainer?.containerSize ?? .zero)) measurements=\(text.textLayoutMeasurementCount) cacheEntries=\(text.measurementCacheEntryCount)")
                    rowCount += 1
                }
            }
            pending.append(contentsOf: view.subviews.reversed())
        }
        lines.append("visitedViews=\(visited) visibleTextRows=\(rowCount) traversalTruncated=\(!pending.isEmpty)")
        return lines.joined(separator: "\n")
    }

    private func attachSnapshot(_ image: NSBitmapImageRep, name: String) {
        let attachment: XCTAttachment
        if let png = image.representation(using: .png, properties: [:]) {
            attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        } else {
            attachment = XCTAttachment(string: "Snapshot PNG encoding failed")
        }
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func differingFraction(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Double {
        var differing = 0
        var total = 0
        for x in stride(from: 0, to: min(lhs.pixelsWide, rhs.pixelsWide), by: 3) {
            for y in stride(from: 0, to: min(lhs.pixelsHigh, rhs.pixelsHigh), by: 3) {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                total += 1
                let distance = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                if distance > 0.02 { differing += 1 }
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }
}

@MainActor
final class StreamingPerformanceTests: XCTestCase {
    func testAccumulatorPreservesOrderedTextReasoningAndSingleBatchRevision() {
        let state = StreamingReplyState()
        let id = UUID()
        state.begin(id: id)
        let afterBegin = state.revision

        state.append(
            text: "Hello, world",
            reasoning: "direct",
            reasoningSections: [1: "second", 0: "first"]
        )

        XCTAssertEqual(state.revision, afterBegin + 1)
        XCTAssertEqual(state.snapshot.text, "Hello, world")
        XCTAssertEqual(state.snapshot.reasoningSections, ["first", "second"])
        XCTAssertEqual(state.snapshot.reasoning, "first\n\nsecond")
        XCTAssertEqual(state.snapshot.turnCharacterCount, 29)

        let finished = state.finish(
            id: id,
            authoritativeText: "Hello, final world",
            authoritativeReasoningSections: ["final reasoning"]
        )
        XCTAssertEqual(finished?.text, "Hello, final world")
        XCTAssertEqual(finished?.reasoning, "final reasoning")
        XCTAssertFalse(state.snapshot.isActive)
    }

    func testStreamingBoundaryNeverFreezesInsideAnOpenFence() throws {
        let source = "Done paragraph.\n\n```swift\nlet value = 1\n\nstill open"
        let boundary = try XCTUnwrap(StreamingMarkdownBoundary.lastStableBoundary(in: source))
        XCTAssertEqual(String(source[..<boundary]), "Done paragraph.\n\n")

        let onlyFence = "```swift\n" + String(repeating: "x", count: 40_000) + "\n\n"
        XCTAssertNil(StreamingMarkdownBoundary.lastStableBoundary(in: onlyFence))
    }

    func testStreamingCoordinatorFreezesStableBlocksAndReconcilesFinalMarkdown() async {
        let coordinator = StreamingRenderCoordinator()
        let source = "# Heading\n\nMutable **tail"
        coordinator.update(text: source)
        await drain(coordinator)

        XCTAssertEqual(coordinator.stableBlocks.count, 1)
        XCTAssertEqual(coordinator.provisionalText, "Mutable **tail")
        XCTAssertEqual(coordinator.parseCountForTesting, 1)

        coordinator.update(text: source + "**")
        XCTAssertEqual(coordinator.provisionalText, "Mutable **tail**")
        coordinator.update(text: source + "**", isFinal: true)
        await drain(coordinator)

        XCTAssertEqual(
            coordinator.stableBlocks,
            MarkdownDocumentParser.parse(source + "**")
        )
        XCTAssertTrue(coordinator.provisionalText.isEmpty)
    }

    func testStreamingCoordinatorRejectsAStaleReplacedSource() async {
        let coordinator = StreamingRenderCoordinator()
        coordinator.update(text: String(repeating: "Old paragraph. ", count: 1_000) + "\n\n")
        coordinator.update(text: "Replacement tail")
        await drain(coordinator)

        XCTAssertEqual(coordinator.sourceText, "Replacement tail")
        XCTAssertEqual(coordinator.provisionalText, "Replacement tail")
        XCTAssertTrue(coordinator.stableBlocks.isEmpty)
    }

    func testThumbnailStoreDeduplicatesCachesAndInvalidatesChangedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("artifact.png")
        try writePNG(size: 32, color: .systemPink, to: url)

        let store = ArtifactThumbnailStore()
        store.resetForTesting()
        let firstTask = Task { await store.image(for: url, displayScale: 2) }
        let secondTask = Task { await store.image(for: url, displayScale: 2) }
        let first = await firstTask.value
        let second = await secondTask.value

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(store.decodeCountForTesting, 1)
        let cached = await store.image(for: url, displayScale: 2)
        XCTAssertNotNil(cached)
        XCTAssertEqual(store.decodeCountForTesting, 1)

        try writePNG(size: 48, color: .systemBlue, to: url)
        let changed = await store.image(for: url, displayScale: 2)
        XCTAssertNotNil(changed)
        XCTAssertEqual(store.decodeCountForTesting, 2)
        XCTAssertEqual(ArtifactThumbnailStore.cacheItemLimit, 128)
        XCTAssertEqual(ArtifactThumbnailStore.cacheCostLimit, 128 * 1_024 * 1_024)
    }

    func testThumbnailCancellationRejectsTheResult() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancel.png")
        try writePNG(size: 512, color: .systemOrange, to: url)
        let store = ArtifactThumbnailStore()

        let task = Task { await store.image(for: url, displayScale: 2) }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    private func drain(_ coordinator: StreamingRenderCoordinator) async {
        for _ in 0..<200 {
            if !coordinator.isParsingForTesting { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Streaming parser did not become idle")
    }

    private func writePNG(size: Int, color: NSColor, to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}
