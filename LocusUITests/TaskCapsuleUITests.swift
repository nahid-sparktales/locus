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

    func testComposerModesAndCapsuleHandoffPreserveDrafts() {
        let composer = element("composer.input")
        let workflow = element("composer.workflow")
        composer.click()
        composer.typeText("Design a reusable workflow")
        XCTAssertFalse(element("composer.mode.plan").exists, "Inactive choices should stay in the dropdown")
        workflow.click()
        XCTAssertTrue(element("composer.mode.work").waitForExistence(timeout: 3))
        XCTAssertTrue(element("composer.mode.grill").exists)
        XCTAssertTrue(element("composer.capsules").exists)
        capture("Composer work options")
        element("composer.mode.plan").click()
        XCTAssertEqual(workflow.value as? String, "Plan · Solo")
        XCTAssertEqual(composer.value as? String, "Design a reusable workflow")
        workflow.click()
        XCTAssertEqual(element("composer.mode.plan").value as? String, "Selected")
        element("composer.mode.grill").click()
        XCTAssertEqual(workflow.value as? String, "Grill · Solo")
        workflow.click()
        element("composer.mode.work").click()
        XCTAssertEqual(workflow.value as? String, "Work · Solo")
        capture("Simplified composer")

        workflow.click()
        element("composer.capsules").click()
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        XCTAssertEqual(element("capsules.request").value as? String, "Design a reusable workflow")
        doneButton.click()
        XCTAssertEqual(composer.value as? String, "Design a reusable workflow")
        composer.click()
        composer.typeKey("a", modifierFlags: .command)
        composer.typeText("A different chat request")
        workflow.click()
        element("composer.capsules").click()
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        XCTAssertEqual(element("capsules.request").value as? String, "Design a reusable workflow")
        doneButton.click()
        XCTAssertEqual(composer.value as? String, "A different chat request")
    }

    func testWorkflowKeyboardSelectionReturnsFocusToDraft() {
        let composer = element("composer.input")
        let workflow = element("composer.workflow")
        composer.click()
        composer.typeText("Keep this draft")
        workflow.click()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(element("composer.mode.plan").exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(workflow.value as? String, "Plan · Solo")
        app.typeText(" after selection")
        XCTAssertEqual(composer.value as? String, "Keep this draft after selection")
        workflow.click()
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(workflow.value as? String, "Work · Solo")
        workflow.click()
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(workflow.value as? String, "Plan · Solo")
        workflow.click()
        app.typeKey(.escape, modifierFlags: [])
        app.typeText(" after escape")
        XCTAssertEqual(composer.value as? String, "Keep this draft after selection after escape")
    }

    func testCompactComposerMenuKeepsActionsReachable() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "720"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "620"
        app.launchEnvironment["LOCUS_UI_TESTING_APPEARANCE"] = "dark"
        app.launch()
        let workflow = element("composer.workflow")
        XCTAssertTrue(workflow.waitForExistence(timeout: 10))
        for id in ["composer.addChatAttachment", "composer.workflow", "composer.permissionMode", "composer.send"] {
            XCTAssertTrue(app.windows.firstMatch.frame.contains(element(id).frame), "\(id) must fit")
        }
        capture("Compact composer in dark appearance")
        workflow.click()
        XCTAssertTrue(element("composer.capsules").waitForExistence(timeout: 3))
        XCTAssertTrue(element("composer.capsules").isHittable)
        capture("Compact work options in dark appearance")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("composer.mode.work").exists)
        element("composer.addChatAttachment").click()
        let context = app.menuItems["Choose workspace context…"]
        XCTAssertTrue(context.waitForExistence(timeout: 3))
        context.click()
        XCTAssertTrue(element("context.add").waitForExistence(timeout: 3))
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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
