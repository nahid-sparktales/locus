import CryptoKit
import Foundation

/// One `@@` hunk of a unified diff, byte-faithful. `lines` keeps every body
/// line verbatim — prefixes, CRLF, and `\ No newline at end of file` markers
/// included — because a synthesized patch must round-trip exactly what git
/// printed or `git apply` will refuse it.
struct DiffHunk: Hashable, Identifiable, Sendable {
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [String]

    /// Content identity: the header plus a digest of the body. Two hunks with
    /// identical edits at different offsets deliberately share the digest part
    /// so a moved-but-unchanged hunk can be re-matched after drift.
    var id: String { "\(header)#\(contentDigest)" }

    var contentDigest: String {
        var hasher = SHA256()
        for line in lines {
            hasher.update(data: Data(line.utf8))
            hasher.update(data: Data([0x0A]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A parsed single-file unified diff: the header block verbatim plus its
/// hunks, with the shapes that carry no hunks called out so the UI can hide
/// per-hunk controls instead of synthesizing nonsense.
struct ParsedFileDiff: Hashable, Sendable {
    let headerLines: [String]
    let hunks: [DiffHunk]
    let isBinary: Bool
    let isRenameOrCopy: Bool
    let isModeChangeOnly: Bool

    private static let hunkHeader = #/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/#

    /// Parses one file's unified diff. Returns nil when the text has no
    /// `diff --git`/`---` header at all (e.g. plain prose).
    static func parse(_ raw: String) -> ParsedFileDiff? {
        // components(separatedBy:), not split(separator:): Swift's Character
        // treats "\r\n" as one grapheme, so a Character-level split would
        // never break CRLF content lines apart. Scalar-level splitting keeps
        // the "\r" on its line, which is exactly what a byte-faithful patch
        // needs. A trailing newline yields one final empty fragment that is
        // not a diff line.
        var lines = raw.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        var headerLines: [String] = []
        var hunks: [DiffHunk] = []
        var isBinary = false
        var isRenameOrCopy = false
        var current: (header: String, old: (Int, Int), new: (Int, Int), body: [String])?

        func closeCurrent() {
            guard let open = current else { return }
            hunks.append(DiffHunk(
                header: open.header,
                oldStart: open.old.0, oldCount: open.old.1,
                newStart: open.new.0, newCount: open.new.1,
                lines: open.body
            ))
            current = nil
        }

        for line in lines {
            if let match = line.firstMatch(of: Self.hunkHeader) {
                closeCurrent()
                let oldStart = Int(match.1) ?? 0
                let oldCount = match.2.flatMap { Int($0) } ?? 1
                let newStart = Int(match.3) ?? 0
                let newCount = match.4.flatMap { Int($0) } ?? 1
                current = (line, (oldStart, oldCount), (newStart, newCount), [])
                continue
            }
            if current != nil {
                if line.hasPrefix("diff --git ") {
                    // A multi-file diff: keep only the first file, matching
                    // the backend's single-pathspec responses.
                    closeCurrent()
                    break
                }
                current?.body.append(line)
                continue
            }
            if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                isBinary = true
            }
            if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
                isRenameOrCopy = true
            }
            headerLines.append(line)
        }
        closeCurrent()

        let looksLikeDiff = headerLines.contains {
            $0.hasPrefix("diff --git ") || $0.hasPrefix("--- ") || $0.hasPrefix("+++ ")
                || $0.hasPrefix("Binary files ") || $0 == "GIT binary patch"
        }
        guard looksLikeDiff || !hunks.isEmpty else { return nil }
        let modeChangeOnly = hunks.isEmpty && !isBinary && headerLines.contains {
            $0.hasPrefix("old mode ") || $0.hasPrefix("new mode ")
        }
        return ParsedFileDiff(
            headerLines: headerLines,
            hunks: hunks,
            isBinary: isBinary,
            isRenameOrCopy: isRenameOrCopy,
            isModeChangeOnly: modeChangeOnly
        )
    }

    /// The header block plus exactly one hunk, byte-identical, ending in a
    /// newline — the smallest patch `git apply` accepts. Renames and copies
    /// return nil: their hunks are not independently applicable against a
    /// single path.
    func minimalPatch(for hunk: DiffHunk) -> String? {
        guard !isBinary, !isRenameOrCopy else { return nil }
        guard hunks.contains(hunk) else { return nil }
        let parts = headerLines + [hunk.header] + hunk.lines
        return parts.joined(separator: "\n") + "\n"
    }

    /// Re-locates `hunk` in this (freshly taken) diff: an exact header match
    /// first, then a content-identity match for a hunk whose offsets moved
    /// but whose edits are untouched. nil means the change drifted and no
    /// patch may be applied from stale data.
    func matching(_ hunk: DiffHunk) -> DiffHunk? {
        if let exact = hunks.first(where: { $0 == hunk }) {
            return exact
        }
        let wanted = hunk.contentDigest
        let candidates = hunks.filter { $0.contentDigest == wanted }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
