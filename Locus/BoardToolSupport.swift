import Foundation

/// Reads Board tool arguments decoded from JSON. Numbers may arrive as
/// `NSNumber`, and a `null` counts as not supplied.
enum BoardToolArguments {
    private static func value(_ arguments: [String: Any], _ key: String) -> Any? {
        guard let value = arguments[key], !(value is NSNull) else { return nil }
        return value
    }

    static func string(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard let raw = value(arguments, key) else { return nil }
        guard let string = raw as? String else {
            throw BoardStoreError.invalidArgument("\(key) must be a string.")
        }
        return string
    }

    static func agentIDs(_ arguments: [String: Any]) throws -> [UUID]? {
        guard let raw = value(arguments, "agent_ids") else { return nil }
        guard let values = raw as? [String], values.count <= 64,
              values.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw BoardStoreError.invalidArgument("agent_ids must contain at most 64 agent UUIDs.")
        }
        return values.compactMap(UUID.init(uuidString:))
    }

    /// A blank string counts as not supplied.
    static func nonBlankString(_ arguments: [String: Any], _ key: String) throws -> String? {
        try string(arguments, key).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    /// Card references are strings, but a bare number is accepted as well.
    static func reference(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard let raw = value(arguments, key) else { return nil }
        if let string = raw as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let number = raw as? Int { return String(number) }
        throw BoardStoreError.invalidArgument("\(key) must be a card key, number, or id.")
    }

    static func int(_ arguments: [String: Any], _ key: String) throws -> Int? {
        guard let raw = value(arguments, key) else { return nil }
        if let number = raw as? Int { return number }
        if let number = raw as? Double, number.isFinite, number == number.rounded(),
           abs(number) <= 1_000_000 {
            return Int(number)
        }
        if let text = raw as? String, let number = Int(text.trimmingCharacters(in: .whitespaces)) {
            return number
        }
        throw BoardStoreError.invalidArgument("\(key) must be a whole number.")
    }

    static func bool(_ arguments: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = value(arguments, key) else { return nil }
        if let flag = raw as? Bool { return flag }
        switch (raw as? String)?.lowercased() {
        case "true": return true
        case "false": return false
        default: throw BoardStoreError.invalidArgument("\(key) must be true or false.")
        }
    }

    /// An array of strings; a comma-separated string is accepted as well.
    static func labels(_ arguments: [String: Any]) throws -> [String]? {
        guard let raw = value(arguments, "labels") else { return nil }
        if let text = raw as? String {
            return text.split(separator: ",").map(String.init)
        }
        let invalid = BoardStoreError.invalidArgument("labels must be an array of strings.")
        guard let list = raw as? [Any] else { throw invalid }
        return try list.map { item in
            guard let label = item as? String else { throw invalid }
            return label
        }
    }

    static func priority(_ arguments: [String: Any]) throws -> BoardPriority? {
        guard let raw = try nonBlankString(arguments, "priority") else { return nil }
        guard let priority = BoardPriority(rawValue: raw.lowercased()) else {
            let names = BoardPriority.allCases.map(\.rawValue).joined(separator: ", ")
            throw BoardStoreError.invalidArgument("priority must be one of \(names).")
        }
        return priority
    }
}

/// What `board_read` found: the text agents see and the cards behind it.
/// Everything that scans card text is worked out with the text, so turning
/// this into a tool result only assembles values.
struct BoardReadResult: Sendable {
    struct ColumnSummary: Sendable {
        let column: BoardColumn
        let cardCount: Int
        let matching: Int?
    }

    struct Listed: Sendable {
        let card: BoardCard
        /// The whole description for a single card's read, the overview's
        /// excerpt otherwise.
        let description: String
    }

    let text: String
    let listed: [Listed]
    /// A single card's full read, with its whole description and timeline.
    let full: Bool
    let columns: [ColumnSummary]
    let truncated: Bool?
    let snapshot: BoardSnapshot

    /// The tool result: `text` plus structured copies for callers that want them.
    var payload: [String: Any] {
        var payload: [String: Any] = [
            "text": text,
            "cards": listed.map { snapshot.payload(for: $0, full: full) },
            "columns": columns.map(BoardSnapshot.columnPayload),
        ]
        if let truncated { payload["truncated"] = truncated }
        return payload
    }
}

