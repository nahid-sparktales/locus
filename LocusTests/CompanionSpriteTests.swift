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

    func testEveryCharacterHasTheSameRestingHeightAtCompactAndHeroSizes() throws {
        let sourceHeights: [CompanionBundledSprite: CGFloat] = [
            .pitou: 193, .scout: 181, .ninja: 134, .clover: 132, .shadow: 135, .pirate: 124, .gon: 128,
        ]
        for sprite in CompanionBundledSprite.supportedAssets {
            let atlas = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: sprite))
            let frame = try XCTUnwrap(atlas.frame(row: .idle, index: 0))
            let bounds = try alphaBounds(frame, threshold: 32)
            XCTAssertEqual(bounds, atlas.layout.referenceBounds, sprite.displayName)
            XCTAssertEqual(bounds.height, try XCTUnwrap(sourceHeights[sprite]), sprite.displayName)
            for edge: CGFloat in [28, 44, 180, 220] {
                let displayed = atlas.layout.displayBounds(for: bounds, in: CGSize(width: edge, height: edge))
                XCTAssertEqual(displayed.height, edge * 0.78, accuracy: 0.0001, sprite.displayName)
                XCTAssertEqual(displayed.midX, edge / 2, accuracy: 0.0001, sprite.displayName)
                XCTAssertEqual(displayed.maxY / edge, 0.88, accuracy: 0.006, sprite.displayName)
            }
        }
    }

    func testEveryPoseAndGazePreservesAllPixelsWithinTheSharedSafetyInset() throws {
        for sprite in CompanionBundledSprite.supportedAssets {
            let atlas = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: sprite))
            for row in CompanionSpriteRow.allCases {
                for index in 0..<row.frameCount {
                    guard let frame = atlas.frame(row: row, index: index) else { continue }
                    // Include even alpha=1 shadows/edges, not just the solid
                    // silhouette used to choose the resting character height.
                    let bounds = try alphaBounds(frame, threshold: 0)
                    XCTAssertTrue(atlas.layout.contentBounds.contains(bounds), "\(sprite) \(row) \(index)")
                    for edge: CGFloat in [28, 44, 180, 220] {
                        let displayed = atlas.layout.displayBounds(for: bounds, in: CGSize(width: edge, height: edge))
                        XCTAssertGreaterThanOrEqual(displayed.minX, edge * 0.04 - 0.0001)
                        XCTAssertGreaterThanOrEqual(displayed.minY, edge * 0.04 - 0.0001)
                        XCTAssertLessThanOrEqual(displayed.maxX, edge * 0.96 + 0.0001)
                        XCTAssertLessThanOrEqual(displayed.maxY, edge * 0.96 + 0.0001)
                    }
                }
            }
        }
    }

    func testAtlasTransformPreservesPoseDifferencesRatherThanResizingEveryFrame() throws {
        for sprite in CompanionBundledSprite.supportedAssets {
            let atlas = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: sprite))
            let size = CGSize(width: 180, height: 180)
            let reference = atlas.layout.displayBounds(for: atlas.layout.referenceBounds, in: size)
            let jumping = try alphaBounds(XCTUnwrap(atlas.frame(row: .jumping, index: 0)), threshold: 32)
            let displayed = atlas.layout.displayBounds(for: jumping, in: size)
            XCTAssertEqual(displayed.height / reference.height,
                           jumping.height / atlas.layout.referenceBounds.height, accuracy: 0.0001)
            XCTAssertEqual((displayed.minY - reference.minY) / reference.height,
                           (jumping.minY - atlas.layout.referenceBounds.minY) / atlas.layout.referenceBounds.height,
                           accuracy: 0.0001)
            XCTAssertLessThan(jumping.height, atlas.layout.referenceBounds.height, sprite.displayName)
        }
    }

    func testLayoutCentersNonSquareHostsAndRejectsInvalidHostSizes() throws {
        let atlas = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: .pitou))
        let square = atlas.layout.imageFrame(in: CGSize(width: 44, height: 44))
        let wide = atlas.layout.imageFrame(in: CGSize(width: 88, height: 44))
        let tall = atlas.layout.imageFrame(in: CGSize(width: 44, height: 88))
        XCTAssertEqual(wide, square.offsetBy(dx: 22, dy: 0))
        XCTAssertEqual(tall, square.offsetBy(dx: 0, dy: 22))
        for size in [CGSize.zero, CGSize(width: -1, height: 44),
                     CGSize(width: CGFloat.nan, height: 44), CGSize(width: 44, height: CGFloat.infinity)] {
            XCTAssertEqual(atlas.layout.imageFrame(in: size), .zero)
        }
    }

    func testLegacyWholeImagePointerMotionRetainsItsSafetyMargin() throws {
        let atlas = try XCTUnwrap(CompanionSpriteCatalog.atlas(for: .gon))
        for edge: CGFloat in [28, 44, 180, 220] {
            let bounds = atlas.layout.displayBounds(for: atlas.layout.contentBounds, in: CGSize(width: edge, height: edge))
            for pointerX: CGFloat in [-1, 0, 1] {
                let angle = Double(CompanionSteppedMotion.snapped(pointerX * 2)) * .pi / 180
                let cosine = CGFloat(cos(angle)), sine = CGFloat(sin(angle))
                for pointerY: CGFloat in [-1, 0, 1] {
                    for x in [bounds.minX, bounds.maxX] {
                        for y in [bounds.minY, bounds.maxY] {
                            let dx = x - edge / 2, dy = y - edge
                            let movedX = edge / 2 + dx * cosine - dy * sine
                                + CompanionSteppedMotion.snapped(pointerX * edge * 0.015)
                            let movedY = edge + dx * sine + dy * cosine
                                + CompanionSteppedMotion.snapped(pointerY * edge * 0.01)
                            XCTAssertGreaterThanOrEqual(movedX, 0)
                            XCTAssertGreaterThanOrEqual(movedY, 0)
                            XCTAssertLessThanOrEqual(movedX, edge)
                            XCTAssertLessThanOrEqual(movedY, edge)
                        }
                    }
                }
            }
        }
    }

    private func alphaBounds(_ image: CGImage, threshold: UInt8) throws -> CGRect {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var minX = image.width, minY = image.height, maxX = -1, maxY = -1
            for y in 0..<image.height {
                for x in 0..<image.width where bytes[(y * image.width + x) * 4 + 3] > threshold {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { throw CompanionSpriteAtlas.ValidationError.invalidFrame }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    func testAtlasRejectsEmptyArtworkInsteadOfComputingAnInvalidScale() throws {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1536, pixelsHigh: 1872,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(image.bitmapData)
        pixels.initialize(repeating: 0, count: image.bytesPerRow * image.pixelsHigh)
        let bytes = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertThrowsError(try CompanionSpriteAtlas(data: bytes)) { error in
            guard case CompanionSpriteAtlas.ValidationError.invalidFrame = error else {
                return XCTFail("Expected empty-frame validation, got \(error)")
            }
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
