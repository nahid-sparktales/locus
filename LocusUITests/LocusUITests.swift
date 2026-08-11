import AppKit
import XCTest

final class LocusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        // Stale window-restoration state can suppress the main window at
        // launch; tests must not depend on the machine's saved state.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    /// SwiftUI controls do not expose a stable element type across macOS
    /// releases. Match anchors by identifier on any element type and take the
    /// first result, because interactions on an ambiguous query fail outright.
    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// SwiftUI alerts surface as sheets labeled "alert" on current macOS;
    /// their message text is exposed as a value, not a label.
    private func staticTextWithValue(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", fragment)
        ).firstMatch
    }

    private func cancelConfirmation() {
        let sheetCancel = app.sheets.buttons["Cancel"].firstMatch
        if sheetCancel.exists {
            sheetCancel.click()
        } else {
            app.buttons["Cancel"].firstMatch.click()
        }
    }

    func testReopeningLocusKeepsOneMainWindowAndItsPresentedSheet() throws {
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["palette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.typeText("keep this state")

        let running = try XCTUnwrap(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "io.sparktales.locus"
            ).first
        )
        let appURL = try XCTUnwrap(running.bundleURL)
        let reopened = expectation(description: "Launch Services reopened Locus")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            XCTAssertNil(error)
            reopened.fulfill()
        }
        wait(for: [reopened], timeout: 5)

        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(search.exists)
        XCTAssertEqual(search.value as? String, "keep this state")
    }

    func testClosingTheUniqueMainWindowTerminatesLocus() {
        XCTAssertEqual(app.windows.count, 1)

        app.typeKey("w", modifierFlags: .command)

        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 5),
            "closing the main Window scene should terminate Locus and its backend owner"
        )
    }

    func testClearChatControlShowsNonDestructiveConfirmation() {
        let actions = anyElement("workspace.actions")
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.click()
        app.menuItems["Clear Chat…"].click()

        XCTAssertTrue(app.buttons["clearChat.confirm"].waitForExistence(timeout: 3))
        XCTAssertTrue(staticTextWithValue(containing: "Clear this chat?").exists)
        cancelConfirmation()
    }

    func testClearSessionsPreservesTheActiveJob() {
        anyElement("sidebar.more").click()
        // Matched by identifier, not title: the menu bar carries an item with
        // the same title, and an ambiguous query cannot be clicked.
        app.menuItems["sidebar.clearSessions"].click()

        XCTAssertTrue(app.buttons["clearSessions.confirm"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            staticTextWithValue(containing: "Previous sessions will move to a recovery folder").exists
        )
        cancelConfirmation()
    }

    func testMessageActionsAreAvailableFromContextMenu() {
        let assistant = anyElement("message.00000000-0000-0000-0000-000000000102")
        XCTAssertTrue(assistant.waitForExistence(timeout: 2))
        assistant.rightClick()

        XCTAssertTrue(app.menuItems["Copy Message"].exists)
        XCTAssertTrue(app.menuItems["Use as Draft"].exists)
        XCTAssertTrue(app.menuItems["Regenerate Response"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testUserMessageOffersRewind() {
        let user = anyElement("message.00000000-0000-0000-0000-000000000101")
        XCTAssertTrue(user.waitForExistence(timeout: 2))
        user.rightClick()

        XCTAssertTrue(app.menuItems["Rewind to This Message"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSessionOrganizerMenusAndArchivedFilter() {
        let current = app.buttons["session.seed-current"]
        XCTAssertTrue(current.waitForExistence(timeout: 2))
        XCTAssertFalse(
            anyElement("session.seed-current.activity").exists,
            "an idle chat should not look as though its elapsed timer is still running"
        )
        current.rightClick()

        XCTAssertTrue(app.menuItems["Rename…"].exists)
        XCTAssertTrue(app.menuItems["Unpin"].exists)
        XCTAssertTrue(app.menuItems["Export Markdown…"].exists)
        XCTAssertTrue(app.menuItems["Archive"].exists)
        XCTAssertTrue(app.menuItems["Delete Chat"].exists)
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(anyElement("sidebar.addWorkspace").exists)

        anyElement("sidebar.more").click()
        let archivedToggle = app.menuItems["sidebar.showArchived"]
        XCTAssertTrue(archivedToggle.waitForExistence(timeout: 2))
        archivedToggle.click()
        XCTAssertTrue(app.buttons["session.seed-archived"].waitForExistence(timeout: 3))
    }

    func testSidebarCollapsesAndRestoresFromWorkspaceHeader() {
        let collapse = anyElement("sidebar.collapse")
        XCTAssertTrue(collapse.waitForExistence(timeout: 3))
        collapse.click()

        let restore = anyElement("workspace.showSidebar")
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["sidebar.newSession"].exists)

        restore.click()
        XCTAssertTrue(app.buttons["sidebar.newSession"].waitForExistence(timeout: 3))
    }

    func testWorkspaceProfileContextPackAndPromptHistoryControls() {
        let workspaceMenu = anyElement("sidebar.workspaceMenu")
        XCTAssertTrue(workspaceMenu.waitForExistence(timeout: 3))
        workspaceMenu.click()
        XCTAssertTrue(app.menuItems["Choose Workspace…"].exists)
        XCTAssertTrue(app.menuItems["tmp"].exists)
        app.typeKey(.escape, modifierFlags: [])

        let composer = app.textViews["composer.input"]
        XCTAssertTrue(composer.exists)
        composer.click()
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue((composer.value as? String)?.contains("Audit the current changes") == true)

        app.buttons["composer.context"].click()
        XCTAssertTrue(app.buttons["context.add"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testExtensionsSettingsExposesAllExtensionCenters() {
        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Accounts…"].click()

        let extensionsPage = anyElement("settings.page.extensions")
        XCTAssertTrue(extensionsPage.waitForExistence(timeout: 3))
        extensionsPage.click()

        for tab in ["installed", "marketplace", "mcp-servers", "skills"] {
            let control = anyElement("extensions.tab.\(tab)")
            XCTAssertTrue(control.waitForExistence(timeout: 3))
            control.click()
        }
        XCTAssertTrue(app.staticTexts["Reusable workflows"].exists)
    }

    func testAgentProfileEditorKeepsInstructionsAndAdvancedActionsVisible() {
        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Agents & Teams…"].click()

        let addAgent = app.buttons["Add Agent"]
        XCTAssertTrue(addAgent.waitForExistence(timeout: 3))
        addAgent.click()

        let instructions = anyElement("agent.instructions")
        let template = anyElement("agent.useRoleTemplate")
        let tags = anyElement("agent.capabilityTags")
        let advanced = anyElement("agent.advancedSettings")
        let testConnection = anyElement("agent.testConnection")
        let cancel = anyElement("agent.cancel")
        let save = anyElement("agent.save")

        XCTAssertTrue(instructions.waitForExistence(timeout: 3))
        XCTAssertTrue(template.exists)
        XCTAssertTrue(tags.exists)
        XCTAssertTrue(advanced.exists)
        XCTAssertTrue(advanced.isHittable)
        XCTAssertTrue(testConnection.exists)
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(save.exists)
        XCTAssertLessThan(instructions.frame.maxY, advanced.frame.minY)

        instructions.click()
        app.typeKey("a", modifierFlags: .command)
        instructions.typeText("Custom editable instructions")
        XCTAssertEqual(instructions.value as? String, "Custom editable instructions")

        template.click()
        XCTAssertNotEqual(instructions.value as? String, "Custom editable instructions")

        let footerY = save.frame.minY
        advanced.click()
        XCTAssertTrue(anyElement("agent.advanced.timeout").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("agent.advanced.tokenLimit").exists)
        XCTAssertTrue(testConnection.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(save.isHittable)
        XCTAssertEqual(save.frame.minY, footerY, accuracy: 1)

        cancel.click()
    }

    func testNetworkSettingsRevealManualProxyFieldsAndGateSave() {
        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Accounts…"].click()

        let networkPage = anyElement("settings.page.network")
        XCTAssertTrue(networkPage.waitForExistence(timeout: 3))
        networkPage.click()

        let mode = anyElement("settings.proxyMode")
        XCTAssertTrue(mode.waitForExistence(timeout: 3))
        // Direct connection by default: no manual fields, Save enabled.
        XCTAssertFalse(anyElement("settings.proxyHost").exists)
        XCTAssertTrue(app.buttons["settings.save"].isEnabled)

        mode.click()
        app.menuItems["Manual proxy"].click()
        XCTAssertTrue(anyElement("settings.proxyHost").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("settings.proxyPort").exists)
        XCTAssertTrue(anyElement("settings.proxyBypass").exists)
        // A manual proxy with no host must not be saveable — silent direct
        // connections are the failure this feature exists to prevent.
        XCTAssertFalse(app.buttons["settings.save"].isEnabled)

        app.buttons["settings.cancel"].click()
    }

    func testRuntimeSettingsShowAutomaticOnlineServices() {
        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Accounts…"].click()

        // Manage Accounts lands on the Accounts tab; the runtime readout lives
        // on General.
        let generalPage = anyElement("settings.page.general")
        XCTAssertTrue(generalPage.waitForExistence(timeout: 3))
        generalPage.click()

        let agentStatus = app.staticTexts["settings.agentStatus"].firstMatch
        let modelStatus = app.staticTexts["settings.modelStatus"].firstMatch
        XCTAssertTrue(agentStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(agentStatus.value as? String, "Online")
        XCTAssertEqual(modelStatus.value as? String, "Online")
        XCTAssertFalse(anyElement("settings.autoLaunch").exists)
        XCTAssertFalse(anyElement("settings.retryLocalServices").exists)
        XCTAssertTrue(anyElement("settings.enterSendsMessages").exists)
        XCTAssertTrue(anyElement("settings.soloPlanPresentation").exists)
        XCTAssertTrue(anyElement("settings.teamRunsPresentation").exists)
    }

    func testFirstLaunchAsksWhichShortcutShouldSendMessages() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TEST_SEND_SHORTCUT_PROMPT"] = "1"
        app.launch()

        let commandEnter = anyElement("sendShortcut.commandEnter")
        let enter = anyElement("sendShortcut.enter")
        XCTAssertTrue(commandEnter.waitForExistence(timeout: 3))
        XCTAssertTrue(enter.exists)
        XCTAssertTrue(app.staticTexts["Choose how to send messages"].exists)
        XCTAssertTrue(
            staticTextWithValue(containing: "Settings → General → Conversation").exists
        )

        enter.click()
        XCTAssertFalse(commandEnter.exists)
    }

    func testHuggingFaceModelLibraryIsAvailableFromModelPicker() {
        let picker = anyElement("workspace.modelPicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.click()
        app.buttons["Browse Hugging Face Models…"].click()

        XCTAssertTrue(app.textFields["modelLibrary.search"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["modelLibrary.searchButton"].exists)
        XCTAssertTrue(app.buttons["modelLibrary.close"].exists)
        app.buttons["modelLibrary.close"].click()
    }

    func testHuggingFaceModelLibraryHandsOffFromSettings() {
        anyElement("workspace.modelPicker").click()
        anyElement("workspace.modelPicker.manageAccounts").click()

        let browse = anyElement("settings.accounts.browseHuggingFace")
        XCTAssertTrue(browse.waitForExistence(timeout: 3))
        browse.click()

        XCTAssertTrue(app.textFields["modelLibrary.search"].waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("settings.accounts.browseHuggingFace").exists)
        app.buttons["modelLibrary.close"].click()
    }

    func testHuggingFaceModelLibraryHandsOffFromNativeSettingsWindow() {
        app.typeKey(",", modifierFlags: .command)
        let accounts = anyElement("settings.page.accounts")
        XCTAssertTrue(accounts.waitForExistence(timeout: 3))
        accounts.click()

        let browse = anyElement("settings.accounts.browseHuggingFace")
        XCTAssertTrue(browse.waitForExistence(timeout: 3))
        browse.click()

        XCTAssertTrue(app.textFields["modelLibrary.search"].waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("settings.page.accounts").exists)
        app.buttons["modelLibrary.close"].click()
    }

    func testAccountInputRowsFocusAcrossTheirWidthAndPasteLeftToRight() {
        anyElement("workspace.modelPicker").click()
        anyElement("workspace.modelPicker.manageAccounts").click()
        anyElement("settings.accounts.add").click()
        app.menuItems["Custom endpoint"].click()

        let name = anyElement("accountEditor.name")
        let baseURL = anyElement("accountEditor.baseURL")
        let apiKey = anyElement("accountEditor.apiKey")
        let context = anyElement("accountEditor.contextWindow")
        XCTAssertTrue(name.waitForExistence(timeout: 3))

        func focusAndReplace(
            _ field: XCUIElement,
            with value: String,
            horizontalOffset: CGFloat,
            paste: Bool = false
        ) {
            field.coordinate(
                withNormalizedOffset: CGVector(dx: horizontalOffset, dy: 0.5)
            ).click()
            app.typeKey("a", modifierFlags: .command)
            if paste {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                app.typeKey("v", modifierFlags: .command)
            } else {
                app.typeText(value)
            }
        }

        // The far-left hit target must focus every row, even though the old
        // Form layout put the actual editor only in a trailing column.
        focusAndReplace(name, with: "Left", horizontalOffset: 0.02)
        XCTAssertEqual(name.value as? String, "Left")
        focusAndReplace(name, with: "Work", horizontalOffset: 0.5, paste: true)
        XCTAssertEqual(name.value as? String, "Work")

        focusAndReplace(baseURL, with: "h", horizontalOffset: 0.02)
        focusAndReplace(
            baseURL,
            with: "https://api.example.com/v1",
            horizontalOffset: 0.5,
            paste: true
        )
        XCTAssertEqual(baseURL.value as? String, "https://api.example.com/v1")

        focusAndReplace(apiKey, with: "x", horizontalOffset: 0.02)
        focusAndReplace(apiKey, with: "sk-test-secret", horizontalOffset: 0.5, paste: true)
        let masked = apiKey.value as? String ?? ""
        XCTAssertFalse(masked.isEmpty)
        XCTAssertNotEqual(masked, "sk-test-secret")

        focusAndReplace(context, with: "8", horizontalOffset: 0.02)
        focusAndReplace(context, with: "8192", horizontalOffset: 0.5, paste: true)
        XCTAssertEqual(context.value as? String, "8192")
        XCTAssertTrue(app.buttons["accountEditor.save"].isEnabled)

        // Avoid leaving a test credential in the developer's account file.
        app.buttons["accountEditor.cancel"].click()
    }

    func testModelPickerStaysResponsiveWithLongVLLMModelName() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_LONG_MODEL"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let originalFrame = app.windows.firstMatch.frame
        anyElement("workspace.modelPicker").click()

        XCTAssertTrue(anyElement("workspace.modelPicker.popover").waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "Qwen3.6-27B-Fable-Fusion")
            ).firstMatch.exists
        )
        XCTAssertTrue(anyElement("workspace.modelPicker.manageAccounts").exists)
        XCTAssertEqual(app.windows.firstMatch.frame, originalFrame)

        anyElement("workspace.modelPicker.close").click()
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["palette.search"].waitForExistence(timeout: 3))
    }

    func testSlashCommandPopupListsCommands() {
        let composer = app.textViews["composer.input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        composer.click()
        composer.typeText("/")

        XCTAssertTrue(anyElement("composer.slash.clear").waitForExistence(timeout: 2))

        // Escape dismisses the popup without clearing the draft.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(anyElement("composer.slash.clear").exists)
        app.typeKey(.delete, modifierFlags: [])
    }

    func testShortcutsSheetOpensWithCommandSlash() {
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(app.buttons["shortcuts.close"].waitForExistence(timeout: 3))
        app.buttons["shortcuts.close"].click()
    }

    func testKeyboardShortcutsHaveASettingsTabBelowExtensions() {
        anyElement("workspace.modelPicker").click()
        anyElement("workspace.modelPicker.manageAccounts").click()

        let extensions = anyElement("settings.page.extensions")
        let shortcuts = anyElement("settings.page.shortcuts")
        XCTAssertTrue(extensions.waitForExistence(timeout: 3))
        XCTAssertTrue(shortcuts.exists)
        XCTAssertLessThan(extensions.frame.maxY, shortcuts.frame.minY)

        shortcuts.click()
        XCTAssertTrue(anyElement("settings.shortcuts").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("shortcuts.reference").exists)
    }

    func testCommandPaletteNavigatesWithArrowKeys() {
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["palette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))

        search.typeText("shortcuts")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["shortcuts.close"].waitForExistence(timeout: 3))
        app.buttons["shortcuts.close"].click()
    }

    // MARK: - Inspector

    func testSidebarPlacesChatWorkAndExtensionsBelowTheBrand() {
        let brand = anyElement("sidebar.brand")
        let chat = app.buttons["workspace.mode.chat"]
        let work = app.buttons["workspace.mode.work"]
        let extensions = anyElement("sidebar.extensions")

        XCTAssertTrue(brand.waitForExistence(timeout: 3))
        XCTAssertTrue(chat.exists)
        XCTAssertTrue(work.exists)
        XCTAssertTrue(extensions.exists)
        XCTAssertLessThan(brand.frame.maxY, chat.frame.minY)
        XCTAssertLessThan(chat.frame.maxY, extensions.frame.minY)

        extensions.click()
        XCTAssertTrue(anyElement("extensions.tab.installed").waitForExistence(timeout: 3))
    }

    func testRunAwarenessControlsAreVisibleAndJustChatHidesAgenticWorkspaceUI() {
        let chat = app.buttons["workspace.mode.chat"]
        let work = app.buttons["workspace.mode.work"]
        XCTAssertTrue(chat.waitForExistence(timeout: 3))
        XCTAssertTrue(work.exists)
        XCTAssertTrue(work.isSelected)

        chat.click()
        XCTAssertTrue(chat.isSelected)
        XCTAssertTrue(anyElement("composer.justChatBoundary").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("composer.chatAttachments").exists)
        XCTAssertTrue(app.buttons["composer.addChatAttachment"].exists)
        XCTAssertFalse(anyElement("composer.context").exists)
        XCTAssertFalse(anyElement("composer.mode.plan").exists)
        XCTAssertFalse(anyElement("composer.mode.build").exists)
        XCTAssertFalse(anyElement("plan.contextWindow").exists)
        // Just Chat is not a workspace surface, so the rail goes with the
        // panel — the whole right side disappears.
        XCTAssertFalse(anyElement("inspector.rail.toggle").exists)

        XCTAssertTrue(
            anyElement("turnCompletion.00000000-0000-0000-0000-000000000103")
                .waitForExistence(timeout: 3)
        )

        app.typeKey("1", modifierFlags: .command)
        XCTAssertFalse(anyElement("plan.contextWindow").exists)

        work.click()
        XCTAssertTrue(work.isSelected)
        XCTAssertTrue(anyElement("composer.mode.plan").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("composer.mode.build").exists)
        XCTAssertTrue(anyElement("plan.contextWindow").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.rail.toggle").exists, "the rail returns with agentic modes")
    }

    func testInspectorButtonAlwaysOpensTheWorkspacePanelThenTogglesIt() {
        let toggle = anyElement("inspector.rail.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))

        // The seeded panel starts on Plan. The general panel button must not
        // restore that special-purpose tab; it opens the workspace strip.
        toggle.click()
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("plan.contextWindow").exists)

        // A second press closes the workspace panel; the rail stays.
        toggle.click()
        XCTAssertFalse(anyElement("changes.file.0").exists)
        XCTAssertTrue(toggle.exists)

        toggle.click()
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
    }

    func testRailIconsOpenAndTogglePanels() {
        // The suite seeds the panel open on Plan; the Plan icon's second
        // click collapses, its next click reopens.
        let planIcon = anyElement("inspector.rail.plan")
        XCTAssertTrue(planIcon.waitForExistence(timeout: 3))
        planIcon.click()
        XCTAssertFalse(anyElement("plan.contextWindow").exists)
        XCTAssertTrue(anyElement("inspector.rail.toggle").exists)

        // A different tab's icon opens the panel straight onto that tab.
        let browserIcon = anyElement("inspector.rail.preview")
        XCTAssertTrue(browserIcon.exists)
        browserIcon.click()
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))
    }

    func testRailMoreMenuReachesOverflowTabs() {
        let more = anyElement("inspector.rail.more")
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        let zoom = anyElement("inspector.zoom")
        XCTAssertTrue(zoom.exists)
        XCTAssertGreaterThan(zoom.frame.minY, more.frame.minY, "expand belongs at the rail bottom")
        more.click()

        XCTAssertFalse(anyElement("inspector.rail.menu.settings").exists)

        let changes = app.menuItems.matching(
            NSPredicate(format: "identifier == %@", "inspector.rail.menu.changes")
        ).firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 3))
        changes.click()
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
    }

    func testBrowserExpandsInPlaceAndRestores() {
        // ⌘5 opens the Browser tab; its top controls bar carries the expand
        // control.
        app.typeKey("5", modifierFlags: .command)
        let expand = anyElement("browser.expand")
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        expand.click()

        // Zoomed: the rail's zoom button flips to "restore" and the session
        // sidebar hands its room to the panel.
        let zoom = anyElement("inspector.zoom")
        XCTAssertTrue(zoom.waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("sidebar.brand").exists)

        zoom.click()
        XCTAssertTrue(anyElement("sidebar.brand").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("browser.url").exists)
    }

    func testInspectorTabsSwitchWithCommandNumberShortcuts() {
        // ⌘2 — Changes, populated from the seeded git status.
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))

        // ⌘3 — Files, populated from the seeded workspace index.
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(anyElement("files.row.0").waitForExistence(timeout: 3))

        // ⌘4 — the native PTY terminal.
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("terminal.empty").exists)

        // ⌘5 — Browser. The address bar is unconditional chrome, so unlike the
        // old Preview tab this needs no seeded page to assert on.
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("browser.empty").exists)

        // ⌘6 — Checkpoints, with its own creation and history panel.
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(anyElement("checkpointTab.content").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("checkpointTab.create").exists)

        // ⌘8 — AGENTS.md, with an explanation and the workspace editor.
        app.typeKey("8", modifierFlags: .command)
        XCTAssertTrue(anyElement("agents.content").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("agents.editor").exists)
        XCTAssertTrue(anyElement("agents.save").exists)

        // ⌘1 — back to Plan, which shows its empty state (no seeded todos).
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(anyElement("plan.create").waitForExistence(timeout: 3))
    }

    func testPlanTabOrdersContextThenActivePlanThenPermissions() {
        let context = anyElement("plan.contextWindow")
        let activePlan = anyElement("plan.activePlan")
        let permissionControl = anyElement("plan.permissionMode")
        let window = app.windows.firstMatch

        XCTAssertTrue(context.waitForExistence(timeout: 3))
        XCTAssertTrue(activePlan.exists)
        XCTAssertTrue(permissionControl.exists)
        XCTAssertLessThan(context.frame.minY, activePlan.frame.minY)
        XCTAssertLessThan(activePlan.frame.minY, permissionControl.frame.minY)
        XCTAssertLessThan(
            window.frame.maxY - permissionControl.frame.maxY,
            110,
            "Permissions should stay anchored at the bottom of the inspector"
        )
        XCTAssertFalse(anyElement("checkpointTab.content").exists)
    }

    func testChangesTabShowsSeededWorkingTreeAndOpensADiff() {
        app.typeKey("2", modifierFlags: .command)

        let firstFile = anyElement("changes.file.0")
        XCTAssertTrue(firstFile.waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("changes.summary").exists)
        XCTAssertTrue(app.buttons["changes.refresh"].exists)
        XCTAssertTrue(anyElement("changes.branch").exists)
        XCTAssertTrue(anyElement("changes.sync.counts").exists)

        firstFile.click()
        // The seeded diff parses into hunks, so per-hunk controls replace the
        // flat diff for this file.
        XCTAssertTrue(anyElement("changes.file.0.hunks").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("changes.file.0.hunk.0.stage").exists)
        XCTAssertTrue(anyElement("changes.file.0.hunk.1.discard").exists)
    }

    func testDiscardingAHunkAsksForConfirmationFirst() {
        app.typeKey("2", modifierFlags: .command)

        let firstFile = anyElement("changes.file.0")
        XCTAssertTrue(firstFile.waitForExistence(timeout: 3))
        firstFile.click()
        let discard = anyElement("changes.file.0.hunk.0.discard")
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        let changesScroll = anyElement("changes.scroll")
        XCTAssertTrue(changesScroll.exists)
        if !discard.isHittable {
            // Expanding the inline diff can leave its first hunk action under
            // a scroll edge on smaller CI windows. Move the containing scroll
            // view explicitly instead of relying on XCUI's implicit scroll,
            // which is unreliable for nested SwiftUI buttons on macOS.
            changesScroll.scroll(byDeltaX: -120, deltaY: 180)
        }
        XCTAssertTrue(discard.isHittable)
        discard.click()

        XCTAssertTrue(app.buttons["changes.discardHunk.confirm"].waitForExistence(timeout: 3))
        // Escape targets the active confirmation reliably on macOS 26. A title
        // query can resolve to the mirrored Touch Bar cancel button instead.
        app.typeKey(.escape, modifierFlags: [])
    }

    func testRemoteButtonsFollowTheSeededAvailability() {
        app.typeKey("2", modifierFlags: .command)

        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
        // The seeded run does not mark origin as GitHub, so the PR button
        // must stay hidden regardless of build flavor.
        XCTAssertFalse(anyElement("changes.pr").exists)
    }

    func testFilesTabFiltersTheWorkspaceIndex() {
        app.typeKey("3", modifierFlags: .command)

        let search = app.textFields["files.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("TerminalSession")

        let firstRow = anyElement("files.row.0")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("files.row.1").exists)
    }

    func testTerminalIsAvailableWithoutTheAgent() {
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(anyElement("terminal.header").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("terminal.output").exists)
        XCTAssertFalse(app.textFields["terminal.command"].exists)
    }

    // MARK: - Permission prompt

    /// Relaunches with the opt-in pending-permission fixture. It is not part
    /// of the base seed because a pending request disables send and
    /// clear-chat, which would break the rest of the suite.
    private func relaunchWithPendingPermission() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_PERMISSION"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithRunFixture(
        _ fixture: String,
        uncleanRecovery: Bool = false,
        staleQuitState: Bool = false
    ) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_RUN_FIXTURE"] = fixture
        app.launchEnvironment["LOCUS_UI_TESTING_UNCLEAN_RECOVERY"] = uncleanRecovery ? "1" : nil
        app.launchEnvironment["LOCUS_UI_TESTING_STALE_QUIT_STATE"] = staleQuitState ? "1" : nil
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    func testCompletedRunWithLargeTimelineRemainsResponsiveAndRestoresAfterForceQuit() {
        relaunchWithRunFixture("completed", uncleanRecovery: true)

        let state = anyElement("runs.state")
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertTrue((state.label + " \(state.value ?? "")").lowercased().contains("completed"))
        XCTAssertFalse(anyElement("runs.recoveryExplanation").exists)
        XCTAssertTrue(anyElement("teamBoard.terminalSummary").exists)

        let activity = anyElement("runs.view.activity")
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        activity.click()
        let filter = app.textFields["runs.filter"]
        filter.click()
        filter.typeText("Team run completed")
        XCTAssertEqual(filter.value as? String, "Team run completed")

        // Exercise controls after the 1,200-event timeline has laid out.
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(anyElement("plan.create").waitForExistence(timeout: 3))
        app.typeKey("7", modifierFlags: .command)
        XCTAssertTrue(anyElement("runs.state").waitForExistence(timeout: 3))
    }

    func testForcedQuitRecoveryExplainsAResumableRun() {
        relaunchWithRunFixture("recoverable", uncleanRecovery: true)

        XCTAssertFalse(anyElement("runs.recoveryExplanation").exists)
        XCTAssertTrue(anyElement("teamBoard.resume").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("teamBoard.discard").exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "can be resumed", "can be resumed")
            ).firstMatch.exists
        )
    }

    func testCompletedRunQuitsWithoutAStopRunningWarningFromStaleState() {
        relaunchWithRunFixture("completed", staleQuitState: true)

        app.typeKey("q", modifierFlags: .command)

        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 5),
            "a durable completed run must not be mistaken for active work"
        )
    }

    func testDispatcherRepairIsVisibleInProgressAndRuns() {
        relaunchWithRunFixture("dispatcher-repair")

        XCTAssertTrue(anyElement("teamDispatch.progress").waitForExistence(timeout: 3))
        let progress = anyElement("workspace.teamProgress")
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        progress.click()
        XCTAssertTrue(anyElement("teamProgress.popover").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("teamBoard.seed-run").waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                    "Correcting dispatcher plan",
                    "Correcting dispatcher plan"
                )
            ).firstMatch.exists
        )

        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                    "dispatcher plan has no jobs",
                    "dispatcher plan has no jobs"
                )
            ).firstMatch.waitForExistence(timeout: 3)
        )
    }

    func testTeamPlanAppearsOnceInConversationWithWholePlanActions() {
        relaunchWithRunFixture("dispatch-plan")

        XCTAssertTrue(anyElement("teamDispatch.approval").waitForExistence(timeout: 3))
        XCTAssertTrue(app.textViews["composer.input"].exists)
        XCTAssertTrue(anyElement("teamDispatch.jobs").exists)
        XCTAssertTrue(anyElement("teamDispatch.run").exists)
        XCTAssertTrue(anyElement("teamDispatch.redispatch").exists)
        XCTAssertTrue(anyElement("teamDispatch.cancel").exists)
        XCTAssertTrue(anyElement("workspace.teamProgress").exists)
    }

    func testPermissionPanelRepliesWithTheKeyboard() {
        relaunchWithPendingPermission()

        let panel = anyElement("permission.panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        // The prompt replaces the input entirely while it waits.
        XCTAssertFalse(app.textViews["composer.input"].exists)
        XCTAssertTrue(anyElement("permission.once").exists)
        XCTAssertTrue(anyElement("permission.always").exists)
        XCTAssertTrue(anyElement("permission.deny").exists)

        panel.click()
        app.typeKey("2", modifierFlags: [])

        XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("permission.panel").exists)
    }

    func testPermissionPanelEscapeDeniesAndReturnsFocusForFeedback() {
        relaunchWithPendingPermission()

        let panel = anyElement("permission.panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        panel.click()
        app.typeKey(.escape, modifierFlags: [])

        let composer = app.textViews["composer.input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))

        // Typing lands in the editor without another click: focus must come
        // back on its own so "tell Locus what to do differently" just works.
        app.typeText("use a dry run instead")
        XCTAssertTrue((composer.value as? String)?.contains("use a dry run instead") == true)
    }
}
