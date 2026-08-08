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

        app.buttons["Activity"].firstMatch.click()
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
