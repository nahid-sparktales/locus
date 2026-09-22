import Foundation

/// One kanban board per workspace, shared by the inspector and by agents.
///
/// The app owns the data. Agents reach it only through `perform`, which
/// AppModel calls with the workspace of the socket that made the request and
/// an author it resolved itself. Every mutation validates first and writes the
/// whole board atomically before it is published, so a rejected or unsaved
/// change never shows up and there is nothing to flush at quit.
@MainActor
final class BoardStore: ObservableObject {
    nonisolated static let maximumCards = 1_000
    nonisolated static let maximumColumns = 12
    nonisolated static let maximumTitleLength = 200
    nonisolated static let maximumDescriptionLength = 20_000
    nonisolated static let maximumCommentLength = 5_000
    nonisolated static let maximumLabels = 8
    nonisolated static let maximumLabelLength = 32
    nonisolated static let maximumAssigneeLength = 64
    nonisolated static let maximumColumnTitleLength = 40
    // The same fields in Unicode code points: five per character is plenty
    // for any script, while stacked accents are refused.
    nonisolated static let maximumTitleScalars = 1_000
    nonisolated static let maximumDescriptionScalars = 40_000
    nonisolated static let maximumCommentScalars = 10_000
    nonisolated static let maximumLabelScalars = 160
    nonisolated static let maximumAssigneeScalars = 320
    nonisolated static let maximumColumnTitleScalars = 200
    nonisolated static let maximumTimelineEntries = 200
    nonisolated static let maximumFileBytes = 8 * 1024 * 1024
    nonisolated static let maximumListedCards = 200
    nonisolated static let overviewDescriptionLength = 160
    static let directoryName = "Workspace Boards"

    static let defaultColumns: [BoardColumn] = [
        BoardColumn(id: "backlog", title: "Backlog"),
        BoardColumn(id: "todo", title: "To Do"),
        BoardColumn(id: "in-progress", title: "In Progress"),
        BoardColumn(id: "review", title: "Review"),
        BoardColumn(id: "done", title: "Done"),
    ]

    /// Shares Notes' root, including its per-launch temporary folder while UI
    /// testing, so the suite never reads or writes a developer's real board.
    nonisolated static var applicationSupportDirectory: URL {
        NotesStore.applicationSupportDirectory
    }

    private struct StoreKey: Hashable {
        let root: String
        let workspace: String
    }
    private static var stores: [StoreKey: BoardStore] = [:]

    /// Everything a mutation may change, edited as one copy and published
    /// only after it has been saved.
    private struct State: Equatable {
        var columns: [BoardColumn]
        var cards: [BoardCard]
        var nextNumber: Int
    }

    @Published private(set) var columns: [BoardColumn] = BoardStore.defaultColumns
    /// Every card in board order; a column's cards keep their relative order.
    @Published private(set) var cards: [BoardCard] = []
    @Published private(set) var keyPrefix: String
    @Published private(set) var lastError: String?
    /// Set whenever an agent changes the board, so the UI can draw attention.
    @Published private(set) var lastAgentChange: Date?

    /// Canonical workspace path; empty means there is no workspace and every
    /// mutation throws `BoardStoreError.workspaceRequired`.
    let workspacePath: String
    let fileURL: URL?
    private var nextNumber = 1
    /// Comments typed in a card sheet that went away without Done or Cancel,
    /// kept for this launch so they come back when the card opens again.
    var commentDrafts: [UUID: String] = [:]

    var isAvailable: Bool { fileURL != nil }

    static func shared(
        workspacePath: String,
        applicationSupport: URL = applicationSupportDirectory
    ) -> BoardStore {
        let workspace = canonicalWorkspace(workspacePath)
        let key = StoreKey(
            root: applicationSupport.standardizedFileURL.resolvingSymlinksInPath().path,
            workspace: workspace
        )
        if let existing = stores[key] { return existing }
        let store = BoardStore(canonicalWorkspace: workspace, applicationSupport: applicationSupport)
        stores[key] = store
        return store
    }

