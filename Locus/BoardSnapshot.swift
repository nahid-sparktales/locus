import Foundation

/// A copy of one board: what `board_read` formats and searches, off the main
/// actor, and what the store's own lookups read.
struct BoardSnapshot: Sendable {
    let workspacePath: String
    let keyPrefix: String
    let columns: [BoardColumn]
    /// Every card in board order.
    let cards: [BoardCard]

    func key(for card: BoardCard) -> String {
        "\(keyPrefix)-\(card.number)"
    }

    func cards(in columnID: String) -> [BoardCard] {
        cards.filter { $0.columnID == columnID }
    }

    /// Accepts a key (`LOC-12`, any case), a number (`12` or `#12`), or a UUID.
    func card(matching reference: String) -> BoardCard? {
        var value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        if let id = UUID(uuidString: value) {
            return cards.first { $0.id == id }
        }
        let number: Int?
        if let bare = Int(value) {
            number = bare
        } else if let dash = value.lastIndex(of: "-"),
                  value[..<dash].caseInsensitiveCompare(keyPrefix) == .orderedSame {
            number = Int(value[value.index(after: dash)...])
        } else {
            number = nil
        }
        guard let number else { return nil }
        return cards.first { $0.number == number }
    }

    func requireColumn(matching reference: String) throws -> BoardColumn {
        guard let column = try resolveColumn(reference) else {
            throw BoardStoreError.columnNotFound(reference, available: columns.map(\.title))
        }
        return column
    }

    /// A column's exact id or title (case-insensitively) comes first, and
    /// throws when it is one column's id and another's title, or when the
    /// same text read as `Title [id]` names another column, so a renamed
    /// column never silently receives cards meant for its namesake. Then the
    /// way `board_read` lists columns (`In Progress [in-progress]`), then a
    /// spelling that only differs in spaces or punctuation (`in_progress`)
    /// when it is unique. A reference with no letters or digits at all (only
    /// punctuation or invisible characters) is never matched loosely.
    func resolveColumn(_ reference: String) throws -> BoardColumn? {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let byID = columns.first { $0.id.caseInsensitiveCompare(value) == .orderedSame }
        let byTitle = columns.first { $0.title.caseInsensitiveCompare(value) == .orderedSame }
        if let byID, let byTitle, byID.id != byTitle.id {
            throw BoardStoreError.ambiguousColumn(value, byID: byID, byTitle: byTitle)
        }
        let listed = listedColumn(value)
        if let exact = byID ?? byTitle {
            if let listed, listed.id != exact.id {
                throw BoardStoreError.ambiguousListedColumn(value, exact: exact, listed: listed)
            }
            return exact
        }
        if let listed { return listed }
        let folded = Self.folded(value)
        guard !folded.isEmpty else { return nil }
        let loose = columns.filter { Self.folded($0.id) == folded || Self.folded($0.title) == folded }
        return loose.count == 1 ? loose[0] : nil
    }

    /// `Title [id]` or `[id]`: the bracketed id decides, and a title, when
    /// given, must be that column's.
    private func listedColumn(_ value: String) -> BoardColumn? {
        guard value.hasSuffix("]"), let open = value.lastIndex(of: "[") else { return nil }
        let id = value[value.index(after: open)..<value.index(before: value.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        let title = value[..<open].trimmingCharacters(in: .whitespaces)
        guard let column = columns.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }),
              title.isEmpty || column.title.caseInsensitiveCompare(title) == .orderedSame
        else { return nil }
        return column
    }

    private static func folded(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The column `include_done: false` hides, and the one whose cards give
    /// up their old activity first when the board file is full.
    static func doneColumn(in columns: [BoardColumn]) -> BoardColumn? {
        columns.first { $0.id.caseInsensitiveCompare("done") == .orderedSame }
            ?? columns.first { $0.title.caseInsensitiveCompare("done") == .orderedSame }
    }
}

/// `board_read`'s arguments, checked on the main actor before any matching
/// work starts. Each filter is capped the way the field it matches is, in
/// characters and in code points, so any stored value can be passed back.
struct BoardReadRequest: Sendable {
    static let maximumQueryLength = 200
    static let maximumQueryScalars = 1_000
    /// A column title, an id, or both as `Title [id]`.
    static let maximumColumnReferenceLength = 500
    static let maximumColumnReferenceScalars = 1_000

