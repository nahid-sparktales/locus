import Foundation

/// Keeps user-selected workspace folders available to the sandbox across
/// launches. All restored scopes stay active while Locus runs so the bundled
/// agent inherits them when it starts.
final class WorkspaceAccess {
    private static let defaultsKey = "Locus.workspaceBookmarks"

    private var activeURLs: [String: URL] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    func restoreAvailable(paths: [String]) -> String? {
        for path in storedBookmarks.keys {
            _ = activateStored(path: path)
        }
        for path in paths {
            let canonical = Self.canonicalPath(path)
            if activeURLs[canonical] != nil || !Self.isSandboxed {
                return activeURLs[canonical]?.path ?? canonical
            }
        }
        return nil
    }

    @discardableResult
    func rememberAndActivate(_ selectedURL: URL) -> Bool {
        let url = selectedURL.standardizedFileURL
        let canonical = Self.canonicalPath(url.path)
        if Self.isAppOwnedWorkspace(canonical) {
            activeURLs[canonical] = url
            return true
        }
        guard url.startAccessingSecurityScopedResource() || !Self.isSandboxed else {
            return false
        }
        activeURLs[canonical] = url

        guard Self.isSandboxed else { return true }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = storedBookmarks
            bookmarks[canonical] = bookmark
            defaults.set(bookmarks, forKey: Self.defaultsKey)
            return true
        } catch {
            activeURLs.removeValue(forKey: canonical)
            url.stopAccessingSecurityScopedResource()
            return false
        }
    }

    @discardableResult
    func activateStored(path: String) -> Bool {
        let canonical = Self.canonicalPath(path)
        if activeURLs[canonical] != nil || !Self.isSandboxed || Self.isAppOwnedWorkspace(canonical) {
            return true
        }
        // Bookmarks saved by older builds used the selected spelling of the
        // path. Match those by canonical destination so symlink-selected
        // workspaces remain usable after canonical IDs were introduced.
        let bookmarks = storedBookmarks
        guard let data = bookmarks[canonical] ?? bookmarks.first(where: {
            Self.canonicalPath($0.key) == canonical
        })?.value else { return false }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), url.startAccessingSecurityScopedResource()
        else {
            return false
        }
        activeURLs[canonical] = url
        if stale {
            _ = rememberAndActivate(url)
        }
        return true
    }

    private static func canonicalPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            return standardized.path
        }
        return standardized.resolvingSymlinksInPath().path
    }

    /// App-created sample workspaces need no external-folder bookmark.
    private static func isAppOwnedWorkspace(_ path: String) -> Bool {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        return ["Quickstart", "Workspace"].contains { folder in
            let root = canonicalPath(AppEdition.current.supportDirectory(in: support).appendingPathComponent(folder).path)
            return path == root || path.hasPrefix(root + "/")
        }
    }

    static func sandboxWorkspaceURL() -> URL? {
        guard isSandboxed,
              let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first
        else {
            return nil
        }
        let url = support
            .appending(path: AppEdition.current.displayName, directoryHint: .isDirectory)
            .appending(path: "Workspace", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var storedBookmarks: [String: Data] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: Data] ?? [:]
    }

    deinit {
        for url in activeURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
