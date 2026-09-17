import Foundation

/// Editable text fields of a card, compared against the values they were
/// loaded from so a save only sends what the user changed and never
/// overwrites an agent's newer edit to another field.
struct BoardCardDraft: Equatable {
    var title = ""
    var details = ""
    var labels = ""
    var assignee = ""

    init() {}

    init(_ card: BoardCard) {
        title = card.title
        details = card.details
        labels = card.labels.joined(separator: ", ")
        assignee = card.assignee ?? ""
    }

    static func labels(from text: String) -> [String] {
        text.split(separator: ",").map(String.init)
    }
}

/// What the card sheet holds that the board does not have yet: field edits
/// and a typed comment. The sheet's close rules live here, out of the view:
/// Done commits both, Cancel asks first only when something would be lost,
/// discarding drops both, and a sheet that goes away without either keeps
/// them (see `closeWithoutChoice`).
@MainActor
struct BoardCardEdits {
    /// What a failed Done or Work on This in Chat left unsaved. Fields are
    /// saved before the comment is posted, so `.comment` means the fields
    /// are safe and only the comment was not posted, and
    /// `.fieldsWithComment` means a typed comment was never tried.
    enum Unsaved: Equatable {
        case fields, fieldsWithComment, comment
    }

    var draft = BoardCardDraft()
    private(set) var baseline = BoardCardDraft()
    var comment = ""
    /// Set once the user has chosen how the sheet closes.
    private(set) var isClosed = false

    var hasFieldChanges: Bool { draft != baseline }

    var hasPendingComment: Bool {
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasUnsavedChanges: Bool { hasFieldChanges || hasPendingComment }

    var unsaved: Unsaved? {
        switch (hasFieldChanges, hasPendingComment) {
        case (true, true): .fieldsWithComment
        case (true, false): .fields
        case (false, true): .comment
        case (false, false): nil
        }
    }

    mutating func load(_ card: BoardCard) {
        draft = BoardCardDraft(card)
        baseline = draft
    }

    /// Brings back a comment kept when the card's sheet last went away
    /// without posting it: without Done or Cancel, or after a failed save.
    mutating func restoreComment(for cardID: UUID, from store: BoardStore) {
        guard let kept = store.commentDrafts.removeValue(forKey: cardID) else { return }
        comment = kept
    }

    /// Fields the user has not touched follow the board, so an agent's
    /// update shows up while the sheet is open.
    mutating func follow(_ card: BoardCard) {
        let fresh = BoardCardDraft(card)
        if draft.title == baseline.title { draft.title = fresh.title }
        if draft.details == baseline.details { draft.details = fresh.details }
        if draft.labels == baseline.labels { draft.labels = fresh.labels }
        if draft.assignee == baseline.assignee { draft.assignee = fresh.assignee }
        baseline = fresh
    }

    /// Sends only the changed fields; the draft then follows the saved card.
    mutating func saveFields(of cardID: UUID, in store: BoardStore) throws {
        guard hasFieldChanges else { return }
        try store.updateCard(
            cardID,
            title: draft.title != baseline.title ? draft.title : nil,
            details: draft.details != baseline.details ? draft.details : nil,
            labels: draft.labels != baseline.labels ? BoardCardDraft.labels(from: draft.labels) : nil,
            assignee: draft.assignee != baseline.assignee ? .some(draft.assignee) : nil
        )
        if let saved = store.cards.first(where: { $0.id == cardID }) { load(saved) }
    }

    /// Posts the typed comment unless it is blank.
    mutating func postComment(on cardID: UUID, in store: BoardStore) throws {
        guard hasPendingComment else { return }
        try store.addComment(to: cardID, text: comment)
        comment = ""
    }

    /// Done: fields first, then the comment. The first failure is thrown and
    /// whatever was not saved stays, for Keep Editing or closing without it.
    mutating func commit(to cardID: UUID, in store: BoardStore) throws {
        try saveFields(of: cardID, in: store)
        try postComment(on: cardID, in: store)
    }

    /// Discard Changes and closing without saving drop both.
    mutating func discard() {
        draft = baseline
        comment = ""
    }

    /// Closing without saving after Done or Work on This in Chat failed.
    /// Field edits are dropped. A comment that was never tried, because the
    /// fields failed first, is kept for the card's next opening, as the
    /// alert says; a comment the board refused is dropped with it.
    mutating func abandon(_ unsaved: Unsaved, cardID: UUID, in store: BoardStore) {
        if unsaved == .fieldsWithComment, hasPendingComment,
           store.cards.contains(where: { $0.id == cardID }) {
            store.commentDrafts[cardID] = comment
        }
        discard()
    }

    /// Done or Work on This in Chat went through, Cancel found nothing to
    /// lose, or the user discarded: the sheet going away changes nothing more.
    mutating func close() {
        isClosed = true
    }

    /// The sheet went away without the user choosing Done or Cancel, say
    /// because the workspace changed or the board was closed under it.
    /// Field edits are saved, as leaving a field always does, and a typed
    /// comment is kept for the next time this card opens rather than posted
    /// unseen or lost. A deleted card has nothing left to keep.
    mutating func closeWithoutChoice(cardID: UUID, in store: BoardStore) throws {
        guard !isClosed else { return }
        isClosed = true
        guard store.cards.contains(where: { $0.id == cardID }) else { return }
        if hasPendingComment { store.commentDrafts[cardID] = comment }
        comment = ""
        try saveFields(of: cardID, in: store)
    }

    /// The alert title after Done or Work on This in Chat fails.
    static func failureTitle(_ unsaved: Unsaved) -> String {
        switch unsaved {
        case .fields, .fieldsWithComment: "Couldn’t save your changes"
        case .comment: "Your comment wasn’t posted"
        }
    }

    /// The alert message: the error, and what happens to a typed comment
    /// that was not posted because the fields failed first.
    static func failureMessage(_ unsaved: Unsaved, error: String) -> String {
        guard unsaved == .fieldsWithComment else { return error }
        return "\(error) The comment you typed wasn’t posted either. If you go on without saving, "
            + "it is kept for the next time you open this card."
    }

    /// The alert's way out. Work on This in Chat still hands the card to
    /// chat without the unsaved part, so its button says so.
    static func abandonTitle(_ unsaved: Unsaved, openingChat: Bool) -> String {
        let without = unsaved == .comment ? "Without Posting" : "Without Saving"
        return openingChat ? "Open in Chat \(without)" : "Close \(without)"
    }

    /// The deleted-card notice, naming what could not be kept.
    var deletedCardDetail: String {
        let removed = "Someone removed it from the board while it was open"
        switch (hasFieldChanges, hasPendingComment) {
        case (true, true): return "\(removed), so your unsaved edits and the comment you typed could not be kept."
        case (true, false): return "\(removed), so your unsaved edits could not be kept."
        case (false, true): return "\(removed), so the comment you typed could not be posted."
        case (false, false): return "\(removed)."
        }
    }
}
