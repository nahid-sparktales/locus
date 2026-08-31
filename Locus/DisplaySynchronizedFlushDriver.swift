import AppKit
import Foundation
import QuartzCore

@MainActor
/// Coalesces work onto the display's own refresh, without trusting it to tick.
///
/// A `CADisplayLink` stops delivering frames whenever its display does: asleep,
/// disconnected, or a Mac running with the lid shut and nothing attached. The
/// link is not cancelled when that happens and reports no error — it simply
/// goes quiet. A flush waiting on the next frame would then wait forever, and
/// because a pending request suppresses further ones, streamed text stops
/// appearing until something calls the flush directly.
///
/// So every request also arms a watchdog. Whichever arrives first wins: the
/// frame on a live display, the watchdog on a dark one. That bounds how long a
/// flush can be deferred without giving up display synchronisation when there
/// is a display to synchronise with.
///
/// Not private, so the tests can exercise the no-frames path that a sleeping
/// display produces and a test machine cannot otherwise reproduce.
final class DisplaySynchronizedFlushDriver: NSObject {
    /// How long to wait for a frame before flushing anyway. Longer than a frame
    /// at any refresh rate a real display runs at — 40ms covers 25Hz and below,
    /// so a live link virtually always wins — and short enough that a dark
    /// display costs a barely perceptible delay rather than a freeze.
    static let frameDeadlineMilliseconds = 40

    private let callback: () -> Void
    private let synchronizesWithDisplay: Bool
    private var displayLink: CADisplayLink?
    private var watchdog: DispatchWorkItem?
    private var pending = false

    init(synchronizesWithDisplay: Bool = true, callback: @escaping () -> Void) {
        self.synchronizesWithDisplay = synchronizesWithDisplay
        self.callback = callback
    }

    func request() {
        guard !pending else { return }
        pending = true
        if synchronizesWithDisplay {
            if displayLink == nil,
               let source = NSApplication.shared.keyWindow?.screen ?? NSScreen.main
            {
                let link = source.displayLink(target: self, selector: #selector(displayTick(_:)))
                link.add(to: .main, forMode: .common)
                link.isPaused = true
                displayLink = link
            }
            displayLink?.isPaused = false
        }
        armWatchdog()
    }

    func cancelPending() {
        pending = false
        displayLink?.isPaused = true
        watchdog?.cancel()
        watchdog = nil
    }

    func invalidate() {
        pending = false
        displayLink?.invalidate()
        displayLink = nil
        watchdog?.cancel()
        watchdog = nil
    }

    private func armWatchdog() {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.frameNeverCame() }
        watchdog = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.frameDeadlineMilliseconds),
            execute: work
        )
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        fire()
    }

    private func frameNeverCame() {
        // Whatever silenced it — the display slept, or the screen it was built
        // against went away — this link is no longer a clock worth waiting on.
        // Drop it so the next request builds one against whatever display
        // exists by then, and the app recovers on its own when one comes back.
        displayLink?.invalidate()
        displayLink = nil
        fire()
    }

    private func fire() {
        guard pending else { return }
        pending = false
        displayLink?.isPaused = true
        watchdog?.cancel()
        watchdog = nil
        callback()
    }
}
