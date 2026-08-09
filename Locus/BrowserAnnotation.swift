import AppKit
import CoreGraphics
import Foundation

/// Annotation colors for the screenshot editor. A fixed palette, not a color
/// picker: five swatches cover callouts without a modal detour.
enum AnnotationColor: String, CaseIterable, Identifiable {
    case red
    case yellow
    case blue
    case green
    case ink

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .red: NSColor(red: 0.86, green: 0.22, blue: 0.18, alpha: 1)
        case .yellow: NSColor(red: 0.95, green: 0.77, blue: 0.06, alpha: 1)
        case .blue: NSColor(red: 0.16, green: 0.44, blue: 0.86, alpha: 1)
        case .green: NSColor(red: 0.17, green: 0.62, blue: 0.30, alpha: 1)
        case .ink: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        }
    }
}

/// One drawn annotation. Every coordinate is an **image pixel** with a
/// top-left origin — the decoded bitmap is the single source of truth, so no
/// view scale or Retina factor ever appears in stored geometry.
enum AnnotationShape: Equatable {
    case pen(points: [CGPoint], color: AnnotationColor)
    case rectangle(CGRect, color: AnnotationColor)
    case arrow(start: CGPoint, end: CGPoint, color: AnnotationColor)
    case label(text: String, origin: CGPoint, color: AnnotationColor)
}

/// Pure geometry — the unit-test surface. The same `CGPath` feeds the live
/// SwiftUI `Canvas` preview and the CoreGraphics flattener, so what the user
/// sees while drawing is what the exported bitmap gets.
enum AnnotationGeometry {
    static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// The two barb points of an arrow head: `length` behind the tip, ±30°
    /// off the shaft.
    static func arrowHead(
        from start: CGPoint,
        to end: CGPoint,
        length: CGFloat
    ) -> (left: CGPoint, right: CGPoint) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let magnitude = max(sqrt(dx * dx + dy * dy), 0.001)
        let ux = dx / magnitude
        let uy = dy / magnitude
        let spread = CGFloat.pi / 6
        func barb(_ angle: CGFloat) -> CGPoint {
            let rx = ux * cos(angle) - uy * sin(angle)
            let ry = ux * sin(angle) + uy * cos(angle)
            return CGPoint(x: end.x - rx * length, y: end.y - ry * length)
        }
        return (barb(spread), barb(-spread))
    }

    /// Clamp a crop to the image, refusing slivers that would flatten into
    /// nothing readable.
    static func clampCrop(
        _ rect: CGRect,
        in size: CGSize,
        minSide: CGFloat = 16
    ) -> CGRect? {
        let bounds = CGRect(origin: .zero, size: size)
        let clamped = rect.standardized.intersection(bounds)
        guard clamped.width >= minSide, clamped.height >= minSide else { return nil }
        return clamped
    }

    /// Stroke width in image pixels, scaled so annotations stay legible on a
    /// 3200-pixel Retina capture and unclownish on a small one.
    static func strokeWidth(forImageWidth width: CGFloat) -> CGFloat {
        max(3, width / 320)
    }

    static func labelFontSize(forImageWidth width: CGFloat) -> CGFloat {
        max(18, width / 60)
    }

    /// The stroke path for a shape, in image-pixel coordinates. Labels have
    /// no path — they draw as text.
    static func path(for shape: AnnotationShape, headLength: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch shape {
        case .pen(let points, _):
            guard let first = points.first else { break }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        case .rectangle(let rect, _):
            path.addRect(rect.standardized)
        case .arrow(let start, let end, _):
            path.move(to: start)
            path.addLine(to: end)
            let head = arrowHead(from: start, to: end, length: headLength)
            path.move(to: head.left)
            path.addLine(to: end)
            path.addLine(to: head.right)
        case .label:
            break
        }
        return path
    }

    static func color(of shape: AnnotationShape) -> AnnotationColor {
        switch shape {
        case .pen(_, let color), .rectangle(_, color: let color),
             .arrow(_, _, color: let color), .label(_, _, color: let color):
            color
        }
    }
}

/// Renders annotations into the bitmap and applies the crop. Headless — a
/// plain CGContext, no windows — so it unit-tests on CI.
enum AnnotationFlattener {
    static func flatten(
        base: CGImage,
        shapes: [AnnotationShape],
        crop: CGRect?
    ) -> Data? {
        let width = base.width
        let height = base.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(base, in: fullRect)

        // One flip to a top-left origin; every stored coordinate then passes
        // through unchanged, for strokes and text alike.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let strokeWidth = AnnotationGeometry.strokeWidth(forImageWidth: CGFloat(width))
        let headLength = strokeWidth * 4
        let fontSize = AnnotationGeometry.labelFontSize(forImageWidth: CGFloat(width))

        for shape in shapes {
            let color = AnnotationGeometry.color(of: shape).nsColor
            if case .label(let text, let origin, _) = shape {
                let graphics = NSGraphicsContext(cgContext: context, flipped: true)
                let previous = NSGraphicsContext.current
                NSGraphicsContext.current = graphics
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                        .foregroundColor: color,
                        .strokeColor: NSColor.white,
                        // Negative width strokes AND fills — a white halo that
                        // keeps the label readable over any page content.
                        .strokeWidth: -3.0,
                    ]
                ).draw(at: origin)
                NSGraphicsContext.current = previous
                continue
            }
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(strokeWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(AnnotationGeometry.path(for: shape, headLength: headLength))
            context.strokePath()
        }

        guard var flattened = context.makeImage() else { return nil }
        if let crop {
            // `cropping(to:)` works in raster space — row zero is the top —
            // so the top-left-origin crop rect passes straight through.
            guard let cropped = flattened.cropping(
                to: crop.integral.intersection(fullRect)
            ) else { return nil }
            flattened = cropped
        }
        return NSBitmapImageRep(cgImage: flattened)
            .representation(using: .png, properties: [:])
    }
}
