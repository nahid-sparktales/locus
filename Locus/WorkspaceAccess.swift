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
        for path in paths where activeURLs[path] != nil || !Self.isSandboxed {
            return activeURLs[path]?.path ?? path
        }
        return nil
    }

    @discardableResult
    func rememberAndActivate(_ selectedURL: URL) -> Bool {
        let url = selectedURL.standardizedFileURL
        guard url.startAccessingSecurityScopedResource() || !Self.isSandboxed else {
            return false
        }
        activeURLs[url.path] = url

        guard Self.isSandboxed else { return true }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = storedBookmarks
            bookmarks[url.path] = bookmark
            defaults.set(bookmarks, forKey: Self.defaultsKey)
            return true
        } catch {
            activeURLs.removeValue(forKey: url.path)
            url.stopAccessingSecurityScopedResource()
            return false
        }
    }

    @discardableResult
    func activateStored(path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if activeURLs[normalized] != nil || !Self.isSandboxed {
            return true
        }
        guard let data = storedBookmarks[normalized] else { return false }
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
        activeURLs[normalized] = url
        if stale {
            _ = rememberAndActivate(url)
        }
        return true
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
            .appending(path: "Locus", directoryHint: .isDirectory)
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
