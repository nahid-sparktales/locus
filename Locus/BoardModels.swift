import Darwin
import Foundation

/// Value types for the workspace board. `BoardStore` owns every mutation; these
/// types only describe what is persisted and shown.
enum BoardPriority: String, Codable, CaseIterable, Identifiable {
    case none, low, medium, high, urgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .urgent: "Urgent"
        }
    }
}

/// Who wrote a timeline entry. Agent names are display labels resolved by the
/// app from the requesting session, never from tool arguments, and are
/// sanitized (BoardAuthorNames.swift) so a model-chosen helper label cannot
/// spoof layout, pass for the person using Locus, or imitate the separators
/// `board_read` prints.
struct BoardAuthor: Codable, Hashable {
    enum Kind: String, Codable { case user, agent }

    static let maximumNameLength = 64
    static let maximumNameScalars = 320
    static let userName = "You"
    static let agentFallbackName = "Agent"
    static let user = BoardAuthor(kind: .user, name: userName)

    var kind: Kind
    var name: String
    var agentID: String?
    var sessionID: String?

    init(kind: Kind, name: String, agentID: String? = nil, sessionID: String? = nil) {
        self.kind = kind
        switch kind {
        case .user:
            self.name = Self.clamped(BoardText.singleLine(name)).nilIfEmpty ?? Self.userName
        case .agent:
            self.name = Self.agentName(name) ?? Self.agentFallbackName
        }
        self.agentID = agentID?.nilIfEmpty
        self.sessionID = sessionID?.nilIfEmpty
    }
}

struct BoardColumn: Codable, Identifiable, Hashable {
    var id: String
    var title: String
}

struct BoardTimelineEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case comment, activity }

    var id: UUID
    var kind: Kind
    var author: BoardAuthor
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), kind: Kind, author: BoardAuthor, text: String, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.author = author
        self.text = text
        self.createdAt = createdAt
    }
}

struct BoardCard: Codable, Identifiable, Hashable {
    var id: UUID
    var number: Int
    var title: String
    /// Called `description` on the wire and on disk; the Swift name avoids
    /// reading like `CustomStringConvertible.description`.
    var details: String
    var columnID: String
    var priority: BoardPriority
    var labels: [String]
    var assignee: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: BoardAuthor
    /// Comments and activity, oldest first.
    var timeline: [BoardTimelineEntry]

    var commentCount: Int { timeline.lazy.filter { $0.kind == .comment }.count }

    private enum CodingKeys: String, CodingKey {
        case id, number, title, columnID, priority, labels, assignee
        case createdAt, updatedAt, createdBy, timeline
        case details = "description"
    }
}

/// The single JSON file stored per workspace.
struct BoardDocument: Codable {
    static let currentVersion = 1

    var version: Int
    var workspacePath: String
    var keyPrefix: String
    var nextNumber: Int
    var columns: [BoardColumn]
    var cards: [BoardCard]
    var updatedAt: Date
}

