import AppKit
import SwiftUI

/// A card's full view: fields that save as you leave them, the shared
/// comment and activity timeline, and the hand-off to chat. Done saves and
/// posts a typed comment. Cancel, which Esc presses from anywhere in the
/// sheet, closes without saving the edit in progress or posting the typed
/// comment, and asks first when either would be lost. A failed save never
/// traps the sheet, and closing after one keeps a comment the save never
/// reached. If the sheet goes away without Done or Cancel, edits are saved
/// and a typed comment waits for the card's next opening.
struct BoardCardDetailSheet: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @ObservedObject var store: BoardStore
    let cardID: UUID
    let onWorkInChat: (BoardCard) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var edits = BoardCardEdits()
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var closeAlert: CloseAlert?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case title, details, assignee, labels, comment
    }

    /// Where the sheet goes once it closes.
    private enum CloseAction {
        case close, workInChat
    }

    private enum CloseAlert {
        case discard
        case saveFailed(CloseAction, BoardCardEdits.Unsaved)
    }

    private static let timelineEnd = "board.card.timelineEnd"

    private var card: BoardCard? {
        store.cards.first { $0.id == cardID }
    }

    var body: some View {
        Group {
            if let card {
                content(card)
            } else {
                BoardMessage(
                    symbol: "trash",
                    title: "This card was deleted",
                    detail: edits.deletedCardDetail,
                    identifier: "board.card.deleted"
                ) {
                    Button("Close") { close(.close) }
                        .buttonStyle(.locus())
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 560)
        .frame(minHeight: 420, idealHeight: 660)
        // Esc otherwise closes the sheet from a text field without running
        // Cancel, which would keep edits the user meant to drop.
        .interactiveDismissDisabled()
        .onAppear {
            guard let card else { return }
            edits.load(card)
            edits.restoreComment(for: card.id, from: store)
            // Start in the reply box once the sheet is key, so typing never
            // replaces the title AppKit would otherwise select.
            Task { @MainActor in
                await Task.yield()
                focus = .comment
            }
        }
        .onChange(of: card) { _, updated in
            if let updated { edits.follow(updated) }
        }
        .onChange(of: focus) { previous, _ in
            if previous != nil, previous != .comment { save() }
        }
        .onDisappear {
            try? edits.closeWithoutChoice(cardID: cardID, in: store)
        }
    }

    private func content(_ card: BoardCard) -> some View {
        let key = store.key(for: card)
        // The comment box stays pinned under the scrolling card, like a chat
        // composer, so a reply is always one keystroke away.
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        titleSection(card, key: key)
                        properties(card)
                        AgentMentionPicker(selectedIDs: $edits.draft.agentIDs)
                            .onChange(of: edits.draft.agentIDs) { _, _ in save() }
                        descriptionSection
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.locus(size: 11))
                                .foregroundStyle(viewColors.coral)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("board.card.error")
                        }
                        Divider()
                        timeline(card)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.timelineEnd)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                }
                commentComposer(card, proxy: proxy)
                footer(card, key: key)
            }
        }
        .alert("Delete \(key)?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(card) }
                .accessibilityIdentifier("board.delete.confirm")
        } message: {
            Text("“\(card.title)” and its comments will be removed for you and your agents.")
        }
    }

    private func titleSection(_ card: BoardCard, key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(key)
                    .font(.locus(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(viewColors.textSecondary)
                    .textSelection(.enabled)
                BoardPriorityBadge(priority: card.priority)
            }
            TextField("Card title", text: $edits.draft.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.locus(size: 18, weight: .semibold))
                .lineLimit(1...4)
                .focused($focus, equals: .title)
                .onSubmit { save() }
                .accessibilityLabel("Title")
                .accessibilityIdentifier("board.card.title")
            Text(createdLine(card))
                .font(.locus(size: 10))
                .foregroundStyle(viewColors.textSecondary)
                .accessibilityIdentifier("board.card.created")
        }
    }

    private func properties(_ card: BoardCard) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                BoardFieldLabel("Column")
                Picker("Column", selection: columnBinding(card)) {
                    ForEach(store.columns) { column in
                        Text(column.title).tag(column.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("board.card.column")
            }
            GridRow {
                BoardFieldLabel("Priority")
                BoardPriorityPicker(selection: priorityBinding(card))
            }
            GridRow {
                BoardFieldLabel("Assignee")
                TextField("Unassigned", text: $edits.draft.assignee)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .focused($focus, equals: .assignee)
                    .onSubmit { save() }
                    .help("A person or agent name. Agents often assign cards to themselves.")
                    .accessibilityLabel("Assignee")
                    .accessibilityIdentifier("board.card.assignee")
            }
            GridRow {
                BoardFieldLabel("Labels")
                TextField("bug, ui", text: $edits.draft.labels)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .focused($focus, equals: .labels)
                    .onSubmit { save() }
                    .help("Separate labels with commas")
                    .accessibilityLabel("Labels")
                    .accessibilityIdentifier("board.card.labels")
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            BoardFieldLabel("Description")
            BoardDescriptionEditor(text: $edits.draft.details, minHeight: 64)
                .focused($focus, equals: .details)
        }
    }

    private func timeline(_ card: BoardCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Activity")
                    .font(.locus(size: 13, weight: .semibold))
                Text(timelineSummary(card))
                    .font(.locus(size: 10))
                    .foregroundStyle(viewColors.textSecondary)
            }
            TimelineView(.everyMinute) { context in
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(card.timeline) { entry in
                        BoardTimelineRow(entry: entry, now: context.date)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.card.timeline")
    }

    private func commentComposer(_ card: BoardCard, proxy: ScrollViewProxy) -> some View {
        let canSend = edits.hasPendingComment
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                BoardAuthorAvatar(author: .user)
                TextField("Add a comment for you and your agents…", text: $edits.comment, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.locus(size: 12))
                    .lineLimit(1...5)
                    .focused($focus, equals: .comment)
                    .padding(9)
                    .background(viewColors.surfaceCard, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(focus == .comment ? viewColors.signalDeep : viewColors.separator, lineWidth: 1)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("Comment")
                    .accessibilityIdentifier("board.card.comment")
            }
            HStack(spacing: 8) {
                Text("Agents read comments when they check this card.")
                    .font(.locus(size: 10))
                    .foregroundStyle(viewColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button {
                    sendComment(card, proxy: proxy)
                } label: {
                    BoardButtonLabel(title: "Comment", symbol: "arrow.up", prominent: true)
                }
                .buttonStyle(.locus(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Add comment (⌘↩)")
                .accessibilityIdentifier("board.card.sendComment")
            }
            .padding(.leading, 33)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(viewColors.line).frame(height: 1)
        }
    }

    private func footer(_ card: BoardCard, key: String) -> some View {
        HStack(spacing: 10) {
            Button { confirmingDelete = true } label: {
                BoardButtonLabel(title: "Delete…", symbol: "trash", destructive: true)
            }
            .buttonStyle(.locus(.destructive))
            .help("Delete \(key)")
            .accessibilityIdentifier("board.card.delete")
            Spacer(minLength: 8)
            Button { finish(.workInChat) } label: {
                BoardButtonLabel(title: "Work on This in Chat", symbol: "text.bubble")
            }
            .buttonStyle(.locus())
            .help("Save your changes and put this card in the message composer so an agent can start on it")
            .accessibilityIdentifier("board.card.workInChat")
            Button(action: cancel) {
                BoardButtonLabel(title: "Cancel")
            }
            .buttonStyle(.locus())
            .keyboardShortcut(.cancelAction)
            .help("Close without saving the edit in progress (Esc)")
            .accessibilityIdentifier("board.card.cancel")
            Button { finish(.close) } label: {
                BoardButtonLabel(title: "Done", prominent: true)
            }
            .buttonStyle(.locus(.primary))
            .help("Save your changes, post your comment, and close")
            .accessibilityIdentifier("board.card.done")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(viewColors.paperDeep.opacity(0.5))
        .overlay(alignment: .top) {
            Rectangle().fill(viewColors.line).frame(height: 1)
        }
        .alert(
            closeAlertTitle,
            isPresented: Binding(
                get: { closeAlert != nil },
                set: { if !$0 { closeAlert = nil } }
            ),
            presenting: closeAlert
        ) { alert in
            Button("Keep Editing", role: .cancel) {}
            switch alert {
            case .discard:
                Button("Discard Changes", role: .destructive) { discardAndClose(.close) }
                    .accessibilityIdentifier("board.card.discard.confirm")
            case .saveFailed(let action, let unsaved):
                Button(
                    BoardCardEdits.abandonTitle(unsaved, openingChat: action == .workInChat),
                    role: .destructive
                ) { abandonAndClose(action, unsaved: unsaved) }
                    .accessibilityIdentifier("board.card.discard.confirm")
            }
        } message: { alert in
            switch alert {
            case .discard:
                Text(discardMessage)
            case .saveFailed(_, let unsaved):
                Text(BoardCardEdits.failureMessage(unsaved, error: errorMessage ?? "The card could not be saved."))
            }
        }
    }

    private var closeAlertTitle: String {
        switch closeAlert {
        case .saveFailed(_, let unsaved): BoardCardEdits.failureTitle(unsaved)
        case .discard, nil: "Discard changes?"
        }
    }

    private var discardMessage: String {
        switch (edits.hasFieldChanges, edits.hasPendingComment) {
        case (true, true): "Your unsaved edits and the comment you typed will be lost."
        case (false, true): "The comment you typed will not be posted."
        default: "Your unsaved edits to this card will be lost."
        }
    }

    // MARK: - Editing

    private func columnBinding(_ card: BoardCard) -> Binding<String> {
        Binding(
            get: { self.card?.columnID ?? card.columnID },
            set: { columnID in
                attempt { try store.moveCard(card.id, toColumn: columnID) }
            }
        )
    }

    private func priorityBinding(_ card: BoardCard) -> Binding<BoardPriority> {
        Binding(
            get: { self.card?.priority ?? card.priority },
            set: { priority in
                attempt { try store.updateCard(card.id, priority: priority) }
            }
        )
    }

    @discardableResult
    private func save() -> Bool {
        guard let card, edits.hasFieldChanges else { return true }
        return attempt { try edits.saveFields(of: card.id, in: store) }
    }

    /// Runs a change and shows its error, or clears the last one.
    @discardableResult
    private func attempt(_ change: () throws -> Void) -> Bool {
        do {
            try change()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func sendComment(_ card: BoardCard, proxy: ScrollViewProxy) {
        guard edits.hasPendingComment,
              attempt({ try edits.postComment(on: card.id, in: store) })
        else { return }
        Task { @MainActor in
            withAnimation(reduceMotion ? nil : LocusMotion.scroll) {
                proxy.scrollTo(Self.timelineEnd, anchor: .bottom)
            }
        }
    }

    // MARK: - Closing

    /// Done and Work on This in Chat: save field edits and post a typed
    /// comment, then close. On failure the error stays visible and the alert
    /// says what was not saved, what happens to a typed comment, and offers
    /// to go on without it.
    private func finish(_ action: CloseAction) {
        guard let card else {
            close(.close)
            return
        }
        guard attempt({ try edits.commit(to: card.id, in: store) }) else {
            closeAlert = .saveFailed(action, edits.unsaved ?? .fields)
            return
        }
        close(action)
    }

    private func cancel() {
        if edits.hasUnsavedChanges {
            closeAlert = .discard
        } else {
            close(.close)
        }
    }

    private func discardAndClose(_ action: CloseAction) {
        edits.discard()
        errorMessage = nil
        close(action)
    }

    /// The failed-save alert's way out, which keeps a comment the save
    /// never reached for the card's next opening.
    private func abandonAndClose(_ action: CloseAction, unsaved: BoardCardEdits.Unsaved) {
        edits.abandon(unsaved, cardID: cardID, in: store)
        errorMessage = nil
        close(action)
    }

    private func close(_ action: CloseAction) {
        let latest = card
        edits.close()
        dismiss()
        if case .workInChat = action, let latest {
            onWorkInChat(latest)
        }
    }

    /// A card an agent already removed is gone, which is what was asked.
    private func delete(_ card: BoardCard) {
        do {
            try store.deleteCardIfPresent(card.id)
            edits.discard()
            edits.close()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createdLine(_ card: BoardCard) -> String {
        let created = card.createdAt.formatted(date: .abbreviated, time: .shortened)
        let author = card.createdBy.kind == .agent
            ? "\(card.createdBy.name) · Agent"
            : card.createdBy.name
        var line = "Created by \(author) · \(created)"
        if card.updatedAt > card.createdAt {
            line += " · Updated \(card.updatedAt.formatted(.relative(presentation: .named)))"
        }
        return line
    }

    private func timelineSummary(_ card: BoardCard) -> String {
        let comments = card.commentCount
        return comments == 0 ? "No comments yet" : "\(comments) comment\(comments == 1 ? "" : "s")"
    }
}

/// Creates a card with every field the board supports.
struct BoardNewCardSheet: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @ObservedObject var store: BoardStore
    let initialColumnID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var columnID = ""
    @State private var priority = BoardPriority.none
    @State private var labels = ""
    @State private var assignee = ""
    @State private var taggedAgentIDs: [UUID] = []
    @State private var errorMessage: String?
    @FocusState private var titleFocused: Bool

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Card")
                    .font(.locus(size: 18, weight: .semibold))
                Text("Cards are shared with the agents working in this workspace.")
                    .font(.locus(size: 11))
                    .foregroundStyle(viewColors.textSecondary)
            }
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(create)
                .accessibilityIdentifier("board.card.title")
            VStack(alignment: .leading, spacing: 6) {
                BoardFieldLabel("Description")
                BoardDescriptionEditor(text: $details, minHeight: 80)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    BoardFieldLabel("Column")
                    Picker("Column", selection: $columnID) {
                        ForEach(store.columns) { column in
                            Text(column.title).tag(column.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("board.card.column")
                }
                GridRow {
                    BoardFieldLabel("Priority")
                    BoardPriorityPicker(selection: $priority)
                }
                GridRow {
                    BoardFieldLabel("Assignee")
                    TextField("Unassigned", text: $assignee)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                        .accessibilityLabel("Assignee")
                        .accessibilityIdentifier("board.card.assignee")
                }
                GridRow {
                    BoardFieldLabel("Labels")
                    TextField("bug, ui", text: $labels)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                        .help("Separate labels with commas")
                        .accessibilityLabel("Labels")
                        .accessibilityIdentifier("board.card.labels")
                }
            }
            AgentMentionPicker(selectedIDs: $taggedAgentIDs)
            if let errorMessage {
                Text(errorMessage)
                    .font(.locus(size: 11))
                    .foregroundStyle(viewColors.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("board.card.error")
            }
            HStack(spacing: 10) {
                Spacer()
                Button { dismiss() } label: {
                    BoardButtonLabel(title: "Cancel")
                }
                .buttonStyle(.locus())
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("board.card.cancel")
                Button(action: create) {
                    BoardButtonLabel(title: "Create Card", prominent: true)
                }
                .buttonStyle(.locus(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCreate)
                .help("Create the card (⌘↩)")
                .accessibilityIdentifier("board.card.create")
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            if columnID.isEmpty {
                columnID = initialColumnID.flatMap { id in store.columns.first { $0.id == id }?.id }
                    ?? store.columns.first?.id ?? ""
            }
            titleFocused = true
        }
    }

    private func create() {
        guard canCreate else { return }
        do {
            try store.createCard(
                title: title,
                details: details,
                columnID: columnID.nilIfEmpty,
                priority: priority,
                labels: BoardCardDraft.labels(from: labels),
                assignee: assignee,
                agentIDs: taggedAgentIDs
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Sheet components

private struct BoardFieldLabel: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.locus(size: 11, weight: .medium))
            .foregroundStyle(viewColors.textSecondary)
            .gridColumnAlignment(.trailing)
    }
}

private struct BoardPriorityPicker: View {
    @Binding var selection: BoardPriority

    var body: some View {
        Picker("Priority", selection: $selection) {
            ForEach(BoardPriority.allCases) { priority in
                if priority == BoardPriority.none {
                    Text(priority.title).tag(priority)
                } else {
                    Label(priority.title, systemImage: priority.symbol).tag(priority)
                }
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("board.card.priority")
    }
}

/// Multi-line description input. A text editor keeps Return as a newline;
/// the placeholder is drawn beneath it because `TextEditor` has none.
private struct BoardDescriptionEditor: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.locus(size: 12))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(minHeight: minHeight, maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .background(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Add a description…")
                        .font(.locus(size: 12))
                        .foregroundStyle(viewColors.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(viewColors.surfaceCard, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(viewColors.separator, lineWidth: 1)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Description")
            .accessibilityIdentifier("board.card.description")
    }
}

/// The same agent picker is used on cards and events. IDs survive renames;
/// names and photos always come from the current shared agent profiles.
struct AgentMentionPicker: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @EnvironmentObject private var teams: AgentTeamsModel
    @Binding var selectedIDs: [UUID]
    @State private var query = ""
    @FocusState private var searching: Bool
    private var matches: [AgentProfile] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return teams.agentProfiles.filter {
            !selectedIDs.contains($0.id) && (term.isEmpty || $0.name.localizedCaseInsensitiveContains(term))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tagged agents").font(.locus(size: 12, weight: .semibold)).foregroundStyle(viewColors.inkSoft)
            if !selectedIDs.isEmpty {
                AgentFlowLayout(spacing: 6) {
                    ForEach(selectedIDs, id: \.self) { id in
                        HStack(spacing: 5) {
                            Text("@" + (teams.agentProfiles.first { $0.id == id }?.name ?? "Unavailable agent"))
                            Button { selectedIDs.removeAll { $0 == id } } label: { Image(systemName: "xmark").font(.locus(size: 9)) }
                                .buttonStyle(.locus(.card)).accessibilityLabel("Remove agent tag")
                        }.font(.locus(size: 11, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 6)
                            .background(viewColors.signalDeep.opacity(0.13), in: Capsule())
                    }
                }
            }
            TextField("@ Tag an agent…", text: $query).textFieldStyle(.roundedBorder)
                .focused($searching).accessibilityIdentifier("agentMentions.search")
                .onSubmit { if let profile = matches.first { choose(profile) } }
                .onExitCommand { searching = false; query = "" }
            if searching {
                if matches.isEmpty {
                    Text(teams.agentProfiles.isEmpty ? "Create an agent to tag it here." : "No matching agents")
                        .font(.locus(size: 11)).foregroundStyle(viewColors.muted)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(matches) { profile in
                                Button { choose(profile) } label: {
                                    HStack(spacing: 8) {
                                        AgentAvatarView(profileID: profile.id, name: profile.name, size: 24)
                                        Text("@" + profile.name).font(.locus(size: 12))
                                        Spacer()
                                        Image(systemName: "plus").font(.locus(size: 11))
                                    }.padding(6).contentShape(Rectangle())
                                }.buttonStyle(.locus(.card))
                            }
                        }
                    }.frame(height: min(CGFloat(matches.count) * 38, 152))
                        .background(viewColors.surfaceCard, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    private func choose(_ profile: AgentProfile) {
        if !selectedIDs.contains(profile.id), selectedIDs.count < 64 { selectedIDs.append(profile.id) }
        query = ""; searching = false
    }
}

struct AgentTagLabels: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @EnvironmentObject private var teams: AgentTeamsModel
    let ids: [UUID]
    var body: some View {
        if !ids.isEmpty {
            Text(ids.map { id in "@" + (teams.agentProfiles.first { $0.id == id }?.name ?? "Unavailable agent") }.joined(separator: " · "))
                .font(.locus(size: 11, weight: .medium)).foregroundStyle(viewColors.signalDeep)
                .lineLimit(2)
        }
    }
}