extension BoardStore {
    /// `perform`, except that `board_read` matches and formats a copy of the
    /// board off the main actor, so a large board or a costly query never
    /// stalls the app. Arguments are checked here first.
    func performDetached(tool: String, arguments: [String: Any], author: BoardAuthor) async -> [String: Any] {
        guard tool == "board_read", isAvailable else {
            return perform(tool: tool, arguments: arguments, author: author)
        }
        let request: BoardReadRequest
        do { request = try BoardReadRequest(arguments) }
        catch { return ["error": error.localizedDescription] }
        let snapshot = snapshot
        let outcome = await Task.detached(priority: .userInitiated) {
            Result { try snapshot.read(request) }
        }.value
        switch outcome {
        case .success(let result): return result.payload
        case .failure(let error): return ["error": error.localizedDescription]
        }
    }
}

/// `board_read`. The runtime forwards only `text` or `error`, and keeps only
/// its first 30,000 code points, so the text is budgeted below that and says
/// what it left out. Every field is clipped in code points, so no one card
/// can crowd out the rest. Free text is quoted line by line (`> ` for a
/// description, `  > ` for a comment or an overview excerpt) and author
/// names sit between curly quotes they cannot contain, so a description,
/// comment, or name can never pass for a heading or a timeline entry.
extension BoardSnapshot {
    static let readTextBudget = 28_000
    /// What a busy timeline keeps even beside a long description.
    static let timelineReserve = 8_000
    /// Headings, omission notes, and separators around the budgeted parts.
    private static let layoutReserve = 400
    /// Clip lengths, in code points, for fields shown inline.
    private enum Clip {
        static let title = BoardStore.maximumTitleScalars
        static let labels = BoardStore.maximumLabels * (BoardStore.maximumLabelScalars + 2)
        static let assignee = BoardStore.maximumAssigneeScalars
        static let columnTitle = BoardStore.maximumColumnTitleScalars
        static let columnID = 400
        static let author = BoardAuthor.maximumNameScalars
        static let workspace = 200
        static let excerpt = BoardStore.overviewDescriptionLength * 2
    }

    private static let timeStyle = Date.ISO8601FormatStyle()