enum BoardStoreError: LocalizedError, Equatable {
    case workspaceRequired
    case missingArgument(tool: String, name: String)
    case invalidArgument(String)
    case titleRequired
    case titleTooLong
    case descriptionTooLong
    case commentRequired
    case commentTooLong
    case tooManyLabels
    case labelTooLong(String)
    case assigneeTooLong
    case boardFull
    case boardTooLarge
    case cardNumbersExhausted
    case cardNotFound(String)
    case columnNotFound(String, available: [String])
    case ambiguousColumn(String, byID: BoardColumn, byTitle: BoardColumn)
    case ambiguousListedColumn(String, exact: BoardColumn, listed: BoardColumn)
    case columnTitleRequired
    case columnTitleTooLong
    case duplicateColumn(String)
    case tooManyColumns
    case columnNotEmpty(String)
    case lastColumn
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .workspaceRequired:
            "Open a workspace to use the board."
        case .missingArgument(let tool, let name):
            "\(tool) requires \(name)."
        case .invalidArgument(let detail):
            detail
        case .titleRequired:
            "A card title is required."
        case .titleTooLong:
            "Card titles are limited to \(BoardStore.maximumTitleLength) characters"
                + Self.scalarNote(BoardStore.maximumTitleScalars)
        case .descriptionTooLong:
            "Card descriptions are limited to \(BoardStore.maximumDescriptionLength) characters"
                + Self.scalarNote(BoardStore.maximumDescriptionScalars)
        case .commentRequired:
            "A comment needs text."
        case .commentTooLong:
            "Comments are limited to \(BoardStore.maximumCommentLength) characters"
                + Self.scalarNote(BoardStore.maximumCommentScalars)
        case .tooManyLabels:
            "A card can have at most \(BoardStore.maximumLabels) labels."
        case .labelTooLong(let label):
            "Labels are limited to \(BoardStore.maximumLabelLength) characters"
                + " (at most \(BoardStore.maximumLabelScalars) Unicode code points, counting accents"
                + " and other combining marks): “\(BoardText.clipped(label.prefix(40), toScalars: 80))”."
        case .assigneeTooLong:
            "Assignees are limited to \(BoardStore.maximumAssigneeLength) characters"
                + Self.scalarNote(BoardStore.maximumAssigneeScalars)
        case .boardFull:
            "The board already has \(BoardStore.maximumCards) cards. Delete finished cards before adding more."
        case .boardTooLarge:
            "The board is too large to save. Delete some cards or shorten long descriptions first."
        case .cardNumbersExhausted:
            "This board has used every card number it can assign."
        case .cardNotFound(let reference):
            "No card matches “\(BoardText.clipped(reference.prefix(80), toScalars: 160))”. Call board_read to list cards."
        case .columnNotFound(let reference, let available):
            "No column matches “\(BoardText.clipped(reference.prefix(80), toScalars: 160))”. "
                + "Columns: \(available.joined(separator: ", "))."
        case .ambiguousColumn(let reference, let byID, let byTitle):
            "“\(BoardText.clipped(reference.prefix(80), toScalars: 160))” matches \(byID.title) [\(byID.id)] by id and "
                + "\(byTitle.title) [\(byTitle.id)] by title. Pass the column the way board_read lists it: "
                + "“\(byID.title) [\(byID.id)]” or “\(byTitle.title) [\(byTitle.id)]”."
        case .ambiguousListedColumn(let reference, let exact, let listed):
            "“\(BoardText.clipped(reference.prefix(80), toScalars: 160))” is the exact title or id of "
                + "\(exact.title) [\(exact.id)], but read the way board_read lists columns it names "
                + "\(listed.title) [\(listed.id)]. Pass only the bracketed id: “[\(exact.id)]” or “[\(listed.id)]”."
        case .columnTitleRequired:
            "A column title is required."
        case .columnTitleTooLong:
            "Column titles are limited to \(BoardStore.maximumColumnTitleLength) characters"
                + Self.scalarNote(BoardStore.maximumColumnTitleScalars)
        case .duplicateColumn(let title):
            "A column named “\(title)” already exists."
        case .tooManyColumns:
            "A board can have at most \(BoardStore.maximumColumns) columns."
        case .columnNotEmpty(let title):
            "Move or delete the cards in “\(title)” before deleting the column."
        case .lastColumn:
            "A board needs at least one column."
        case .saveFailed(let detail):
            "Could not save the board: \(detail)"
        }
    }

    /// Characters are what people see; a character can carry any number of
    /// accents, so each field also has a ceiling in code points.
    private static func scalarNote(_ limit: Int) -> String {
        " (at most \(limit) Unicode code points, counting accents and other combining marks)."
    }
}

