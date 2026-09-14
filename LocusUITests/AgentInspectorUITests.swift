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
        // The compact CI display leaves the fourth agent below the sidebar
        // viewport. Its accessibility element still exists, so reveal the
        // actual row before clicking instead of hitting the footer over it.
        let sidebar = element("sidebar.scroll")
        XCTAssertTrue(sidebar.exists)
        for _ in 0..<16 {
            if sidebar.frame.contains(parent.frame), parent.isHittable { break }
            let scrollUp = parent.frame.minY < sidebar.frame.minY
            sidebar.scroll(byDeltaX: 0, deltaY: scrollUp ? 100 : -100)
        }
        XCTAssertTrue(sidebar.frame.contains(parent.frame))
        XCTAssertTrue(parent.isHittable)
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

    func testSavedAgentDisclosuresRespondAcrossTheWholeHeader() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_AGENT_FIXTURE"] = "saved-profile"
        app.launch()
        let overview = element("savedAgent.overview")
        XCTAssertTrue(overview.waitForExistence(timeout: 10))

        // macOS exposes a styled DisclosureGroup as a disclosure triangle;
        // its native accessibility node also inherits the card identifier.
        // Match its unique visible label and compare the native open state.
        for title in ["Folder details & linked projects", "Instructions"] {
            let header = app.disclosureTriangles.matching(NSPredicate(format: "label == %@", title)).firstMatch
            for _ in 0..<12 {
                if header.exists && header.isHittable && overview.frame.contains(header.frame) { break }
                overview.scroll(byDeltaX: 0, deltaY: -200)
            }
            XCTAssertTrue(header.exists && header.isHittable)
            XCTAssertGreaterThan(header.frame.width, 180)
            let collapsedValue = String(describing: header.value)
            // Click empty space well beyond the label and disclosure arrow.
            // On the Instructions card this also covers its top padding.
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.15)).click()
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                String(describing: header.value) != collapsedValue
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 3), .completed)
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.5)).click()
            let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                String(describing: header.value) == collapsedValue
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 3), .completed)
        }
        attachScreenshot("Saved agent full-row disclosure headers")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