    func read(_ request: BoardReadRequest) throws -> BoardReadResult {
        if let reference = request.cardReference {
            guard let card = card(matching: reference) else {
                throw BoardStoreError.cardNotFound(reference)
            }
            var counts: [String: Int] = [:]
            for card in cards { counts[card.columnID, default: 0] += 1 }
            return BoardReadResult(
                text: detailText(for: card), listed: [.init(card: card, description: card.details)], full: true,
                columns: columns.map { .init(column: $0, cardCount: counts[$0.id] ?? 0, matching: nil) },
                truncated: nil, snapshot: self
            )
        }
        let column = try request.column.map { try requireColumn(matching: $0) }
        // An explicit column wins over include_done.
        let hiddenColumn = request.includeDone || column != nil ? nil : Self.doneColumn(in: columns)
        var folding = BoardSearchFolding()
        let assignee = request.assignee.map { folding.fold($0) }
        let pattern = request.query.map { BoardSearchPattern(folding.fold($0)) }
        // Each card is folded once; the search itself is linear.
        let isMatch: (BoardCard) -> Bool = { card in
            if let assignee, card.assignee.map({ folding.fold($0) }) != assignee { return false }
            guard let pattern else { return true }
            return ([key(for: card), card.title, card.details] + card.labels)
                .contains { pattern.occurs(in: folding.fold($0)) }
        }

        var filters: [String] = []
        if let column { filters.append("column \(Self.field(column.title, Clip.columnTitle))") }
        if let assignee = request.assignee { filters.append("assignee “\(BoardText.inline(assignee))”") }
        if let query = request.query { filters.append("query “\(BoardText.inline(query))”") }
        if let hiddenColumn { filters.append("excluding \(Self.field(hiddenColumn.title, Clip.columnTitle))") }
        let workspaceName = URL(fileURLWithPath: workspacePath).lastPathComponent
        var head = [
            "Board for “\(Self.field(workspaceName, Clip.workspace))”: \(Self.count(cards.count, "card", "cards")) in "
                + "\(Self.count(columns.count, "column", "columns")). Card keys look like "
                + "\(keyPrefix)-12; pass one as card_id to read a card with its comments.",
        ]
        if !filters.isEmpty { head.append("Filters: \(filters.joined(separator: ", ")).") }

        let sections = columns
            .filter { (column == nil || $0.id == column?.id) && $0.id != hiddenColumn?.id }
            .map { shown -> (column: BoardColumn, total: Int, visible: [BoardCard]) in
                let inColumn = cards(in: shown.id)
                return (shown, inColumn.count, inColumn.filter(isMatch))
            }
        let matchingTotal = sections.reduce(0) { $0 + $1.visible.count }
        let headings = sections.map { section in
            let count = filters.isEmpty
                ? Self.count(section.total, "card", "cards")
                : "\(section.visible.count) of \(Self.count(section.total, "card", "cards"))"
            return "## \(Self.columnLabel(section.column)) · \(count)"
        }
        // Headings and a closing line per column are always shown; cards fill the rest.
        var remaining = Self.readTextBudget - Self.layoutReserve - Self.size(head.joined(separator: "\n"))
            - headings.reduce(0) { $0 + Self.size($1) + 60 }

        var body: [String] = []
        var listed: [BoardReadResult.Listed] = []
        var summaries: [BoardReadResult.ColumnSummary] = []
        var skippedForRoom = false
        for (section, heading) in zip(sections, headings) {
            summaries.append(.init(
                column: section.column, cardCount: section.total,
                matching: filters.isEmpty ? nil : section.visible.count
            ))
            body.append("")
            body.append(heading)
            if section.visible.isEmpty {
                body.append(filters.isEmpty ? "No cards." : "No matching cards.")
                continue
            }
            var shownHere = 0
            for card in section.visible {
                guard listed.count < BoardStore.maximumListedCards else { break }
                var entry = overviewLine(for: card)
                let excerpt = Self.excerpt(card.details)
                if !excerpt.isEmpty { entry += "\n  > \(excerpt)" }
                let cost = Self.size(entry) + 1
                // A card too long for what is left is counted, not shown,
                // and shorter cards after it still are.
                guard cost <= remaining else {
                    skippedForRoom = true
                    continue
                }
                remaining -= cost
                body.append(entry)
                listed.append(.init(card: card, description: excerpt))
                shownHere += 1
            }
            if shownHere < section.visible.count {
                body.append("(\(section.visible.count - shownHere) more not listed)")
            }
        }
        let truncated = matchingTotal > listed.count
        if truncated {
            // Up top, where a cut-off reply still carries it.
            head.append(
                (skippedForRoom
                    ? "Showing \(listed.count) of \(matchingTotal) matching cards; the rest did not fit "
                        + "and are counted under their columns. "
                    : "Showing the first \(listed.count) of \(matchingTotal) matching cards. ")
                    + "Narrow the list with column, assignee, or query."
            )
        }
        return BoardReadResult(
            text: Self.bounded((head + body).joined(separator: "\n")), listed: listed, full: false,
            columns: summaries, truncated: truncated, snapshot: self
        )
    }

    private func overviewLine(for card: BoardCard) -> String {
        var parts = ["- \(key(for: card)) “\(Self.field(card.title, Clip.title))”"]
        if card.priority != BoardPriority.none { parts.append("priority \(card.priority.rawValue)") }
        if !card.labels.isEmpty { parts.append("labels: \(Self.labelList(card.labels))") }
        parts.append(card.assignee.map { "assignee: \(Self.field($0, Clip.assignee))" } ?? "unassigned")
        if card.commentCount > 0 {
            parts.append(Self.count(card.commentCount, "comment", "comments"))
        }
        parts.append("updated \(Self.time(card.updatedAt))")
        return parts.joined(separator: " · ")
    }

