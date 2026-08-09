import Foundation

/// Per-build gate for git commands that need the network and the user's own
/// credentials. Push, fetch, and pull run `git` as the user, which reaches
/// the osxkeychain credential helper and the SSH agent — both unreachable
/// from the App Store sandbox, whose container $HOME hides `~/.gitconfig`
/// and `~/.ssh`. Same shape as `ComputerControlService.isAvailable`.
enum GitRemoteFeatures {
    static var isAvailable: Bool {
        #if LOCUS_APP_STORE
        false
        #else
        !WorkspaceAccess.isSandboxed
        #endif
    }
}

enum GitRemoteURL {
    /// The GitHub compare page for a branch, prefilled for a pull request —
    /// the human stays in the publish step. Understands the three remote
    /// shapes git produces: `git@github.com:org/repo.git`,
    /// `ssh://git@github.com/org/repo`, and `https://github.com/org/repo`.
    /// Returns nil for anything that is not github.com.
    static func githubCompareURL(remote: String, branch: String) -> URL? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !branch.isEmpty else { return nil }
        var path: String?
        if let scp = trimmed.firstMatch(of: #/^git@github\.com:(.+)$/#) {
            path = String(scp.1)
        } else if let url = URL(string: trimmed),
                  let host = url.host,
                  host == "github.com" || host.hasSuffix("@github.com"),
                  ["https", "http", "ssh", "git"].contains(url.scheme ?? "") {
            path = url.path
        }
        guard var repoPath = path?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        else { return nil }
        if repoPath.hasSuffix(".git") { repoPath = String(repoPath.dropLast(4)) }
        let segments = repoPath.split(separator: "/")
        guard segments.count == 2 else { return nil }
        guard let encodedBranch = branch.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else { return nil }
        return URL(string: "https://github.com/\(segments[0])/\(segments[1])/compare/\(encodedBranch)?expand=1")
    }
}

enum GitBranchName {
    /// Fast pre-check for the obvious refusals so the create-branch sheet can
    /// explain before running anything; `git check-ref-format --branch` stays
    /// the authority at execution time.
    static func validationError(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "A branch needs a name." }
        if trimmed != name || name.contains(" ") {
            return "Branch names cannot contain spaces."
        }
        if name.hasPrefix("-") { return "A branch name cannot start with a dash." }
        if name.hasPrefix("/") || name.hasSuffix("/") || name.contains("//") {
            return "Slashes can separate segments but cannot lead, trail, or repeat."
        }
        if name.hasSuffix(".lock") { return "A branch name cannot end in .lock." }
        if name.hasSuffix(".") { return "A branch name cannot end with a dot." }
        if name.contains("..") { return "A branch name cannot contain \"..\"." }
        if name.contains("@{") { return "A branch name cannot contain \"@{\"." }
        let forbidden = CharacterSet(charactersIn: "~^:?*[\\")
            .union(.controlCharacters)
        if name.unicodeScalars.contains(where: { forbidden.contains($0) }) {
            return "A branch name cannot contain ~ ^ : ? * [ \\ or control characters."
        }
        return nil
    }
}

enum GitPushPlan {
    /// `git push` when the branch already tracks an upstream; otherwise
    /// publish it: `git push --set-upstream origin <branch>`.
    static func arguments(branch: String, upstream: String?) -> [String] {
        if let upstream, !upstream.isEmpty {
            return ["push"]
        }
        return ["push", "--set-upstream", "origin", branch]
    }
}