    /// A non-shared store keeps tests out of the user's Application Support.
    static func testingStore(workspacePath: String, applicationSupport: URL) -> BoardStore {
        BoardStore(
            canonicalWorkspace: canonicalWorkspace(workspacePath),
            applicationSupport: applicationSupport
        )
    }

    static func storageIdentity(workspacePath: String) -> String {
        "board\u{0}" + canonicalWorkspace(workspacePath)
    }

    /// `SessionSummary.canonicalWorkspacePath("")` resolves to the process's
    /// working directory, so a blank path must never reach it.
    static func canonicalWorkspace(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : SessionSummary.canonicalWorkspacePath(trimmed)
    }

    /// The first three ASCII letters or digits of the workspace folder name.
    /// Accented letters count as their base letter (`été` gives `ETE`).
    nonisolated static func keyPrefix(forWorkspace path: String) -> String {
        guard !path.isEmpty else { return "CARD" }
        var prefix = ""
        let name = URL(fileURLWithPath: path).lastPathComponent.decomposedStringWithCanonicalMapping
        for scalar in name.unicodeScalars
        where prefix.unicodeScalars.count < 3 && isKeyScalar(scalar) {
            prefix.unicodeScalars.append(scalar)
        }
        return prefix.isEmpty ? "CARD" : prefix.uppercased()
    }

