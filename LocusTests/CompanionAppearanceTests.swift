import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Locus

final class CompanionAppearanceTests: XCTestCase {
    func testEveryOriginalAndVariationRoundTripsExactReference() throws {
        for character in CompanionCharacterKind.allCases {
            for palette in CompanionPalette.allCases {
                for accessory in CompanionAccessory.allCases {
                    let original = CompanionAppearance(character: character, palette: palette,
                        accessory: accessory, variationSeed: .max)
                    let restored = try JSONDecoder().decode(CompanionAppearance.self,
                        from: JSONEncoder().encode(original))
                    XCTAssertEqual(restored, original)
                    XCTAssertEqual(restored.validated, original)
                    XCTAssertEqual(restored.animationCapability, .articulated)
                }
            }
        }
    }

    func testSurpriseIsDeterministicAndUsesOnlyApprovedChoices() {
        var characters = Set<CompanionCharacterKind>()
        for seed in UInt64(0)..<100 {
            let choice = CompanionAppearance.surprise(seed: seed)
            XCTAssertEqual(choice, CompanionAppearance.surprise(seed: seed))
            XCTAssertEqual(choice.variationSeed, seed)
            XCTAssertEqual(choice.validated, choice)
            if let character = choice.builtIn { characters.insert(character) }
        }
        XCTAssertEqual(characters, Set(CompanionCharacterKind.allCases))
    }

    func testMissingAndFutureAssetsHaveStableVisualFallback() {
        var unavailable = CompanionAppearance(character: .fox, palette: .amber)
        unavailable.assetID = "removed-asset"
        XCTAssertEqual(unavailable.validated, .robot)
        unavailable.version = 42
        XCTAssertEqual(unavailable.validated, .robot)
        XCTAssertEqual(CompanionAppearance.portrait.validated, .portrait)
    }

    func testFutureAppearanceValuesDoNotInvalidateContainingPresentationRecord() throws {
        let data = Data("{\"version\":1,\"kind\":\"hologram\",\"assetID\":\"future\",\"palette\":\"future\",\"accessory\":\"future\"}".utf8)
        let decoded = try JSONDecoder().decode(CompanionAppearance.self, from: data)
        XCTAssertEqual(decoded.validated, .robot)
    }

    func testStaticArtDoesNotClaimArticulationOrAppearanceControls() throws {
        let appearance = CompanionAppearance.portrait
        XCTAssertEqual(appearance.animationCapability, .wholeImage)
        XCTAssertFalse(appearance.supportsAppearanceControls)
        XCTAssertNil(appearance.builtIn)
        let json = String(decoding: try JSONEncoder().encode(appearance), as: UTF8.self)
        XCTAssertFalse(json.contains("prompt"))
        XCTAssertFalse(json.contains("path"))
        XCTAssertFalse(json.contains("url"))
    }

    func testImageValidationRejectsActiveContentOversizeAndInvalidBytes() {
        for data in [Data("<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>".utf8),
                     Data("<html><img src='file:///private/example'></html>".utf8), Data([0, 1, 2]),
                     Data(repeating: 0, count: AgentAvatarImage.maximumSourceBytes + 1)] {
            XCTAssertThrowsError(try AgentAvatarImage.normalized(data))
        }
    }

    func testDecodedPixelAndDimensionBoundariesDoNotOverflow() {
        XCTAssertTrue(AgentAvatarImage.supportsDimensions(width: 1, height: 1))
        XCTAssertTrue(AgentAvatarImage.supportsDimensions(width: 8_000, height: 5_000))
        for dimensions in [(0, 1), (1, 0), (-1, 256), (16_385, 1), (1, 16_385), (8_001, 5_000), (Int.max, Int.max)] {
            XCTAssertFalse(AgentAvatarImage.supportsDimensions(width: dimensions.0, height: dimensions.1))
        }
    }

    func testApprovedPictureIsReencodedLocallyWithTransparencyAndWithoutMetadata() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(.init(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(.init(x: 8, y: 8, width: 16, height: 16))
        let pixels = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, [kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGDescription: "Private prompt that must not survive import"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let approved = try AgentAvatarImage.normalized(data as Data)
        XCTAssertLessThanOrEqual(approved.count, AgentAvatarImage.maximumStoredBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(approved as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
        XCTAssertTrue([CGImageAlphaInfo.premultipliedLast, .last, .premultipliedFirst, .first].contains(image.alphaInfo))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertFalse(String(describing: properties).contains("Private prompt"))
    }
}