/// Field rules shared by every writer, so the UI can check input the same way.
/// Each field is capped in characters (what people see) and in Unicode code
/// points (what agents are sent), so stacked accents cannot make a short
/// field huge.
extension BoardStore {
    static func validatedTitle(_ title: String) throws -> String {
        let value = BoardText.singleLine(title)
        guard !value.isEmpty else { throw BoardStoreError.titleRequired }
        guard BoardText.fits(value, characters: maximumTitleLength, scalars: maximumTitleScalars) else {
            throw BoardStoreError.titleTooLong
        }
        return value
    }

    static func validatedDetails(_ details: String) throws -> String {
        let value = BoardText.multiLine(details)
        guard BoardText.fits(value, characters: maximumDescriptionLength, scalars: maximumDescriptionScalars) else {
            throw BoardStoreError.descriptionTooLong
        }
        return value
    }

    static func validatedComment(_ text: String) throws -> String {
        let value = BoardText.multiLine(text)
        guard !value.isEmpty else { throw BoardStoreError.commentRequired }
        guard BoardText.fits(value, characters: maximumCommentLength, scalars: maximumCommentScalars) else {
            throw BoardStoreError.commentTooLong
        }
        return value
    }

    /// Trims each label, drops blanks and case-insensitive duplicates.
    static func validatedLabels(_ labels: [String]) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in labels {
            let label = BoardText.singleLine(raw)
            guard !label.isEmpty else { continue }
            guard BoardText.fits(label, characters: maximumLabelLength, scalars: maximumLabelScalars) else {
                throw BoardStoreError.labelTooLong(label)
            }
            guard seen.insert(label.lowercased()).inserted else { continue }
            result.append(label)
        }
        guard result.count <= maximumLabels else { throw BoardStoreError.tooManyLabels }
        return result
    }

    /// A blank assignee means unassigned.
    static func validatedAssignee(_ assignee: String?) throws -> String? {
        guard let assignee else { return nil }
        let value = BoardText.singleLine(assignee)
        guard BoardText.fits(value, characters: maximumAssigneeLength, scalars: maximumAssigneeScalars) else {
            throw BoardStoreError.assigneeTooLong
        }
        return value.nilIfEmpty
    }

    static func validatedColumnTitle(_ title: String) throws -> String {
        let value = BoardText.singleLine(title)
        guard !value.isEmpty else { throw BoardStoreError.columnTitleRequired }
        guard BoardText.fits(value, characters: maximumColumnTitleLength, scalars: maximumColumnTitleScalars) else {
            throw BoardStoreError.columnTitleTooLong
        }
        return value
    }
}

/// Text normalization shared by the store and author resolution.
enum BoardText {
    /// Single-line fields (titles, labels, names) turn control characters into
    /// spaces and drop bidirectional overrides, which can disguise a label.
    static func singleLine(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                scalars.append(" ")
            case .format where isBidiControl(scalar):
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Multi-line fields keep newlines and tabs but lose other control
    /// characters and bidirectional overrides. Unicode line and paragraph
    /// separators become `\n`, so stored text has one kind of line break.
    static func multiLine(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control where scalar != "\n" && scalar != "\t":
                continue
            case .lineSeparator, .paragraphSeparator:
                scalars.append("\n")
            case .format where isBidiControl(scalar):
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits at every character that starts a new line for a reader:
    /// `\n`, `\r`, `\r\n`, NEL, U+2028, U+2029, vertical tab, and form feed.
    static func lines(_ value: String) -> [Substring] {
        value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// One line for inline display, whatever an older file stored.
    static func inline(_ value: String) -> String {
        lines(value).joined(separator: " ")
    }

    /// `“` `”` and look-alikes: `board_read` puts author names between them.
    static let curlyQuotes: Set<UInt32> = [0x201C, 0x201D, 0x201E, 0x201F, 0x301D, 0x301E, 0x301F]

    /// Code points are counted first, so a huge value is refused before its
    /// characters are.
    static func fits(_ value: String, characters: Int, scalars: Int) -> Bool {
        value.unicodeScalars.count <= scalars && value.count <= characters
    }

    /// The longest prefix of whole characters within `limit` code points.
    static func clipped(_ text: Substring, toScalars limit: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let cost = character.unicodeScalars.count
            guard used + cost <= limit else { break }
            result.append(character)
            used += cost
        }
        return result
    }

    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
    }
}

/// The board file: bounded, validated reads and size-bounded saves.
enum BoardFile {
    /// Numbers outside this range can only come from a damaged or hand-edited
    /// file, and would overflow when the next number is worked out.
    static let cardNumbers = 1...1_000_000_000
    /// A board that used the last card number saves the one after it, and
    /// must still open; it just cannot create more cards.
    static let nextNumbers = cardNumbers.lowerBound...(cardNumbers.upperBound + 1)

