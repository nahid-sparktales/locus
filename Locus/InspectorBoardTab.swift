import AppKit
import SwiftUI

/// The workspace board: kanban columns of cards shared by the user and the
/// agents working in this workspace. A narrow panel shows one column at a
/// time behind a column picker; a wide or expanded panel lays the columns
/// side by side. Every change goes through `BoardStore`, which saves before
/// it publishes, so this view only renders and reports errors.
struct InspectorBoardTab: View {
    @ObservedObject var store: BoardStore
    var isDetached = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var selectedColumnID: String?
    @State private var openCard: BoardCardSelection?
    @State private var newCard: BoardNewCardRequest?
    @State private var pendingDelete: BoardCard?
    @State private var columnPrompt: BoardColumnPrompt?
    @State private var columnTitleDraft = ""
    @State private var actionError: String?
    @State private var openingChat = false

    static let columnWidth: CGFloat = 232
    private static let quickAddAnchor = "board.quickAdd.anchor"

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 480 && (isDetached || !model.inspectorZoomed)
            VStack(spacing: 0) {
                header
                Divider()
                errorBanner
                if !store.isAvailable {
                    BoardMessage(
                        symbol: "folder",
                        title: "Open a workspace to use the board",
                        detail: "Each workspace keeps its own board of cards that you and your agents share.",
                        identifier: "board.noWorkspace"
                    )
                } else if !searchNeedle.isEmpty, !store.cards.contains(where: matchesSearch) {
                    BoardMessage(
                        symbol: "magnifyingglass",
                        title: "No cards match “\(searchNeedle)”",
                        detail: "Search looks at card keys, titles, descriptions, labels, and assignees.",
                        identifier: "board.noResults"
                    ) {
                        Button("Clear Search") { query = "" }
                            .buttonStyle(.locus())
                            .accessibilityIdentifier("board.noResults.clear")
                    }
                } else if compact {
                    compactBoard
                } else {
                    wideBoard
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .sheet(item: $openCard) { selection in
            BoardCardDetailSheet(store: store, cardID: selection.id, onWorkInChat: workInChat)
        }
        .sheet(item: $newCard) { request in
            BoardNewCardSheet(store: store, initialColumnID: request.columnID)
        }
        .alert(
            "Delete \(pendingDelete.map(store.key(for:)) ?? "card")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { card in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(card) }
                .accessibilityIdentifier("board.delete.confirm")
        } message: { card in
            Text("“\(card.title)” and its comments will be removed for you and your agents.")
        }
        .alert(
            columnPrompt?.title ?? "Column",
            isPresented: Binding(
                get: { columnPrompt != nil },
                set: { if !$0 { columnPrompt = nil } }
            )
        ) {
            TextField("Column name", text: $columnTitleDraft)
                .accessibilityIdentifier("board.columnTitle")
            Button("Cancel", role: .cancel) {}
            Button(columnPrompt?.confirmTitle ?? "Save") { commitColumnPrompt() }
                .accessibilityIdentifier("board.columnTitle.confirm")
        }
        .onAppear(perform: openFixtureCardIfRequested)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.content")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(LocusTheme.signalDeep)
                .accessibilityHidden(true)
            Text("Board")
                .font(.locus(size: 13, weight: .semibold))
                .fixedSize()
            if store.isAvailable {
                Text(store.keyPrefix)
                    .font(.locus(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .padding(.horizontal, 5)
                    .frame(minHeight: 18)
                    .background(LocusTheme.textPrimary.opacity(0.06), in: Capsule())
                    .fixedSize()
                    .help("Cards in this workspace are numbered \(store.keyPrefix)-1, \(store.keyPrefix)-2, and so on")
                    .accessibilityLabel("Card key prefix \(store.keyPrefix)")
            }
            Spacer(minLength: 4)
            if store.isAvailable {
                searchField
            }
            if openingChat {
                ProgressView().controlSize(.small)
                    .help("Opening a new chat for this card")
                    .accessibilityLabel("Opening a new chat for this card")
            }
            if !isDetached {
                Button { model.boardWindows.open(store: store, model: model) } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.locus(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.locus(.icon))
                .disabled(!store.isAvailable)
                .help("Open board in window")
                .accessibilityLabel("Open board in window")
                .accessibilityIdentifier("board.openWindow")
            }
            Button { newCard = BoardNewCardRequest(columnID: nil) } label: {
                Image(systemName: "plus")
                    .font(.locus(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.locus(.icon))
            .disabled(!store.isAvailable)
            .help("New card")
            .accessibilityLabel("New card")
            .accessibilityIdentifier("board.newCard")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(LocusTheme.textSecondary)
                .accessibilityHidden(true)
            TextField("Search cards", text: $query)
                .textFieldStyle(.plain)
                .font(.locus(size: 11))
                .onExitCommand { query = "" }
                .accessibilityLabel("Search cards")
                .accessibilityIdentifier("board.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(LocusTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.locus(.icon))
                .help("Clear search")
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("board.search.clear")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, query.isEmpty ? 8 : 1)
        .frame(height: 26)
        .background(LocusTheme.surfaceCard, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(LocusTheme.separator, lineWidth: 1)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 90, maxWidth: 240)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = actionError ?? store.lastError {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(LocusTheme.coral)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.locus(size: 10))
                    .foregroundStyle(LocusTheme.coral)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    actionError = nil
                    store.dismissError()
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(LocusTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.locus(.icon))
                .help("Dismiss")
                .accessibilityLabel("Dismiss board message")
                .accessibilityIdentifier("board.error.dismiss")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(LocusTheme.coral.opacity(0.08))
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("board.error")
        }
    }

    // MARK: - Wide layout

    private var wideBoard: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(store.columns) { column in
                    lane(column)
                }
                addColumnButton
            }
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func lane(_ column: BoardColumn) -> some View {
        let all = store.cards(in: column.id)
        let visible = all.filter(matchesSearch)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(column.title)
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.textPrimary)
                    .lineLimit(1)
                BoardCountBadge(count: visible.count, total: all.count)
                Spacer(minLength: 4)
                columnMenu(column)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 38)

            // The add field follows the last card, as on a paper board, and
            // stays in view while a list is typed out.
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(visible) { card in
                            tile(card)
                        }
                        // An empty lane is just its add field; the dashed
                        // box only explains a search that hides every card.
                        if visible.isEmpty, !searchNeedle.isEmpty {
                            Text("No matches")
                                .font(.locus(size: 10))
                                .foregroundStyle(LocusTheme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(LocusTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                        .accessibilityHidden(true)
                                }
                        }
                        BoardQuickAddField(column: column) { title, column in
                            guard quickAdd(title, column) else { return false }
                            Task { @MainActor in
                                withAnimation(reduceMotion ? nil : LocusMotion.scroll) {
                                    proxy.scrollTo(Self.quickAddAnchor, anchor: .bottom)
                                }
                            }
                            return true
                        }
                        .padding(.top, 2)
                        .id(Self.quickAddAnchor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .animation(reduceMotion ? nil : LocusMotion.spatial, value: visible.map(\.id))
                }
            }
        }
        .frame(width: Self.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LocusTheme.textPrimary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .modifier(BoardDropTarget(indicator: .outline(radius: 12)) { drop($0, into: column.id, before: nil) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.title) column")
        .accessibilityIdentifier("board.column.\(column.id)")
    }

    private var addColumnButton: some View {
        Button(action: beginAddColumn) {
            Label("Add Column", systemImage: "plus")
                .font(.locus(size: 11, weight: .semibold))
                .foregroundStyle(LocusTheme.textSecondary)
                .frame(width: 150, height: 38)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(LocusTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .accessibilityHidden(true)
                }
        }
        .buttonStyle(.locus())
        .disabled(store.columns.count >= BoardStore.maximumColumns)
        .help(
            store.columns.count >= BoardStore.maximumColumns
                ? "A board can have at most \(BoardStore.maximumColumns) columns"
                : "Add a column to the end of the board"
        )
        .accessibilityIdentifier("board.addColumn")
    }

    // MARK: - Compact layout

    private var compactBoard: some View {
        let column = selectedColumn
        let all = column.map { store.cards(in: $0.id) } ?? []
        let visible = all.filter(matchesSearch)
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                columnPicker
                if let column {
                    columnMenu(column)
                        .padding(.trailing, 6)
                }
            }
            .frame(height: 40)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            if let column {
                VStack(spacing: 0) {
                    if visible.isEmpty {
                        compactEmptyState(column)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 6) {
                                ForEach(visible) { card in
                                    tile(card)
                                }
                            }
                            .padding(10)
                            .animation(reduceMotion ? nil : LocusMotion.spatial, value: visible.map(\.id))
                        }
                    }
                    BoardQuickAddField(column: column, onAdd: quickAdd)
                        .padding(10)
                        .overlay(alignment: .top) {
                            Rectangle().fill(LocusTheme.line).frame(height: 1)
                        }
                }
                .modifier(BoardDropTarget(indicator: .outline(radius: 0)) { drop($0, into: column.id, before: nil) })
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(column.title) column")
                .accessibilityIdentifier("board.column.\(column.id)")
            }
        }
    }

    private var columnPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.columns) { column in
                        columnChip(column)
                            .id(column.id)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 18)
                .padding(.vertical, 6)
            }
            // Fade the trailing edge so chips that scroll under the column
            // menu read as more to come rather than as clipped.
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                }
            }
            .onAppear { proxy.scrollTo(selectedColumn?.id) }
            .onChange(of: selectedColumn?.id) { _, id in
                withAnimation(reduceMotion ? nil : LocusMotion.scroll) { proxy.scrollTo(id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Columns")
        .accessibilityIdentifier("board.columnPicker")
    }

    private func columnChip(_ column: BoardColumn) -> some View {
        let selected = column.id == selectedColumn?.id
        let all = store.cards(in: column.id)
        let count = searchNeedle.isEmpty ? all.count : all.filter(matchesSearch).count
        return Button {
            withAnimation(reduceMotion ? nil : LocusMotion.content) { selectedColumnID = column.id }
        } label: {
            HStack(spacing: 5) {
                Text(column.title)
                    .font(.locus(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.locus(size: 10, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(
                        selected ? LocusTheme.surfaceCanvas.opacity(0.22) : LocusTheme.textPrimary.opacity(0.07),
                        in: Capsule()
                    )
            }
            .foregroundStyle(selected ? LocusTheme.surfaceCanvas : LocusTheme.textSecondary)
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .frame(height: 26)
            .background(selected ? LocusTheme.textPrimary : Color.clear, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(selected ? Color.clear : LocusTheme.separator, lineWidth: 1)
                    .accessibilityHidden(true)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.locus())
        .modifier(BoardDropTarget(indicator: .outline(radius: 13)) { drop($0, into: column.id, before: nil) })
        .help("Show \(column.title). Drop a card here to move it.")
        .accessibilityLabel(column.title)
        .accessibilityValue("\(count) card\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("board.columnPicker.\(column.id)")
    }

    private func compactEmptyState(_ column: BoardColumn) -> some View {
        Group {
            if !searchNeedle.isEmpty {
                let elsewhere = store.cards.filter(matchesSearch).count
                BoardMessage(
                    symbol: "magnifyingglass",
                    title: "No matches in \(column.title)",
                    detail: "\(elsewhere) matching card\(elsewhere == 1 ? " is" : "s are") in other columns.",
                    identifier: "board.column.empty"
                )
            } else if store.cards.isEmpty {
                BoardMessage(
                    symbol: "rectangle.split.3x1",
                    title: "Plan work with your agents",
                    detail: "Add cards here, then ask an agent to pick one up. Agents can read the board, "
                        + "move cards, and reply in comments.",
                    identifier: "board.empty"
                ) {
                    Button { newCard = BoardNewCardRequest(columnID: column.id) } label: {
                        BoardButtonLabel(title: "New Card", symbol: "plus", prominent: true)
                    }
                    .buttonStyle(.locus(.primary))
                    .accessibilityIdentifier("board.empty.newCard")
                }
            } else {
                BoardMessage(
                    symbol: "tray",
                    title: "No cards in \(column.title)",
                    detail: "Add one below, or drag a card onto this column in the picker.",
                    identifier: "board.column.empty"
                )
            }
        }
    }

    // MARK: - Shared pieces

    private func tile(_ card: BoardCard) -> some View {
        BoardCardTile(
            card: card,
            key: store.key(for: card),
            columns: store.columns,
            open: { openCard = BoardCardSelection(id: $0.id) },
            move: { move($0, to: $1, position: nil) },
            reorder: reorder,
            workInChat: workInChat,
            requestDelete: { pendingDelete = $0 },
            drop: { drop($0, into: card.columnID, before: card) }
        )
        .transition(.opacity)
    }

    private func columnMenu(_ column: BoardColumn) -> some View {
        let index = store.columns.firstIndex(of: column) ?? 0
        let isEmpty = !store.cards.contains { $0.columnID == column.id }
        return Menu {
            Button("New Card in \(column.title)…") {
                newCard = BoardNewCardRequest(columnID: column.id)
            }
            Button("Rename Column…") { beginRename(column) }
            Divider()
            Button("Move Column Left") { moveColumn(column, by: -1) }
                .disabled(index == 0)
            Button("Move Column Right") { moveColumn(column, by: 1) }
                .disabled(index == store.columns.count - 1)
            Divider()
            Button("Add Column…", action: beginAddColumn)
                .disabled(store.columns.count >= BoardStore.maximumColumns)
            if isEmpty, store.columns.count > 1 {
                Button("Delete Column", role: .destructive) { deleteColumn(column) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.locus(size: 11, weight: .semibold))
                .foregroundStyle(LocusTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Column actions")
        .accessibilityLabel("\(column.title) column actions")
        .accessibilityIdentifier("board.column.\(column.id).menu")
    }

    // MARK: - State

    private var selectedColumn: BoardColumn? {
        store.columns.first { $0.id == selectedColumnID } ?? store.columns.first
    }

    private var searchNeedle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesSearch(_ card: BoardCard) -> Bool {
        let needle = searchNeedle
        guard !needle.isEmpty else { return true }
        return store.key(for: card).localizedCaseInsensitiveContains(needle)
            || card.title.localizedCaseInsensitiveContains(needle)
            || card.details.localizedCaseInsensitiveContains(needle)
            || card.labels.contains { $0.localizedCaseInsensitiveContains(needle) }
            || card.assignee?.localizedCaseInsensitiveContains(needle) == true
    }

    // MARK: - Actions

    /// Store errors are already user-facing sentences.
    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func quickAdd(_ title: String, _ column: BoardColumn) -> Bool {
        var added = false
        withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
            attempt {
                try store.createCard(title: title, columnID: column.id)
                added = true
            }
        }
        return added
    }

    private func move(_ card: BoardCard, to columnID: String, position: Int?) {
        withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
            attempt { try store.moveCard(card.id, toColumn: columnID, position: position) }
        }
    }

    private func reorder(_ card: BoardCard, _ offset: Int) {
        let siblings = store.cards(in: card.columnID)
        guard let index = siblings.firstIndex(where: { $0.id == card.id }) else { return }
        move(card, to: card.columnID, position: max(index + offset, 0))
    }

    /// A card dropped on another card lands before it; dropped on a column,
    /// it goes to the end. Positions count the destination without the card.
    private func drop(_ items: [String], into columnID: String, before target: BoardCard?) -> Bool {
        guard let id = items.lazy.compactMap(BoardDragPayload.cardID(from:)).first,
              id != target?.id,
              let card = store.cards.first(where: { $0.id == id })
        else { return false }
        let siblings = store.cards(in: columnID).filter { $0.id != id }
        let position = target.flatMap { target in siblings.firstIndex { $0.id == target.id } } ?? siblings.count
        move(card, to: columnID, position: position)
        return true
    }

    /// A card an agent removed while the confirmation was open is already
    /// gone, which is what the user asked for, so nothing is reported.
    private func delete(_ card: BoardCard) {
        withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
            attempt { _ = try store.deleteCardIfPresent(card.id) }
        }
    }

    /// UI-test launches can open a seeded card so its sheet can be audited
    /// and captured without driving the pointer.
    private func openFixtureCardIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LOCUS_UI_TESTING"] == "1",
              let reference = environment["LOCUS_UI_TESTING_BOARD_CARD"]
        else { return }
        if reference == "new" {
            newCard = BoardNewCardRequest(columnID: nil)
        } else if let card = store.card(matching: reference) {
            openCard = BoardCardSelection(id: card.id)
        }
    }

    private func workInChat(_ card: BoardCard) {
        openCard = nil
        guard isDetached else {
            model.prefillComposerFromBoard(store.chatPrompt(for: card))
            return
        }
        guard !openingChat else { return }
        openingChat = true
        actionError = nil
        Task { @MainActor in
            let opened = await model.openBoardCardInNewChat(card, store: store)
            openingChat = false
            if !opened {
                actionError = "The card’s chat could not be opened. Finish any pending chat change and check that this workspace is still available, then try again."
            }
        }
    }

    private func beginAddColumn() {
        columnTitleDraft = ""
        columnPrompt = .add
    }

    private func beginRename(_ column: BoardColumn) {
        columnTitleDraft = column.title
        columnPrompt = .rename(column)
    }

    private func commitColumnPrompt() {
        guard let prompt = columnPrompt else { return }
        withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
            attempt {
                switch prompt {
                case .add:
                    selectedColumnID = try store.addColumn(title: columnTitleDraft).id
                case .rename(let column):
                    try store.renameColumn(column.id, to: columnTitleDraft)
                }
            }
        }
    }

    private func moveColumn(_ column: BoardColumn, by offset: Int) {
        withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
            attempt { try store.moveColumn(column.id, by: offset) }
        }
    }

    private func deleteColumn(_ column: BoardColumn) {
        withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
            attempt { try store.deleteColumn(column.id) }
        }
    }
}

// MARK: - Presentation state

struct BoardCardSelection: Identifiable {
    let id: UUID
}

struct BoardNewCardRequest: Identifiable {
    let id = UUID()
    let columnID: String?
}

private enum BoardColumnPrompt {
    case add
    case rename(BoardColumn)

    var title: String {
        switch self {
        case .add: "Add Column"
        case .rename(let column): "Rename “\(column.title)”"
        }
    }

    var confirmTitle: String {
        switch self {
        case .add: "Add"
        case .rename: "Rename"
        }
    }
}

/// Cards travel as plain strings so no custom pasteboard type needs to be
/// declared; the prefix keeps stray text drops from moving anything.
enum BoardDragPayload {
    static let prefix = "locus-board-card:"

    static func string(for id: UUID) -> String {
        prefix + id.uuidString
    }

    static func cardID(from payload: String) -> UUID? {
        guard payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }
}