    private init(canonicalWorkspace: String, applicationSupport: URL) {
        workspacePath = canonicalWorkspace
        keyPrefix = Self.keyPrefix(forWorkspace: canonicalWorkspace)
        fileURL = canonicalWorkspace.isEmpty ? nil : applicationSupport
            .appendingPathComponent(AppEdition.current.displayName, isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent("\(NotesStore.digest(of: canonicalWorkspace)).json")
        reload()
    }

    // MARK: - Lookup

    func key(for card: BoardCard) -> String {
        "\(keyPrefix)-\(card.number)"
    }

    func cards(in columnID: String) -> [BoardCard] {
        cards.filter { $0.columnID == columnID }
    }

    /// A copy of the board for work that runs off the main actor.
    var snapshot: BoardSnapshot {
        BoardSnapshot(workspacePath: workspacePath, keyPrefix: keyPrefix, columns: columns, cards: cards)
    }

    /// Accepts a key (`LOC-12`, any case), a number (`12` or `#12`), or a UUID.
    func card(matching reference: String) -> BoardCard? {
        snapshot.card(matching: reference)
    }

    /// Accepts a column id or title, case-insensitively, or both the way
    /// `board_read` lists them (`In Progress [in-progress]`). Nil when
    /// nothing matches or the reference is ambiguous.
    func column(matching reference: String) -> BoardColumn? {
        try? snapshot.resolveColumn(reference)
    }

    func requireColumn(matching reference: String) throws -> BoardColumn {
        try snapshot.requireColumn(matching: reference)
    }

    // MARK: - Mutations

    @discardableResult
    func createCard(
        title: String,
        details: String = "",
        columnID: String? = nil,
        priority: BoardPriority = .none,
        labels: [String] = [],
        assignee: String? = nil,
        agentIDs: [UUID] = [],
        position: Int? = nil,
        author: BoardAuthor = .user
    ) throws -> BoardCard {
        guard agentIDs.count <= 64 else { throw BoardStoreError.invalidArgument("Tag at most 64 agents.") }
        let title = try Self.validatedTitle(title)
        let details = try Self.validatedDetails(details)
        let labels = try Self.validatedLabels(labels)
        let assignee = try Self.validatedAssignee(assignee)
        return try commit(by: author) { state in
            guard state.cards.count < Self.maximumCards else { throw BoardStoreError.boardFull }
            // Numbering stops after the last number; the saved next number
            // (one past it) still loads, and nothing here can overflow.
            guard BoardFile.cardNumbers.contains(state.nextNumber) else {
                throw BoardStoreError.cardNumbersExhausted
            }
            let column = try Self.requireColumn(columnID ?? state.columns[0].id, in: state.columns)
            let now = Self.timestamp()
            let card = BoardCard(
                id: UUID(),
                number: state.nextNumber,
                title: title,
                details: details,
                columnID: column.id,
                priority: priority,
                labels: labels,
                assignee: assignee,
                createdAt: now,
                updatedAt: now,
                createdBy: author,
                timeline: [BoardTimelineEntry(
                    kind: .activity,
                    author: author,
                    text: "Created in \(column.title)",
                    createdAt: now
                )],
                agentIDs: Array(Set(agentIDs)).sorted { $0.uuidString < $1.uuidString }
            )
            state.nextNumber += 1
            Self.insert(card, at: position, into: &state.cards)
            return card
        }
    }

    /// Only non-nil arguments change. `assignee` is doubly optional: `nil`
    /// leaves it alone, while `.some(nil)` or `""` clears it.
    func updateCard(
        _ id: UUID,
        title: String? = nil,
        details: String? = nil,
        priority: BoardPriority? = nil,
        labels: [String]? = nil,
        assignee: String?? = nil,
        agentIDs: [UUID]? = nil,
        author: BoardAuthor = .user
    ) throws {
        try commit(by: author) { state in
            _ = try Self.applyUpdate(
                id, title: title, details: details, priority: priority,
                labels: labels, assignee: assignee, agentIDs: agentIDs, author: author, in: &state
            )
        }
    }

    /// `position` is a 0-based index among the destination column's cards;
    /// nil appends when changing columns and keeps the card in place otherwise.
    func moveCard(
        _ id: UUID,
        toColumn columnID: String,
        position: Int? = nil,
        author: BoardAuthor = .user
    ) throws {
        try commit(by: author) { state in
            _ = try Self.move(id, to: columnID, position: position, author: author, in: &state)
        }
    }

    func addComment(to id: UUID, text: String, author: BoardAuthor = .user) throws {
        let text = try Self.validatedComment(text)
        try commit(by: author) { state in
            let index = try Self.requireCardIndex(id, in: state.cards)
            let now = Self.timestamp()
            var card = state.cards[index]
            card.timeline.append(BoardTimelineEntry(kind: .comment, author: author, text: text, createdAt: now))
            card.timeline = Self.trimmedTimeline(card.timeline)
            card.updatedAt = now
            state.cards[index] = card
        }
    }

    func deleteCard(_ id: UUID) throws {
        try commit(by: nil) { state in
            let index = try Self.requireCardIndex(id, in: state.cards)
            state.cards.remove(at: index)
        }
    }

    /// The UI's delete: a card someone else already removed is the outcome
    /// the user asked for, not an error. False when it was already gone.
    @discardableResult
    func deleteCardIfPresent(_ id: UUID) throws -> Bool {
        guard cards.contains(where: { $0.id == id }) else { return false }
        try deleteCard(id)
        return true
    }

    @discardableResult
    func addColumn(title: String) throws -> BoardColumn {
        let title = try Self.validatedColumnTitle(title)
        return try commit(by: nil) { state in
            guard state.columns.count < Self.maximumColumns else { throw BoardStoreError.tooManyColumns }
            guard !state.columns.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) else {
                throw BoardStoreError.duplicateColumn(title)
            }
            let column = BoardColumn(id: Self.uniqueColumnID(for: title, in: state.columns), title: title)
            state.columns.append(column)
            return column
        }
    }

    func renameColumn(_ id: String, to title: String) throws {
        let title = try Self.validatedColumnTitle(title)
        try commit(by: nil) { state in
            let index = try Self.requireColumnIndex(id, in: state.columns)
            guard !state.columns.contains(where: {
                $0.id != id && $0.title.caseInsensitiveCompare(title) == .orderedSame
            }) else { throw BoardStoreError.duplicateColumn(title) }
            state.columns[index].title = title
        }
    }

