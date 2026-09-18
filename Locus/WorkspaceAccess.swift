import Foundation

/// Resolves a remembered workspace path to the canonical spelling the bundled
/// agent and the UI must agree on.
enum WorkspaceAccess {
    /// The first remembered path, canonicalized, or nil when none were stored.
    static func restoreAvailable(paths: [String]) -> String? {
        paths.first.map(canonicalPath)
    }

    private static func canonicalPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            return standardized.path
        }
        return standardized.resolvingSymlinksInPath().path
    }
}