    var cardReference: String?
    var column: String?
    var assignee: String?
    var query: String?
    var includeDone = true

    init(_ arguments: [String: Any]) throws {
        cardReference = try BoardToolArguments.reference(arguments, "card_id")
        guard cardReference == nil else { return }
        column = try Self.bounded(
            arguments, "column",
            characters: Self.maximumColumnReferenceLength, scalars: Self.maximumColumnReferenceScalars
        )
        assignee = try Self.bounded(
            arguments, "assignee",
            characters: BoardStore.maximumAssigneeLength, scalars: BoardStore.maximumAssigneeScalars
        )
        query = try Self.bounded(
            arguments, "query", characters: Self.maximumQueryLength, scalars: Self.maximumQueryScalars
        )
        includeDone = try BoardToolArguments.bool(arguments, "include_done") ?? true
    }

    private static func bounded(
        _ arguments: [String: Any],
        _ key: String,
        characters: Int,
        scalars: Int
    ) throws -> String? {
        guard let value = try BoardToolArguments.nonBlankString(arguments, key) else { return nil }
        guard BoardText.fits(value, characters: characters, scalars: scalars) else {
            throw BoardStoreError.invalidArgument(
                "\(key) is limited to \(characters) characters (at most \(scalars) Unicode code points)."
            )
        }
        return value
    }
}

/// Case-, accent-, and width-insensitive search text for `board_read`.
/// Each code point is folded on its own and remembered, so folding a board
/// costs the same per byte whatever the text is. An accent folds away after
/// any letter, so `é` and `e` + U+0301 both become `e`.
struct BoardSearchFolding {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    private var cache: [UInt32: [UInt8]] = [:]

    /// UTF-8 of the folded text.
    mutating func fold(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value < 0x80 {
                let byte = UInt8(truncatingIfNeeded: value)
                bytes.append((0x41...0x5A).contains(byte) ? byte | 0x20 : byte)
            } else if let folded = cache[value] {
                bytes.append(contentsOf: folded)
            } else {
                let folded = Self.fold(scalar)
                cache[value] = folded
                bytes.append(contentsOf: folded)
            }
        }
        return bytes
    }

    private static func fold(_ scalar: Unicode.Scalar) -> [UInt8] {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            // A mark on its own survives folding, so ask with a letter in front.
            let folded = "a\(scalar)".folding(options: options, locale: nil)
            return folded == "a" ? [] : Array(String(scalar).utf8)
        default:
            let decomposed = String(scalar).decomposedStringWithCanonicalMapping
            return Array(decomposed.folding(options: options, locale: nil).utf8)
        }
    }
}

/// A folded query, found in linear time (Knuth–Morris–Pratt), so no
/// combination of query and text makes a search slow.
struct BoardSearchPattern {
    private let needle: [UInt8]
    private let fallback: [Int]

    init(_ needle: [UInt8]) {
        self.needle = needle
        var fallback = [Int](repeating: 0, count: needle.count)
        var matched = 0
        for index in needle.indices.dropFirst() {
            while matched > 0, needle[index] != needle[matched] { matched = fallback[matched - 1] }
            if needle[index] == needle[matched] { matched += 1 }
            fallback[index] = matched
        }
        self.fallback = fallback
    }

    /// An empty query (one made only of accents, say) matches everything.
    func occurs(in text: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= text.count else { return false }
        var matched = 0
        for byte in text {
            while matched > 0, byte != needle[matched] { matched = fallback[matched - 1] }
            if byte == needle[matched] {
                matched += 1
                if matched == needle.count { return true }
            }
        }
        return false
    }
}
