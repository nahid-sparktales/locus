import AppKit
import SwiftUI
import XCTest
@testable import Locus

/// The transcript's Markdown tree is value-stable: none of its inputs mention
/// the accent, so SwiftUI does not re-evaluate it when the accent changes. Any
/// leaf in there that paints an accent colour has to say so, or it keeps the
/// colour it first resolved until something rebuilds the row — which, to a
/// customer, looks like "the icons only change once I switch chats".
@MainActor
final class AccentPropagationTests: XCTestCase {
    /// Mirrors the shape of a transcript row: a parent that re-evaluates, and a
    /// Markdown subtree underneath it whose own inputs never change.
    private struct StableMarkdownHost: View {
        @ObservedObject var accent: AccentBox
        let text: String
        let workspacePath: String

        var body: some View {
            ZStack {
                Color.black
                MarkdownBodyView(text: text, workspacePath: workspacePath)
            }
            .frame(width: 620, height: 120)
            .environment(\.locusAccent, accent.selection)
        }
    }

    private final class AccentBox: ObservableObject {
        @Published var selection: LocusAccentSelection

        init(_ selection: LocusAccentSelection) {
            self.selection = selection
        }
    }

    private var windows: [NSWindow] = []
    private var restoreAccent: LocusAccentSelection?

    override func setUp() {
        super.setUp()
        restoreAccent = LocusAccentRuntime.shared.currentSelection()
    }

    override func tearDown() {
        // The accent store is process-wide; leaving it changed would leak into
        // every test that renders afterwards.
        if let restoreAccent { LocusAccentRuntime.shared.configure(restoreAccent) }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    func testMarkdownArtifactChipFollowsAccentWithoutBeingRebuilt() throws {
        // A list-item reference mounts the compact chip, whose kind icon is
        // accent-tinted.
        try assertMarkdownArtifactFollowsAccent(text: "- `notes.md`")
    }

    func testListItemFileReferenceMountsAChipNotProse() throws {
        // Same-length names, one resolving to a real workspace file and one
        // not: if the chip failed to mount, both bullets would render as the
        // identical pill-styled prose and the images could not differ.
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("locus-chip-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("notes".utf8).write(to: workspace.appendingPathComponent("notes.md"))

        let lime = selection(.lime)
        apply(lime)
        let chip = mount(StableMarkdownHost(
            accent: AccentBox(lime),
            text: "- `notes.md`",
            workspacePath: workspace.path
        ))
        let prose = mount(StableMarkdownHost(
            accent: AccentBox(lime),
            text: "- `notas.md`",
            workspacePath: workspace.path
        ))
        let chipImage = try XCTUnwrap(snapshot(chip))
        let proseImage = try XCTUnwrap(snapshot(prose))
        XCTAssertGreaterThan(
            differingPixels(chipImage, proseImage), 0,
            "A resolvable list-item file reference must mount the chip's chrome"
        )
    }

    func testMarkdownArtifactCardFollowsAccentWithoutBeingRebuilt() throws {
        // A top-level reference mounts the full card.
        try assertMarkdownArtifactFollowsAccent(text: "`notes.md`")
    }

    private func assertMarkdownArtifactFollowsAccent(text: String) throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("locus-accent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("notes".utf8).write(to: workspace.appendingPathComponent("notes.md"))

        let lime = selection(.lime)
        let pink = selection(.pink)
        apply(lime)

        let box = AccentBox(lime)
        let live = mount(StableMarkdownHost(
            accent: box,
            text: text,
            workspacePath: workspace.path
        ))
        let onLime = try XCTUnwrap(snapshot(live))

        apply(pink)
        box.selection = pink
        pump()
        let onPink = try XCTUnwrap(snapshot(live))

        // A second host built from scratch under the new accent is what the
        // mounted one has to agree with. Comparing renders rather than colour
        // values keeps the assertion out of the display's colour space.
        let rebuilt = mount(StableMarkdownHost(
            accent: AccentBox(pink),
            text: text,
            workspacePath: workspace.path
        ))
        let rebuiltOnPink = try XCTUnwrap(snapshot(rebuilt))

        XCTAssertGreaterThan(
            differingPixels(onLime, onPink), 0,
            "The mounted artifact tile kept the previous accent instead of following the change"
        )
        XCTAssertEqual(
            differingPixels(onPink, rebuiltOnPink), 0,
            "A mounted artifact tile must match one built fresh under the same accent"
        )
    }

    /// The colours themselves must not freeze the accent they were created
    /// with: a Color that outlives its body evaluation has to resolve to the
    /// accent in force when it is drawn, not the one in force when it was made.
    func testThemeAccentColoursResolveAtDrawTimeNotCreationTime() throws {
        apply(selection(.lime))
        let held = LocusTheme.signalDeep
        apply(selection(.pink))

        var resolved: NSColor?
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(held).usingColorSpace(.sRGB)
        }

        let expected = try XCTUnwrap(
            selection(.pink).actionNSColor(for: appearance).usingColorSpace(.sRGB)
        )
        let actual = try XCTUnwrap(resolved)
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.02)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.02)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.02)
    }

    // MARK: - Harness

    private func selection(_ preset: LocusAccentPreset) -> LocusAccentSelection {
        LocusAccentSelection(
            rawValue: preset.rawValue,
            customHex: LocusAccentSelection.defaultCustomHex
        )
    }

    private func apply(_ selection: LocusAccentSelection) {
        LocusAccentRuntime.shared.configure(selection)
    }

    private func mount(_ view: some View) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 120)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        pump()
        return host
    }

    private func pump(_ rounds: Int = 30) {
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

    private func differingPixels(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        var differing = 0
        for x in 0..<min(lhs.pixelsWide, rhs.pixelsWide) {
            for y in 0..<min(lhs.pixelsHigh, rhs.pixelsHigh) {
                guard let a = lhs.colorAt(x: x, y: y),
                      let b = rhs.colorAt(x: x, y: y)
                else { continue }
                let distance = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                if distance > 0.02 { differing += 1 }
            }
        }
        return differing
    }
}
