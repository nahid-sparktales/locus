import Foundation

/// Shared definition of the text file types Locus will read into context.
enum ContextFileTypes {
    static let allowedExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt",
        "css", "scss", "html", "md", "json", "yaml", "yml", "toml", "txt",
        "sh", "zsh", "sql", "xml", "plist",
    ]

    static let skippedDirectories: Set<String> = [
        "node_modules", ".git", "dist", "build", ".next", ".build", ".venv",
    ]
}

/// Fast, capped index of workspace text files backing "@" mentions in the
/// composer, the way Claude Code autocompletes file paths.
enum WorkspaceIndex {
    /// Enumerates readable text files under the workspace root.
    /// Runs off the main thread; results are relative-path sorted.
    static func scan(root: String, limit: Int = 3_000) -> [URL] {
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if ContextFileTypes.skippedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard files.count < limit else { break }
            guard ContextFileTypes.allowedExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            files.append(url)
        }
        return files.sorted {
            relativePath($0, root: root).localizedCaseInsensitiveCompare(
                relativePath($1, root: root)
            ) == .orderedAscending
        }
    }

    /// Returns the best-matching files for a mention query. File-name prefix
    /// matches rank first, then file-name substrings, then path substrings.
    static func matches(
        query: String,
        in files: [URL],
        root: String,
        limit: Int = 8
    ) -> [URL] {
        let term = query.lowercased()
        guard !term.isEmpty else { return Array(files.prefix(limit)) }

        func rank(_ url: URL) -> Int? {
            let name = url.lastPathComponent.lowercased()
            let path = relativePath(url, root: root).lowercased()
            if name.hasPrefix(term) { return 0 }
            if name.contains(term) { return 1 }
            if path.contains(term) { return 2 }
            return nil
        }

        let ranked: [(url: URL, rank: Int)] = files.compactMap { url in
            guard let value = rank(url) else { return nil }
            return (url: url, rank: value)
        }
        let sorted = ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.url.lastPathComponent.count < rhs.url.lastPathComponent.count
        }
        return sorted.prefix(limit).map(\.url)
    }

    static func relativePath(_ url: URL, root: String) -> String {
        let path = url.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// The active "@mention" token at the end of the draft, if any.
    /// Returns the token range (including "@") and the query after it.
    static func activeMention(in draft: String) -> (range: Range<String.Index>, query: String)? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        if atIndex > draft.startIndex {
            let before = draft[draft.index(before: atIndex)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let query = draft[draft.index(after: atIndex)...]
        guard !query.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return (atIndex..<draft.endIndex, String(query))
    }
}
