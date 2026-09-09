import XCTest

/// In-process goal transport; these tests never start a provider or worker.
final class GoalUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_GOAL"] = "empty"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    }

    override func tearDownWithError() throws { app.terminate() }

    func testStartPauseResumeEditAndEndGoalPreserveComposerDraft() {
        let composer = element("composer.input")
        composer.click()
        composer.typeText("Keep this ordinary draft")
        element("composer.workflow").click()
        let goalButton = element("composer.goal")
        XCTAssertTrue(goalButton.waitForExistence(timeout: 5))
        goalButton.click()
        let objective = element("goal.editor.objective")
        XCTAssertTrue(objective.waitForExistence(timeout: 5))
        replace(objective, with: "Implement and verify the feature")
        element("goal.editor.calls").click()
        element("goal.editor.calls").typeText("25")
        element("goal.editor.save").click()

        XCTAssertTrue(element("goal.card").waitForExistence(timeout: 5))
        XCTAssertTrue(text("goal.status").contains("Working"))
        XCTAssertEqual(composer.value as? String, "Keep this ordinary draft")
        element("goal.pause").click()
        XCTAssertTrue(element("goal.resume").waitForExistence(timeout: 5))
        element("goal.resume").click()
        XCTAssertTrue(element("goal.pause").waitForExistence(timeout: 5))

        element("goal.edit").click()
        XCTAssertTrue(element("goal.editor.objective").waitForExistence(timeout: 5))
        replace(element("goal.editor.objective"), with: "Verify the revised feature")
        element("goal.editor.save").click()
        XCTAssertTrue(element("goal.resume").waitForExistence(timeout: 5))
        XCTAssertTrue(text("goal.objective").contains("revised feature"))
        element("goal.end").click()
        waitForText("goal.status", containing: "ended")
        XCTAssertFalse(element("goal.resume").exists)
        XCTAssertEqual(composer.value as? String, "Keep this ordinary draft")

        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Ended goal with preserved composer draft"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testRestoredBlockedGoalShowsReasonAndCanResume() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_GOAL"] = "blocked"
        app.launch()
        XCTAssertTrue(element("goal.card").waitForExistence(timeout: 10))
        XCTAssertTrue(text("goal.status").contains("attention"))
        XCTAssertTrue(element("goal.usage").exists)
        element("goal.resume").click()
        XCTAssertTrue(element("goal.pause").waitForExistence(timeout: 5))
    }

    func testGoalEditorRejectsInvalidAllowanceWithoutLosingTheObjective() {
        element("composer.workflow").click()
        element("composer.goal").click()
        let objective = element("goal.editor.objective")
        XCTAssertTrue(objective.waitForExistence(timeout: 5))
        objective.click()
        objective.typeText("Complete the planned feature")
        let allowance = element("goal.editor.calls")
        allowance.click()
        allowance.typeText("-1")
        XCTAssertFalse(element("goal.editor.save").isEnabled)
        replace(allowance, with: "10")
        XCTAssertTrue(element("goal.editor.save").isEnabled)
        element("goal.editor.cancel").click()
        XCTAssertFalse(element("goal.card").exists)
    }

    func testNeedsReviewRequiresExplicitAcceptanceAndLabelsItHonestly() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_GOAL"] = "needs_review"
        app.launch()
        XCTAssertTrue(element("goal.card").waitForExistence(timeout: 10))
        XCTAssertTrue(text("goal.status").contains("Needs review"))
        XCTAssertTrue(element("goal.resume").exists)
        XCTAssertTrue(element("goal.accept").exists)
        XCTAssertFalse(element("goal.pause").exists)
        element("goal.accept").click()
        waitForText("goal.status", containing: "completed")
        XCTAssertTrue(element("goal.verificationLabel").waitForExistence(timeout: 5))
        XCTAssertTrue(text("goal.verificationLabel").contains("Accepted by you"))
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Explicit acceptance after Needs review"
        capture.lifetime = .keepAlways
        add(capture)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func text(_ id: String) -> String {
        let item = element(id)
        return item.label + " " + (item.value as? String ?? "")
    }

    private func replace(_ element: XCUIElement, with value: String) {
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(value)
    }

    private func waitForText(_ id: String, containing value: String) {
        let predicate = NSPredicate { [weak self] _, _ in self?.text(id).contains(value) == true }
        expectation(for: predicate, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }
}
