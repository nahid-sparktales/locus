import XCTest
@testable import Locus
#if LOCUS_DIRECT_DOWNLOAD
import Sparkle
#endif

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
    private var automaticInfo: [String: Any] {
        [
            "LocusEdition": "locus", "CFBundleIdentifier": "io.sparktales.locus",
            "LocusUpdateMode": "automatic", "SUFeedURL": AppUpdateConfiguration.locusFeedURL,
            "SUEnableAutomaticChecks": true, "SUAutomaticallyUpdate": true,
            "SUAllowsAutomaticUpdates": true,
        ]
    }

    func testInvalidBundleConfigurationCannotEnableUpdatesEvenWithSavedPreferences() {
        for key in ["LocusEdition", "CFBundleIdentifier", "LocusUpdateMode", "SUFeedURL"] {
            for value in [nil, "", "unknown"] as [String?] {
                var info = automaticInfo
                info[key] = value
                let driver = FakeUpdateDriver()
                let controller = AppUpdateController(
                    distribution: .directDownload, updateMode: .automatic,
                    bundleInfo: info, driver: driver
                )
                XCTAssertNil(AppUpdateConfiguration(info: info))
                XCTAssertFalse(controller.isAvailable)
                controller.checkForUpdates()
                controller.setAutomaticallyChecksForUpdates(false)
                controller.setAutomaticallyDownloadsUpdates(false)
                XCTAssertEqual(driver.checkCount, 0)
                XCTAssertTrue(driver.automaticallyChecksForUpdates)
                XCTAssertTrue(driver.automaticallyDownloadsUpdates)
            }
        }
        var info = automaticInfo
        info["SUFeedURL"] = "https://github.com/nahid-sparktales/locus/releases/latest/download/appcast.xml"
        XCTAssertNil(AppUpdateConfiguration(info: info))
        info = automaticInfo
        info["LocusEdition"] = "locusx"
        info["CFBundleIdentifier"] = "io.sparktales.locusx"
        XCTAssertNil(AppUpdateConfiguration(info: info))
    }

    func testValidBundleConfigurationEnablesUpdatesWithoutAnOverride() {
        let controller = AppUpdateController(
            distribution: .directDownload, bundleInfo: automaticInfo,
            driver: FakeUpdateDriver(automaticChecks: false, automaticDownloads: false)
        )
        XCTAssertTrue(controller.isAvailable)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyDownloadsUpdates)
    }

    #if LOCUS_DIRECT_DOWNLOAD
    func testSparkleUsesSealedFeedAndRetainsSavedOptOuts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let identifier = "io.sparktales.updater-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defer {
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: directory)
        }
        var info = automaticInfo
        info["CFBundleIdentifier"] = identifier
        info["CFBundleName"] = "Updater Test"
        info["CFBundleVersion"] = "27"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: directory))
        let driver = SparkleUpdateDriver(
            configuration: try XCTUnwrap(AppUpdateConfiguration(info: automaticInfo)), startImmediately: false
        )
        let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: driver)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertTrue(updater.automaticallyDownloadsUpdates)
        defaults.set("https://github.com/nahid-sparktales/locus/releases/latest/download/appcast.xml", forKey: "SUFeedURL")
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        let relaunched = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: driver)
        XCTAssertEqual(relaunched.feedURL?.absoluteString, AppUpdateConfiguration.locusFeedURL)
        XCTAssertFalse(relaunched.automaticallyChecksForUpdates)
        XCTAssertFalse(relaunched.automaticallyDownloadsUpdates)
        XCTAssertFalse(relaunched.canCheckForUpdates, "Tests must never start Sparkle")
    }
    #endif

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
            bundleInfo: automaticInfo,
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
            bundleInfo: automaticInfo,
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
            bundleInfo: automaticInfo,
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
            updateMode: .automatic,
            bundleInfo: automaticInfo,
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
            bundleInfo: automaticInfo,
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