    /// Only an empty column can be deleted, and the last column never can.
    func deleteColumn(_ id: String) throws {
        try commit(by: nil) { state in
            let index = try Self.requireColumnIndex(id, in: state.columns)
            guard !state.cards.contains(where: { $0.columnID == id }) else {
                throw BoardStoreError.columnNotEmpty(state.columns[index].title)
            }
            guard state.columns.count > 1 else { throw BoardStoreError.lastColumn }
            state.columns.remove(at: index)
        }
    }

    func moveColumn(_ id: String, by offset: Int) throws {
        try commit(by: nil) { state in
            let index = try Self.requireColumnIndex(id, in: state.columns)
            let target = min(max(index + offset, 0), state.columns.count - 1)
            guard target != index else { return }
            let column = state.columns.remove(at: index)
            state.columns.insert(column, at: target)
        }
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Agent bridge

    /// Execute the native Board tool family. The workspace comes from the
    /// socket that asked and the author from AppModel; neither can be chosen
    /// through `arguments`.
    func perform(tool: String, arguments: [String: Any], author: BoardAuthor) -> [String: Any] {
        do {
            guard isAvailable else { throw BoardStoreError.workspaceRequired }
            switch tool {
            case "board_read":
                return try snapshot.read(BoardReadRequest(arguments)).payload
            case "board_create_card":
                return try performCreate(arguments, author: author)
            case "board_update_card":
                return try performUpdate(arguments, author: author)
            case "board_comment":
                let card = try requireCard(arguments, tool: tool)
                guard let text = try BoardToolArguments.string(arguments, "text") else {
                    throw BoardStoreError.missingArgument(tool: tool, name: "text")
                }
                try addComment(to: card.id, text: text, author: author)
                return ["text": "Commented on \(key(for: card)).", "card_id": key(for: card)]
            case "board_delete_card":
                let card = try requireCard(arguments, tool: tool)
                try commit(by: author) { state in
                    let index = try Self.requireCardIndex(card.id, in: state.cards)
                    state.cards.remove(at: index)
                }
                return ["text": "Deleted \(key(for: card)) “\(card.title)”."]
            default:
                return ["error": "Unknown Board tool: \(tool)."]
            }
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Composer text for a card's "Work on this in chat".
    func chatPrompt(for card: BoardCard) -> String {
        var parts = ["Work on board card \(key(for: card)): \(card.title)"]
        if !card.details.isEmpty { parts.append(card.details) }
        parts.append("When you make progress, update the card with board_update_card / board_comment.")
        return parts.joined(separator: "\n\n")
    }

    private func performCreate(_ arguments: [String: Any], author: BoardAuthor) throws -> [String: Any] {
        guard let title = try BoardToolArguments.string(arguments, "title") else {
            throw BoardStoreError.missingArgument(tool: "board_create_card", name: "title")
        }
        let column = try BoardToolArguments.nonBlankString(arguments, "column")
            .map { try requireColumn(matching: $0) }
        let card = try createCard(
            title: title,
            details: try BoardToolArguments.string(arguments, "description") ?? "",
            columnID: column?.id,
            priority: try BoardToolArguments.priority(arguments) ?? BoardPriority.none,
            labels: try BoardToolArguments.labels(arguments) ?? [],
            assignee: try BoardToolArguments.string(arguments, "assignee"),
            agentIDs: try BoardToolArguments.agentIDs(arguments) ?? [],
            position: try BoardToolArguments.int(arguments, "position"),
            author: author
        )
        let columnTitle = columns.first { $0.id == card.columnID }?.title ?? card.columnID
        return [
            "text": "Created \(key(for: card)) “\(card.title)” in \(columnTitle).",
            "card_id": key(for: card),
        ]
    }

    private func performUpdate(_ arguments: [String: Any], author: BoardAuthor) throws -> [String: Any] {
        let tool = "board_update_card"
        let card = try requireCard(arguments, tool: tool)
        let title = try BoardToolArguments.string(arguments, "title")
        let details = try BoardToolArguments.string(arguments, "description")
        let priority = try BoardToolArguments.priority(arguments)
        let labels = try BoardToolArguments.labels(arguments)
        let agentIDs = try BoardToolArguments.agentIDs(arguments)
        let assignee: String?? = try BoardToolArguments.string(arguments, "assignee").map { .some($0) }
        let column = try BoardToolArguments.nonBlankString(arguments, "column")
            .map { try requireColumn(matching: $0) }
        let position = try BoardToolArguments.int(arguments, "position")
        guard title != nil || details != nil || priority != nil || labels != nil
            || assignee != nil || agentIDs != nil || column != nil || position != nil
        else {
            throw BoardStoreError.invalidArgument(
                "\(tool) needs at least one of title, description, column, position, priority, labels, assignee, or agent_ids."
            )
        }
        // Fields and the move land in one save, so a rejected value changes nothing.
        let changes = try commit(by: author) { state -> [String] in
            var changes: [String] = []
            if column != nil || position != nil,
               let moved = try Self.move(
                   card.id, to: column?.id ?? card.columnID, position: position,
                   author: author, in: &state
               ) {
                changes.append(moved)
            }
            changes += try Self.applyUpdate(
                card.id, title: title, details: details, priority: priority,
                labels: labels, assignee: assignee, agentIDs: agentIDs, author: author, in: &state
            )
            return changes
        }
        let key = key(for: card)
        guard !changes.isEmpty else {
            return ["text": "\(key) already matches; nothing changed.", "card_id": key]
        }
        return ["text": "Updated \(key): \(changes.joined(separator: "; ")).", "card_id": key]
    }

    private func requireCard(_ arguments: [String: Any], tool: String) throws -> BoardCard {
        guard let reference = try BoardToolArguments.reference(arguments, "card_id") else {
            throw BoardStoreError.missingArgument(tool: tool, name: "card_id")
        }
        guard let card = card(matching: reference) else { throw BoardStoreError.cardNotFound(reference) }
        return card
    }

    // MARK: - State changes

    /// Apply one change to a copy, save it, then publish it. Validation and
    /// save failures leave the published board exactly as it was.
    @discardableResult
    private func commit<T>(by author: BoardAuthor?, _ change: (inout State) throws -> T) throws -> T {
        guard let fileURL else { throw BoardStoreError.workspaceRequired }
        let current = State(columns: columns, cards: cards, nextNumber: nextNumber)
        var next = current
        let result = try change(&next)
        guard next != current else { return result }
        do {
            try write(&next, to: fileURL)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        if next.columns != current.columns { columns = next.columns }
        if next.cards != current.cards { cards = next.cards }
        nextNumber = next.nextNumber
        if lastError != nil { lastError = nil }
        if author?.kind == .agent { lastAgentChange = Date() }
        return result
    }

    /// Returns tool summaries of what changed; records one activity per change.
    private static func applyUpdate(
        _ id: UUID,
        title: String?,
        details: String?,
        priority: BoardPriority?,
        labels: [String]?,
        assignee: String??,
        agentIDs: [UUID]? = nil,
        author: BoardAuthor,
        in state: inout State
    ) throws -> [String] {
        let title = try title.map(validatedTitle)
        let details = try details.map(validatedDetails)
        let labels = try labels.map(validatedLabels)
        let assignee = try assignee.map(validatedAssignee)
        let index = try requireCardIndex(id, in: state.cards)
        var card = state.cards[index]
        var activity: [String] = []
        var summaries: [String] = []
        if let title, title != card.title {
            card.title = title
            activity.append("Renamed to “\(title)”")
            summaries.append("title “\(title)”")
        }
        if let details, details != card.details {
            card.details = details
            activity.append(details.isEmpty ? "Cleared the description" : "Updated the description")
            summaries.append(details.isEmpty ? "description cleared" : "description updated")
        }
        if let priority, priority != card.priority {
            card.priority = priority
            activity.append("Set priority to \(priority.title)")
            summaries.append("priority \(priority.rawValue)")
        }
        if let labels, labels != card.labels {
            card.labels = labels
            let list = labels.joined(separator: ", ")
            activity.append(labels.isEmpty ? "Cleared labels" : "Set labels to \(list)")
            summaries.append(labels.isEmpty ? "labels cleared" : "labels \(list)")
        }
        if let assignee, assignee != card.assignee {
            card.assignee = assignee
            activity.append(assignee.map { "Assigned to \($0)" } ?? "Cleared the assignee")
            summaries.append(assignee.map { "assignee \($0)" } ?? "assignee cleared")
        }
        if let agentIDs {
            guard agentIDs.count <= 64 else { throw BoardStoreError.invalidArgument("Tag at most 64 agents.") }
            let ids = Array(Set(agentIDs)).sorted { $0.uuidString < $1.uuidString }
            if ids != (card.agentIDs ?? []).sorted(by: { $0.uuidString < $1.uuidString }) {
                card.agentIDs = ids
                activity.append(ids.isEmpty ? "Cleared tagged agents" : "Updated tagged agents")
                summaries.append("tagged agents updated")
            }
        }
        guard !activity.isEmpty else { return [] }
        record(activity, by: author, on: &card)
        state.cards[index] = card
        return summaries
    }

    /// Returns a tool summary, or nil when the card already sits there.
    private static func move(
        _ id: UUID,
        to columnID: String,
        position: Int?,
        author: BoardAuthor,
        in state: inout State
    ) throws -> String? {
        let index = try requireCardIndex(id, in: state.cards)
        let destination = try requireColumn(columnID, in: state.columns)
        var card = state.cards[index]
        let source = state.columns.first { $0.id == card.columnID } ?? destination
        let changesColumn = source.id != destination.id
        guard changesColumn || position != nil else { return nil }
        let oldPosition = state.cards[..<index].filter { $0.columnID == destination.id }.count
        var remaining = state.cards
        remaining.remove(at: index)
        let available = remaining.filter { $0.columnID == destination.id }.count
        let newPosition = min(max(position ?? available, 0), available)
        guard changesColumn || newPosition != oldPosition else { return nil }
        card.columnID = destination.id
        if changesColumn {
            record(["Moved from \(source.title) to \(destination.title)"], by: author, on: &card)
        } else {
            record(["Reordered within \(destination.title)"], by: author, on: &card)
        }
        insert(card, at: newPosition, into: &remaining)
        state.cards = remaining
        guard changesColumn else { return "position \(newPosition) in \(destination.title)" }
        let placement = position == nil ? "" : " at position \(newPosition)"
        return "moved \(source.title) → \(destination.title)\(placement)"
    }

    private static func record(_ activity: [String], by author: BoardAuthor, on card: inout BoardCard) {
        let now = timestamp()
        card.timeline += activity.map {
            BoardTimelineEntry(kind: .activity, author: author, text: $0, createdAt: now)
        }
        card.timeline = trimmedTimeline(card.timeline)
        card.updatedAt = now
    }

    /// The board keeps one array, so a column position maps to the array
    /// index of the sibling currently at that position.
    /// Out-of-range positions clamp: below zero is the top, past the end appends.
    private static func insert(_ card: BoardCard, at position: Int?, into cards: inout [BoardCard]) {
        let siblings = cards.indices.filter { cards[$0].columnID == card.columnID }
        if let position {
            let index = max(position, 0)
            if index < siblings.count {
                cards.insert(card, at: siblings[index])
                return
            }
        }
        cards.append(card)
    }

    /// Keeps the newest entries, dropping the oldest activity before any comment.
    static func trimmedTimeline(_ timeline: [BoardTimelineEntry]) -> [BoardTimelineEntry] {
        guard timeline.count > maximumTimelineEntries else { return timeline }
        let activityCount = timeline.lazy.filter { $0.kind == .activity }.count
        var activityToDrop = min(timeline.count - maximumTimelineEntries, activityCount)
        var kept: [BoardTimelineEntry] = []
        kept.reserveCapacity(timeline.count - activityToDrop)
        for entry in timeline {
            if activityToDrop > 0, entry.kind == .activity {
                activityToDrop -= 1
                continue
            }
            kept.append(entry)
        }
        if kept.count > maximumTimelineEntries {
            kept.removeFirst(kept.count - maximumTimelineEntries)
        }
        return kept
    }

    private static func requireCardIndex(_ id: UUID, in cards: [BoardCard]) throws -> Int {
        guard let index = cards.firstIndex(where: { $0.id == id }) else {
            throw BoardStoreError.cardNotFound(id.uuidString)
        }
        return index
    }

    private static func requireColumnIndex(_ id: String, in columns: [BoardColumn]) throws -> Int {
        guard let index = columns.firstIndex(where: { $0.id == id }) else {
            throw BoardStoreError.columnNotFound(id, available: columns.map(\.title))
        }
        return index
    }

    private static func requireColumn(_ id: String, in columns: [BoardColumn]) throws -> BoardColumn {
        columns[try requireColumnIndex(id, in: columns)]
    }

    private static func uniqueColumnID(for title: String, in columns: [BoardColumn]) -> String {
        var slug = ""
        for scalar in title.lowercased().unicodeScalars {
            if isKeyScalar(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        let base = slug.isEmpty ? "column" : slug
        let taken = Set(columns.map { $0.id.lowercased() })
        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    nonisolated static func isKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    // MARK: - Persistence

    /// ISO-8601 keeps whole seconds, so stored times start that way and a
    /// reloaded board compares equal to the one that was saved.
    private static func timestamp() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    /// Re-read the board. A file that cannot be used is left untouched until
    /// the next change replaces it; `lastError` says why it was skipped.
    func reload() {
        var document: BoardDocument?
        var failure: Error?
        if let fileURL {
            do { document = try BoardFile.read(at: fileURL, workspacePath: workspacePath) }
            catch { failure = error }
        }
        columns = document?.columns ?? Self.defaultColumns
        cards = document?.cards ?? []
        nextNumber = document?.nextNumber ?? 1
        keyPrefix = document?.keyPrefix ?? Self.keyPrefix(forWorkspace: workspacePath)
        lastError = failure.map {
            "The saved board could not be opened because \($0.localizedDescription). "
                + "It will be replaced the next time the board changes."
        }
    }

    /// Saves `state`. When the board would pass the file limit, old activity
    /// is dropped first (finished cards before others, oldest first) so busy
    /// boards keep working; comments are never dropped to make room.
    private func write(_ state: inout State, to url: URL) throws {
        var data = try encoded(state)
        while data.count > Self.maximumFileBytes {
            guard let trimmed = BoardFile.removingActivity(
                from: state.cards,
                doneColumnID: BoardSnapshot.doneColumn(in: state.columns)?.id,
                bytes: data.count - Self.maximumFileBytes
            ) else { throw BoardStoreError.boardTooLarge }
            state.cards = trimmed
            data = try encoded(state)
        }
        do { try NotebookFileIO.write(data, to: url) }
        catch { throw BoardStoreError.saveFailed(error.localizedDescription) }
    }

    private func encoded(_ state: State) throws -> Data {
        try BoardFile.saveData(for: BoardDocument(
            version: BoardDocument.currentVersion,
            workspacePath: workspacePath,
            keyPrefix: keyPrefix,
            nextNumber: state.nextNumber,
            columns: state.columns,
            cards: state.cards,
            updatedAt: Self.timestamp()
        ), workspacePath: workspacePath)
    }
}
