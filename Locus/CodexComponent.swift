import CryptoKit
import Foundation
import Security

/// The ChatGPT-plan helper pair (`codex` and `codex-code-mode-host`), delivered
/// as a downloadable component rather than bundled inside the app.
///
/// The pair is ~270 MB installed and does nothing unless a ChatGPT-plan account
/// is signed in, so bundling it charged every Ollama and API-key user for a
/// feature they never touch. Direct-download builds ship without it and fetch it
/// on demand; the sandboxed App Store build still bundles it, because the App
/// Store does not permit downloading executable code.
///
/// The install path is deliberately a stable symlink rather than a versioned
/// directory. The backend resolves the helper once per launch from
/// `LOCUS_CODEX_APP_SERVER_PATH`, but re-`stat`s that path on every
/// availability check — so pointing the variable at `current/codex` lets an
/// install or upgrade take effect without restarting the agent and dropping
/// live sessions.
enum CodexComponent {
    /// Matches the `identifier` BundleBackend.sh and PackageComponents.sh seal
    /// the helpers with. Pinned in the requirement below so a validly signed
    /// SparkTales binary that is not *this* binary cannot be substituted.
    static let helperIdentifier = "io.sparktales.locus.codex"
    static let codeModeHostIdentifier = "io.sparktales.locus.codex-code-mode-host"
    static let teamIdentifier = "4X4RJA7GMD"
    static let componentID = "chatgpt-plan"

    /// A downloaded binary lands outside the app's signed seal, so notarization
    /// says nothing about it and Gatekeeper will not vet it on our behalf. This
    /// requirement is the actual trust boundary: a tampered manifest can change
    /// which URL we fetch, but it cannot produce a payload that satisfies this.
    static func requirement(identifier: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    // MARK: - Layout

    static var supportRoot: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appending(path: "\(AppEdition.current.displayName)/Components/\(componentID)", directoryHint: .isDirectory)
    }

    /// Stable path the backend is pointed at, whether or not anything is
    /// installed there yet.
    static var currentRoot: URL? {
        supportRoot?.appending(path: "current", directoryHint: .isDirectory)
    }

    static var installedHelper: URL? {
        currentRoot?.appending(path: "codex", directoryHint: .notDirectory)
    }

    static var installedCodeModeHost: URL? {
        currentRoot?.appending(path: "codex-code-mode-host", directoryHint: .notDirectory)
    }

    /// Present in the App Store build and in local Debug builds, absent from a
    /// direct-download release.
    static var bundledHelper: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/codex")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// What `LOCUS_CODEX_APP_SERVER_PATH` should be set to.
    ///
    /// Returns the component path even when nothing is installed: the backend
    /// treats a configured-but-missing path as "runtime unavailable", which is
    /// already a first-class state, and the same path becomes live the instant
    /// the symlink appears.
    static func helperPathForBackend() -> String? {
        if let bundledHelper { return bundledHelper.path }
        return installedHelper?.path
    }

    static var isInstalled: Bool {
        guard let installedHelper else { return false }
        return FileManager.default.isExecutableFile(atPath: installedHelper.path)
    }

    /// Total bytes on disk for every installed version, for the settings row
    /// that offers to reclaim the space.
    static func installedBytes() -> Int64 {
        guard let supportRoot,
              let walker = FileManager.default.enumerator(
                  at: supportRoot,
                  includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
              )
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func installedVersion() -> String? {
        guard let currentRoot,
              let resolved = try? FileManager.default.destinationOfSymbolicLink(
                  atPath: currentRoot.path
              )
        else { return nil }
        let name = URL(fileURLWithPath: resolved).lastPathComponent
        return name.isEmpty ? nil : name
    }

    // MARK: - Verification

    /// Verifies a Mach-O against `requirement(identifier:)`. Used on the
    /// extracted payload before it is moved into place, and again before the
    /// backend is told the component exists.
    static func verifySignature(at url: URL, identifier: String) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL, SecCSFlags(rawValue: 0), &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw CodexComponentError.signatureUnreadable(identifier, createStatus)
        }
        var requirementRef: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirement(identifier: identifier) as CFString,
            SecCSFlags(rawValue: 0),
            &requirementRef
        )
        guard requirementStatus == errSecSuccess, let requirementRef else {
            throw CodexComponentError.signatureUnreadable(identifier, requirementStatus)
        }
        let validity = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            requirementRef
        )
        guard validity == errSecSuccess else {
            throw CodexComponentError.signatureRejected(identifier, validity)
        }
    }

    /// Streams the file so a ~100 MB payload is never held in memory at once.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum CodexComponentError: LocalizedError, Equatable {
    case feedUnavailable
    case manifestInvalid(String)
    case unsupportedArchitecture(String)
    case appTooOld(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case signatureUnreadable(String, OSStatus)
    case signatureRejected(String, OSStatus)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .feedUnavailable:
            "Could not reach the component feed. Check your connection and try again."
        case let .manifestInvalid(detail):
            "The component feed is malformed: \(detail)"
        case let .unsupportedArchitecture(arch):
            "No ChatGPT plan component is published for \(arch)."
        case let .appTooOld(version):
            "This component requires Locus \(version) or newer. Update Locus first."
        case let .downloadFailed(detail):
            "The download did not complete: \(detail)"
        case let .checksumMismatch(expected, actual):
            "The download was corrupted or altered. Expected \(expected.prefix(16))…, "
                + "got \(actual.prefix(16))…. Nothing was installed."
        case let .extractionFailed(detail):
            "The component archive could not be expanded: \(detail)"
        case let .signatureUnreadable(identifier, status):
            "\(identifier) has no readable code signature (status \(status)). "
                + "Nothing was installed."
        case let .signatureRejected(identifier, status):
            "\(identifier) is not signed by SparkTales (status \(status)). "
                + "Nothing was installed."
        case let .installFailed(detail):
            "The component could not be installed: \(detail)"
        }
    }
}

/// One entry in `components.json`, published as a GitHub release asset beside
/// `appcast.xml` so both travel with the release they describe.
struct CodexComponentRelease: Codable, Hashable {
    let id: String
    let version: String
    let arch: String
    let minAppVersion: String
    let url: String
    let sha256: String
    let downloadBytes: Int64
    let installedBytes: Int64
}

struct CodexComponentFeed: Codable, Hashable {
    let schemaVersion: Int
    let components: [CodexComponentRelease]
}
