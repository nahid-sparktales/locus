import Combine
import Foundation

#if LOCUS_DIRECT_DOWNLOAD
import AppKit
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

    enum UpdateMode: String {
        case automatic
        case manual

        static func configured(bundleValue: String?) -> UpdateMode {
            // New local builds must never fall back to the legacy wallet feed.
            UpdateMode(rawValue: bundleValue ?? "") ?? .manual
        }
    }

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false

    let distribution: Distribution
    let updateMode: UpdateMode
    private let driver: AppUpdateDriving

    var isAvailable: Bool { distribution == .directDownload && updateMode == .automatic }

    var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }

    init(
        startImmediately: Bool = true,
        distribution: Distribution? = nil,
        updateMode: UpdateMode? = nil,
        driver: AppUpdateDriving? = nil
    ) {
        #if LOCUS_DIRECT_DOWNLOAD
        let resolvedDistribution = distribution ?? .directDownload
        #else
        let resolvedDistribution = distribution ?? .appStore
        #endif
        self.distribution = resolvedDistribution
        let resolvedMode = updateMode ?? .configured(
            bundleValue: Bundle.main.object(forInfoDictionaryKey: "LocusUpdateMode") as? String
        )
        self.updateMode = resolvedMode

        if let driver {
            self.driver = driver
        } else {
            #if LOCUS_DIRECT_DOWNLOAD
            if resolvedDistribution == .directDownload && resolvedMode == .automatic {
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
    #if LOCUS_WALLET
    private var candidateAuthorityObservation: AnyCancellable?
    private var requestedSafetyUpdate = false
    #endif

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
        #if LOCUS_WALLET
        candidateAuthorityObservation = NotificationCenter.default.publisher(for: WalletCandidateUpdateAuthority.changed)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stateDidChange?() }
        #endif
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
        #if LOCUS_WALLET
        if WalletCandidateUpdateAuthority.isCandidate() {
            let alert = NSAlert()
            alert.messageText = "Check for an update outside this wallet candidate?"
            alert.informativeText = "Installing a newer signed release ends participation in this candidate. Mainnet wallet access will require fresh release approval and, where applicable, a new invitation. Your vault and recovery material are not changed by this check."
            alert.addButton(withTitle: "Check for Safety Updates")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            requestedSafetyUpdate = true
        }
        #endif
        controller.checkForUpdates(nil)
    }

    #if LOCUS_WALLET
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if WalletCandidateUpdateAuthority.isCandidate(), !requestedSafetyUpdate,
           WalletCandidateUpdateAuthority.selection() == nil {
            throw NSError(domain: "LocusCandidateUpdate", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Updates for this wallet candidate require current verified release access."])
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard WalletCandidateUpdateAuthority.isCandidate() else { return nil }
        if requestedSafetyUpdate { return Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String }
        return WalletCandidateUpdateAuthority.selection()?.feedURL
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        if requestedSafetyUpdate { return [] }
        guard let channel = WalletCandidateUpdateAuthority.selection()?.channel else { return [] }
        return [channel]
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard WalletCandidateUpdateAuthority.isCandidate() else { return }
        if requestedSafetyUpdate {
            guard WalletCandidateUpdateAuthority.permitsSafetyUpdate(archiveURL: updateItem.fileURL?.absoluteString,
                version: updateItem.versionString, channel: updateItem.channel,
                stableFeed: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                candidateArchive: Bundle.main.object(forInfoDictionaryKey: "LocusWalletCandidateArchiveURL") as? String,
                installedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) else {
                throw NSError(domain: "LocusCandidateUpdate", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "The safety update is not a newer release on the approved stable channel."])
            }
            return
        }
        guard WalletCandidateUpdateAuthority.permits(WalletCandidateUpdateAuthority.selection(),
            archiveURL: updateItem.fileURL?.absoluteString, version: updateItem.versionString,
            channel: updateItem.channel) else {
            throw NSError(domain: "LocusCandidateUpdate", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "This update does not match the verified wallet candidate and distribution channel."])
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        requestedSafetyUpdate = false
    }
    #endif

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
