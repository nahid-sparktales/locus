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

        // Select the most recently launched Locus copy so this also works when
        // the suite uses an isolated bundle identifier alongside a developer
        // build that is already running.
        let running = try XCTUnwrap(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleURL?.lastPathComponent == "Locus.app" }
                .max {
                    ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast)
                }
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
        XCTAssertFalse(anyElement("settings.enterSendsMessages").exists)
        XCTAssertTrue(anyElement("settings.soloPlanPresentation").exists)
        XCTAssertTrue(anyElement("settings.teamRunsPresentation").exists)
    }

    func testAppearanceSettingsExposeAndApplySystemLightDarkChoices() {
        app.typeKey(",", modifierFlags: .command)

        let picker = anyElement("settings.appearance")
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        for value in ["system", "light", "dark"] {
            let choice = anyElement("settings.appearance.\(value)")
            XCTAssertTrue(choice.exists, "Missing \(value) appearance choice")
            XCTAssertTrue(choice.isHittable, "\(value) appearance choice is not selectable")
            choice.click()
            XCTAssertEqual(picker.value as? String, value)
        }

        app.buttons["settings.save"].click()
        XCTAssertFalse(picker.exists)

        // UI-test models do not persist to disk, but the saved in-memory
        // preference must still drive both scenes for the rest of the launch.
        app.typeKey(",", modifierFlags: .command)
        let dark = anyElement("settings.appearance.dark")
        XCTAssertTrue(dark.waitForExistence(timeout: 3))
        XCTAssertEqual(anyElement("settings.appearance").value as? String, "dark")
        app.buttons["settings.cancel"].click()
    }

    func testBackgroundChatAndWorktreeControlsAreReachable() {
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(anyElement("settings.maximumActiveChats").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("settings.newGitChatsUseWorktree").exists)
        XCTAssertTrue(anyElement("settings.worktreeRetentionLimit").exists)
        app.buttons["settings.cancel"].click()

        XCTAssertFalse(anyElement("workspace.environment").exists)
        let actions = anyElement("workspace.actions")
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.click()
        XCTAssertTrue(app.menuItems["Start Worktree Chat From"].exists)
        XCTAssertTrue(app.menuItems["Start New Local Chat"].exists)
        app.menuItems["Start Worktree Chat From"].hover()
        XCTAssertTrue(
            anyElement("workspace.actions.worktree.head").waitForExistence(timeout: 2)
        )
        XCTAssertTrue(anyElement("workspace.actions.worktree.branch.main").exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testLaunchDoesNotAskForAMessageShortcut() {
        XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("sendShortcut.commandEnter").exists)
        XCTAssertFalse(anyElement("sendShortcut.enter").exists)
        XCTAssertFalse(app.staticTexts["Choose how to send messages"].exists)
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
        XCTAssertFalse(anyElement("inspector.rail.more").exists)
        XCTAssertFalse(anyElement("inspector.rail.terminal").exists)

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
        XCTAssertTrue(anyElement("inspector.rail.more").exists, "the rail returns with agentic modes")
    }

    func testRailOverflowReplacesSettingsAndSidebarSettingsMenuIsRestored() {
        let more = anyElement("inspector.rail.more")
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("inspector.rail.settings").exists)
        XCTAssertFalse(anyElement("inspector.rail.toggle").exists)

        let settingsMenu = anyElement("sidebar.more")
        XCTAssertTrue(settingsMenu.waitForExistence(timeout: 3))
        settingsMenu.click()
        app.menuItems["sidebar.settings"].click()
        XCTAssertTrue(anyElement("settings.page.general").waitForExistence(timeout: 3))
        app.buttons["settings.cancel"].click()
    }

    func testRailIconsOpenAndTogglePanels() {
        // The suite seeds the panel open on Plan; the Plan icon's second
        // click collapses, its next click reopens.
        let planIcon = anyElement("inspector.rail.plan")
        XCTAssertTrue(planIcon.waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.plan").exists)
        for closedTab in ["changes", "files", "terminal", "preview", "checkpoints", "runs", "agents"] {
            XCTAssertFalse(
                anyElement("inspector.tab.\(closedTab)").exists,
                "the old permanent inspector strip must not expose \(closedTab)"
            )
        }
        planIcon.click()
        XCTAssertFalse(anyElement("plan.contextWindow").exists)
        XCTAssertTrue(anyElement("inspector.rail.more").exists)

        // Terminal is a direct rail destination and closes on a second click.
        let terminalIcon = anyElement("inspector.rail.terminal")
        XCTAssertTrue(terminalIcon.exists)
        terminalIcon.click()
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.terminal").exists)
        terminalIcon.click()
        XCTAssertFalse(anyElement("terminal.output").exists)

        // A different tab's icon opens the panel straight onto that tab.
        let browserIcon = anyElement("inspector.rail.preview")
        XCTAssertTrue(browserIcon.exists)
        browserIcon.click()
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.plan").exists)
        XCTAssertTrue(anyElement("inspector.tab.terminal").exists)
        XCTAssertTrue(anyElement("inspector.tab.preview").exists)
    }

    func testRailMoreMenuReachesOverflowTabs() {
        let more = anyElement("inspector.rail.more")
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        let zoom = anyElement("inspector.zoom")
        XCTAssertTrue(zoom.exists)
        let terminal = anyElement("inspector.rail.terminal")
        XCTAssertLessThan(more.frame.maxY, terminal.frame.minY, "overflow belongs at the rail top")
        XCTAssertGreaterThan(zoom.frame.minY, more.frame.minY, "expand belongs at the rail bottom")
        more.click()

        XCTAssertFalse(anyElement("inspector.rail.menu.settings").exists)
        XCTAssertFalse(anyElement("inspector.rail.menu.terminal").exists)

        let changes = app.menuItems.matching(
            NSPredicate(format: "identifier == %@", "inspector.rail.menu.changes")
        ).firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 3))
        changes.click()
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.plan").exists)
        XCTAssertTrue(anyElement("inspector.tab.changes").exists)
        XCTAssertFalse(anyElement("inspector.tab.files").exists)

        // A second menu destination appends to the dynamic bar instead of
        // replacing the first or exposing every destination permanently.
        more.click()
        let files = app.menuItems.matching(
            NSPredicate(format: "identifier == %@", "inspector.rail.menu.files")
        ).firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 3))
        files.click()
        XCTAssertTrue(anyElement("files.search").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.files").exists)

        // Existing tabs switch in place and an active close selects the tab to
        // its right (Files here) without collapsing the inspector.
        anyElement("inspector.tab.changes").click()
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
        anyElement("inspector.tab.close.changes").click()
        XCTAssertFalse(anyElement("inspector.tab.changes").exists)
        XCTAssertFalse(anyElement("changes.file.0").exists)
        XCTAssertTrue(anyElement("files.search").exists)

        anyElement("inspector.tab.close.plan").click()
        anyElement("inspector.tab.close.files").click()
        XCTAssertTrue(anyElement("inspector.tabBar").waitForNonExistence(timeout: 3))
        XCTAssertFalse(anyElement("files.search").exists)
        XCTAssertTrue(anyElement("inspector.rail.more").exists)
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

        let handle = anyElement("inspector.resizeHandle")
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        XCTAssertEqual(handle.label, "Expanded panel resize grip")
        XCTAssertGreaterThanOrEqual(handle.frame.width, 12)

        let originalDividerX = handle.frame.midX
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.1,
            thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0))
        )
        let dividerMovedRight = NSPredicate { candidate, _ in
            guard let element = candidate as? XCUIElement else { return false }
            return element.frame.midX > originalDividerX + 20
        }
        expectation(for: dividerMovedRight, evaluatedWith: handle)
        waitForExpectations(timeout: 3)

        let rightwardDividerX = handle.frame.midX
        let secondStart = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        secondStart.press(
            forDuration: 0.1,
            thenDragTo: secondStart.withOffset(CGVector(dx: -30, dy: 0))
        )
        let dividerMovedLeft = NSPredicate { candidate, _ in
            guard let element = candidate as? XCUIElement else { return false }
            return element.frame.midX < rightwardDividerX - 10
        }
        expectation(for: dividerMovedLeft, evaluatedWith: handle)
        waitForExpectations(timeout: 3)
        let persistedDividerX = handle.frame.midX

        zoom.click()
        XCTAssertTrue(anyElement("sidebar.brand").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("browser.url").exists)
        XCTAssertEqual(handle.label, "Resize inspector divider")

        anyElement("browser.expand").click()
        XCTAssertEqual(handle.label, "Expanded panel resize grip")
        let dividerReturned = NSPredicate { candidate, _ in
            guard let element = candidate as? XCUIElement else { return false }
            return abs(element.frame.midX - persistedDividerX) <= 4
        }
        expectation(for: dividerReturned, evaluatedWith: handle)
        waitForExpectations(timeout: 3)
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

    private func relaunchWithLandingFixture() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_LANDING"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithScrollFixture() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_SCROLL"] = "1"
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

    func testActivityDestinationShowsBackgroundRunAndReturnsToChat() {
        relaunchWithRunFixture("activity")

        let destination = anyElement("sidebar.activity")
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        XCTAssertTrue("\(destination.value ?? "")".contains("1 needs attention"))
        destination.click()
        XCTAssertTrue(anyElement("activity.center").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("activity.run.seed-run").waitForExistence(timeout: 3))
        XCTAssertTrue("\(destination.value ?? "")".contains("No new activity"))

        anyElement("session.seed-current").click()
        XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("activity.center").exists)

        destination.click()
        let remove = anyElement("activity.remove.seed-run")
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.click()
        XCTAssertTrue(app.staticTexts["No Activity Yet"].waitForExistence(timeout: 3))
    }

    func testTranscriptScrollsContinuouslyAcrossToolAndReasoningBlocks() {
        relaunchWithScrollFixture()

        let transcript = anyElement("conversation.scroll")
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
        let firstTool = anyElement("tool.scroll-tool-0.toggle")
        XCTAssertTrue(firstTool.waitForExistence(timeout: 3))
        firstTool.click()

        // Begin the gesture over selectable tool output. It must continue on
        // the transcript instead of being swallowed by the nested responder.
        firstTool.scroll(byDeltaX: 0, deltaY: -2_400)
        let lastTool = anyElement("tool.scroll-tool-11.toggle")
        XCTAssertTrue(lastTool.waitForExistence(timeout: 3))
        lastTool.click()

        lastTool.scroll(byDeltaX: 0, deltaY: 2_400)
        let firstMessage = anyElement("message.00000000-0000-0000-0000-000000000101")
        XCTAssertTrue(firstMessage.waitForExistence(timeout: 3))
        XCTAssertTrue(firstMessage.isHittable)
    }

    func testReviewAndLandShowsDiffChecksAndBothDestinations() {
        relaunchWithLandingFixture()

        let review = anyElement("workspace.reviewAndLand")
        XCTAssertTrue(review.waitForExistence(timeout: 3))
        review.click()
        XCTAssertTrue(anyElement("landing.diff").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("landing.checkCommands").exists)
        XCTAssertTrue(anyElement("landing.runChecks").exists)
        XCTAssertTrue(anyElement("landing.destination").exists)

        let branchDestination = app.radioButtons["Branch, Commit & PR"].firstMatch
        XCTAssertTrue(branchDestination.exists)
        branchDestination.click()
        XCTAssertTrue(anyElement("landing.branch").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("landing.commitMessage").exists)
        XCTAssertTrue(anyElement("landing.confirm").exists)
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
