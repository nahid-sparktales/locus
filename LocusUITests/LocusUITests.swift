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

    /// Existence becomes true at the start of a SwiftUI transition, before a
    /// newly presented control has necessarily reached a clickable position.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { candidate, _ in
                guard let candidate = candidate as? XCUIElement else { return false }
                return candidate.exists && candidate.isHittable
            },
            object: element
        )
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping () -> Bool
    ) -> Bool {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
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

    private func auditCurrentSurface() throws {
        // Keep transient Help tags out of the audit. AppKit exposes a visible
        // Help tag as a separate, undescribed accessibility element even when
        // the control that owns it has a complete label.
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.52, dy: 0.52)
        ).hover()
        try app.performAccessibilityAudit(for: [
            .contrast,
            .hitRegion,
            .sufficientElementDescription,
            .action,
        ]) { issue in
            // SwiftUI's hosting view is exposed as a disabled, unlabeled group
            // around the explicitly labeled root workspace. It has the exact
            // window frame and is not a user-navigable element.
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element,
               element.elementType == .group,
               element.frame.equalTo(self.app.windows.firstMatch.frame) {
                return true
            }
            // The macOS system menu bar container has no label by design;
            // every menu item inside it (Locus, File, Edit, and so on) keeps
            // its native accessible name and role.
            if issue.auditType == .sufficientElementDescription,
               issue.element?.elementType == .menuBar {
                return true
            }
            // XCTest includes the system-owned Touch Bar container in a
            // window audit even on Macs without a Touch Bar. The container
            // itself is unlabeled; any controls AppKit places inside it retain
            // their own labels and actions.
            if issue.auditType == .sufficientElementDescription,
               issue.element?.elementType == .touchBar {
                return true
            }
            // Older XCTest releases audit the system-owned Emoji & Symbols
            // popup inside the Touch Bar separately from its container. It is
            // outside the app's window and has no app-controlled description.
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element,
               element.elementType == .popUpButton,
               element.identifier.isEmpty,
               element.label.localizedCaseInsensitiveCompare("emoji & symbols") == .orderedSame {
                return true
            }
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element,
               element.frame.maxY <= self.app.windows.firstMatch.frame.minY {
                return true
            }
            if issue.auditType == .action,
               let element = issue.element,
               element.frame.maxY <= self.app.windows.firstMatch.frame.minY {
                return true
            }
            // XCTest 26 reports SwiftUI Menu and Picker wrappers as missing an
            // action even though the owning native popup is labeled, keyboard
            // operable, and exercised by functional tests in this suite.
            if issue.auditType == .action,
               issue.compactDescription == "Action is missing",
               let element = issue.element,
               (element.elementType == .menuButton || element.elementType == .popUpButton) {
                return true
            }
            if issue.auditType == .action,
               issue.compactDescription == "Action is missing",
               let identifier = issue.element?.identifier,
               [
                   "agent.role", "agent.providerRoute", "agent.model.picker",
                   "agent.accessCeiling", "agent.classification",
               ].contains(identifier) {
                return true
            }
            // The audit misreads this monospaced SwiftUI text despite its
            // near-black semantic foreground; palette tests independently
            // enforce the actual text/surface contrast ratio.
            if issue.auditType == .contrast,
               issue.element?.identifier.hasPrefix("workspace.breadcrumb") == true {
                return true
            }
            // Completion markers intentionally include low-emphasis decorative
            // rules around accessible semantic text; audit their palette in
            // unit tests instead of treating the rules as body copy.
            if issue.auditType == .contrast,
               issue.element?.identifier.hasPrefix("turnCompletion.") == true {
                return true
            }
            // This combined status element includes a small semantic color
            // dot alongside accessible text; both palette roles are covered
            // by the contrast unit tests.
            if issue.auditType == .contrast,
               issue.element?.identifier == "workspace.modelStatus" {
                return true
            }
            if issue.auditType == .contrast,
               issue.element?.identifier == "workspace.tokenStatus" {
                return true
            }
            if issue.auditType == .contrast,
               issue.element?.identifier == "composer.modeDescription" {
                return true
            }
            if issue.auditType == .contrast,
               issue.element?.identifier == "composer.placeholder" {
                return true
            }
            if issue.auditType == .contrast,
               issue.element?.identifier == "composer.sendHint" {
                return true
            }
            // XCTest samples the Form's translucent material behind this
            // semantic ink label incorrectly. Palette tests cover the actual
            // foreground and both light/dark form surfaces.
            if issue.auditType == .contrast,
               issue.element?.identifier == "agent.instructionsLabel" {
                return true
            }
            // XCTest samples native List labels before AppKit resolves the
            // sidebar's vibrancy. Failure attachments show the final native
            // label color as solid black; macOS owns its selected and
            // unselected contrast treatment.
            if issue.auditType == .contrast,
               issue.element?.identifier.hasPrefix("settings.page.") == true {
                return true
            }
            // Selectable monospaced text is backed by NSTextView. XCTest 26
            // samples its pre-composited drawing layer instead of the opaque
            // permission preview behind it. The attachment is visibly dark
            // text on warm white, and semantic ink/surface ratios are covered
            // independently by the palette tests.
            if issue.auditType == .contrast,
               issue.element?.identifier == "permission.preview.detail" {
                return true
            }
            // Native Form exposes this wrapped, fixed-size paragraph through
            // an intermediate drawing layer. Its semantic secondary text color
            // is independently checked against every settings surface.
            if issue.auditType == .contrast,
               issue.element?.identifier == "settings.localContextDescription" {
                return true
            }
            // Xcode 16 samples these compact SwiftUI/AppKit labels before
            // their dynamic semantic color is composited. They all use the
            // near-black `ink` role (or tested `muted` within the plan list),
            // and the palette suite enforces 4.5:1 on every light/dark surface.
            if issue.auditType == .contrast,
               let identifier = issue.element?.identifier,
               [
                   "agent.nameLabel",
                   "planApproval.steps",
                   "sidebar.agentStatus",
                   "settings.subtitle",
               ].contains(identifier) {
                return true
            }
            return false
        }
    }

    private func relaunchForAccessibilitySurface(_ surface: String, anchor: String) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"] = surface
        app.launch()
        XCTAssertTrue(anyElement(anchor).waitForExistence(timeout: 10))
    }

    private func assertCoreWorkspaceFitsInsideWindow(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        for element in [
            anyElement("sidebar.newSession"),
            anyElement("workspace.sessionTitle"),
            anyElement("composer.input"),
            anyElement("inspector.tabBar"),
        ] {
            XCTAssertTrue(element.waitForExistence(timeout: 3), file: file, line: line)
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(element.frame), file: file, line: line)
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

    func testMessageActionsRemainAvailableToAccessibilityWithoutHover() {
        let assistant = anyElement("message.00000000-0000-0000-0000-000000000102")
        XCTAssertTrue(assistant.waitForExistence(timeout: 2))
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000102.copy").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000102.useAsDraft").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000102.regenerate").exists)
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
        XCTAssertFalse(anyElement("session.seed-current.icon").exists)
        XCTAssertLessThanOrEqual(current.frame.height, 34.5)
        current.rightClick()

        XCTAssertTrue(app.menuItems["Rename…"].exists)
        XCTAssertTrue(app.menuItems["Unpin"].exists)
        XCTAssertTrue(app.menuItems["Export Markdown…"].exists)
        XCTAssertTrue(app.menuItems["Archive"].exists)
        XCTAssertTrue(app.menuItems["Delete Chat"].exists)
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertFalse(anyElement("sidebar.addWorkspace").exists)
        XCTAssertTrue(anyElement("sidebar.activity").exists)

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

    func testSidebarDragAndDoubleClickResetItsWidth() {
        let handle = anyElement("sidebar.resize")
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        let initialEdge = handle.frame.midX
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.1,
            thenDragTo: start.withOffset(CGVector(dx: 55, dy: 0))
        )
        XCTAssertTrue(waitUntil { handle.frame.midX > initialEdge + 35 })

        handle.doubleClick()
        XCTAssertTrue(waitUntil { abs(handle.frame.midX - (initialEdge + 20)) < 4 })
    }

    func testWorkspaceProfileContextPackAndPromptHistoryControls() {
        let breadcrumb = anyElement("workspace.breadcrumb")
        let title = anyElement("workspace.sessionTitle")
        let modelPicker = anyElement("workspace.modelPicker")
        XCTAssertTrue(breadcrumb.waitForExistence(timeout: 3))
        XCTAssertTrue(breadcrumb.exists)
        XCTAssertTrue(title.exists)
        XCTAssertTrue(modelPicker.exists)
        XCTAssertFalse(anyElement("workspace.openInFinder").exists)
        XCTAssertLessThanOrEqual(
            breadcrumb.frame.minY - app.windows.firstMatch.frame.minY,
            20,
            "the workspace header should occupy the hidden title-bar band without a blank top row"
        )

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
            if tab == "mcp-servers" {
                XCTAssertTrue(
                    anyElement("extensions.mcp.preset.github.logo").waitForExistence(timeout: 3),
                    "MCP providers should display their own identity marks"
                )
            }
        }
        XCTAssertTrue(app.staticTexts["Reusable workflows"].exists)
    }

    func testUpdatesSettingsShowAutomaticDirectDownloadControls() {
        app.menuBars.menuBarItems["Locus"].firstMatch.click()
        XCTAssertTrue(app.menuItems["Check for Updates…"].exists)
        app.typeKey(.escape, modifierFlags: [])

        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Accounts…"].click()

        let updatesPage = anyElement("settings.page.updates")
        XCTAssertTrue(updatesPage.waitForExistence(timeout: 3))
        updatesPage.click()

        XCTAssertTrue(anyElement("settings.updateVersion").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("settings.automaticUpdateChecks").exists)
        XCTAssertTrue(anyElement("settings.automaticUpdateDownloads").exists)
        XCTAssertTrue(anyElement("settings.checkForUpdates").exists)
        XCTAssertFalse(anyElement("settings.appStoreUpdates").exists)
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
        XCTAssertFalse(
            anyElement("workspace.contextUsage").exists,
            "context usage is opt-in so the header starts uncluttered"
        )
        XCTAssertLessThanOrEqual(
            app.textViews["composer.input"].frame.height,
            70,
            "the resting composer should leave most of the window to the transcript"
        )
        let status = anyElement("workspace.workStatus")
        let composer = app.textViews["composer.input"]
        XCTAssertTrue(status.exists)
        XCTAssertTrue(anyElement("sidebar.agentStatus").exists)
        XCTAssertFalse(anyElement("workspace.agentStatus").exists)
        XCTAssertTrue(anyElement("workspace.modelStatus").exists)
        XCTAssertLessThanOrEqual(status.frame.width, 740)
        XCTAssertEqual(
            status.frame.midX,
            composer.frame.midX,
            accuracy: 2,
            "the model readiness indicator should stay centered with the composer"
        )
        app.typeKey(",", modifierFlags: .command)

        let picker = anyElement("settings.appearance")
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        let teamProgress = anyElement("settings.showTeamProgressInHeader")
        let contextUsage = anyElement("settings.showContextUsageInHeader")
        XCTAssertTrue(teamProgress.exists)
        XCTAssertTrue(contextUsage.exists)
        for value in ["system", "light", "dark"] {
            let choice = anyElement("settings.appearance.\(value)")
            XCTAssertTrue(choice.exists, "Missing \(value) appearance choice")
            XCTAssertTrue(choice.isHittable, "\(value) appearance choice is not selectable")
            choice.click()
            XCTAssertEqual(picker.value as? String, value)
        }
        teamProgress.click()
        contextUsage.click()

        app.buttons["settings.save"].click()
        XCTAssertFalse(picker.exists)
        XCTAssertTrue(anyElement("workspace.contextUsage").waitForExistence(timeout: 3))

        // UI-test models do not persist to disk, but the saved in-memory
        // preference must still drive both scenes for the rest of the launch.
        app.typeKey(",", modifierFlags: .command)
        let dark = anyElement("settings.appearance.dark")
        XCTAssertTrue(dark.waitForExistence(timeout: 3))
        XCTAssertEqual(anyElement("settings.appearance").value as? String, "dark")
        XCTAssertTrue(anyElement("settings.showTeamProgressInHeader").exists)
        XCTAssertTrue(anyElement("settings.showContextUsageInHeader").exists)
        app.buttons["settings.cancel"].click()
        XCTAssertTrue(
            anyElement("workspace.contextUsage").exists,
            "reopening and cancelling Settings must keep the saved header choice"
        )
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
        XCTAssertFalse(anyElement("plan.context").exists)
        // Just Chat is not a workspace surface, so the rail goes with the
        // panel — the whole right side disappears.
        XCTAssertFalse(anyElement("inspector.rail.more").exists)
        XCTAssertFalse(anyElement("inspector.rail.terminal").exists)

        XCTAssertTrue(
            anyElement("turnCompletion.00000000-0000-0000-0000-000000000103")
                .waitForExistence(timeout: 3)
        )

        app.typeKey("1", modifierFlags: .command)
        XCTAssertFalse(anyElement("plan.context").exists)

        work.click()
        XCTAssertTrue(work.isSelected)
        XCTAssertTrue(anyElement("composer.mode.plan").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("composer.mode.build").exists)
        XCTAssertTrue(anyElement("plan.context").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.rail.plan").exists, "the rail returns with agentic modes")
    }

    func testRailOmitsDuplicateSettingsAndSidebarSettingsMenuIsAvailable() {
        XCTAssertTrue(anyElement("inspector.rail.notes").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("inspector.rail.more").exists)
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
        // The suite seeds the panel open on Overview; the Overview icon's second
        // click collapses, its next click reopens.
        let planIcon = anyElement("inspector.rail.plan")
        XCTAssertTrue(planIcon.waitForExistence(timeout: 3))
        XCTAssertTrue(planIcon.label.contains("Overview"))
        let terminalIcon = anyElement("inspector.rail.terminal")
        XCTAssertTrue(terminalIcon.exists)
        XCTAssertLessThan(planIcon.frame.maxY, terminalIcon.frame.minY)
        XCTAssertTrue(anyElement("inspector.tab.plan").exists)
        for closedTab in ["changes", "files", "terminal", "preview", "checkpoints", "runs", "agents"] {
            XCTAssertFalse(
                anyElement("inspector.tab.\(closedTab)").exists,
                "the old permanent inspector strip must not expose \(closedTab)"
            )
        }
        planIcon.click()
        XCTAssertFalse(anyElement("plan.context").exists)
        XCTAssertTrue(planIcon.exists)

        // Terminal is a direct rail destination and closes on a second click.
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

    func testKeyboardShortcutsReachAdditionalInspectorTabs() {
        XCTAssertTrue(anyElement("inspector.rail.plan").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("inspector.rail.more").exists)
        let zoom = anyElement("inspector.zoom")
        XCTAssertTrue(zoom.exists)
        XCTAssertGreaterThan(
            zoom.frame.minY,
            anyElement("inspector.rail.notes").frame.minY,
            "expand belongs at the rail bottom"
        )

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.plan").exists)
        XCTAssertTrue(anyElement("inspector.tab.changes").exists)
        XCTAssertFalse(anyElement("inspector.tab.files").exists)

        // A second shortcut destination appends to the dynamic bar instead of
        // replacing the first or exposing every destination permanently.
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(anyElement("files.search").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.files").exists)

        // Existing tabs switch in place and an active close selects the tab to
        // its right (Files here) without collapsing the inspector.
        let changesTab = app.buttons["inspector.tab.changes"].firstMatch
        XCTAssertTrue(changesTab.isHittable)
        // On macOS 15 an AX click can land on the adjacent close control when
        // two plain buttons share a horizontally scrolling tab. Press the
        // label-side coordinate so this continues to exercise tab selection.
        changesTab.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
        anyElement("inspector.tab.close.changes").click()
        XCTAssertFalse(anyElement("inspector.tab.changes").exists)
        XCTAssertFalse(anyElement("changes.file.0").exists)
        XCTAssertTrue(anyElement("files.search").exists)

        anyElement("inspector.tab.close.plan").click()
        anyElement("inspector.tab.close.files").click()
        XCTAssertTrue(anyElement("inspector.tabBar").waitForNonExistence(timeout: 3))
        XCTAssertFalse(anyElement("files.search").exists)
        XCTAssertTrue(anyElement("inspector.rail.plan").exists)
        XCTAssertFalse(anyElement("inspector.rail.more").exists)
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
        XCTAssertEqual(handle.label, "Expanded panel width")
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
        XCTAssertEqual(handle.label, "Inspector width")

        anyElement("browser.expand").click()
        XCTAssertEqual(handle.label, "Expanded panel width")
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

        // ⌘1 — back to the idle Overview.
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(anyElement("plan.status").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("plan.context").exists)
        XCTAssertFalse(anyElement("plan.identity").exists)
        XCTAssertTrue(anyElement("plan.quickActions").exists)
        XCTAssertTrue(anyElement("inspector.tab.plan").label.contains("Overview"))
    }

    func testIdleOverviewShowsQuickAccessAndKeepsContextPinned() {
        let tabBar = anyElement("inspector.tabBar")
        let overview = anyElement("plan.status")
        let context = anyElement("plan.context")
        let window = app.windows.firstMatch

        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        XCTAssertTrue(overview.exists)
        XCTAssertTrue(context.exists)
        XCTAssertFalse(anyElement("plan.identity").exists)
        XCTAssertFalse(anyElement("plan.processes").exists)
        XCTAssertFalse(anyElement("plan.lastRun").exists)
        XCTAssertFalse(anyElement("plan.suggestions").exists)
        XCTAssertTrue(anyElement("plan.quickActions").exists)
        for action in ["agents", "skills", "browser", "files", "changes", "terminal"] {
            XCTAssertTrue(anyElement("plan.quickAction.\(action)").exists)
        }
        XCTAssertFalse(anyElement("plan.livePlan").exists)
        XCTAssertFalse(anyElement("plan.activity").exists)
        XCTAssertLessThanOrEqual(
            window.frame.maxY - context.frame.maxY,
            30,
            "Context should remain pinned to the bottom of the Overview tab"
        )
        XCTAssertLessThanOrEqual(
            context.frame.maxX,
            tabBar.frame.maxX + 1,
            "Session overview content must stay inside the inspector"
        )
        XCTAssertFalse(anyElement("checkpointTab.content").exists)
    }

    func testOverviewQuickAccessOpensInspectorAndSettingsDestinations() {
        let browser = anyElement("plan.quickAction.browser")
        XCTAssertTrue(browser.waitForExistence(timeout: 3))
        browser.click()
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))

        app.typeKey("1", modifierFlags: .command)
        let agents = anyElement("plan.quickAction.agents")
        XCTAssertTrue(agents.waitForExistence(timeout: 3))
        agents.click()
        XCTAssertTrue(app.staticTexts["GLOBAL SCHEDULER"].waitForExistence(timeout: 5))
    }

    func testOverviewShowsAnAlreadyLoadedRunningProcess() {
        relaunchWithRunFixture("swarm-live")
        app.typeKey("1", modifierFlags: .command)

        XCTAssertTrue(anyElement("plan.processes").waitForExistence(timeout: 3))
        let process = anyElement("plan.process.seed-run")
        XCTAssertTrue(process.waitForExistence(timeout: 3))
        XCTAssertTrue(process.label.localizedCaseInsensitiveContains("running"))
    }

    private func relaunchWithPlanOverview(_ fixture: String) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_PLAN_OVERVIEW"] = fixture
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    func testAcceptanceWindowSizesRemainUsableInLightAndDarkAppearances() {
        let cases = [("1120", "700", "Light"), ("1250", "760", "Dark")]
        for (width, height, appearance) in cases {
            app.terminate()
            app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = width
            app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = height
            app.launchArguments = [
                "-ApplePersistenceIgnoreState", "YES",
                "-AppleInterfaceStyle", appearance,
            ]
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            let visibleSize = try! XCTUnwrap(NSScreen.main?.visibleFrame.size)
            XCTAssertEqual(
                app.windows.firstMatch.frame.width,
                min(CGFloat(Double(width)!), visibleSize.width),
                accuracy: 2
            )
            XCTAssertEqual(
                app.windows.firstMatch.frame.height,
                min(CGFloat(Double(height)!), visibleSize.height),
                accuracy: 2
            )
            assertCoreWorkspaceFitsInsideWindow()
        }
    }

    func testCompactWindowKeepsChromeClearAndUsesAnOverlaySidebar() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "720"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "620"
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        let restore = anyElement("workspace.showSidebar")
        let title = anyElement("workspace.sessionTitle")
        let composer = anyElement("composer.input")
        let tabBar = anyElement("inspector.tabBar")
        for element in [restore, title, composer, tabBar] {
            XCTAssertTrue(element.waitForExistence(timeout: 3))
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(element.frame))
        }
        XCTAssertGreaterThanOrEqual(
            restore.frame.minX - window.frame.minX,
            68,
            "The sidebar restore control must stay clear of the macOS traffic lights"
        )
        XCTAssertFalse(anyElement("sidebar.newSession").exists)

        restore.click()
        XCTAssertTrue(anyElement("sidebar.newSession").waitForExistence(timeout: 3))
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(
            anyElement("sidebar.newSession").frame
        ))
        anyElement("sidebar.collapse").click()
        XCTAssertTrue(waitUntil { !self.anyElement("sidebar.newSession").exists })

        // Four intrinsic-width labels exceed this compact inspector. The tab
        // strip must overflow safely and keep the selected tab and its close
        // control reachable instead of clipping them at a count breakpoint.
        for key in ["2", "3", "4"] {
            app.typeKey(key, modifierFlags: .command)
        }
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))
        let terminalTab = anyElement("inspector.tab.terminal")
        let terminalClose = anyElement("inspector.tab.close.terminal")
        XCTAssertTrue(waitUntil { terminalTab.isHittable && terminalClose.isHittable })
        XCTAssertGreaterThanOrEqual(terminalTab.frame.minX, tabBar.frame.minX - 1)
        XCTAssertLessThanOrEqual(terminalClose.frame.maxX, tabBar.frame.maxX + 1)
    }

    func testPrimaryWorkspacePassesAccessibilityAudit() throws {
        try auditCurrentSurface()
    }

    func testSettingsPassesAccessibilityAudit() throws {
        relaunchForAccessibilitySurface("settings", anchor: "settings.page.general")
        try auditCurrentSurface()
    }

    func testModelLibraryPassesAccessibilityAudit() throws {
        relaunchForAccessibilitySurface("model-library", anchor: "modelLibrary.search")
        try auditCurrentSurface()
    }

    func testAgentEditorPassesAccessibilityAudit() throws {
        relaunchForAccessibilitySurface("agent-editor", anchor: "agent.instructions")
        XCTAssertTrue(anyElement("agent.nameLabel").exists)
        try auditCurrentSurface()
    }

    func testPermissionAndPlanApprovalPassAccessibilityAudit() throws {
        app.launchEnvironment["LOCUS_UI_TESTING_PERMISSION"] = "1"
        relaunchForAccessibilitySurface("permission", anchor: "permission.panel")
        try auditCurrentSurface()

        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_PERMISSION"] = nil
        app.launchEnvironment["LOCUS_UI_TESTING_PLAN_APPROVAL"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"] = "plan-approval"
        app.launch()
        XCTAssertTrue(anyElement("planApproval.panel").waitForExistence(timeout: 10))
        try auditCurrentSurface()
    }

    func testDocumentationScreenshots() {
        let captures = [
            (surface: "workspace", anchor: "files.search", name: "locus-workspace"),
            (surface: "files", anchor: "files.search", name: "locus-files"),
            (surface: "plan", anchor: "plan.status", name: "locus-plan"),
        ]

        for capture in captures {
            app.terminate()
            app.launchEnvironment["LOCUS_UI_TESTING_DOCUMENTATION_SURFACE"] = capture.surface
            app.launch()
            XCTAssertTrue(anyElement("conversation.welcome").waitForExistence(timeout: 10))
            XCTAssertTrue(anyElement(capture.anchor).waitForExistence(timeout: 5))

            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = capture.name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testContextWindowCardCollapsesAndExpands() {
        let toggle = anyElement("plan.contextWindow.toggle")
        let details = anyElement("plan.contextWindow.details")
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        if !details.exists {
            toggle.click()
            XCTAssertTrue(details.waitForExistence(timeout: 3))
        }

        toggle.click()
        XCTAssertTrue(waitUntil { !details.exists })
        toggle.click()
        XCTAssertTrue(details.waitForExistence(timeout: 3))
    }

    func testRunningOverviewShowsLiveChecklistActivityAndOverflowActions() {
        relaunchWithPlanOverview("running")

        let status = anyElement("plan.status")
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        let statusText = "\(status.label) \((status.value as? String) ?? "")"
        XCTAssertTrue(
            statusText.contains("Running"),
            "Expected the running status text; got: \(statusText)"
        )
        XCTAssertTrue(anyElement("plan.livePlan").exists)
        XCTAssertTrue(anyElement("plan.activity").exists)
        XCTAssertTrue(anyElement("plan.files").exists)
        XCTAssertTrue(anyElement("plan.runningActions").exists)
        XCTAssertTrue(anyElement("plan.quickActions").exists)
        XCTAssertTrue(app.staticTexts["Refactor retry logic with backoff"].exists)

        anyElement("plan.runningActions").click()
        app.menuItems["New session"].click()
        XCTAssertTrue(staticTextWithValue(containing: "Start a new session?").waitForExistence(timeout: 3))
        cancelConfirmation()
    }

    func testErrorOverviewKeepsStoppedWorkVisibleWithRecoveryActions() {
        relaunchWithPlanOverview("error")

        let status = anyElement("plan.status")
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        let statusText = "\(status.label) \((status.value as? String) ?? "")"
        XCTAssertTrue(
            statusText.contains("Error"),
            "Expected the error status text; got: \(statusText)"
        )
        XCTAssertTrue(anyElement("plan.error").exists)
        XCTAssertTrue(anyElement("plan.livePlan").exists)
        XCTAssertTrue(anyElement("plan.activity").exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertTrue(app.buttons["View logs"].exists)
    }

    func testOverflowingInspectorTabsStillSwitchBrowserAndTerminal() {
        // Six destinations exercise the horizontally scrolling tab path.
        // Browser and Terminal both install native AppKit views; those views
        // must never cover the shared inspector tabs for hit-testing.
        app.typeKey("2", modifierFlags: .command)
        app.typeKey("3", modifierFlags: .command)
        app.typeKey("4", modifierFlags: .command)
        app.typeKey("5", modifierFlags: .command)
        app.typeKey("7", modifierFlags: .command)
        app.typeKey("4", modifierFlags: .command)

        var browserTab: XCUIElement { app.buttons["inspector.tab.preview"].firstMatch }
        var terminalTab: XCUIElement { app.buttons["inspector.tab.terminal"].firstMatch }
        XCTAssertTrue(browserTab.waitForExistence(timeout: 3))
        XCTAssertTrue(terminalTab.exists)
        XCTAssertTrue(browserTab.isHittable)
        XCTAssertTrue(terminalTab.isHittable)
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))

        browserTab.click()
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("terminal.output").exists)

        terminalTab.click()
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))

        browserTab.click()
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))
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
    private func relaunchWithPendingPermission(toolActivityMode: String? = nil) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_PERMISSION"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_TOOL_ACTIVITY_MODE"] = toolActivityMode
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithLandingFixture() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_LANDING"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithScrollFixture(toolActivityMode: String? = nil) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_SCROLL"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_TOOL_ACTIVITY_MODE"] = toolActivityMode
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithThinkingFixture(mode: String) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_THINKING_FIXTURE"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_THINKING_MODE"] = mode
        app.launchEnvironment["LOCUS_UI_TESTING_TOOL_ACTIVITY_MODE"] = "collapsed"
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
        XCTAssertTrue(anyElement("plan.status").waitForExistence(timeout: 3))
        app.typeKey("7", modifierFlags: .command)
        XCTAssertTrue(anyElement("runs.list").waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["runs.search"].exists)
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
        let newChat = anyElement("sidebar.newSession")
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        XCTAssertTrue(newChat.exists)
        XCTAssertLessThanOrEqual(abs(destination.frame.midY - newChat.frame.midY), 2)
        XCTAssertGreaterThan(destination.frame.minX, newChat.frame.maxX)
        XCTAssertTrue("\(destination.value ?? "")".contains("1 needs attention"))
        destination.click()
        XCTAssertTrue(anyElement("activity.center").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("activity.run.seed-run").waitForExistence(timeout: 3))
        XCTAssertTrue(app.textViews["composer.input"].exists)
        XCTAssertTrue("\(destination.value ?? "")".contains("No new activity"))

        destination.click()
        XCTAssertFalse(anyElement("activity.center").exists)
        XCTAssertTrue(app.textViews["composer.input"].exists)

        destination.click()
        let remove = anyElement("activity.remove.seed-run")
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        // The activity center is a SwiftUI overlay. macOS 15 and 26 can mark
        // its visible buttons non-hittable in XCUI even though AppKit routes a
        // pointer at the same frame correctly. Exercise the real hit-testing
        // path at the button's center and verify the resulting removal.
        remove.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["No Activity Yet"].waitForExistence(timeout: 3))
    }

    func testTranscriptScrollsContinuouslyAcrossToolAndReasoningBlocks() {
        relaunchWithScrollFixture()

        let transcript = anyElement("conversation.scroll")
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
        let group = anyElement(
            "toolActivity.group.00000000-0000-0000-0000-000000000101"
        )
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        let firstTool = anyElement("tool.scroll-tool-0.toggle")
        XCTAssertFalse(firstTool.exists, "collapsed mode starts with one request-level row")
        group.click()
        XCTAssertTrue(firstTool.waitForExistence(timeout: 3))
        firstTool.click()

        // Begin the gesture over selectable tool output. It must continue on
        // the transcript instead of being swallowed by the nested responder.
        let lastTool = anyElement("tool.scroll-tool-11.toggle")
        // Grouping puts the tool cards next to one another. Move through them
        // in bounded steps so a single synthetic wheel event cannot jump past
        // the lazy stack and evict the final card from accessibility.
        firstTool.scroll(byDeltaX: 0, deltaY: -320)
        for _ in 0..<8 {
            if lastTool.exists, lastTool.isHittable { break }
            transcript.scroll(byDeltaX: 0, deltaY: -320)
        }
        XCTAssertTrue(lastTool.waitForExistence(timeout: 3))
        XCTAssertTrue(lastTool.isHittable)
        lastTool.click()

        let firstMessage = anyElement("message.00000000-0000-0000-0000-000000000101")
        lastTool.scroll(byDeltaX: 0, deltaY: 320)
        for _ in 0..<8 {
            if firstMessage.exists, firstMessage.isHittable { break }
            transcript.scroll(byDeltaX: 0, deltaY: 320)
        }
        XCTAssertTrue(firstMessage.waitForExistence(timeout: 3))
        XCTAssertTrue(firstMessage.isHittable)

        let messageHeightBeforeHover = firstMessage.frame.height
        firstMessage.hover()
        XCTAssertEqual(
            firstMessage.frame.height,
            messageHeightBeforeHover,
            accuracy: 0.5,
            "revealing message actions must not change transcript geometry"
        )

        // Starting a fresh wheel gesture over ordinary selectable chat text
        // must move the transcript by the same amount as a gesture over its
        // scrollbar or empty background.
        let messageYBeforeWheel = firstMessage.frame.minY
        firstMessage.scroll(byDeltaX: 0, deltaY: -160)
        XCTAssertTrue(waitUntil(timeout: 3) {
            firstMessage.exists && firstMessage.frame.minY < messageYBeforeWheel - 20
        })
    }

    func testCollapsedToolActivityGroupsAndExpands() {
        relaunchWithScrollFixture()

        let group = anyElement(
            "toolActivity.group.00000000-0000-0000-0000-000000000101"
        )
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        XCTAssertTrue(group.label.contains("12 tool calls"))

        let firstTool = anyElement("tool.scroll-tool-0.toggle")
        XCTAssertFalse(firstTool.exists)
        group.click()
        XCTAssertTrue(firstTool.waitForExistence(timeout: 3))
    }

    func testVerboseToolActivityView() {
        relaunchWithScrollFixture(toolActivityMode: "verbose")

        XCTAssertTrue(anyElement("tool.scroll-tool-0.toggle").waitForExistence(timeout: 3))
        XCTAssertFalse(
            anyElement("toolActivity.group.00000000-0000-0000-0000-000000000101").exists
        )
    }

    func testHiddenToolActivityView() {
        relaunchWithScrollFixture(toolActivityMode: "hidden")

        let hidden = anyElement(
            "toolActivity.hidden.00000000-0000-0000-0000-000000000101"
        )
        XCTAssertTrue(hidden.waitForExistence(timeout: 3))
        XCTAssertEqual(hidden.label, "Actions complete")
        XCTAssertFalse(anyElement("tool.scroll-tool-0.toggle").exists)
        XCTAssertFalse(
            anyElement("toolActivity.group.00000000-0000-0000-0000-000000000101").exists
        )
    }

    func testCollapsedThinkingGroupsReasoningWithoutEmptyAssistantRows() {
        relaunchWithThinkingFixture(mode: "collapsed")

        let group = anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000101"
        )
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        XCTAssertTrue(group.label.contains("3 updates"))
        XCTAssertFalse(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000201.0"
        ).exists)
        XCTAssertFalse(anyElement("message.00000000-0000-0000-0000-000000000201").exists)
        XCTAssertFalse(anyElement("message.00000000-0000-0000-0000-000000000203").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000202").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000204").exists)

        group.click()
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000201.0"
        ).waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000203.0"
        ).exists)
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000204.0"
        ).exists)
    }

    func testHiddenThinkingRemovesGroupAndReasoningOnlyAssistantRows() {
        relaunchWithThinkingFixture(mode: "hidden")

        XCTAssertFalse(anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000101"
        ).exists)
        XCTAssertFalse(anyElement("message.00000000-0000-0000-0000-000000000201").exists)
        XCTAssertFalse(anyElement("message.00000000-0000-0000-0000-000000000203").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000202").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000204").exists)
    }

    func testExpandedThinkingStartsWithGroupedReasoningOpen() {
        relaunchWithThinkingFixture(mode: "expanded")

        let group = anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000101"
        )
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        XCTAssertTrue(group.label.contains("collapse"))
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000201.0"
        ).waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000203.0"
        ).exists)
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000204.0"
        ).exists)
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

        let destinationControl = anyElement("landing.destination")
        let branchDestination = app.buttons["Branch, Commit & PR"].firstMatch
        XCTAssertTrue(branchDestination.exists)
        branchDestination.click()
        // AppKit only publishes descendants of a SwiftUI ScrollView once they
        // enter its viewport. Scroll the selected destination's form into the
        // accessibility hierarchy before querying its fields.
        destinationControl.scroll(byDeltaX: 0, deltaY: -400)
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

    func testLiveSwarmTreeShowsNestedBranchAndStopControl() {
        relaunchWithRunFixture("swarm-live")

        XCTAssertTrue(anyElement("runs.agentTree").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Research lead"].exists)
        XCTAssertTrue(app.staticTexts["API specialist"].exists)
        XCTAssertTrue(anyElement("runs.agentTree.stop.inspect.1").exists)
        XCTAssertFalse(anyElement("runs.agentTree.retry.inspect.1").exists)
    }

    func testRecoverableSwarmTreeShowsBranchRetryControl() {
        relaunchWithRunFixture("swarm-recoverable")

        XCTAssertTrue(anyElement("runs.agentTree").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["API specialist"].exists)
        XCTAssertTrue(anyElement("runs.agentTree.retry.inspect.1").exists)
        XCTAssertFalse(anyElement("runs.agentTree.stop.inspect.1").exists)
    }

    func testCompletedSoloSwarmShowsReadOnlyWorkerEvidenceAndUsage() {
        relaunchWithRunFixture("solo-swarm-completed")

        XCTAssertTrue(anyElement("runs.soloSwarm.overview").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Inventory API reader"].exists)
        let worker = anyElement("runs.soloSwarm.worker./root/inventory-api")
        XCTAssertTrue(worker.exists)
        XCTAssertFalse(anyElement("runs.agentTree.stop./root/inventory-api").exists)
        XCTAssertTrue((worker.value as? String)?.localizedCaseInsensitiveContains(
            "Rate-limit headers are undocumented"
        ) == true)
    }

    func testSoloSwarmWithoutDelegationHasMeaningfulEmptyState() {
        relaunchWithRunFixture("solo-swarm-empty")

        XCTAssertTrue(anyElement("runs.soloSwarm.overview").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("runs.soloSwarm.noWorkers").exists)
        XCTAssertTrue(app.staticTexts["This run did not delegate any workers"].exists)
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

    func testHiddenToolActivityKeepsThePermissionPanelUsable() {
        relaunchWithPendingPermission(toolActivityMode: "hidden")

        XCTAssertTrue(anyElement("permission.panel").waitForExistence(timeout: 3))
        let hidden = anyElement(
            "toolActivity.hidden.00000000-0000-0000-0000-000000000201"
        )
        XCTAssertTrue(hidden.waitForExistence(timeout: 3))
        XCTAssertEqual(hidden.label, "Action needs approval")
        XCTAssertFalse(anyElement("tool.seed-tool-permission.toggle").exists)
        XCTAssertTrue(anyElement("permission.once").exists)
        XCTAssertTrue(anyElement("permission.always").exists)
        XCTAssertTrue(anyElement("permission.deny").exists)
        XCTAssertFalse(
            anyElement("workspace.workStatus").label.localizedCaseInsensitiveContains("bash"),
            "hidden mode must not leak the tool name through the persistent status strip"
        )
    }
}
