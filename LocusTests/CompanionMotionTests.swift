import XCTest
@testable import Locus

final class CompanionMotionTests: XCTestCase {
    func testSpritePlaybackUsesEightFPSOrHeldFramesWithoutFasterUpdates() {
        for row in CompanionSpriteRow.allCases {
            XCTAssertEqual(row.frameDurations.count, row.frameCount)
            for duration in row.frameDurations {
                XCTAssertGreaterThanOrEqual(duration, 125, "\(row) must not exceed eight source frames per second")
                XCTAssertEqual(duration % 125, 0, "\(row) must use whole stepped ticks")
            }
        }
    }

    func testIdleAndWaitingHoldQuietPosesWhileGreetingAndCompletionAreBrief() {
        let idle = CompanionSpriteRow.idle.frameDurations
        XCTAssertEqual(idle.filter { $0 >= 2_000 }.count, 2)
        XCTAssertGreaterThan(idle.reduce(0, +), CompanionSpriteRow.working.frameDurations.reduce(0, +) * 4)
        XCTAssertTrue(CompanionSpriteRow.waiting.frameDurations.allSatisfy { $0 >= 250 })
        for row in [CompanionSpriteRow.waving, .jumping] {
            XCTAssertLessThanOrEqual(row.frameDurations.reduce(0, +), 1_000)
            XCTAssertGreaterThan(row.frameDurations.last ?? 0, row.frameDurations.first ?? 0)
        }
    }

    func testPresentationOffsetsUseDiscreteSymmetricPosesAndRejectNonfiniteValues() {
        let values: [CGFloat] = [-2.6, -1.5, -0.49, 0, 0.49, 1.5, 2.6]
        XCTAssertEqual(values.map(CompanionSteppedMotion.snapped), [-3, -2, 0, 0, 0, 2, 3])
        for value in values {
            XCTAssertEqual(CompanionSteppedMotion.snapped(value), -CompanionSteppedMotion.snapped(-value))
        }
        XCTAssertEqual(CompanionSteppedMotion.snapped(.nan), 0)
        XCTAssertEqual(CompanionSteppedMotion.snapped(.infinity), 0)
        XCTAssertEqual(CompanionSteppedMotion.snapped(-.infinity), 0)
    }
}
