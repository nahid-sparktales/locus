import AppKit
import XCTest
@testable import Locus

@MainActor
final class CompanionVisibilityTests: XCTestCase {
    func testClosingWindowReleasesAllVisibilityObservers() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 180, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let visibility = CompanionVisibilityView { _ in }
        window.contentView = visibility
        XCTAssertEqual(visibility.observationCount, 6)
        window.close()
        XCTAssertEqual(visibility.observationCount, 0)
    }

    func testRemovingCharacterFromWindowDetachesObserversAndCanReattach() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 180, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView()
        let visibility = CompanionVisibilityView { _ in }
        window.contentView = container
        container.addSubview(visibility)
        XCTAssertEqual(visibility.observationCount, 6)
        visibility.removeFromSuperview()
        XCTAssertEqual(visibility.observationCount, 0)
        container.addSubview(visibility)
        XCTAssertEqual(visibility.observationCount, 6)
        visibility.detach()
        XCTAssertEqual(visibility.observationCount, 0)
        visibility.detach()
        XCTAssertEqual(visibility.observationCount, 0)
    }
}
