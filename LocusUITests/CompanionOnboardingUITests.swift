import AppKit
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
        for sprite in ["pitou-v2", "scout-v2", "ninja-v1", "clover-v1", "shadow-v1", "pirate-v1"] {
            XCTAssertTrue(element("companion.sprite.\(sprite)").exists)
        }
        XCTAssertFalse(element("companion.palette").exists, "Bundled sprites do not expose unsupported recoloring")
        XCTAssertFalse(app.radioButtons["Originals"].exists)
        for kind in ["robot", "spark", "cat", "fox", "frog", "explorer"] {
            XCTAssertFalse(element("companion.character.\(kind)").exists)
        }
        element("companion.sprite.ninja-v1").click()
        capture("Companion character gallery")
        element("companion.continue").click()
        let name = element("companion.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Ninja")
        let personality = element("companion.personality")
        XCTAssertTrue(personality.exists)
        XCTAssertTrue((personality.value as? String)?.hasPrefix("Be precise, composed, and methodical.") == true)
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
        element("inspector.rail.companion").click()
        XCTAssertTrue(element("companion.panel.name").waitForExistence(timeout: 5))
        let panelName = element("companion.panel.name")
        XCTAssertTrue([panelName.label, panelName.value as? String].compactMap { $0 }
            .joined(separator: " ").contains("Mochi"))
        XCTAssertTrue(element("companion.panel.notice").exists)
        element("companion.panel.options").click()
        app.menuItems["Profile and activity"].click()
        XCTAssertTrue(element("savedAgent.name").waitForExistence(timeout: 5))
        let profileName = element("savedAgent.name")
        XCTAssertTrue([profileName.label, profileName.value as? String].compactMap { $0 }
            .joined(separator: " ").contains("Mochi"))
        capture("Companion panel and existing profile")
    }

    func testSkipEscapeAndReturnPreserveDraftWithoutCreatingAgent() {
        app.launch()
        XCTAssertTrue(element("companion.continue").waitForExistence(timeout: 15))
        element("companion.continue").click()
        element("companion.sprite.clover-v1").click()
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
        XCTAssertTrue(element("companion.sprite.clover-v1").waitForExistence(timeout: 5))
        element("onboarding.skip").click()
        XCTAssertFalse(element("savedAgent.name").exists)
    }

    func testCustomCharacterCancellationKeepsBundledPathAvailable() {
        app.launch()
        XCTAssertTrue(element("companion.continue").waitForExistence(timeout: 15))
        element("companion.continue").click()
        element("companion.sprite.shadow-v1").click()
        element("companion.createOwn").click()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(element("companion.sprite.shadow-v1").waitForExistence(timeout: 5))
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

    func testCompanionPanelPreservesCenterTaskAndBothDrafts() {
        app.launchEnvironment["LOCUS_UI_TESTING_FIRST_LAUNCH"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_OFFLINE"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_CHAT"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "1200"
        app.launch()
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        XCTAssertFalse(element("sidebar.mode.companion").exists)
        XCTAssertTrue(element("sidebar.mode.ask").exists)
        XCTAssertTrue(element("sidebar.mode.agents").exists)
        XCTAssertLessThan(element("sidebar.companion").frame.maxY, element("sidebar.accounts").frame.minY)
        composer.click()
        composer.typeText("Unsent work note")
        XCTAssertTrue(waitForComposerValue("Unsent work note"))
        element("inspector.rail.companion").click()
        let companionInput = element("companion.panel.input")
        XCTAssertTrue(companionInput.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForComposerValue("Unsent work note"))
        companionInput.click()
        companionInput.typeText("Unsent companion idea")
        XCTAssertEqual(companionInput.value as? String, "Unsent companion idea")
        XCTAssertTrue(waitForComposerValue("Unsent work note"))
        XCTAssertTrue(element("companion.panel.send").exists)
        capture("Companion panel alongside current task")
        element("inspector.rail.companion").click()
        XCTAssertFalse(element("companion.panel").exists)
        XCTAssertTrue(waitForComposerValue("Unsent work note"))
        element("inspector.rail.companion").click()
        XCTAssertTrue(companionInput.waitForExistence(timeout: 5))
        XCTAssertEqual(companionInput.value as? String, "Unsent companion idea")
        XCTAssertTrue(waitForComposerValue("Unsent work note"))
        capture("Companion panel drafts restored")
    }

    func testLeftCompanionShortcutOpensItsCharacterAtTopOfMainConversation() {
        app.launchEnvironment["LOCUS_UI_TESTING_FIRST_LAUNCH"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_OFFLINE"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_CHAT"] = "1"
        app.launch()
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.click()
        composer.typeText("Unsent work note")
        element("sidebar.companion").click()
        let title = element("workspace.sessionTitle")
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                    "Companion UI fixture", "Companion UI fixture")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate,
                                object: title)], timeout: 5), .completed)
        XCTAssertTrue(composer.exists)
        XCTAssertFalse(element("companion.panel").exists)
        XCTAssertFalse(element("sidebar.mode.companion").exists)
        let character = element("companion.conversation.character")
        XCTAssertTrue(character.waitForExistence(timeout: 5))
        XCTAssertTrue(element("session.companion-fixture-chat").exists)
        XCTAssertFalse(element("session.companion-fixture-project").exists,
                       "The normal sidebar exposes only the current Companion chat")
        let transcript = element("conversation.scroll")
        XCTAssertEqual(character.frame.midX, transcript.frame.midX, accuracy: 3)
        XCTAssertLessThanOrEqual(character.frame.maxY, transcript.frame.minY + 3)
        XCTAssertFalse(element("conversation.welcome").exists)
        composer.click()
        composer.typeText("Main companion draft")
        element("sidebar.mode.ask").click()
        XCTAssertTrue(waitForComposerValue("Unsent work note"))
        element("sidebar.companion").click()
        XCTAssertTrue(waitForComposerValue("Main companion draft"))
        capture("Left shortcut opens companion in main composer")
    }

    func testCompanionPanelAndMainConversationShareOneChatAndDraft() {
        app.launchEnvironment["LOCUS_UI_TESTING_FIRST_LAUNCH"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_OFFLINE"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_CHAT"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "1200"
        app.launch()
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.click()
        composer.typeText("Keep my work draft")
        element("inspector.rail.companion").click()
        let folder = element("companion.panel.workspace")
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertTrue([folder.label, folder.value as? String].compactMap { $0 }
            .joined(separator: " ").contains("Companion home"), "Folder: \(folder.label), value: \(String(describing: folder.value))")
        XCTAssertFalse(app.menuButtons["companion.panel.workspace"].exists)
        XCTAssertFalse(element("companion.panel.history").exists)
        XCTAssertFalse(element("companion.panel.new").exists)
        XCTAssertTrue(element("companion.panel.clear").exists)
        let character = element("companion.panel.character")
        XCTAssertTrue(character.exists)
        XCTAssertEqual(character.frame.midX, element("companion.panel").frame.midX, accuracy: 3)
        XCTAssertEqual(element("companion.panel.name").frame.midX,
                       element("companion.panel").frame.midX, accuracy: 3)
        let input = element("companion.panel.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("One companion draft")
        XCTAssertTrue(waitForComposerValue("Keep my work draft"))
        element("companion.panel.options").click()
        app.menuItems["Open full conversation"].click()
        XCTAssertTrue(element("companion.conversation.character").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForComposerValue("One companion draft"))
        composer.click()
        app.typeKey("a", modifierFlags: .command)
        composer.typeText("Updated companion draft")
        element("sidebar.mode.ask").click()
        XCTAssertTrue(waitForComposerValue("Keep my work draft"))
        if !element("companion.panel").exists { element("inspector.rail.companion").click() }
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let updatedDraft = NSPredicate(format: "value == %@", "Updated companion draft")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: updatedDraft,
                                object: input)], timeout: 5), .completed)
        XCTAssertTrue([folder.label, folder.value as? String].compactMap { $0 }
            .joined(separator: " ").contains("Companion home"))
        XCTAssertFalse(element("companion.panel.history").exists)
        XCTAssertFalse(element("companion.panel.new").exists)
        capture("One companion chat shared across both surfaces")
    }

    func testCompanionCharacterRemainsCenteredAboveExistingMessages() {
        app.launchEnvironment["LOCUS_UI_TESTING_FIRST_LAUNCH"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_OFFLINE"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_CHAT"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_HISTORY"] = "1"
        app.launch()
        XCTAssertTrue(element("sidebar.companion").waitForExistence(timeout: 15))
        element("sidebar.companion").click()
        let character = element("companion.conversation.character")
        XCTAssertTrue(character.waitForExistence(timeout: 5))
        let reply = app.textViews.matching(NSPredicate(
            format: "value == %@", "We can keep talking here.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertEqual(character.frame.midX, element("conversation.scroll").frame.midX, accuracy: 3)
        XCTAssertLessThanOrEqual(character.frame.maxY, element("conversation.scroll").frame.minY + 3)
        XCTAssertFalse(element("conversation.welcome").exists)
        capture("Companion stays centered above chat history")
    }

    func testMenuBarCompanionPreservesDraftAcrossDismissalAndOpensLocus() throws {
        app.launchEnvironment["LOCUS_UI_TESTING_FIRST_LAUNCH"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_OFFLINE"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_CHAT"] = "1"
        app.launch()
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.click()
        composer.typeText("Keep my main task draft")
        XCTAssertTrue(waitForComposerValue("Keep my main task draft"))
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        try openMenuBarCompanion(statusItem)
        let popover = element("companion.menubar.popover")
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        let input = element("companion.panel.input")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("A quick companion draft")
        XCTAssertEqual(input.value as? String, "A quick companion draft")
        element("companion.menubar.activity").click()
        XCTAssertTrue(element("companion.menubar.open").exists)
        capture("Companion menu-bar activity")
        element("companion.menubar.chat").click()
        XCTAssertEqual(input.value as? String, "A quick companion draft")
        capture("Companion menu-bar quick chat")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: popover)], timeout: 5), .completed)
        try openMenuBarCompanion(statusItem)
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "A quick companion draft")
        element("companion.menubar.close").click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: popover)], timeout: 5), .completed)
        try openMenuBarCompanion(statusItem)
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "A quick companion draft")
        element("companion.menubar.open").click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: popover)], timeout: 5), .completed)
        XCTAssertTrue(waitForComposerValue("Keep my main task draft"))
        XCTAssertFalse(element("companion.panel").exists)
        element("inspector.rail.companion").click()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "A quick companion draft",
                       "The menu bar and inspector use the same canonical companion draft")
        let mainWindow = app.windows["locus.main"]
        mainWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: mainWindow)], timeout: 5), .completed)
        try openMenuBarCompanion(statusItem)
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "A quick companion draft")
        element("companion.menubar.open").click()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForComposerValue("Keep my main task draft"))
    }

    func testCompanionContextRequiresPreviewAndStaysWithItsChat() {
        app.launchEnvironment["LOCUS_UI_TESTING_FIRST_LAUNCH"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_OFFLINE"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_CHAT"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "1200"
        app.launch()
        app.activate()
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 15))
        element("composer.input").hover()
        element("composer.input").click()
        element("composer.input").typeText("Keep this work note")
        XCTAssertTrue(waitForComposerValue("Keep this work note"))
        element("inspector.rail.companion").hover()
        element("inspector.rail.companion").click()
        let workTitle = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                    "Work UI fixture", "Work UI fixture")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: workTitle,
            object: element("workspace.sessionTitle"))], timeout: 5), .completed)
        XCTAssertTrue(element("companion.context.add").waitForExistence(timeout: 5))
        XCTAssertFalse(element("companion.panel.send").isEnabled)
        element("companion.context.add").click()
        app.menuItems["Selected text or error…"].click()
        let text = element("companion.context.text")
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.click(); text.typeText("Only this error should be shared")
        element("companion.context.review").click()
        XCTAssertTrue(element("companion.context.confirm").waitForExistence(timeout: 5))
        capture("Companion explicit context preview")
        element("companion.context.confirm").click()
        let enabled = NSPredicate(format: "enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled,
            object: element("companion.panel.send"))], timeout: 5), .completed)
        XCTAssertTrue(waitForComposerValue("Keep this work note"))
        element("sidebar.companion").click()
        XCTAssertTrue(element("companion.conversation.character").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove Selected text"].firstMatch.waitForExistence(timeout: 5))
        capture("Shared context follows Companion into main chat")
    }

    func testCompanionToolsAndDesktopUseExistingIdentity() {
        app.launchEnvironment["LOCUS_UI_TESTING_FIRST_LAUNCH"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_OFFLINE"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_CHAT"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "1200"
        app.launch()
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 15))
        element("inspector.rail.companion").click()
        element("companion.panel.options").click()
        app.menuItems["Companion tools…"].click()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5))
        for title in ["Activity", "Memory", "Focus", "Handoffs", "Guide", "Character"] {
            let tab = app.radioButtons[title].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 5), title)
            tab.click()
        }
        XCTAssertTrue(element("companion.pack.import").waitForExistence(timeout: 5))
        capture("Companion character and desktop tools")
        app.buttons["Show desktop companion"].firstMatch.click()
        XCTAssertTrue(element("companion.desktop.character").waitForExistence(timeout: 5))
        capture("Floating Companion")
        app.buttons["Done"].firstMatch.click()
    }

    func testCompanionGuideOpensTheActualMCPControls() {
        app.launchEnvironment["LOCUS_UI_TESTING_FIRST_LAUNCH"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_OFFLINE"] = "0"
        app.launchEnvironment["LOCUS_UI_TESTING_COMPANION_CHAT"] = "1"
        app.launch()
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 15))
        element("inspector.rail.companion").click()
        element("companion.panel.options").click()
        app.menuItems["Companion tools…"].click()
        XCTAssertTrue(app.radioButtons["Guide"].firstMatch.waitForExistence(timeout: 5))
        app.radioButtons["Guide"].firstMatch.click()
        app.buttons["Connect an MCP server"].firstMatch.click()
        XCTAssertTrue(element("extensions.tab.mcp-servers").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Stop guidance"].firstMatch.waitForExistence(timeout: 5))
        capture("Companion guidance highlights real controls")
        app.buttons["Stop guidance"].firstMatch.click()
    }

    private func openMenuBarCompanion(_ item: XCUIElement) throws {
        // XCTest falls back to an invisible center point when macOS puts a
        // crowded status item behind the MacBook notch. A virtual/unobstructed
        // display exercises the real click; do not pretend a covered click passed.
        if !item.isHittable, let screen = NSScreen.main,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           item.frame.minX < right.minX, item.frame.maxX > left.maxX {
            throw XCTSkip("The display notch obscures Locus’s status item; run this case on an unobstructed menu bar.")
        }
        item.click()
    }

    private func waitForComposerValue(_ value: String) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate,
                                object: element("composer.input"))], timeout: 5) == .completed
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
