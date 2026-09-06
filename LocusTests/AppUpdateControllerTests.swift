import XCTest
@testable import Locus

@MainActor
private final class FakeUpdateDriver: AppUpdateDriving {
    var canCheckForUpdates: Bool
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    var stateDidChange: (() -> Void)?
    weak var relaunchHandler: AppUpdateRelaunchHandling?
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
    func testManualUpdatesIgnorePreviouslyEnabledUpdaterPreferences() {
        let driver = FakeUpdateDriver()
        let controller = AppUpdateController(
            distribution: .directDownload, updateMode: .manual, driver: driver
        )
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyDownloadsUpdates)
        controller.checkForUpdates()
        controller.setAutomaticallyChecksForUpdates(true)
        controller.setAutomaticallyDownloadsUpdates(true)
        driver.publishStateChange()
        XCTAssertEqual(driver.checkCount, 0)
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyDownloadsUpdates)
    }

    func testUnconfiguredLocalBuildsDefaultToManualUpdates() {
        for value in [nil, "", "unknown", "manual"] as [String?] {
            XCTAssertEqual(AppUpdateController.UpdateMode.configured(bundleValue: value), .manual)
        }
        XCTAssertEqual(AppUpdateController.UpdateMode.configured(bundleValue: "automatic"), .automatic)
        let controller = AppUpdateController(distribution: .directDownload, updateMode: .manual)
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.canCheckForUpdates)
    }

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
            updateMode: .automatic,
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
            updateMode: .automatic,
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
            updateMode: .automatic,
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

    func testRelaunchHandlerIsForwardedToTheUpdateDriver() {
        let driver = FakeUpdateDriver()
        let controller = AppUpdateController(
            startImmediately: false,
            distribution: .directDownload,
            updateMode: .automatic,
            driver: driver
        )
        let lifecycle = ApplicationLifecycleCoordinator()

        controller.setRelaunchHandler(lifecycle)

        XCTAssertTrue(driver.relaunchHandler === lifecycle)
    }

    func testUpdaterCleanupAndContinuationAreIdempotent() {
        let lifecycle = ApplicationLifecycleCoordinator()
        var continuations = 0

        XCTAssertTrue(lifecycle.shouldAllowUpdateRelaunch())
        lifecycle.prepareForUpdateRelaunch { continuations += 1 }
        lifecycle.prepareForUpdateRelaunch { continuations += 1 }

        XCTAssertEqual(lifecycle.state, .relaunching)
        XCTAssertEqual(continuations, 1)
    }

    func testInvalidOpenSettingsAbortRelaunchBeforeCleanup() {
        let model = AppModel(startImmediately: false)
        let registrationID = UUID()
        model.registerSettingsUpdatePreparation(id: registrationID) { false }
        let lifecycle = ApplicationLifecycleCoordinator()
        lifecycle.connect(model: model)
        var continuations = 0

        XCTAssertFalse(lifecycle.shouldAllowUpdateRelaunch())
        XCTAssertEqual(lifecycle.state, .idle)
        lifecycle.prepareForUpdateRelaunch { continuations += 1 }

        // Sparkle does not enter the postponed path after a false preflight;
        // this direct call only verifies the coordinator itself remains usable.
        XCTAssertEqual(continuations, 1)
        model.unregisterSettingsUpdatePreparation(id: registrationID)
    }

    func testIdleApplicationTerminationDoesNotRequireAReply() {
        let lifecycle = ApplicationLifecycleCoordinator()

        XCTAssertEqual(lifecycle.applicationShouldTerminate(.shared), .terminateNow)
        XCTAssertEqual(lifecycle.state, .idle)
    }
}