    enum LoadFailure: LocalizedError {
        case unreadable
        case tooLarge
        case malformed
        case unsupportedVersion(Int)
        case otherWorkspace

        var errorDescription: String? {
            switch self {
            case .unreadable: "the file could not be read"
            case .tooLarge: "the file is larger than 8 MB"
            case .malformed: "the file is not a valid board"
            case .unsupportedVersion(let version): "the file uses unsupported version \(version)"
            case .otherWorkspace: "the file belongs to a different workspace"
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func encode(_ document: BoardDocument) throws -> Data {
        do { return try encoder.encode(document) }
        catch { throw BoardStoreError.saveFailed(error.localizedDescription) }
    }

    static func read(at url: URL, workspacePath: String) throws -> BoardDocument? {
        guard let data = try boundedContents(of: url) else { return nil }
        return try document(from: data, workspacePath: workspacePath)
    }

    /// The bytes to save, checked by decoding them the way a load does: a
    /// file the next launch refused would show an empty board, and the change
    /// after that would replace every card.
    static func saveData(for document: BoardDocument, workspacePath: String) throws -> Data {
        let data = try encode(document)
        do { _ = try self.document(from: data, workspacePath: workspacePath) }
        catch {
            throw BoardStoreError.saveFailed("it would not open again, because \(error.localizedDescription).")
        }
        return data
    }

    static func document(from data: Data, workspacePath: String) throws -> BoardDocument {
        guard let document = try? decoder.decode(BoardDocument.self, from: data) else {
            throw LoadFailure.malformed
        }
        return try validated(document, workspacePath: workspacePath)
    }

    /// What a board must be to open. A card whose column is gone and an
    /// unusable key prefix are repaired; anything else is refused.
    private static func validated(_ document: BoardDocument, workspacePath: String) throws -> BoardDocument {
        var document = document
        guard document.version == BoardDocument.currentVersion else {
            throw LoadFailure.unsupportedVersion(document.version)
        }
        guard document.workspacePath == workspacePath else { throw LoadFailure.otherWorkspace }
        let columnIDs = Set(document.columns.map(\.id))
        guard !document.columns.isEmpty, columnIDs.count == document.columns.count else {
            throw LoadFailure.malformed
        }
        guard nextNumbers.contains(document.nextNumber),
              document.cards.allSatisfy({ cardNumbers.contains($0.number) })
        else { throw LoadFailure.malformed }
        // A card whose column vanished stays visible in the first column.
        for index in document.cards.indices where !columnIDs.contains(document.cards[index].columnID) {
            document.cards[index].columnID = document.columns[0].id
        }
        // At most upperBound + 1, which is still in `nextNumbers`.
        let highest = document.cards.map(\.number).max() ?? 0
        document.nextNumber = max(document.nextNumber, highest + 1)
        for card in document.cards.indices {
            normalizeDates(of: &document.cards[card])
        }
        let prefix = document.keyPrefix
        if prefix.isEmpty || prefix.count > 8 || !prefix.unicodeScalars.allSatisfy(BoardStore.isKeyScalar) {
            document.keyPrefix = BoardStore.keyPrefix(forWorkspace: workspacePath)
        }
        return document
    }

    /// The span of dates that always save in a form the decoder accepts.
    private static let savableDates: ClosedRange<Date> = {
        let formatter = ISO8601DateFormatter()
        let earliest = formatter.date(from: "0001-01-01T00:00:00Z") ?? .distantPast
        let latest = formatter.date(from: "9999-12-31T23:59:59Z") ?? .distantFuture
        return earliest...latest
    }()

    /// A decoded date outside `savableDates` whose encoding the decoder
    /// refuses, such as "0000-01-01T00:00:00+01:00", which is written back as
    /// year -1, moves to the nearest end of that span. Otherwise one bad
    /// entry would fail every later save check and leave the board read-only.
    private static func normalizeDates(of card: inout BoardCard) {
        if let date = savable(card.createdAt) { card.createdAt = date }
        if let date = savable(card.updatedAt) { card.updatedAt = date }
        for entry in card.timeline.indices {
            if let date = savable(card.timeline[entry].createdAt) { card.timeline[entry].createdAt = date }
        }
    }

    /// The replacement for `date`, or nil when it already saves and opens.
    private static func savable(_ date: Date) -> Date? {
        guard !savableDates.contains(date) else { return nil }
        struct Probe: Codable { let date: Date }
        if let data = try? encoder.encode(Probe(date: date)),
           (try? decoder.decode(Probe.self, from: data)) != nil {
            return nil
        }
        return date < savableDates.lowerBound ? savableDates.lowerBound : savableDates.upperBound
    }

    /// Nil when no board has been saved yet. Symlinks, non-regular files, and
    /// files over the size limit are refused rather than followed or loaded.
    /// The open never waits: a FIFO at the path is refused, not read from.
    static func boundedContents(of url: URL) throws -> Data? {
        let limit = BoardStore.maximumFileBytes
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw LoadFailure.unreadable
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { throw LoadFailure.unreadable }
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw LoadFailure.unreadable
        }
        guard status.st_size <= off_t(limit) else { throw LoadFailure.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw LoadFailure.unreadable }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw LoadFailure.tooLarge }
        }
    }

