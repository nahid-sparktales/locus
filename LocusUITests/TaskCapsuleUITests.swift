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
        element("capsules.done").click()
        openCapsules()
        XCTAssertEqual(element("capsules.title").value as? String, "A reusable plan")
        XCTAssertTrue((element("capsules.request").value as? String ?? "").contains("selected worker"))
    }

    private func openCapsules() {
        app.typeKey("k", modifierFlags: [.command, .option])
        XCTAssertTrue(element("capsules.done").waitForExistence(timeout: 5))
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
}
