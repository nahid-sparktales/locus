import Foundation

/// How a file differs from the last commit, as reported by the agent's
/// `/api/git/status`.
enum GitFileState: String, Codable, Hashable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case unmerged
    case typechange

    var symbol: String {
        switch self {
        case .modified: "pencil"
        case .added: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.right"
        case .copied: "doc.on.doc"
        case .untracked: "questionmark"
        case .unmerged: "exclamationmark.triangle"
        case .typechange: "arrow.triangle.2.circlepath"
        }
    }

    /// One-letter gutter marker, matching what `git status --short` shows.
    var marker: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "?"
        case .unmerged: "U"
        case .typechange: "T"
        }
    }
}

struct GitChange: Codable, Hashable, Identifiable {
    var id: String { path }
    let path: String
    let origPath: String?
    let status: GitFileState
    let staged: Bool
    let unstaged: Bool
    let binary: Bool
    let additions: Int?
    let deletions: Int?

    var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var directory: String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    /// "+12 −3", omitted entirely for binary files where git reports no counts.
    var changeSummary: String? {
        guard !binary else { return "binary" }
        guard let additions, let deletions else { return nil }
        return "+\(additions) −\(deletions)"
    }

    enum CodingKeys: String, CodingKey {
        case path, status, staged, unstaged, binary, additions, deletions
        case origPath = "orig_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        origPath = try container.decodeIfPresent(String.self, forKey: .origPath)
        // An unrecognized state from a newer agent must not fail the whole
        // listing; fall back to "modified" rather than dropping the file.
        status = (try? container.decode(GitFileState.self, forKey: .status)) ?? .modified
        staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
        unstaged = try container.decodeIfPresent(Bool.self, forKey: .unstaged) ?? false
        binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        additions = try container.decodeIfPresent(Int.self, forKey: .additions)
        deletions = try container.decodeIfPresent(Int.self, forKey: .deletions)
    }

    init(
        path: String,
        origPath: String? = nil,
        status: GitFileState,
        staged: Bool = false,
        unstaged: Bool = true,
        binary: Bool = false,
        additions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.path = path
        self.origPath = origPath
        self.status = status
        self.staged = staged
        self.unstaged = unstaged
        self.binary = binary
        self.additions = additions
        self.deletions = deletions
    }
}

struct GitStatusResponse: Codable {
    let ok: Bool
    let isRepo: Bool
    let branch: String?
    let ahead: Int?
    let behind: Int?
    let files: [GitChange]
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, branch, ahead, behind, files, error
        case isRepo = "is_repo"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        isRepo = try container.decodeIfPresent(Bool.self, forKey: .isRepo) ?? false
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        ahead = try container.decodeIfPresent(Int.self, forKey: .ahead)
        behind = try container.decodeIfPresent(Int.self, forKey: .behind)
        files = try container.decodeIfPresent([GitChange].self, forKey: .files) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

struct GitDiffResponse: Codable {
    let ok: Bool
    let path: String
    let binary: Bool
    let truncated: Bool
    let raw: String?

    enum CodingKeys: String, CodingKey {
        case ok, path, binary, truncated, raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        raw = try container.decodeIfPresent(String.self, forKey: .raw)
    }
}
