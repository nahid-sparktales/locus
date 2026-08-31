import AppKit
import SwiftUI
import XCTest
@testable import Locus

/// The viewer sheet is where a workspace file is actually read — it has to
/// load the file it was asked for and lay the source out from the leading
/// edge, not centered in the viewport the way a bare two-axis ScrollView
/// leaves short lines.
@MainActor
final class WorkspaceFileViewerTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var workspace: URL?

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        super.tearDown()
    }

    func testViewerLoadsTheFileAndAlignsSourceLeading() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = root
        let file = root.appending(path: "greeting.py")
        let source = (1...80).map { "print(\"line \($0)\")" }.joined(separator: "\n")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let request = WorkspaceFileViewerRequest(
            url: file,
            relativePath: "greeting.py",
            location: WorkspacePreviewLocation(line: 40, column: nil)
        )
        let model = AppModel(startImmediately: false)
        let host = NSHostingView(rootView: WorkspaceFileViewerSheet(request: request)
            .environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 880, height: 620)
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

        let scroll = try XCTUnwrap(
            firstScrollView(in: host),
            "The viewer did not finish loading the file into its source view"
        )
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(
            document.bounds.height, scroll.contentView.bounds.height,
            "80 numbered lines should overflow the sheet"
        )
        // Leading alignment: content must span at least the viewport, so a
        // stack of short lines cannot float centered.
        XCTAssertGreaterThanOrEqual(
            document.bounds.width + 1, scroll.contentView.bounds.width,
            "Source content should be laid out at least viewport-wide"
        )
    }

    private func pump(_ rounds: Int = 60) {
        for _ in 0..<rounds {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func firstScrollView(in root: NSView) -> NSScrollView? {
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let scroll = view as? NSScrollView { return scroll }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}