    /// The header and fields, the description (clipped only when the newest
    /// timeline entries would not fit beside it), and as many of the newest
    /// entries as fit, printed oldest first.
    private func detailText(for card: BoardCard) -> String {
        let column = columns.first { $0.id == card.columnID } ?? BoardColumn(id: card.columnID, title: card.columnID)
        let lastAuthor = card.timeline.last?.author ?? card.createdBy
        let header = [
            "\(key(for: card)) “\(Self.field(card.title, Clip.title))”",
            "Column: \(Self.columnLabel(column))",
            "Priority: \(card.priority.rawValue)",
            "Labels: \(card.labels.isEmpty ? "none" : Self.labelList(card.labels))",
            "Assignee: \(card.assignee.map { Self.field($0, Clip.assignee) } ?? "unassigned")",
            (card.agentIDs ?? []).isEmpty ? nil : "Tagged agent IDs: \((card.agentIDs ?? []).map(\.uuidString).joined(separator: ", "))",
            "Created: \(Self.time(card.createdAt)) by \(Self.label(card.createdBy))",
            "Updated: \(Self.time(card.updatedAt)) by \(Self.label(lastAuthor))",
            "",
            "Description:",
        ].compactMap { $0 }.joined(separator: "\n")

        let entries = card.timeline.map { Self.entryText($0, limit: nil) }
        let timelineSize = entries.reduce(0) { $0 + Self.size($1) + 1 }
        let available = Self.readTextBudget - Self.layoutReserve - Self.size(header)
        let description: String
        if card.details.isEmpty {
            description = "(none)"
        } else {
            let limit = available - min(timelineSize, Self.timelineReserve)
            description = Self.quoted(card.details, prefix: "> ", limit: limit, clippedNote: { hidden in
                "…(description clipped: \(hidden) not shown)"
            })
        }

        var room = available - Self.size(description)
        var kept: [String] = []
        for (index, entry) in zip(card.timeline.indices, entries).reversed() {
            let cost = Self.size(entry) + 1
            if cost <= room {
                kept.append(entry)
                room -= cost
                continue
            }
            // The newest entry always shows, clipped if it has to be.
            if kept.isEmpty { kept.append(Self.entryText(card.timeline[index], limit: max(room, 0))) }
            break
        }
        kept.reverse()
        let omitted = card.timeline.count - kept.count
        let total = Self.count(card.timeline.count, "entry", "entries")
        var lines = [header, description, ""]
        if omitted > 0 {
            lines.append("Timeline (newest \(kept.count) of \(total), oldest first):")
            lines.append("(\(Self.count(omitted, "older entry", "older entries")) omitted)")
        } else {
            lines.append("Timeline (\(total), oldest first):")
        }
        if card.timeline.isEmpty { lines.append("No comments or activity yet.") }
        lines += kept
        return Self.bounded(lines.joined(separator: "\n"))
    }

    /// Activity is app-written and stays on its line. A comment's text goes
    /// on quoted lines of its own below the entry line.
    private static func entryText(_ entry: BoardTimelineEntry, limit: Int?) -> String {
        let line = "- \(time(entry.createdAt)) · \(label(entry.author)) · \(entry.kind.rawValue):"
        switch entry.kind {
        case .activity:
            let text = "\(line) \(BoardText.inline(entry.text))"
            guard let limit, size(text) > limit else { return text }
            return BoardText.clipped(text[...], toScalars: max(limit - 1, 0)) + "…"
        case .comment:
            let body = quoted(entry.text, prefix: "  > ", limit: (limit ?? .max) - size(line) - 1) { hidden in
                "  …(comment clipped: \(hidden) not shown)"
            }
            return "\(line)\n\(body)"
        }
    }

    /// Every line of `text` behind `prefix`, splitting at any newline
    /// character, within `limit` code points. When it does not all fit, the
    /// rest is replaced by the clipped note, which counts toward the limit
    /// and says how many lines and characters were left out, so a clip in a
    /// run of blank lines never hides text unannounced.
    private static func quoted(
        _ text: String,
        prefix: String,
        limit: Int,
        clippedNote: (String) -> String
    ) -> String {
        let source = BoardText.lines(text)
        let prefixSize = size(prefix)
        let costs = source.map { prefixSize + $0.unicodeScalars.count + 1 }
        guard costs.reduce(0, +) > limit else {
            return source.map { prefix + $0 }.joined(separator: "\n")
        }
        let total = source.reduce(0) { $0 + $1.unicodeScalars.count }
        // The note for everything hidden is the longest the note can be.
        let longestNote = clippedNote(hiddenSummary(lines: source.count, characters: max(total, 1)))
        let room = limit - (size(longestNote) + 1)
        var output: [String] = []
        var used = 0
        var shown = 0
        var started = 0
        for (line, cost) in zip(source, costs) {
            if used + cost <= room {
                output.append(prefix + line)
                used += cost
                shown += cost - prefixSize - 1
                started += 1
                continue
            }
            let rest = room - used - prefixSize - 1
            let part = rest > 0 ? BoardText.clipped(line, toScalars: rest) : ""
            if !part.isEmpty {
                output.append(prefix + part)
                shown += part.unicodeScalars.count
                started += 1
            }
            break
        }
        let hidden = hiddenSummary(lines: source.count - started, characters: total - shown)
        output.append(clippedNote(hidden))
        return output.joined(separator: "\n")
    }

