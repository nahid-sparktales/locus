import AppKit
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
        let dragged = try XCTUnwrap(snapshot(live))

        // The same model state, laid out from scratch, is the answer the
        // dragged transcript has to agree with.
        let rebuilt = mount(makeModel(inspectorWidth: endWidth), size: size)
        let reference = try XCTUnwrap(snapshot(rebuilt))

        // A few tenths of a percent of drift is the scroll anchor settling in
        // a different place between the two mounts. The defect this guards
        // against moves ~4.5% of the window, so the bar sits well between the
        // two rather than at either edge.
        XCTAssertLessThan(
            differingFraction(dragged, reference), 0.01,
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

    private func mount(_ model: AppModel, size: NSSize) -> NSView {
        let host = NSHostingView(rootView: RelayoutProbeRoot()
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

    private func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
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