    /// Frees at least `bytes` (as estimated) by dropping activity entries:
    /// cards in `doneColumnID` first, then oldest first across the board.
    /// Comments are never dropped. Nil when no activity is left to drop.
    static func removingActivity(
        from cards: [BoardCard],
        doneColumnID: String?,
        bytes: Int
    ) -> [BoardCard]? {
        struct Candidate {
            let done: Bool
            let date: Date
            let order: Int
            let card: Int
            let id: UUID
            let size: Int
        }
        var candidates: [Candidate] = []
        for (cardIndex, card) in cards.enumerated() {
            let done = card.columnID == doneColumnID
            for entry in card.timeline where entry.kind == .activity {
                candidates.append(Candidate(
                    done: done, date: entry.createdAt, order: candidates.count,
                    card: cardIndex, id: entry.id, size: encodedSize(of: entry)
                ))
            }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { lhs, rhs in
            if lhs.done != rhs.done { return lhs.done }
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.order < rhs.order
        }
        var freed = 0
        var removals: [Int: Set<UUID>] = [:]
        for candidate in candidates {
            removals[candidate.card, default: []].insert(candidate.id)
            freed += candidate.size
            if freed >= bytes { break }
        }
        var trimmed = cards
        for (index, ids) in removals {
            trimmed[index].timeline.removeAll { ids.contains($0.id) }
        }
        return trimmed
    }

    /// What one entry adds to the sorted-key JSON: 144 bytes of keys,
    /// punctuation, UUID, and date, plus its strings. Escaping only adds, so
    /// this is a close lower bound; the caller re-encodes to check.
    private static func encodedSize(of entry: BoardTimelineEntry) -> Int {
        var size = 144 + entry.text.utf8.count + entry.author.name.utf8.count
        if let agentID = entry.author.agentID { size += 13 + agentID.utf8.count }
        if let sessionID = entry.author.sessionID { size += 15 + sessionID.utf8.count }
        return size
    }
}