    /// "3402 more lines and 12 more characters", leaving out a zero count.
    /// Lines are those not shown at all; characters are code points, not
    /// counting line breaks, including the rest of a line shown in part.
    private static func hiddenSummary(lines: Int, characters: Int) -> String {
        let characterCount = count(characters, "more character", "more characters")
        guard lines > 0 else { return characterCount }
        let lineCount = count(lines, "more line", "more lines")
        return characters > 0 ? "\(lineCount) and \(characterCount)" : lineCount
    }

    /// A last guard for files written by hand: the reply never passes the budget.
    private static func bounded(_ text: String) -> String {
        guard size(text) > readTextBudget else { return text }
        return BoardText.clipped(text[...], toScalars: readTextBudget - 40) + "\n…(board_read output clipped)"
    }

    /// Python measures the reply in code points.
    private static func size(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// One line of at most `limit` code points, ending in "…" when clipped.
    private static func field(_ value: String, _ limit: Int) -> String {
        let line = BoardText.inline(value)
        guard size(line) > limit else { return line }
        return BoardText.clipped(line[...], toScalars: limit - 1) + "…"
    }

    private static func columnLabel(_ column: BoardColumn) -> String {
        "\(field(column.title, Clip.columnTitle)) [\(field(column.id, Clip.columnID))]"
    }

    private static func labelList(_ labels: [String]) -> String {
        field(labels.map(BoardText.inline).joined(separator: ", "), Clip.labels)
    }

    /// `“Atlas” (agent)`. A name cannot contain the curly quotes around it,
    /// so nothing after the closing quote comes from the name.
    private static func label(_ author: BoardAuthor) -> String {
        let name = String(String.UnicodeScalarView(author.name.unicodeScalars.map { scalar in
            BoardText.curlyQuotes.contains(scalar.value) ? "\"" : scalar
        }))
        return "“\(field(name, Clip.author))” (\(author.kind.rawValue))"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(timeStyle)
    }

    private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    /// One line of at most `overviewDescriptionLength` characters, and at
    /// most twice that in code points, with whitespace runs as one space.
    /// It stops reading as soon as the excerpt is full.
    private static func excerpt(_ text: String) -> String {
        var result = ""
        var characters = 0
        var scalars = 0
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            for next in pendingSpace ? [" ", character] : [character] {
                let cost = next.unicodeScalars.count
                guard characters < BoardStore.overviewDescriptionLength, scalars + cost <= Clip.excerpt else {
                    return result + "…"
                }
                result.append(next)
                characters += 1
                scalars += cost
            }
            pendingSpace = false
        }
        return result
    }

    fileprivate func payload(for listed: BoardReadResult.Listed, full: Bool) -> [String: Any] {
        let card = listed.card
        var payload: [String: Any] = [
            "id": card.id.uuidString,
            "key": key(for: card),
            "number": card.number,
            "title": card.title,
            "description": listed.description,
            "column": card.columnID,
            "column_title": columns.first { $0.id == card.columnID }?.title ?? card.columnID,
            "priority": card.priority.rawValue,
            "labels": card.labels,
            "assignee": card.assignee ?? "",
            "agent_ids": (card.agentIDs ?? []).map(\.uuidString),
            "comment_count": card.commentCount,
            "created_at": Self.time(card.createdAt),
            "updated_at": Self.time(card.updatedAt),
            "created_by": Self.authorPayload(card.createdBy),
        ]
        if full {
            payload["timeline"] = card.timeline.map { entry -> [String: Any] in
                [
                    "id": entry.id.uuidString,
                    "kind": entry.kind.rawValue,
                    "author": Self.authorPayload(entry.author),
                    "text": entry.text,
                    "created_at": Self.time(entry.createdAt),
                ]
            }
        }
        return payload
    }

    fileprivate static func columnPayload(_ summary: BoardReadResult.ColumnSummary) -> [String: Any] {
        var payload: [String: Any] = [
            "id": summary.column.id,
            "title": summary.column.title,
            "card_count": summary.cardCount,
        ]
        if let matching = summary.matching { payload["matching_count"] = matching }
        return payload
    }

    private static func authorPayload(_ author: BoardAuthor) -> [String: Any] {
        ["kind": author.kind.rawValue, "name": author.name]
    }
}
