import CoreGraphics

/// One selectable leaf as the drag hit-tester sees it: where it is on screen,
/// and where it sits in the transcript.
///
/// Kept free of AppKit views so the resolution rules can be tested directly.
/// Frames are in **window coordinates**, so y increases upward and a leaf
/// earlier in the transcript has the larger y.
struct TranscriptSpanFrame: Equatable {
    let spanID: String
    /// Document order. Lower comes first in the transcript.
    let order: Int
    let frame: CGRect
    let utf16Length: Int
}

enum TranscriptSelectionGeometry {
    enum Resolution: Equatable {
        /// The drag is over this leaf; the point is clamped into its bounds so
        /// the text view can turn it into a character index.
        case inside(spanID: String, point: CGPoint)
        /// Before every live leaf — collapse to the start of the first.
        case start(spanID: String)
        /// After every live leaf — extend to the end of the last.
        case end(spanID: String)
    }

    /// Where a drag point lands.
    ///
    /// The rule that matters is the second one. Leaves are laid out
    /// `.leading`, so most of a transcript row's width is empty, and the row
    /// itself has generous padding. A drag therefore spends much of its time
    /// outside every leaf's rect. Resolving that by nearest rectangle — which
    /// is what this replaced — snapped the offset to either 0 or the whole
    /// leaf, so dragging through the right margin of one line of a paragraph
    /// selected the entire paragraph. Clamping x while **keeping y** picks the
    /// line the pointer is actually beside.
    static func resolve(point: CGPoint, in frames: [TranscriptSpanFrame]) -> Resolution? {
        guard !frames.isEmpty else { return nil }

        if let hit = frames.first(where: { $0.frame.contains(point) }) {
            return .inside(spanID: hit.spanID, point: point)
        }

        // Same line of the transcript, just off to one side.
        let band = frames.filter { point.y >= $0.frame.minY && point.y <= $0.frame.maxY }
        if let nearest = band.min(by: {
            horizontalDistance(from: point, to: $0.frame) < horizontalDistance(from: point, to: $1.frame)
        }) {
            return .inside(spanID: nearest.spanID, point: clamp(point, into: nearest.frame))
        }

        // Window coordinates: earlier in the document means higher on screen.
        let ordered = frames.sorted { $0.order < $1.order }
        if let above = ordered.first, point.y > above.frame.maxY,
           ordered.allSatisfy({ point.y > $0.frame.maxY }) {
            return .start(spanID: above.spanID)
        }
        if let below = ordered.last, point.y < below.frame.minY,
           ordered.allSatisfy({ point.y < $0.frame.minY }) {
            return .end(spanID: below.spanID)
        }

        // In the gap between two leaves: attach to the nearer edge, still
        // keeping the pointer's x so the column survives.
        guard let nearest = frames.min(by: {
            verticalDistance(from: point, to: $0.frame) < verticalDistance(from: point, to: $1.frame)
        }) else { return nil }
        return .inside(spanID: nearest.spanID, point: clamp(point, into: nearest.frame))
    }

    private static func clamp(_ point: CGPoint, into rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private static func horizontalDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        max(rect.minX - point.x, 0, point.x - rect.maxX)
    }

    private static func verticalDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        max(rect.minY - point.y, 0, point.y - rect.maxY)
    }
}

/// Tells a click from a drag.
///
/// Without this a one-pixel wobble during a click counted as a selection, and
/// the mouse-up handler — which only follows a link when nothing is selected —
/// silently swallowed the click. Links in assistant prose were unreliable for
/// exactly that reason.
enum TranscriptSelectionDrag {
    /// Roughly the slop a steady hand produces while pressing the button.
    static let threshold: CGFloat = 3

    static func exceedsThreshold(
        from origin: CGPoint,
        to point: CGPoint,
        threshold: CGFloat = threshold
    ) -> Bool {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        return (dx * dx + dy * dy) > (threshold * threshold)
    }
}
