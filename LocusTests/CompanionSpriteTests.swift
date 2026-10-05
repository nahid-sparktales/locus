import AppKit
import CryptoKit
import ImageIO
import XCTest
@testable import Locus

@MainActor
final class CompanionSpriteTests: XCTestCase {
    func testNewDefaultIsPitouAndStoredOriginalsRemainUnchanged() throws {
        XCTAssertEqual(CompanionAppearance.default, .pitou)
        XCTAssertEqual(CompanionAppearance.pitou.bundledSprite, .pitou)
        XCTAssertEqual(CompanionAppearance.pitou.displayName, "Pitou")
        XCTAssertEqual(CompanionAppearance.pitou.animationCapability, .spriteFrames)
        XCTAssertFalse(CompanionAppearance.pitou.supportsAppearanceControls)
        let legacy = CompanionAppearance(character: .fox, palette: .amber, accessory: .scarf, variationSeed: 42)
        let restored = try JSONDecoder().decode(CompanionAppearance.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(restored, legacy)
        XCTAssertEqual(restored.validated, legacy)
        for sprite in CompanionBundledSprite.supportedAssets {
            let appearance = CompanionAppearance(sprite: sprite)
            XCTAssertEqual(try JSONDecoder().decode(CompanionAppearance.self, from: JSONEncoder().encode(appearance)), appearance)
            XCTAssertEqual(appearance.validated, appearance)
            XCTAssertFalse(appearance.supportsAppearanceControls)
        }
    }

    func testMissingSpriteReferenceFallsBackToRobotRatherThanNewDefault() {
        var missing = CompanionAppearance.pitou
        missing.assetID = "unavailable-pet-v99"
        XCTAssertEqual(missing.validated, .robot)
        XCTAssertNotEqual(missing.validated, .default)
        missing.version = 99
        XCTAssertEqual(missing.validated, .robot)
    }

    func testStateRowsPreserveMeaningAndNeverUseTravelForWork() {
        let expected: [(CompanionCharacterPose, CompanionSpriteRow)] = [
            (.idle, .idle), (.greeting, .waving), (.queued, .idle), (.working, .working),
            (.needsApproval, .waiting), (.completed, .jumping), (.failed, .failed),
            (.paused, .idle), (.unavailable, .idle),
        ]
        for (pose, row) in expected { XCTAssertEqual(CompanionSpriteRow.row(for: pose), row) }
        XCTAssertEqual(CompanionSpriteRow.working.rawValue, 7)
        XCTAssertEqual(CompanionSpriteRow.runningRight.rawValue, 1)
        XCTAssertEqual(CompanionSpriteRow.runningLeft.rawValue, 2)
        for row in CompanionSpriteRow.allCases {
            XCTAssertEqual(row.frameDurations.count, row.frameCount)
            XCTAssertTrue(row.frameDurations.allSatisfy { $0 > 0 })
        }
    }

    func testBundledPitouRetainsExactGeometryAndAllApprovedFrames() throws {
        let url = try XCTUnwrap(CompanionSpriteCatalog.resourceURL(for: .pitou))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "57622683e6c527c1bb3df63aecad27bcca3bc993d512b5632ecd6b2cc02d5257",
            "Pitou must retain the exact user-selected artwork bytes")
        let atlas = try CompanionSpriteAtlas(data: data)
        XCTAssertEqual(atlas.version, 2)
        XCTAssertEqual(atlas.pixelWidth, 1536)
        XCTAssertEqual(atlas.pixelHeight, 2288)
        XCTAssertEqual(atlas.frameCount, 73)
        for row in CompanionSpriteRow.allCases {
            for index in 0..<row.frameCount {
                let image = try XCTUnwrap(atlas.frame(row: row, index: index))
                XCTAssertEqual(image.width, 192)
                XCTAssertEqual(image.height, 208)
            }
            XCTAssertNil(atlas.frame(row: row, index: -1))
            XCTAssertNil(atlas.frame(row: row, index: row.frameCount), "Unused cells must never enter playback")
        }
    }

