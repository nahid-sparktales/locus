import XCTest
@testable import Locus

@MainActor
private final class FakeUpdateDriver: AppUpdateDriving {
    var canCheckForUpdates: Bool
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    var stateDidChange: (() -> Void)?
    private(set) var checkCount = 0

    init(canCheck: Bool = true, automaticChecks: Bool = true, automaticDownloads: Bool = true) {
        canCheckForUpdates = canCheck
        automaticallyChecksForUpdates = automaticChecks
        automaticallyDownloadsUpdates = automaticDownloads
    }

    func checkForUpdates() {
        checkCount += 1
    }

    func publishStateChange() {
        stateDidChange?()
    }
}

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testAutomaticUpdaterStartsOnlyForNormalLaunches() {
        XCTAssertTrue(locusShouldStartAutomaticUpdater(environment: [:]))
        XCTAssertFalse(locusShouldStartAutomaticUpdater(environment: [
            "XCTestConfigurationFilePath": "/tmp/LocusTests.xctestconfiguration",
        ]))
        XCTAssertFalse(locusShouldStartAutomaticUpdater(environment: [
            "LOCUS_UI_TESTING": "1",
        ]))
    }

    func testDirectDownloadReflectsAndUpdatesSparklePreferences() {
        let driver = FakeUpdateDriver()
        let controller = AppUpdateController(
            startImmediately: false,
            distribution: .directDownload,
            driver: driver
        )

        XCTAssertTrue(controller.isAvailable)
        XCTAssertTrue(controller.canCheckForUpdates)
        XCTAssertTrue(controller.automaticallyChecksForUpdates)
        XCTAssertTrue(controller.automaticallyDownloadsUpdates)

        controller.setAutomaticallyChecksForUpdates(false)
        controller.setAutomaticallyDownloadsUpdates(false)

        XCTAssertFalse(driver.automaticallyChecksForUpdates)
        XCTAssertFalse(driver.automaticallyDownloadsUpdates)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyDownloadsUpdates)
    }

    func testDriverChangesRefreshPublishedState() {
        let driver = FakeUpdateDriver(canCheck: false, automaticChecks: false, automaticDownloads: false)
        let controller = AppUpdateController(
            startImmediately: false,
            distribution: .directDownload,
            driver: driver
        )

        driver.canCheckForUpdates = true
        driver.automaticallyChecksForUpdates = true
        driver.automaticallyDownloadsUpdates = true
        driver.publishStateChange()

        XCTAssertTrue(controller.canCheckForUpdates)
        XCTAssertTrue(controller.automaticallyChecksForUpdates)
        XCTAssertTrue(controller.automaticallyDownloadsUpdates)
    }

    func testManualCheckRunsOnlyWhenAvailable() {
        let driver = FakeUpdateDriver(canCheck: false)
        let controller = AppUpdateController(
            startImmediately: false,
            distribution: .directDownload,
            driver: driver
        )

        controller.checkForUpdates()
        XCTAssertEqual(driver.checkCount, 0)

        driver.canCheckForUpdates = true
        driver.publishStateChange()
        controller.checkForUpdates()
        XCTAssertEqual(driver.checkCount, 1)
    }

    func testAppStoreDistributionCannotUseInjectedUpdater() {
        let driver = FakeUpdateDriver()
        let controller = AppUpdateController(
            startImmediately: false,
            distribution: .appStore,
            driver: driver
        )

        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyDownloadsUpdates)

        controller.setAutomaticallyChecksForUpdates(false)
        controller.setAutomaticallyDownloadsUpdates(false)
        controller.checkForUpdates()

        XCTAssertTrue(driver.automaticallyChecksForUpdates)
        XCTAssertTrue(driver.automaticallyDownloadsUpdates)
        XCTAssertEqual(driver.checkCount, 0)
    }
}
