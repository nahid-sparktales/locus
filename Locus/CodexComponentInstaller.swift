import Combine
import Foundation

#if !LOCUS_APP_STORE

/// Fetches, verifies, and installs the ChatGPT-plan component.
///
/// Order matters and is not negotiable: hash the payload, expand it, verify
/// *both* binaries against SparkTales' code-signing identity, clear quarantine,
/// and only then publish the `current` symlink. A failure at any step leaves
/// the previous install — or the absence of one — exactly as it was.
@MainActor
final class CodexComponentInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case downloading(received: Int64, total: Int64)
        case verifying
        case installing
        case installed(version: String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .installing: true
            case .idle, .installed, .failed: false
            }
        }

        var fractionComplete: Double? {
            guard case let .downloading(received, total) = self, total > 0 else { return nil }
            return min(1, max(0, Double(received) / Double(total)))
        }
    }

    @Published private(set) var state: State = .idle

    private let session: ProxyAwareSession
    private var activeTask: Task<Void, Never>?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        // A 100 MB payload on a slow link must not trip the resource timeout.
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        session = ProxyAwareSession(scope: .downloads, configuration: { configuration })
        if let version = CodexComponent.installedVersion(), CodexComponent.isInstalled {
            state = .installed(version: version)
        }
    }

    static var feedURL: URL? {
        let configured = Bundle.main.object(forInfoDictionaryKey: "LocusComponentFeedURL") as? String
        return URL(string: configured ?? "")
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    static var appShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Pure selection logic, kept separate from the network so it can be tested
    /// against hand-written feeds. `nonisolated` because it touches no state —
    /// the actor hop would only make the tests contort around it.
    nonisolated static func selectRelease(
        from feed: CodexComponentFeed,
        arch: String,
        appVersion: String
    ) throws -> CodexComponentRelease {
        guard feed.schemaVersion == 1 else {
            throw CodexComponentError.manifestInvalid(
                "unsupported schemaVersion \(feed.schemaVersion)"
            )
        }
        let forComponent = feed.components.filter { $0.id == CodexComponent.componentID }
        guard !forComponent.isEmpty else {
            throw CodexComponentError.manifestInvalid("no \(CodexComponent.componentID) entry")
        }
        guard let match = forComponent.first(where: { $0.arch == arch }) else {
            throw CodexComponentError.unsupportedArchitecture(arch)
        }
        guard appVersion.compare(match.minAppVersion, options: .numeric) != .orderedAscending else {
            throw CodexComponentError.appTooOld(match.minAppVersion)
        }
        guard let url = URL(string: match.url), url.scheme == "https" else {
            throw CodexComponentError.manifestInvalid("component URL must be https")
        }
        guard match.sha256.count == 64,
              match.sha256.allSatisfy(\.isHexDigit)
        else {
            throw CodexComponentError.manifestInvalid("component sha256 is malformed")
        }
        // The version becomes a directory name under Application Support, so a
        // feed offering "../../../../bin" would otherwise install outside the
        // component root entirely.
        guard isSafePathComponent(match.version) else {
            throw CodexComponentError.manifestInvalid("component version is not a safe name")
        }
        return match
    }

    /// Completes when the in-flight install finishes, whatever the outcome.
    /// Callers need this because the view that started the install is often
    /// gone by the time it lands — the moment the component exists, the account
    /// editor switches back to the sign-in button.
    func waitForCompletion() async {
        await activeTask?.value
    }

    /// A manifest value that will be used as a single path component. Rejects
    /// separators, traversal, leading dots and anything not plainly a version.
    nonisolated static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64, value != ".", value != ".." else { return false }
        guard !value.hasPrefix(".") else { return false }
        // `current` is the symlink that publishes the active install. A version
        // by that name would have the link created over its own target.
        guard value != "current" else { return false }
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_+"))
        return value.unicodeScalars.allSatisfy(permitted.contains)
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        state = .idle
    }

    func install() {
        guard !state.isBusy else { return }
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performInstall()
            } catch is CancellationError {
                self.state = .idle
            } catch {
                self.state = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    private func performInstall() async throws {
        state = .checking
        guard let feedURL = Self.feedURL else { throw CodexComponentError.feedUnavailable }
        let release = try await fetchRelease(from: feedURL)

        let archive = try await download(release)
        defer { try? FileManager.default.removeItem(at: archive) }

        // Hashing ~104 MB and expanding ~268 MB are seconds of synchronous work
        // apiece. Both helpers below are `nonisolated`, so they run off the main
        // actor and the window keeps drawing while they work — doing this inline
        // froze the whole app for the length of the install.
        try Task.checkCancellation()
        state = .verifying
        try await Self.verifyChecksum(of: archive, against: release)

        try Task.checkCancellation()
        state = .installing
        try await Self.installVerified(archive: archive, release: release)
        state = .installed(version: release.version)
    }

    nonisolated private static func verifyChecksum(
        of archive: URL,
        against release: CodexComponentRelease
    ) async throws {
        let actual = try CodexComponent.sha256(ofFileAt: archive)
        guard actual.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            throw CodexComponentError.checksumMismatch(expected: release.sha256, actual: actual)
        }
    }

    private func fetchRelease(from feedURL: URL) async throws -> CodexComponentRelease {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.current.data(for: request)
        } catch {
            throw CodexComponentError.feedUnavailable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CodexComponentError.feedUnavailable
        }
        let feed: CodexComponentFeed
        do {
            feed = try JSONDecoder().decode(CodexComponentFeed.self, from: data)
        } catch {
            throw CodexComponentError.manifestInvalid(error.localizedDescription)
        }
        return try Self.selectRelease(
            from: feed,
            arch: Self.currentArchitecture,
            appVersion: Self.appShortVersion
        )
    }

    private func download(_ release: CodexComponentRelease) async throws -> URL {
        guard let url = URL(string: release.url) else {
            throw CodexComponentError.manifestInvalid("component URL is not a URL")
        }
        state = .downloading(received: 0, total: release.downloadBytes)
        let progress = DownloadProgress { [weak self] received, total in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(
                    received: received,
                    total: total > 0 ? total : release.downloadBytes
                )
            }
        }
        let located: URL
        let response: URLResponse
        do {
            (located, response) = try await session.current.download(
                from: url,
                delegate: progress
            )
        } catch let error as URLError where error.code == .cancelled {
            // URLSession surfaces task cancellation as URLError.cancelled, not
            // CancellationError. Without this the user's own Cancel click comes
            // back to them as a red "the download did not complete" error.
            throw CancellationError()
        } catch {
            throw CodexComponentError.downloadFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CodexComponentError.downloadFailed(
                "server returned \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }
        // URLSession deletes the temp file when this call returns, so move it
        // somewhere we own before doing anything slow with it.
        let staged = FileManager.default.temporaryDirectory
            .appending(path: "locus-component-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: located, to: staged)
        return staged
    }

    /// Everything from here down runs only after the archive's hash matched.
    nonisolated private static func installVerified(
        archive: URL,
        release: CodexComponentRelease
    ) async throws {
        guard let supportRoot = CodexComponent.supportRoot,
              let currentRoot = CodexComponent.currentRoot
        else { throw CodexComponentError.installFailed("no Application Support directory") }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        let staging = supportRoot.appending(path: ".staging-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path]) {
            CodexComponentError.extractionFailed($0)
        }

        // The hash gate above proves the archive is the one the feed named — it
        // proves nothing if the feed itself is what an attacker controls. So the
        // expanded tree is checked before anything is trusted: no symlink may
        // point out of the staging directory, and no entry may appear that the
        // component is not supposed to contain.
        try Self.validateExpandedTree(at: staging)

        let helper = staging.appending(path: "codex")
        let codeModeHost = staging.appending(path: "codex-code-mode-host")
        for binary in [helper, codeModeHost] {
            guard fileManager.fileExists(atPath: binary.path) else {
                throw CodexComponentError.extractionFailed(
                    "archive is missing \(binary.lastPathComponent)"
                )
            }
        }
        // Nothing has been exec'd yet and nothing is in place — this is the
        // gate that decides whether the payload is ours.
        try CodexComponent.verifySignature(at: helper, identifier: CodexComponent.helperIdentifier)
        try CodexComponent.verifySignature(
            at: codeModeHost, identifier: CodexComponent.codeModeHostIdentifier
        )
        // A quarantined binary refuses to launch even with a valid signature.
        try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path]) {
            CodexComponentError.installFailed($0)
        }

        let versioned = supportRoot.appending(path: release.version, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: versioned.path) {
            try fileManager.removeItem(at: versioned)
        }
        try fileManager.moveItem(at: staging, to: versioned)

        // Publish atomically: build the new link beside the old one and rename
        // over it, so a crash here can never leave `current` dangling.
        let pending = supportRoot.appending(path: ".current-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(
            atPath: pending.path, withDestinationPath: release.version
        )
        guard rename(pending.path, currentRoot.path) == 0 else {
            try? fileManager.removeItem(at: pending)
            throw CodexComponentError.installFailed("could not publish the component link")
        }
        pruneVersions(keeping: release.version, in: supportRoot)
    }

    /// Entries a published component may contain. Anything else means the
    /// archive is not what PackageComponents.sh produces.
    static let permittedEntries: Set<String> = [
        "codex", "codex-code-mode-host", "LICENSE", "NOTICE", "PROVENANCE",
    ]

    nonisolated static func validateExpandedTree(at staging: URL) throws {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(atPath: staging.path)
        for entry in entries {
            guard permittedEntries.contains(entry) else {
                throw CodexComponentError.extractionFailed("unexpected entry \(entry)")
            }
            let attributes = try fileManager.attributesOfItem(
                atPath: staging.appending(path: entry).path
            )
            // A symlink here could redirect the signature check at one file and
            // the exec at another, or point the install outside its directory.
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw CodexComponentError.extractionFailed("\(entry) is a symbolic link")
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CodexComponentError.extractionFailed("\(entry) is not a regular file")
            }
        }
    }

    nonisolated private static func pruneVersions(keeping version: String, in root: URL) {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for entry in contents where entry != version && entry != "current" {
            try? fileManager.removeItem(at: root.appending(path: entry))
        }
    }

    /// Deleting ~268 MB is not instant either, and the settings row reads
    /// `CodexComponent.isInstalled` — so the state only changes once the tree
    /// is actually gone.
    func remove() async {
        guard let supportRoot = CodexComponent.supportRoot else { return }
        await Self.deleteTree(at: supportRoot)
        state = .idle
    }

    nonisolated private static func deleteTree(at url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated private static func run(
        _ launchPath: String,
        _ arguments: [String],
        failure: (String) -> CodexComponentError
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw failure(error.localizedDescription)
        }
        let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8) ?? ""
            throw failure(
                detail.isEmpty
                    ? "\(launchPath.split(separator: "/").last ?? "") exited \(process.terminationStatus)"
                    : String(detail.prefix(200))
            )
        }
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Int64, Int64) -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The async `download(from:delegate:)` variant owns the file handoff.
    }
}

#endif
