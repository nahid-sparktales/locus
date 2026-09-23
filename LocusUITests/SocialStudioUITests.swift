import XCTest

final class SocialStudioUITests: XCTestCase {
    func testDraftWorkflowDark() { exercise(appearance: "dark") }
    func testDraftWorkflowLight() { exercise(appearance: "light") }

    private func exercise(appearance: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_SOCIAL_STUDIO"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_APPEARANCE"] = appearance
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        defer { app.terminate() }
        let newPost = app.buttons["socialStudio.newPost"]
        XCTAssertTrue(newPost.waitForExistence(timeout: 15))
        capture(app, "social-studio-empty-\(appearance)")
        newPost.click()
        let title = app.textFields["socialStudio.draftTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click(); title.typeText("A useful product update")
        let text = app.textViews["socialStudio.draftText"]
        text.click(); text.typeText("A calmer way to plan social content.")
        capture(app, "social-studio-composer-\(appearance)")
        app.buttons["socialStudio.saveDraft"].click()
        XCTAssertTrue(app.staticTexts["A useful product update"].waitForExistence(timeout: 5))
        capture(app, "social-studio-drafts-\(appearance)")
        app.buttons["socialStudio.section.Calendar"].click()
        XCTAssertTrue(app.descendants(matching: .any)["socialStudio.calendarExplanation"].waitForExistence(timeout: 5))
        capture(app, "social-studio-calendar-\(appearance)")
        app.buttons["socialStudio.section.Research"].click()
        XCTAssertTrue(app.textFields["socialStudio.researchTopic"].waitForExistence(timeout: 5))
        app.textFields["socialStudio.researchTopic"].click()
        app.textFields["socialStudio.researchTopic"].typeText("Local AI tools")
        XCTAssertTrue(app.buttons["socialStudio.researchRecent"].isEnabled)
        capture(app, "social-studio-research-\(appearance)")
        app.buttons["socialStudio.section.Accounts"].click()
        XCTAssertTrue(app.buttons["socialStudio.connect"].waitForExistence(timeout: 5))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let window = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'locus.socialStudio.'")).firstMatch
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
