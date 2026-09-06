import Foundation

/// Only the app/signer-acknowledged in-memory authority selects a candidate's
/// update channel. Public wallet metadata and Sparkle preferences cannot do so.
@MainActor
enum WalletCandidateUpdateAuthority {
    static let changed = Notification.Name("LocusWalletCandidateUpdateAuthorityChanged")
    struct Selection: Equatable {
        let feedURL: String
        let channel: String?
        let archiveURL: String
        let bundleVersion: String
    }

    static var source: (() -> (WalletVerifiedReleaseAuthority, String)?)?

    static func isCandidate(bundle: Bundle = .main) -> Bool {
        let archive = bundle.object(forInfoDictionaryKey: "LocusWalletCandidateArchiveURL") as? String ?? ""
        return !archive.isEmpty || WalletSignedReviewCeiling.loadBundled(bundle: bundle) != nil
    }

    static func selection(bundle: Bundle = .main, now: Date = Date()) -> Selection? {
        guard let (authority, installation) = source?(),
              let stable = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let canary = bundle.object(forInfoDictionaryKey: "LocusCanaryUpdateFeedURL") as? String,
              let archive = bundle.object(forInfoDictionaryKey: "LocusWalletCandidateArchiveURL") as? String else { return nil }
        return selection(authority: authority, installation: installation, stable: stable,
            canary: canary, archive: archive, now: now)
    }

    static func selection(authority: WalletVerifiedReleaseAuthority, installation: String,
                          stable: String, canary: String, archive: String, now: Date) -> Selection? {
        func validURL(_ text: String) -> Bool {
            guard text.utf8.count <= 2_048, let url = URLComponents(string: text),
                  url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else { return false }
            return true
        }
        let envelope = authority.checkpoint.signedTransition.envelope
        guard envelope.purpose == .production, authority.authorityExpiresAt > now,
              validURL(stable), validURL(canary), validURL(archive), stable != canary,
              (try? authority.requireAdmission(installationID: installation, now: now)) != nil else { return nil }
        let isCanary = envelope.releaseStage == .invitedCanary
        return .init(feedURL: isCanary ? canary : stable, channel: isCanary ? "canary" : nil,
            archiveURL: archive, bundleVersion: envelope.bundleVersion)
    }

    static func permits(_ selection: Selection?, archiveURL: String?, version: String, channel: String?) -> Bool {
        guard let selection else { return false }
        return selection.archiveURL == archiveURL && selection.bundleVersion == version
            && selection.channel == channel
    }

    /// An explicitly requested safety update uses the sealed stable channel,
    /// normal Sparkle signature verification, and a strictly newer build.
    /// It never grants wallet authority or preserves the old candidate's soak.
    static func permitsSafetyUpdate(archiveURL: String?, version: String, channel: String?,
                                    stableFeed: String?, candidateArchive: String?, installedVersion: String?) -> Bool {
        guard channel == nil, let archiveURL, let url = URLComponents(string: archiveURL),
              url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              let host = url.host, let stableFeed, let stable = URLComponents(string: stableFeed),
              stable.scheme == "https", stable.user == nil, stable.password == nil,
              stable.query == nil, stable.fragment == nil,
              let candidateArchive, let candidate = URLComponents(string: candidateArchive),
              candidate.scheme == "https", host == stable.host || host == candidate.host,
              let installedVersion, let old = UInt64(installedVersion), String(old) == installedVersion,
              let next = UInt64(version), String(next) == version, next > old else { return false }
        return true
    }
}
