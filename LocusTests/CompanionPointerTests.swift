import AppKit
import SwiftUI
import XCTest
@testable import Locus

@MainActor
final class CompanionPointerTests: XCTestCase {
    func testPointerUsesScreenClockwiseDirectionsAndNeutralDeadZone() {
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 180)
        let cases: [(CGPoint, Int)] = [
            (.init(x: 90, y: -100), 0), (.init(x: 280, y: -100), 2),
            (.init(x: 280, y: 90), 4), (.init(x: 280, y: 280), 6),
            (.init(x: 90, y: 280), 8), (.init(x: -100, y: 280), 10),
            (.init(x: -100, y: 90), 12), (.init(x: -100, y: -100), 14),
        ]
        for (point, expected) in cases {
            XCTAssertEqual(CompanionPointerResponse.response(at: point, in: bounds).directionIndex, expected)
        }
        XCTAssertEqual(CompanionPointerResponse.response(at: .init(x: 90, y: 90), in: bounds), .neutral)
        XCTAssertEqual(CompanionPointerResponse.response(at: .init(x: 100, y: 94), in: bounds), .neutral)
        XCTAssertNil(CompanionPointerResponse.neutral.directionIndex)
    }

    func testPointerBoundsAndRejectsInvalidGeometry() {
        let bounds = CGRect(x: 10, y: 20, width: 40, height: 40)
        for point in [CGPoint(x: 10_000, y: -10_000), CGPoint(x: -10_000, y: 10_000)] {
            let response = CompanionPointerResponse.response(at: point, in: bounds)
            XCTAssertLessThanOrEqual(abs(response.x), 1)
            XCTAssertLessThanOrEqual(abs(response.y), 1)
        }
        XCTAssertEqual(CompanionPointerResponse.response(at: .init(x: CGFloat.nan, y: 0), in: bounds), .neutral)
        XCTAssertEqual(CompanionPointerResponse.response(at: .init(x: 100, y: 0), in: .zero), .neutral)
        XCTAssertEqual(CompanionPointerResponse.response(at: .zero,
            in: .init(x: 0, y: 0, width: CGFloat.infinity, height: 20)), .neutral)
        XCTAssertNil(CompanionPointerResponse(x: .nan, y: 1).directionIndex)
    }

    func testTaskAndAvailabilityStatesAlwaysTakePriorityOverPointer() {
        XCTAssertTrue(CompanionPointerResponse.allowsReaction(canAnimate: true, pose: .idle))
        XCTAssertFalse(CompanionPointerResponse.allowsReaction(canAnimate: false, pose: .idle))
        for pose in [CompanionCharacterPose.greeting, .queued, .working, .needsApproval,
                     .completed, .failed, .paused, .unavailable] {
            XCTAssertFalse(CompanionPointerResponse.allowsReaction(canAnimate: true, pose: pose), pose.rawValue)
        }
    }

    func testDirectionalFramesAreHeldCorrectCellsAndNeverInventedForV1() throws {
        let atlas = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: .pitou))
        for direction in 0..<16 {
            let angle = Double(direction) * 2 * .pi / 16
            let pointer = CompanionPointerResponse(x: CGFloat(sin(angle)), y: CGFloat(-cos(angle)))
            let frame = try XCTUnwrap(atlas.lookFrame(for: pointer, pose: .idle, canAnimate: true))
            XCTAssertEqual(frame.row, direction < 8 ? .lookFirst : .lookSecond)
            XCTAssertEqual(frame.index, direction % 8)
            XCTAssertNotNil(atlas.frame(row: frame.row, index: frame.index))
            XCTAssertNil(atlas.lookFrame(for: pointer, pose: .working, canAnimate: true))
            XCTAssertNil(atlas.lookFrame(for: pointer, pose: .idle, canAnimate: false))
        }
        XCTAssertNil(atlas.lookFrame(for: .neutral, pose: .idle, canAnimate: true))
        let legacy = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: .gon))
        XCTAssertNil(legacy.lookFrame(for: .init(x: 1, y: 0), pose: .idle, canAnimate: true))
    }

    func testDisableHideRemoveAndCloseReleaseWindowTracking() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: .init(x: 0, y: 0, width: 300, height: 300))
        window.contentView = host
        let tracker = CompanionPointerTrackingView { _ in }
        tracker.frame = .init(x: 20, y: 20, width: 100, height: 100)
        host.addSubview(tracker)
        XCTAssertFalse(tracker.isTracking)
        XCTAssertFalse(tracker.hasMovementMonitor)
        let baseline = host.trackingAreas.count
        tracker.setEnabled(true)
        XCTAssertTrue(tracker.isTracking)
        XCTAssertTrue(tracker.hasMovementMonitor)
        XCTAssertEqual(host.trackingAreas.count, baseline + 1)
        XCTAssertEqual(tracker.observationCount, 2)
        XCTAssertNil(tracker.hitTest(.zero), "Pointer reactions must not intercept ordinary controls")
        tracker.setEnabled(false)
        XCTAssertFalse(tracker.isTracking)
        XCTAssertFalse(tracker.hasMovementMonitor)
        XCTAssertEqual(host.trackingAreas.count, baseline)
        XCTAssertEqual(tracker.observationCount, 0)
        tracker.setEnabled(true)
        tracker.isHidden = true
        XCTAssertFalse(tracker.isTracking)
        XCTAssertFalse(tracker.hasMovementMonitor)
        tracker.isHidden = false
        XCTAssertTrue(tracker.isTracking)
        XCTAssertTrue(tracker.hasMovementMonitor)
        tracker.removeFromSuperview()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertFalse(tracker.hasMovementMonitor)
        XCTAssertEqual(host.trackingAreas.count, baseline)
        host.addSubview(tracker)
        XCTAssertTrue(tracker.isTracking)
        window.close()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertFalse(tracker.hasMovementMonitor)
        XCTAssertEqual(tracker.observationCount, 0)
        XCTAssertEqual(host.trackingAreas.count, baseline)
        tracker.detach()
        XCTAssertEqual(tracker.observationCount, 0)
    }

    func testMouseEventsStayInOwningWindowAndDisableDiscardsQueuedMovement() throws {
        // A key-window fixture exercises delivery without activating an app or
        // moving the user's system cursor during the native unit-test run.
        let window = CompanionPointerKeyWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        defer { window.close(); otherWindow.close() }
        var delivered: [CompanionPointerResponse] = []
        let tracker = CompanionPointerTrackingView { delivered.append($0) }
        tracker.frame = .init(x: 0, y: 0, width: 180, height: 180)
        window.contentView?.addSubview(tracker)
        tracker.setEnabled(true)
        func event(for target: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .init(x: 250, y: 90),
                modifierFlags: [], timestamp: 0, windowNumber: target.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
        }
        let movement = try event(for: window)
        tracker.mouseMoved(with: try event(for: otherWindow))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertTrue(delivered.isEmpty)
        tracker.mouseMoved(with: movement)
        tracker.setEnabled(false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertTrue(delivered.isEmpty, "A queued reaction must not survive disabling animation")
        tracker.setEnabled(true)
        tracker.mouseMoved(with: movement)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(delivered.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(delivered.last).x, 0)
        tracker.mouseMoved(with: movement)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(delivered.count, 1, "Native tracking and local listener callbacks must coalesce")
        tracker.mouseExited(with: movement)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(delivered.last, .neutral)
        tracker.mouseMoved(with: movement)
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(delivered.last, .neutral)
        XCTAssertFalse(tracker.isTracking)
    }

    func testHostedWindowDeliversQueuedMouseMovementAndReleasesLocalListener() throws {
        let previousKeyWindow = NSApp.keyWindow
        let window = NSWindow(contentRect: .init(x: 200, y: 200, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); previousKeyWindow?.makeKey() }
        var delivered: [CompanionPointerResponse] = []
        let root = ZStack(alignment: .bottomLeading) {
            Color.clear
            Color.clear.frame(width: 96, height: 96)
                .background(CompanionPointerTracking(enabled: true) { delivered.append($0) }
                    .allowsHitTesting(false))
        }.frame(width: 400, height: 300)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        func findTracker(in view: NSView) -> CompanionPointerTrackingView? {
            if let tracker = view as? CompanionPointerTrackingView { return tracker }
            return view.subviews.lazy.compactMap { findTracker(in: $0) }.first
        }

        func pumpEvents(until condition: () -> Bool) {
            let deadline = Date(timeIntervalSinceNow: 1)
            repeat {
                if let event = NSApp.nextEvent(matching: .any,
                    until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                NSApp.updateWindows()
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            } while !condition() && Date() < deadline
        }
        pumpEvents { window.isKeyWindow && NSApp.isActive }
        guard window.isKeyWindow, NSApp.isActive else {
            throw XCTSkip("Hosted fixture could not activate: key=\(window.isKeyWindow), active=\(NSApp.isActive), "
                + "hidden=\(NSApp.isHidden), visible=\(window.isVisible), policy=\(NSApp.activationPolicy().rawValue)")
        }
        pumpEvents {
            guard let tracker = findTracker(in: host) else { return false }
            return tracker.window === window && tracker.isTracking
                && tracker.hasMovementMonitor
                && tracker.bounds.width == 96 && tracker.bounds.height == 96
                && !tracker.visibleRect.isEmpty && !tracker.isHiddenOrHasHiddenAncestor
                && host.trackingAreas.contains { ($0.owner as? CompanionPointerTrackingView) === tracker }
        }
        let tracker = try XCTUnwrap(findTracker(in: host))
        XCTAssertTrue(tracker.isTracking)
        XCTAssertTrue(tracker.hasMovementMonitor)
        XCTAssertTrue(tracker.window === window)
        XCTAssertEqual(tracker.bounds.size, CGSize(width: 96, height: 96))
        XCTAssertFalse(tracker.visibleRect.isEmpty)
        XCTAssertTrue(host.trackingAreas.contains { ($0.owner as? CompanionPointerTrackingView) === tracker })
        var observedMoves = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            if event.window === window { observedMoves += 1 }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        // Test native queue dispatch, not a direct mouseMoved call. An app-local
        // listener works across NSHostingView's own tracking-area management.
        window.acceptsMouseMovedEvents = false
        for (point, direction) in [(CGPoint(x: 350, y: 48), 4), (CGPoint(x: 48, y: 250), 0)] {
            delivered.removeAll()
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
                location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
            NSApp.postEvent(event, atStart: false)
            pumpEvents { delivered.contains(where: { $0.directionIndex == direction }) }
            XCTAssertTrue(delivered.contains(where: { $0.directionIndex == direction }),
                "Queued move \(direction) missing. key=\(window.isKeyWindow), active=\(NSApp.isActive), "
                + "tracking=\(tracker.isTracking), bounds=\(tracker.bounds), visible=\(tracker.visibleRect), "
                + "registered=\(host.trackingAreas.contains { ($0.owner as? CompanionPointerTrackingView) === tracker }), "
                + "localMoves=\(observedMoves), responses=\(delivered), modal=\(String(describing: NSApp.modalWindow))")
        }
        tracker.setEnabled(false)
        pumpEvents { delivered.last == .neutral }
        delivered.removeAll()
        let disabledMovement = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
            location: .init(x: 350, y: 48), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0))
        let beforeDisabledMove = observedMoves
        NSApp.postEvent(disabledMovement, atStart: false)
        pumpEvents { observedMoves > beforeDisabledMove }
        XCTAssertFalse(tracker.hasMovementMonitor)
        XCTAssertTrue(delivered.isEmpty, "Disabling reactions removes the local listener without consuming the mouse event")
        tracker.setEnabled(true)
        XCTAssertTrue(tracker.hasMovementMonitor)
        window.close()
        XCTAssertFalse(tracker.hasMovementMonitor)
        XCTAssertFalse(window.acceptsMouseMovedEvents, "Tracking must not change a shared window preference")
    }
}

private final class CompanionPointerKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
