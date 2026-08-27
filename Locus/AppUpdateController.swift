import Combine
import Foundation

#if LOCUS_DIRECT_DOWNLOAD
import Sparkle
#endif

@MainActor
protocol AppUpdateRelaunchHandling: AnyObject {
    func shouldAllowUpdateRelaunch() -> Bool
    func prepareForUpdateRelaunch(continuation: @escaping @MainActor () -> Void)
    func updaterWillRelaunch()
}

@MainActor
protocol AppUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var stateDidChange: (() -> Void)? { get set }
    var relaunchHandler: AppUpdateRelaunchHandling? { get set }

    func checkForUpdates()
}

@MainActor
final class AppUpdateController: ObservableObject {
    enum Distribution {
        case directDownload
        case appStore
    }

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false

    let distribution: Distribution
    private let driver: AppUpdateDriving

    var isAvailable: Bool { distribution == .directDownload }

    var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }

    init(
        startImmediately: Bool = true,
        distribution: Distribution? = nil,
        driver: AppUpdateDriving? = nil
    ) {
        #if LOCUS_DIRECT_DOWNLOAD
        let resolvedDistribution = distribution ?? .directDownload
        #else
        let resolvedDistribution = distribution ?? .appStore
        #endif
        self.distribution = resolvedDistribution

        if let driver {
            self.driver = driver
        } else {
            #if LOCUS_DIRECT_DOWNLOAD
            if resolvedDistribution == .directDownload {
                self.driver = SparkleUpdateDriver(startImmediately: startImmediately)
            } else {
                self.driver = AppStoreUpdateDriver()
            }
            #else
            self.driver = AppStoreUpdateDriver()
            #endif
        }

        self.driver.stateDidChange = { [weak self] in
            self?.refreshState()
        }
        refreshState()
    }

    func checkForUpdates() {
        guard isAvailable, canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    func setRelaunchHandler(_ handler: AppUpdateRelaunchHandling?) {
        driver.relaunchHandler = handler
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        driver.automaticallyChecksForUpdates = enabled
        refreshState()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard isAvailable else { return }
        driver.automaticallyDownloadsUpdates = enabled
        refreshState()
    }

    private func refreshState() {
        canCheckForUpdates = isAvailable && driver.canCheckForUpdates
        automaticallyChecksForUpdates = isAvailable && driver.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = isAvailable && driver.automaticallyDownloadsUpdates
    }
}

@MainActor
private final class AppStoreUpdateDriver: AppUpdateDriving {
    var canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var stateDidChange: (() -> Void)?
    weak var relaunchHandler: AppUpdateRelaunchHandling?

    func checkForUpdates() {}
}

#if LOCUS_DIRECT_DOWNLOAD
@MainActor
private final class SparkleUpdateDriver: NSObject, AppUpdateDriving, SPUUpdaterDelegate {
    var stateDidChange: (() -> Void)?
    weak var relaunchHandler: AppUpdateRelaunchHandling?

    private var controller: SPUStandardUpdaterController!
    private var canCheckObservation: AnyCancellable?
    private var automaticCheckObservation: AnyCancellable?
    private var automaticDownloadObservation: AnyCancellable?

    init(startImmediately: Bool) {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: startImmediately,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        let updater = controller.updater
        canCheckObservation = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stateDidChange?() }
        automaticCheckObservation = updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stateDidChange?() }
        automaticDownloadObservation = updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stateDidChange?() }
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let relaunchHandler else { return false }
        relaunchHandler.prepareForUpdateRelaunch(continuation: installHandler)
        return true
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        relaunchHandler?.shouldAllowUpdateRelaunch() ?? true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        relaunchHandler?.updaterWillRelaunch()
    }
}
#endif
