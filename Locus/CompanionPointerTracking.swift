import AppKit
import SwiftUI

/// Presentation-only cursor direction in the character's local, top-down space.
/// It never leaves this view, enters a profile, or changes execution state.
struct CompanionPointerResponse: Equatable {
    var x: CGFloat
    var y: CGFloat
    static let neutral = Self(x: 0, y: 0)

    static func response(at point: CGPoint, in bounds: CGRect) -> Self {
        guard bounds.width > 0, bounds.height > 0,
              bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              point.x.isFinite, point.y.isFinite else { return .neutral }
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        let distance = hypot(dx, dy)
        guard distance.isFinite else { return .neutral }
        // Avoid flickering through opposite directions while crossing the face.
        guard distance > max(8, min(bounds.width, bounds.height) * 0.1) else { return .neutral }
        let reach = max(80, max(bounds.width, bounds.height) * 1.5)
        let divisor = max(reach, distance)
        // Bound SwiftUI updates without a polling timer or a background task.
        return Self(x: (dx / divisor * 16).rounded() / 16,
                    y: (dy / divisor * 16).rounded() / 16)
    }

    /// Atlas v2 is clockwise in screen coordinates: up=0, right=4, down=8, left=12.
    var directionIndex: Int? {
        guard x.isFinite, y.isFinite, self != .neutral else { return nil }
        let turns = atan2(Double(x), -Double(y)) / (2 * .pi)
        return (Int((turns * 16).rounded()) + 16) % 16
    }

    static func allowsReaction(canAnimate: Bool, pose: CompanionCharacterPose) -> Bool {
        // Task and connection indications always take precedence over decoration.
        canAnimate && pose == .idle
    }
}

struct CompanionPointerTracking: NSViewRepresentable {
    var enabled: Bool
    var changed: (CompanionPointerResponse) -> Void

    func makeNSView(context: Context) -> CompanionPointerTrackingView {
        CompanionPointerTrackingView(changed: changed)
    }
    func updateNSView(_ view: CompanionPointerTrackingView, context: Context) {
        view.changed = changed
        view.setEnabled(enabled)
    }
    static func dismantleNSView(_ view: CompanionPointerTrackingView, coordinator: ()) { view.detach() }
}

/// Event-driven, app-local tracking filtered to the owning active key window.
/// NSHostingView can suppress forwarding mouseMoved from a foreign tracking
/// area, so an app-local listener guarantees movement delivery. The area still
/// requests native movement events and handles entry/exit. Duplicate callbacks
/// are coalesced into one changed value before reaching SwiftUI.
/// Neither path intercepts events, polls the cursor, or observes other apps.
@MainActor
final class CompanionPointerTrackingView: NSView {
    var changed: (CompanionPointerResponse) -> Void
    private(set) var isTracking = false
    private(set) var observationCount = 0
    private var enabled = false
    private weak var trackingHost: NSView?
    private var area: NSTrackingArea?
    private var movementMonitor: Any?
    var hasMovementMonitor: Bool { movementMonitor != nil }
    private var observers: [NSObjectProtocol] = []
    private var pending = CompanionPointerResponse.neutral
    private var delivered = CompanionPointerResponse.neutral
    private var deliveryScheduled = false
    private var generation = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(changed: @escaping (CompanionPointerResponse) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("CompanionPointerTrackingView is programmatic") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        attachIfNeeded()
    }
    override func viewDidHide() { super.viewDidHide(); detach() }
    override func viewDidUnhide() { super.viewDidUnhide(); attachIfNeeded() }

    func setEnabled(_ value: Bool) {
        enabled = value
        if value { attachIfNeeded() } else { detach() }
    }

    private func attachIfNeeded() {
        guard enabled, !isTracking, !isHiddenOrHasHiddenAncestor,
              let window, let host = window.contentView else { return }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        host.addTrackingArea(area)
        trackingHost = host
        self.area = area
        isTracking = true
        movementMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated {
                // A nonactivating menu-bar panel can be key while Locus is inactive.
                // This app-local monitor still accepts only its own key window's events.
                guard let self, event.window === self.window,
                      self.window?.isKeyWindow == true else { return }
                self.updatePointer(event)
            }
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name,
                object: window, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if notification.name == NSWindow.willCloseNotification { self.detach() }
                    else { self.publish(.neutral) }
                }
            })
        }
        observationCount = observers.count
    }

    override func mouseEntered(with event: NSEvent) { updatePointer(event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(event) }
    override func mouseExited(with event: NSEvent) { publish(.neutral) }

    private func updatePointer(_ event: NSEvent) {
        guard isTracking, enabled, event.window === window,
              window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { return }
        publish(.response(at: convert(event.locationInWindow, from: nil), in: bounds))
    }

    private func publish(_ response: CompanionPointerResponse) {
        pending = response
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        let generation = generation
        // Coalesce mouse events and avoid mutating SwiftUI during AppKit layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.deliveryScheduled = false
            guard self.delivered != self.pending else { return }
            self.delivered = self.pending
            self.changed(self.pending)
        }
    }

    func detach() {
        if let area { trackingHost?.removeTrackingArea(area) }
        area = nil
        trackingHost = nil
        isTracking = false
        if let movementMonitor { NSEvent.removeMonitor(movementMonitor) }
        movementMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        observationCount = 0
        generation += 1
        deliveryScheduled = false
        publish(.neutral)
    }
    deinit {
        if let movementMonitor { NSEvent.removeMonitor(movementMonitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
