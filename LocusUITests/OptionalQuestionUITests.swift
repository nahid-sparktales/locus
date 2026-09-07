import XCTest

/// Seeded in process; these interactions never call a model or external service.
final class OptionalQuestionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_OPTIONAL_QUESTION"] = "1"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    }

    override func tearDownWithError() throws { app.terminate() }

    func testOptionalCardKeepsNormalComposerAndShowsRecommendation() {
        XCTAssertTrue(element("optionalQuestion.panel").waitForExistence(timeout: 5))
        XCTAssertTrue(element("composer.input").exists)
        XCTAssertTrue(text("optionalQuestion.recommendation.q1").contains("SQLite"))
        element("optionalQuestion.skip").click()
        XCTAssertTrue(element("optionalQuestion.delivery").waitForExistence(timeout: 5))
        XCTAssertTrue(text("optionalQuestion.delivery").contains("accepted"))
        XCTAssertTrue(element("composer.input").exists)
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        image.name = "Optional answer accepted with composer available"
        image.lifetime = .keepAlways
        add(image)
    }

    func testSkipKeepsUnsentDraftAvailableForFollowup() {
        let entry = element("optionalQuestion.entry.q1")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.click()
        entry.typeText("Use an encrypted cache")
        element("optionalQuestion.skip").click()
        let followup = element("optionalQuestion.useDraft")
        XCTAssertTrue(followup.waitForExistence(timeout: 5))
        followup.click()
        XCTAssertTrue((element("composer.input").value as? String ?? "").contains("Use an encrypted cache"))
    }

    func testFocusAloneDoesNotPauseButEditingDoesAndBlurReleases() {
        let entry = element("optionalQuestion.entry.q1")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.click()
        XCTAssertFalse(text("optionalQuestion.countdown").contains("paused"))
        entry.typeText("Use durable storage")
        XCTAssertTrue(text("optionalQuestion.countdown").contains("paused"), text("optionalQuestion.countdown"))
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        image.name = "Optional question pauses only while editing"
        image.lifetime = .keepAlways
        add(image)
        element("composer.input").click()
        XCTAssertFalse(text("optionalQuestion.countdown").contains("paused"), text("optionalQuestion.countdown"))
    }

    func testHelperCanReceiveMessageInterruptAndResumeInInspector() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_OPTIONAL_QUESTION"] = nil
        app.launchEnvironment["LOCUS_UI_TESTING_SOLO_COLLABORATION"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_RUN_FIXTURE"] = "solo-swarm-live"
        app.launch()
        let entry = element("soloHelper.instruction.seed-helper")
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.click()
        entry.typeText("Include the timeout check")
        element("soloHelper.message.seed-helper").click()
        element("soloHelper.interrupt.seed-helper").click()
        let resume = element("soloHelper.resume.seed-helper")
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        image.name = "Solo helper interrupted with resume available"
        image.lifetime = .keepAlways
        add(image)
        resume.click()
        XCTAssertTrue(element("soloHelper.interrupt.seed-helper").waitForExistence(timeout: 5))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func text(_ id: String) -> String {
        let value = element(id)
        return value.label + " " + (value.value as? String ?? "")
    }
}
