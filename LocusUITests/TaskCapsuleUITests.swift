import XCTest

/// Uses the isolated UI fixture; never connects to a real model account.
final class TaskCapsuleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_CAPSULES"] = "1"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    }

    override func tearDownWithError() throws { app.terminate() }

    func testCapsuleSheetShowsSeparateRoutesAndPreservesDraft() {
        openCapsules()
        let request = element("capsules.request")
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        let title = element("capsules.title")
        title.click()
        title.typeText("A reusable plan")
        request.click()
        request.typeText("Design a task, then implement it with the selected worker.")
        XCTAssertTrue(element("capsules.planner").exists)
        XCTAssertTrue(element("capsules.executor").exists)
        XCTAssertTrue(element("capsules.reviewer").exists)
        XCTAssertTrue(element("capsules.generate").exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Task Capsule model choices"
        shot.lifetime = .keepAlways
        add(shot)
        doneButton.click()
        openCapsules()
        XCTAssertEqual(element("capsules.title").value as? String, "A reusable plan")
        XCTAssertTrue((element("capsules.request").value as? String ?? "").contains("selected worker"))
    }

    func testExampleStartsAnEditableDraftWithoutRunningAPlan() {
        openCapsules()
        let generate = element("capsules.generate")
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        XCTAssertFalse(generate.isEnabled)
        let nextStep = element("capsules.nextStep")
        XCTAssertTrue(nextStep.exists)
        element("capsules.example.Fix a bug").click()
        XCTAssertTrue((element("capsules.request").value as? String ?? "").contains("[describe the issue]"))
        XCTAssertTrue(generate.isEnabled)
        XCTAssertTrue(doneButton.exists, "Choosing an example must leave the draft open for editing")
        doneButton.click()
        openCapsules()
        XCTAssertTrue((element("capsules.request").value as? String ?? "").contains("[describe the issue]"))
    }

    private func openCapsules() {
        app.typeKey("k", modifierFlags: [.command, .option])
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
    }

    private var doneButton: XCUIElement {
        // macOS 15 can propagate the capsule container's identifier to Done.
        app.sheets.buttons.matching(NSPredicate(
            format: "identifier == %@ OR (identifier == %@ AND label == %@)",
            "capsules.done", "capsules.sheet", "Done"
        )).firstMatch
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
}
