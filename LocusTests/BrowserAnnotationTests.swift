import AppKit
import XCTest
@testable import Locus

/// The annotation model and flattener — pure geometry plus a headless
/// CoreGraphics render, so the whole pipeline tests without a window. The
/// quadrant test exists specifically to catch y-flip regressions between
/// SwiftUI's top-left space and CoreGraphics' bottom-left one.
final class BrowserAnnotationTests: XCTestCase {
    func testArrowHeadIsSymmetricAndBehindTheTip() {
        let head = AnnotationGeometry.arrowHead(
            from: CGPoint(x: 0, y: 0),
            to: CGPoint(x: 100, y: 0),
            length: 12
        )

        XCTAssertLessThan(head.left.x, 100)
        XCTAssertLessThan(head.right.x, 100)
        XCTAssertEqual(head.left.y, -head.right.y, accuracy: 0.001)
        for barb in [head.left, head.right] {
            let distance = hypot(barb.x - 100, barb.y)
            XCTAssertEqual(distance, 12, accuracy: 0.001)
        }
    }

    func testNormalizedRectFromAnyDragDirection() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        let corners = [
            (CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 60)),
            (CGPoint(x: 40, y: 60), CGPoint(x: 10, y: 20)),
            (CGPoint(x: 40, y: 20), CGPoint(x: 10, y: 60)),
            (CGPoint(x: 10, y: 60), CGPoint(x: 40, y: 20)),
        ]
        for (start, end) in corners {
            XCTAssertEqual(AnnotationGeometry.normalizedRect(from: start, to: end), expected)
        }
    }

    func testClampCropIntersectsAndRejectsSlivers() {
        let size = CGSize(width: 100, height: 80)

        let overhanging = AnnotationGeometry.clampCrop(
            CGRect(x: 60, y: 50, width: 200, height: 200), in: size
        )
        XCTAssertEqual(overhanging, CGRect(x: 60, y: 50, width: 40, height: 30))

        XCTAssertNil(AnnotationGeometry.clampCrop(
            CGRect(x: 0, y: 0, width: 8, height: 60), in: size
        ), "a sliver narrower than minSide flattens into nothing readable")
        XCTAssertNil(AnnotationGeometry.clampCrop(
            CGRect(x: 200, y: 200, width: 50, height: 50), in: size
        ), "a crop entirely outside the image is no crop")
    }

    func testPastedAttachmentNameStemIsDeterministic() {
        let attachment = ChatAttachment.pasted(
            imageData: Data([0x89, 0x50]),
            mimeType: "image/png",
            date: Date(timeIntervalSince1970: 1_754_700_000),
            nameStem: "Browser screenshot"
        )

        XCTAssertTrue(attachment.name.hasPrefix("Browser screenshot "))
        XCTAssertTrue(attachment.name.hasSuffix(".png"))
        // The default stem stays what paste always produced.
        XCTAssertTrue(
            ChatAttachment.pasted(imageData: Data([0x89]), mimeType: "image/png")
                .name.hasPrefix("Pasted image ")
        )
    }

    private func solidWhiteImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func color(at point: CGPoint, in data: Data) -> NSColor? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.colorAt(x: Int(point.x), y: Int(point.y))
    }

    func testFlattenDrawsInTopLeftSpaceAndCropsExactly() throws {
        let base = solidWhiteImage(width: 64, height: 48)

        // A red rectangle outline in the TOP-LEFT quadrant. If a y-flip
        // regression lands, the stroke ends up in the bottom-left instead.
        let flattened = try XCTUnwrap(AnnotationFlattener.flatten(
            base: base,
            shapes: [.rectangle(CGRect(x: 4, y: 4, width: 20, height: 12), color: .red)],
            crop: nil
        ))
        let onStroke = try XCTUnwrap(color(at: CGPoint(x: 14, y: 4), in: flattened))
        XCTAssertGreaterThan(onStroke.redComponent, 0.6)
        XCTAssertLessThan(onStroke.greenComponent, 0.4)
        let bottomRight = try XCTUnwrap(color(at: CGPoint(x: 56, y: 42), in: flattened))
        XCTAssertGreaterThan(bottomRight.greenComponent, 0.9, "the far quadrant stays white")

        let cropped = try XCTUnwrap(AnnotationFlattener.flatten(
            base: base,
            shapes: [],
            crop: CGRect(x: 8, y: 8, width: 32, height: 24)
        ))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: cropped))
        XCTAssertEqual(bitmap.pixelsWide, 32)
        XCTAssertEqual(bitmap.pixelsHigh, 24)
    }

    func testFlattenRefusesRenderingNothing() {
        let base = solidWhiteImage(width: 64, height: 48)
        XCTAssertNil(AnnotationFlattener.flatten(
            base: base,
            shapes: [],
            crop: CGRect(x: 200, y: 200, width: 10, height: 10)
        ), "a crop with no intersection cannot produce an image")
    }
}
