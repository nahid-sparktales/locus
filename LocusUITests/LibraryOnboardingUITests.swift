import AppKit
import XCTest

final class LibraryOnboardingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    }

    override func tearDownWithError() throws { app.terminate() }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testSetupBackSkipAndResumeDoNotRunTask() {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        openSetup()
        XCTAssertTrue(element("onboarding.path.coding").waitForExistence(timeout: 10))
        element("onboarding.path.coding").click()
        element("onboarding.continue").click()
        XCTAssertTrue(element("onboarding.readiness").waitForExistence(timeout: 5))
        element("onboarding.back").click()
        XCTAssertTrue(element("onboarding.path.coding").waitForExistence(timeout: 5))
        element("onboarding.continue").click()
        element("onboarding.skip").click()
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5))
        openSetup()
        XCTAssertTrue(element("onboarding.readiness").waitForExistence(timeout: 5))
        XCTAssertFalse(element("onboarding.runFirstTask").exists)
        capture("Setup resumes at connection")
    }

    func testFirstLaunchAutomaticallyOffersGettingStarted() {
        app.launchEnvironment["LOCUS_UI_TESTING_FIRST_LAUNCH"] = "1"
        app.launch()
        let agents = element("onboarding.path.agents")
        XCTAssertTrue(agents.waitForExistence(timeout: 15))
        XCTAssertTrue(element("onboarding.path.documents").exists)
        XCTAssertTrue(element("onboarding.path.coding").exists)
        capture("First launch offers Getting Started automatically")
        element("onboarding.skip").click()
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5))
        XCTAssertFalse(agents.exists)
        openSetup()
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
    }

    func testGettingStartedOpensRecurringAgentSetupAndPreservesDraft() {
        app.launch()
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.click()
        composer.typeText("Keep this unrelated draft")
        let previous = composer.value as? String
        openSetup()
        let agents = element("onboarding.path.agents")
        XCTAssertTrue(agents.waitForExistence(timeout: 10))
        capture("Getting Started choices")
        agents.click()
        element("onboarding.continue").click()
        let create = element("onboarding.createAgent")
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(element("onboarding.runFirstTask").exists)
        capture("Getting Started agents and recurring tasks")
        element("onboarding.back").click()
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        element("onboarding.continue").click()
        create.click()
        let scheduled = element("configureAgent.create.schedule")
        XCTAssertTrue(scheduled.waitForExistence(timeout: 10))
        scheduled.click()
        XCTAssertTrue(element("scheduleEditor.name").waitForExistence(timeout: 10))
        XCTAssertFalse((element("scheduleEditor.prompt").value as? String ?? "").contains("Keep this unrelated draft"))
        capture("Getting Started opens recurring task editor")
        element("scheduleEditor.cancel").click()
        element("configureAgent.close").click()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, previous)
    }

    func testLibraryPreservesDraftAcrossTabsAndClose() {
        app.launch()
        let composer = element("composer.input")
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.click()
        composer.typeText("Keep this unsent library draft")
        let previous = composer.value as? String
        element("sidebar.library").click()
        XCTAssertTrue(element("library.documentSearch").waitForExistence(timeout: 10))
        let outputs = app.radioButtons["Outputs"].firstMatch
        if outputs.exists { outputs.click() }
        else { app.buttons["Outputs"].firstMatch.click() }
        XCTAssertTrue(app.textFields["Search outputs"].waitForExistence(timeout: 5))
        capture("Library Outputs")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, previous)
    }

    func testSetupKeyboardNavigationInNarrowWindow() {
        app.launchEnvironment["LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"] = "onboarding"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "760"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "600"
        app.launch()
        XCTAssertTrue(element("onboarding.continue").waitForExistence(timeout: 15))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("onboarding.readiness").waitForExistence(timeout: 5))
        XCTAssertTrue(element("onboarding.back").isHittable)
        XCTAssertTrue(element("onboarding.skip").isHittable)
        capture("Setup narrow window")
    }

    func testPopulatedLibraryOpensPDFAndNavigatesPages() {
        app.launchEnvironment["LOCUS_UI_TESTING_LIBRARY_CONTENT"] = "1"
        useConnectedFixtureWhenAvailable()
        app.launch()
        XCTAssertTrue(element("sidebar.library").waitForExistence(timeout: 15))
        element("sidebar.library").click()
        let report = element("library.document.fixture-pdf")
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        report.click()
        let page = element("library.pdf.page")
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertTrue(pageCaption(page).contains("Page 1"), page.debugDescription)
        element("library.pdf.next").click()
        XCTAssertTrue(pageCaption(page).contains("Page 2"), page.debugDescription)
        capture("PDF evidence page two")
        element("library.pdf.previous").click()
        XCTAssertTrue(pageCaption(page).contains("Page 1"), page.debugDescription)
    }

    func testPopulatedLibraryComparesImmutableVersionsAfterOriginalDisappears() {
        app.launchEnvironment["LOCUS_UI_TESTING_LIBRARY_CONTENT"] = "1"
        useConnectedFixtureWhenAvailable()
        app.launch()
        XCTAssertTrue(element("sidebar.library").waitForExistence(timeout: 15))
        element("sidebar.library").click()
        XCTAssertTrue(element("library.document.fixture-pdf").waitForExistence(timeout: 10))
        let outputsTab = app.radioButtons["Outputs"].firstMatch
        if outputsTab.exists { outputsTab.click() } else { app.buttons["Outputs"].firstMatch.click() }
        let versions = element("library.output.versions")
        XCTAssertTrue(versions.waitForExistence(timeout: 10))
        versions.click()
        let previous = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@ OR label BEGINSWITH %@", "Version 1", "Version 1")).firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 5))
        previous.click()
        let addedLine = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "Additional finding from the second review.", "Additional finding from the second review.")).firstMatch
        XCTAssertFalse(addedLine.exists)
        versions.click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@ OR label BEGINSWITH %@", "Version 2", "Version 2")).firstMatch.click()
        let more = element("library.output.more")
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.click()
        app.menuItems.matching(NSPredicate(format: "title == %@ OR label == %@", "Compare with previous version", "Compare with previous version")).firstMatch.click()
        let difference = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "+ Additional finding from the second review.", "+ Additional finding from the second review.")).firstMatch
        XCTAssertTrue(difference.waitForExistence(timeout: 10))
        capture("Immutable output versions compared")
    }

    func testPopulatedLibraryCanReplaceAndCloseAnImagePreview() {
        app.launchEnvironment["LOCUS_UI_TESTING_LIBRARY_CONTENT"] = "1"
        app.launch()
        XCTAssertTrue(element("sidebar.library").waitForExistence(timeout: 15))
        element("sidebar.library").click()
        XCTAssertTrue(element("library.document.fixture-pdf").waitForExistence(timeout: 10))
        let outputsTab = app.radioButtons["Outputs"].firstMatch
        if outputsTab.exists { outputsTab.click() } else { app.buttons["Outputs"].firstMatch.click() }
        let image = element("library.output.item.Findings.png")
        let text = element("library.output.item.Summary.md")
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            image.click()
            XCTAssertTrue(element("library.output.versions").waitForExistence(timeout: 5))
            text.click()
            XCTAssertTrue(element("library.output.versions").waitForExistence(timeout: 5))
        }
        image.click()
        XCTAssertTrue(element("preview.image.actualSize").waitForExistence(timeout: 5))
        element("preview.image.actualSize").click()
        XCTAssertTrue(pageCaption(element("preview.image.zoom")).contains("100%"))
        element("preview.image.zoomIn").click()
        XCTAssertTrue(pageCaption(element("preview.image.zoom")).contains("125%"))
        XCTAssertTrue(element("library.output.export").isHittable)
        element("library.output.expand").click()
        XCTAssertTrue(element("preview.image.fit").waitForExistence(timeout: 5))
        // Controls can exist even when an AppKit canvas never received its
        // initial layout. Verify the known teal fixture is actually visible.
        let bitmap = NSBitmapImageRep(data: app.windows.firstMatch.screenshot().pngRepresentation)
        let center = bitmap.flatMap { $0.colorAt(x: $0.pixelsWide / 2, y: $0.pixelsHigh / 2)?.usingColorSpace(.sRGB) }
        XCTAssertNotNil(center)
        XCTAssertGreaterThan(center?.blueComponent ?? 0, (center?.redComponent ?? 1) + 0.15)
        capture("Expanded image with zoom controls")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("library.output.expand").waitForExistence(timeout: 5))
        element("preview.image.fit").click()
        capture("Owned image preview")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testOutputSearchExplainsNoResultsAndRecoversSelection() {
        app.launchEnvironment["LOCUS_UI_TESTING_LIBRARY_CONTENT"] = "1"
        app.launch()
        XCTAssertTrue(element("sidebar.library").waitForExistence(timeout: 15))
        element("sidebar.library").click()
        XCTAssertTrue(element("library.document.fixture-pdf").waitForExistence(timeout: 10))
        selectTab("Outputs")
        let search = element("library.output.search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("no-such-output")
        XCTAssertTrue(app.staticTexts["No matching outputs"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("library.output.expand").exists)
        app.buttons["Clear filters"].click()
        XCTAssertTrue(element("library.output.expand").waitForExistence(timeout: 5))
        capture("Library search recovered")
    }

    func testVaultCreatesProfileFindsFieldsAndExplainsEmptySearch() {
        app.launchEnvironment["LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"] = "identity-vault"
        app.launch()
        XCTAssertTrue(element("identity.search").waitForExistence(timeout: 15))
        app.buttons["Personal"].firstMatch.click()
        let name = element("identity.profile.name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Delete Profile"].exists)
        name.click()
        app.typeKey("a", modifierFlags: .command)
        name.typeText("Travel details")
        let fields = element("identity.profile.fieldSearch")
        fields.click()
        fields.typeText("email")
        XCTAssertTrue(app.textFields["Email"].exists)
        XCTAssertFalse(app.textFields["Phone"].exists)
        element("identity.profile.save").click()
        XCTAssertTrue(app.buttons["Edit Travel details"].waitForExistence(timeout: 5))
        capture("Identity Vault profile")
        let search = element("identity.search")
        search.click()
        search.typeText("no-such-profile")
        XCTAssertTrue(app.staticTexts["No matching profiles"].waitForExistence(timeout: 5))
        app.buttons["Clear search"].firstMatch.click()
        XCTAssertTrue(app.buttons["Edit Travel details"].waitForExistence(timeout: 5))
        selectTab("Signatures")
        XCTAssertTrue(app.buttons["Import Signature…"].waitForExistence(timeout: 5))
        capture("Identity Vault signature onboarding")
        selectTab("Sharing History")
        XCTAssertTrue(app.staticTexts["No sharing yet"].waitForExistence(timeout: 5))
    }

    private func selectTab(_ title: String) {
        let tab = app.radioButtons[title].firstMatch
        if tab.exists { tab.click() } else { app.buttons[title].firstMatch.click() }
    }

    func testVaultVersionsAndPrivateImagePreview() {
        app.launchEnvironment["LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"] = "identity-vault"
        app.launchEnvironment["LOCUS_UI_TESTING_IDENTITY_CONTENT"] = "1"
        app.launch()
        XCTAssertTrue(element("identity.allVersions").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Resume.pdf"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "Resume.pdf").count, 1)
        element("identity.allVersions").click()
        XCTAssertEqual(app.buttons.matching(identifier: "Resume.pdf").count, 2)
        capture("Vault document versions")
        app.buttons["Resume.pdf"].firstMatch.click()
        XCTAssertTrue(element("library.pdf.page").waitForExistence(timeout: 5))
        capture("Private PDF preview")
        app.typeKey(.escape, modifierFlags: [])
        selectTab("Signatures")
        app.buttons["Signature.png"].firstMatch.click()
        XCTAssertTrue(element("preview.image.zoomIn").waitForExistence(timeout: 5))
        element("preview.image.actualSize").click()
        element("preview.image.zoomIn").click()
        XCTAssertTrue(pageCaption(element("preview.image.zoom")).contains("125%"))
        capture("Private signature preview")
    }

    private func useConnectedFixtureWhenAvailable() {
        let path = "/tmp/locus-connected-acceptance"
        if FileManager.default.fileExists(atPath: path + "/summary.md") {
            app.launchEnvironment["LOCUS_UI_TESTING_LIBRARY_SOURCE"] = path
        }
    }

    private func pageCaption(_ page: XCUIElement) -> String {
        // macOS static text normally exposes its contents as AXValue, while
        // labelled accessibility wrappers can expose them as AXDescription.
        page.label + " " + (page.value as? String ?? "")
    }

    private func openSetup() {
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Getting Started…"].click()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
