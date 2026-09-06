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
        capture("Owned image preview")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("composer.input").waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
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
