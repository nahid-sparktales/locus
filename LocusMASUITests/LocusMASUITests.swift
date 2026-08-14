import XCTest

final class LocusMASUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testUpdatesAreManagedByTheMacAppStore() {
        app.menuBars.menuBarItems["Locus"].firstMatch.click()
        XCTAssertFalse(app.menuItems["Check for Updates…"].exists)
        app.typeKey(.escape, modifierFlags: [])

        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Accounts…"].click()

        let updatesPage = anyElement("settings.page.updates")
        XCTAssertTrue(updatesPage.waitForExistence(timeout: 3))
        updatesPage.click()

        XCTAssertTrue(anyElement("settings.updateVersion").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("settings.appStoreUpdates").exists)
        XCTAssertFalse(anyElement("settings.automaticUpdateChecks").exists)
        XCTAssertFalse(anyElement("settings.automaticUpdateDownloads").exists)
        XCTAssertFalse(anyElement("settings.checkForUpdates").exists)
    }
}