    func testVisibleInstancesShareDecodedAssetAndCrops() throws {
        let first = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: .pitou))
        let second = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: .pitou))
        XCTAssertTrue(first === second)
        let firstFrame = try XCTUnwrap(first.frame(row: .idle, index: 0))
        let secondFrame = try XCTUnwrap(second.frame(row: .idle, index: 0))
        XCTAssertTrue(firstFrame === secondFrame)
    }

    func testEveryGallerySpriteHasItsApprovedBundledAtlasVersion() throws {
        for sprite in CompanionBundledSprite.supportedAssets {
            let url = try XCTUnwrap(CompanionSpriteCatalog.resourceURL(for: sprite), sprite.displayName)
            let atlas = try CompanionSpriteAtlas(data: Data(contentsOf: url))
            let hasGaze = sprite != .gon
            XCTAssertEqual(atlas.version, hasGaze ? 2 : 1, sprite.displayName)
            XCTAssertEqual(atlas.frameCount, hasGaze ? 73 : 57, sprite.displayName)
            XCTAssertEqual(atlas.pixelWidth, 1536, sprite.displayName)
            XCTAssertEqual(atlas.pixelHeight, hasGaze ? 2288 : 1872, sprite.displayName)
            if !hasGaze {
                XCTAssertNil(atlas.frame(row: .lookFirst, index: 0))
                XCTAssertNil(atlas.frame(row: .lookSecond, index: 0))
            }
        }
    }

    func testScoutReplacesGonInGalleryWithoutBreakingSavedGonReferences() throws {
        XCTAssertEqual(CompanionBundledSprite.allCases.count, 6)
        XCTAssertTrue(CompanionBundledSprite.allCases.contains(.scout))
        XCTAssertFalse(CompanionBundledSprite.allCases.contains(.gon))
        let stored = CompanionAppearance(sprite: .gon)
        let restored = try JSONDecoder().decode(CompanionAppearance.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(restored.assetID, "gon-v1")
        XCTAssertEqual(restored.validated, stored)
        XCTAssertNotNil(CompanionSpriteCatalog.atlas(for: .gon))
        XCTAssertEqual(CompanionAppearance(sprite: .scout).displayName, "Scout")
    }

    func testDisplayedCharactersHaveComparableVisibleHeight() throws {
        // Compare real opaque pixels rather than the identically sized transparent cells.
        let pitou = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: .pitou)?.frame(row: .idle, index: 0))
        let reference = try opaqueHeight(pitou)
        for sprite in CompanionBundledSprite.supportedAssets {
            let frame = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: sprite)?.frame(row: .idle, index: 0))
            let ratio = try opaqueHeight(frame) * sprite.presentationScale / reference
            XCTAssertGreaterThanOrEqual(ratio, 0.86, sprite.displayName)
            XCTAssertLessThanOrEqual(ratio, 1.08, sprite.displayName)
        }
    }

    private func opaqueHeight(_ image: CGImage) throws -> Double {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            let occupied = (0..<image.height).filter { row in
                (0..<image.width).contains { column in bytes[(row * image.width + column) * 4 + 3] > 32 }
            }
            return Double(try XCTUnwrap(occupied.last) - XCTUnwrap(occupied.first) + 1)
        }
    }

    func testAtlasRejectsOrdinaryPortraitActiveContentAndOversizedBytes() throws {
        XCTAssertThrowsError(try CompanionSpriteAtlas(data: Data("<svg><script>not an image</script></svg>".utf8)))
        XCTAssertThrowsError(try CompanionSpriteAtlas(data: Data(count: CompanionSpriteAtlas.maximumSourceBytes + 1)))
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertThrowsError(try CompanionSpriteAtlas(data: bytes)) { error in
            guard case CompanionSpriteAtlas.ValidationError.invalidDimensions = error else {
                return XCTFail("Expected exact atlas geometry validation, got \(error)")
            }
        }
    }
}
