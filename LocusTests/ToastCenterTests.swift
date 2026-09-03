import Combine
import XCTest

@testable import Locus

@MainActor
final class ToastCenterTests: XCTestCase {
    func testPlainToastReplacesActionableOneAndClearsUndoPayload() {
        let center = ToastCenter()
        var replaced = 0
        center.onToastReplaced = { replaced += 1 }

        center.showToast("Chat deleted", actionTitle: "Undo")
        XCTAssertEqual(center.toast?.actionTitle, "Undo")
        XCTAssertEqual(replaced, 0, "an actionable toast must keep its undo payload")

        center.showToast("Saved")
        XCTAssertNil(center.toast?.actionTitle)
        XCTAssertEqual(replaced, 1)
    }

    func testToastAutoDismissesAndClearsPayload() async throws {
        let center = ToastCenter()
        var replaced = 0
        center.onToastReplaced = { replaced += 1 }
        center.showToast("Quick", duration: 0.05)
        for _ in 0..<100 where center.toast != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(center.toast)
        XCTAssertEqual(replaced, 2, "dismissal clears the payload after the initial replacement")
    }

    func testCancelPendingDismissalKeepsTheToast() async throws {
        let center = ToastCenter()
        center.showToast("Sticky", actionTitle: "Undo", duration: 0.05)
        center.cancelPendingDismissal()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(center.toast, "a cancelled dismissal must leave the toast visible")
    }

}
