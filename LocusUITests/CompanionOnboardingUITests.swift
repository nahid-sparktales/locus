import XCTest

final class CompanionOnboardingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_FIRST_LAUNCH"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_OFFLINE"] = "1"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    }

    override func tearDownWithError() throws { app.terminate() }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testOfflineCharacterNameAndExploreUseOneGettingStartedSurface() {
        app.launch()
        XCTAssertTrue(element("companion.continue").waitForExistence(timeout: 15))
        capture("Companion welcome")
        element("companion.continue").click()
        for sprite in ["pitou-v2", "gon-v1", "ninja-v1", "clover-v1", "shadow-v1", "pirate-v1"] {
            XCTAssertTrue(element("companion.sprite.\(sprite)").exists)
        }
        XCTAssertFalse(element("companion.palette").exists, "Bundled sprites do not expose unsupported recoloring")
        selectCollection("Originals")
        for kind in ["robot", "spark", "cat", "fox", "frog", "explorer"] {
            XCTAssertTrue(element("companion.character.\(kind)").exists)
        }
        element("companion.character.fox").click()
        capture("Companion character gallery")
        element("companion.continue").click()
        let name = element("companion.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Pitou")
        name.click()
        app.typeKey("a", modifierFlags: .command)
        name.typeText("Mochi")
        element("companion.continue").click()
        XCTAssertTrue(element("companion.introduction").waitForExistence(timeout: 5))
        // macOS may merge adjacent read-only Text views into one AX element.
        let introduction = element("companion.introduction")
        let introductionText = [introduction.label, introduction.value as? String].compactMap { $0 }.joined(separator: " ")
        XCTAssertTrue(element("companion.connectNotice").exists
            || introductionText.contains("Connect a model to start chatting."))
        capture("Companion introduction")
        element("companion.explore").click()
        XCTAssertTrue(element("onboarding.path.documents").waitForExistence(timeout: 5))
        XCTAssertTrue(element("onboarding.path.coding").exists)
        XCTAssertTrue(element("onboarding.path.agents").exists)
        element("onboarding.skip").click()
        let entry = element("sidebar.companion")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.click()
        XCTAssertTrue(element("savedAgent.name").waitForExistence(timeout: 5))
        XCTAssertEqual(element("savedAgent.name").label, "Mochi")
        capture("Persistent companion overview")
    }

    func testSkipEscapeAndReturnPreserveDraftWithoutCreatingAgent() {
        app.launch()
        XCTAssertTrue(element("companion.continue").waitForExistence(timeout: 15))
        element("companion.continue").click()
        selectCollection("Originals")
        element("companion.character.cat").click()
        element("companion.continue").click()
        let name = element("companion.name")
        name.click()
        app.typeKey("a", modifierFlags: .command)
        name.typeText("Pip")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("sidebar.companion").waitForExistence(timeout: 5))
        element("sidebar.companion").click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Pip")
        element("companion.back").click()
        XCTAssertTrue(element("companion.character.cat").waitForExistence(timeout: 5))
        element("onboarding.skip").click()
        XCTAssertFalse(element("savedAgent.name").exists)
    }

    func testCustomCharacterCancellationKeepsBundledPathAvailable() {
        app.launch()
        XCTAssertTrue(element("companion.continue").waitForExistence(timeout: 15))
        element("companion.continue").click()
        selectCollection("Originals")
        element("companion.character.frog").click()
        element("companion.createOwn").click()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(element("companion.character.frog").waitForExistence(timeout: 5))
        element("companion.continue").click()
        XCTAssertTrue(element("companion.name").waitForExistence(timeout: 5))
    }

    func testCompactDarkSetupSupportsKeyboardAndStaticCharacters() {
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "760"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "650"
        app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(element("companion.continue").waitForExistence(timeout: 15))
        element("companion.continue").click()
        element("companion.animations").click()
        app.typeKey(.tab, modifierFlags: [])
        capture("Companion compact dark static gallery")
        XCTAssertTrue(element("companion.continue").isHittable)
        element("companion.continue").click()
        XCTAssertTrue(element("companion.name").waitForExistence(timeout: 5))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func selectCollection(_ title: String) {
        let choice = app.radioButtons[title].firstMatch
        if choice.exists { choice.click() }
        else { app.buttons[title].firstMatch.click() }
    }
}
