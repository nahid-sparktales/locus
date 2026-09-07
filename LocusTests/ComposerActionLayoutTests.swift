import AppKit
import SwiftUI
import XCTest
@testable import Locus

@MainActor
private final class ComposerLayoutFixtureState: ObservableObject {
    struct Control: Identifiable {
        let id: String
        var width: CGFloat
    }

    @Published var controls: [Control] = [
        .init(id: "context", width: 72), .init(id: "attachment", width: 30),
        .init(id: "permission", width: 68), .init(id: "plan", width: 38),
        .init(id: "grill", width: 38), .init(id: "team", width: 108),
        .init(id: "send", width: 142),
    ]
    @Published var rightToLeft = false
}

private final class ComposerControlProbeView: NSView {
    var controlID = ""
    override var isFlipped: Bool { true }
}

private struct ComposerControlProbe: NSViewRepresentable {
    let control: ComposerLayoutFixtureState.Control

    func makeNSView(context: Context) -> ComposerControlProbeView { ComposerControlProbeView() }

    func updateNSView(_ nsView: ComposerControlProbeView, context: Context) {
        nsView.controlID = control.id
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerControlProbeView, context: Context) -> CGSize? {
        let minimum = min(30, control.width)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? control.width
        return CGSize(width: max(minimum, min(width, control.width)), height: 32)
    }
}

private struct ComposerLayoutFixture: View {
    @ObservedObject var state: ComposerLayoutFixtureState

    var body: some View {
        // Several ancestors ask the toolbar for its dimensions and alignment,
        // as the real composer does while the inspector changes chat width.
        VStack(spacing: 0) {
            Text("Message").frame(height: 24)
            VStack(spacing: 0) {
                ComposerActionLayout(rightToLeft: state.rightToLeft) {
                    ForEach(state.controls) { control in
                        ComposerControlProbe(control: control)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .environment(\.layoutDirection, state.rightToLeft ? .rightToLeft : .leftToRight)
    }
}

@MainActor
final class ComposerActionLayoutTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    func testHostedToolbarReflowsAcrossRepeatedInspectorWidths() async throws {
        let state = ComposerLayoutFixtureState()
        let host = makeHost(state: state)
        for width in [532, 292, 720, 360, 292, 532, 720, 292] as [CGFloat] {
            let frames = await layout(host, width: width)
            assertContained(frames, ids: state.controls.map(\.id), width: width)
            XCTAssertEqual(try XCTUnwrap(frames["send"]).maxX, width, accuracy: 0.5)
            let rows = Set(frames.values.map { Int($0.minY.rounded()) })
            XCTAssertEqual(rows.count, width < 400 ? 2 : 1)
        }
    }

    func testHostedCacheUpdatesSameCountLabelWidthsAndDynamicControlGroups() async throws {
        let state = ComposerLayoutFixtureState()
        let host = makeHost(state: state)
        let before = await layout(host, width: 532)
        XCTAssertEqual(try XCTUnwrap(before["team"]).width, 108, accuracy: 0.5)

        // A renamed team changes measurement without adding/removing a view.
        state.controls[state.controls.firstIndex { $0.id == "team" }!].width = 2_000
        let renamed = await layout(host, width: 292)
        assertContained(renamed, ids: state.controls.map(\.id), width: 292)
        XCTAssertEqual(try XCTUnwrap(renamed["team"]).width, 292, accuracy: 0.5)

        state.controls.removeAll { ["plan", "grill", "team"].contains($0.id) }
        let chatOnly = await layout(host, width: 532)
        assertContained(chatOnly, ids: state.controls.map(\.id), width: 532)
        XCTAssertNil(chatOnly["team"])
        state.controls.insert(.init(id: "team", width: 86), at: state.controls.count - 1)
        let restored = await layout(host, width: 532)
        assertContained(restored, ids: state.controls.map(\.id), width: 532)
        XCTAssertEqual(try XCTUnwrap(restored["team"]).width, 86, accuracy: 0.5)
    }

    func testHostedDirectionChangesKeepControlsAndRestoreGeometry() async throws {
        let state = ComposerLayoutFixtureState()
        let host = makeHost(state: state)
        let leftToRight = await layout(host, width: 292)
        state.rightToLeft = true
        let rightToLeft = await layout(host, width: 292)
        assertContained(rightToLeft, ids: state.controls.map(\.id), width: 292)
        for id in state.controls.map(\.id) {
            let left = try XCTUnwrap(leftToRight[id])
            let right = try XCTUnwrap(rightToLeft[id])
            XCTAssertEqual(right.minY, left.minY, accuracy: 0.5, id)
            XCTAssertEqual(right.width, left.width, accuracy: 0.5, id)
        }
        state.rightToLeft = false
        let restored = await layout(host, width: 292)
        for id in state.controls.map(\.id) {
            let initial = try XCTUnwrap(leftToRight[id])
            let final = try XCTUnwrap(restored[id])
            XCTAssertEqual(final.minX, initial.minX, accuracy: 0.5, id)
            XCTAssertEqual(final.minY, initial.minY, accuracy: 0.5, id)
            XCTAssertEqual(final.width, initial.width, accuracy: 0.5, id)
        }
    }

    private func makeHost(state: ComposerLayoutFixtureState) -> NSHostingView<ComposerLayoutFixture> {
        let host = NSHostingView(rootView: ComposerLayoutFixture(state: state))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 532, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        return host
    }

    private func layout(_ host: NSHostingView<ComposerLayoutFixture>, width: CGFloat) async -> [String: CGRect] {
        host.window?.setContentSize(NSSize(width: width, height: 300))
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
        host.layoutSubtreeIfNeeded()
        var frames: [String: CGRect] = [:]
        func visit(_ view: NSView) {
            if let control = view as? ComposerControlProbeView {
                frames[control.controlID] = host.convert(control.bounds, from: control)
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return frames
    }

    private func assertContained(_ frames: [String: CGRect], ids: [String], width: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(frames.keys), Set(ids), file: file, line: line)
        for (id, frame) in frames {
            XCTAssertTrue(frame.width.isFinite && frame.height.isFinite, id, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, id, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, id, file: file, line: line)
            XCTAssertEqual(frame.height, 32, accuracy: 0.5, id, file: file, line: line)
            for (otherID, other) in frames where id < otherID {
                XCTAssertFalse(frame.insetBy(dx: 0.5, dy: 0.5).intersects(other), "\(id) overlaps \(otherID)", file: file, line: line)
            }
        }
    }
}
