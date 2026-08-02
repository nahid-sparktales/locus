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

    /// SwiftUI `Menu` controls surface as MenuButton (not Button) on current
    /// macOS, so menu anchors are matched by identifier on any element type.
    /// Identifiers can propagate to nested elements, so take the first match —
    /// interactions on an ambiguous query fail outright.
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
        anyElement("workspace.commandPalette").click()
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
        current.rightClick()

        XCTAssertTrue(app.menuItems["Rename…"].exists)
        XCTAssertTrue(app.menuItems["Unpin"].exists)
        XCTAssertTrue(app.menuItems["Export Markdown…"].exists)
        XCTAssertTrue(app.menuItems["Archive"].exists)
        app.typeKey(.escape, modifierFlags: [])

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
        app.menuItems["Manage Accounts…"].click()

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

    func testHuggingFaceModelLibraryIsAvailableFromModelPicker() {
        let picker = anyElement("workspace.modelPicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.click()
        app.menuItems["Browse Hugging Face Models…"].click()

        XCTAssertTrue(app.textFields["modelLibrary.search"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["modelLibrary.searchButton"].exists)
        XCTAssertTrue(app.buttons["modelLibrary.close"].exists)
        app.buttons["modelLibrary.close"].click()
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
        XCTAssertFalse(anyElement("inspector.tab.plan").exists)
        XCTAssertFalse(anyElement("workspace.showInspector").exists)

        XCTAssertTrue(
            anyElement("turnCompletion.00000000-0000-0000-0000-000000000103")
                .waitForExistence(timeout: 3)
        )

        app.typeKey("1", modifierFlags: .command)
        XCTAssertFalse(anyElement("inspector.tab.plan").exists)

        work.click()
        XCTAssertTrue(work.isSelected)
        XCTAssertTrue(anyElement("composer.mode.plan").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("composer.mode.build").exists)
        XCTAssertTrue(anyElement("plan.contextWindow").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("workspace.showInspector").exists)
    }

    func testInspectorCollapsesAndRestoresFromWorkspaceHeader() {
        let collapse = anyElement("inspector.collapse")
        XCTAssertTrue(collapse.waitForExistence(timeout: 3))
        collapse.click()

        let restore = anyElement("workspace.showInspector")
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("inspector.tab.plan").exists)

        restore.click()
        XCTAssertTrue(anyElement("inspector.tab.plan").waitForExistence(timeout: 3))
    }

    func testInspectorTabsSwitchWithCommandNumberShortcuts() {
        // ⌘2 — Changes, populated from the seeded git status.
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))

        // ⌘3 — Files, populated from the seeded workspace index.
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(anyElement("files.row.0").waitForExistence(timeout: 3))

        // ⌘4 — Console, which has seeded output rather than its empty state.
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("terminal.empty").exists)

        // ⌘6 — Checkpoints, with its own creation and history panel.
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(anyElement("checkpointTab.content").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("checkpointTab.create").exists)

        // ⌘7 — AGENTS.md, with an explanation and the workspace editor.
        app.typeKey("7", modifierFlags: .command)
        XCTAssertTrue(anyElement("agents.content").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("agents.editor").exists)
        XCTAssertTrue(anyElement("agents.save").exists)

        // ⌘8 — durable LangGraph workflows and recovery controls.
        app.typeKey("8", modifierFlags: .command)
        XCTAssertTrue(anyElement("workflows.content").waitForExistence(timeout: 3))

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

    func testGraphStudioCanPinAnInstalledLocalOllamaModel() {
        let engine = anyElement("composer.executionEngine")
        XCTAssertTrue(engine.waitForExistence(timeout: 3))
        engine.click()
        XCTAssertTrue(app.menuItems["LangGraph"].waitForExistence(timeout: 2))
        app.menuItems["LangGraph"].click()

        app.typeKey("8", modifierFlags: .command)
        let openStudio = anyElement("workflows.openStudio")
        XCTAssertTrue(openStudio.waitForExistence(timeout: 3))
        openStudio.click()

        let finalNode = anyElement("graphStudio.node.final")
        XCTAssertTrue(finalNode.waitForExistence(timeout: 3))
        finalNode.click()

        let source = anyElement("graphStudio.modelSource")
        XCTAssertTrue(source.waitForExistence(timeout: 3))
        source.click()
        XCTAssertTrue(app.menuItems["Local Ollama"].waitForExistence(timeout: 2))
        app.menuItems["Local Ollama"].click()

        XCTAssertTrue(anyElement("graphStudio.localModel").waitForExistence(timeout: 2))
        XCTAssertTrue(anyElement("graphStudio.localModels").exists)
    }

    func testChangesTabShowsSeededWorkingTreeAndOpensADiff() {
        app.typeKey("2", modifierFlags: .command)

        let firstFile = anyElement("changes.file.0")
        XCTAssertTrue(firstFile.waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("changes.summary").exists)
        XCTAssertTrue(app.buttons["changes.refresh"].exists)

        firstFile.click()
        XCTAssertTrue(anyElement("changes.file.0.diff").waitForExistence(timeout: 3))
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

    func testConsoleReportsThatItCannotReachTheAgent() {
        app.typeKey("4", modifierFlags: .command)

        let command = app.textFields["terminal.command"]
        XCTAssertTrue(command.waitForExistence(timeout: 3))
        command.click()
        command.typeText("git status")
        app.typeKey(.return, modifierFlags: [])

        // No agent is running under test, so the console must say so rather
        // than sit there claiming to run.
        XCTAssertTrue(
            staticTextWithValue(containing: "Reconnect the local agent")
                .waitForExistence(timeout: 3)
                || app.staticTexts["Reconnect the local agent to run commands."]
                    .waitForExistence(timeout: 1)
        )
        XCTAssertTrue(app.buttons["terminal.run"].exists)
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
