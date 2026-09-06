import XCTest

final class AgentInspectorUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_AGENT_FIXTURE"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "950"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(element("agentOverview.name").waitForExistence(timeout: 15))
    }

    override func tearDownWithError() throws { app.terminate() }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func reveal(_ identifier: String) -> XCUIElement {
        let item = element(identifier)
        let inspector = element("agentOverview")
        for _ in 0..<8 {
            if item.exists && item.isHittable { return item }
            inspector.scroll(byDeltaX: 0, deltaY: -250)
        }
        XCTAssertTrue(item.exists && item.isHittable, "Could not reach \(identifier)")
        return item
    }

    func testEventDetailsUseTheClickedRecordAndReturnToItsAgent() {
        reveal("agentOverview.event.seed-delivery-done.details").click()
        let title = element("agentInspector.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue((title.label + " \(title.value ?? "")").contains("Invoice #1042 ready"))
        XCTAssertFalse((title.label + " \(title.value ?? "")").contains("Invoice #1041 overdue"))
        XCTAssertTrue(element("agentInspector.untrustedContent").exists)
        attachScreenshot("Exact incoming event")
        let execution = element("agentInspector.execution.agent-inspector-seed-delivery-done")
        for _ in 0..<4 where !execution.isHittable {
            element("agentInspector.detail").scroll(byDeltaX: 0, deltaY: -200)
        }
        XCTAssertTrue(execution.exists && execution.isHittable)
        execution.click()
        XCTAssertTrue(element("agentInspector.runOutputs").waitForExistence(timeout: 5))
        attachScreenshot("Exact event execution")
        element("agentInspector.back").click()
        XCTAssertTrue(element("agentInspector.untrustedContent").waitForExistence(timeout: 5))
        element("agentInspector.back").click()
        XCTAssertTrue(element("agentOverview.event.seed-delivery-done.details").waitForExistence(timeout: 5))
        XCTAssertFalse(element("agentInspector.title").exists)
    }

    func testParentSelectionKeepsTheOpenConversation() {
        let chatTitle = element("workspace.sessionTitle")
        XCTAssertTrue(chatTitle.exists)
        let initialTitle = chatTitle.label + " \(chatTitle.value ?? "")"
        let parent = element("agent.seed-schedule")
        XCTAssertTrue(parent.waitForExistence(timeout: 5))
        parent.click()
        let agentName = element("agentOverview.name")
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (agentName.label + " \(agentName.value ?? "")").contains("Morning Review")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertTrue(element("agentOverview.runNow").exists)
        // The source conversation remains in the central pane; parent
        // selection is independent from selecting one of its child chats.
        XCTAssertEqual(chatTitle.label + " \(chatTitle.value ?? "")", initialTitle)
        attachScreenshot("Scheduled agent overview")
    }

    func testTaskContextExplainsTheSideConversationAndHasABackPath() {
        reveal("agentOverview.chat.seed-agent-chat-older").click()
        let title = element("agentInspector.title")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let status = element("agentInspector.status")
        XCTAssertTrue((status.label + " \(status.value ?? "")").contains("side conversation"))
        let workState = element("agentInspector.chat.state")
        XCTAssertTrue((workState.label + " \(workState.value ?? "")").contains("Idle"))
        XCTAssertTrue(element("agentInspector.openChat").exists)
        attachScreenshot("Agent task detail")
        element("agentInspector.back").click()
        XCTAssertTrue(element("agentOverview.chat.seed-agent-chat-older").waitForExistence(timeout: 5))
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
