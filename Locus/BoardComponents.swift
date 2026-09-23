import AppKit
import SwiftUI

// Building blocks of the workspace board: the card tile, drop feedback, the
// quick-add field, and the badges and messages shared with the sheets.

// MARK: - Card tile

struct BoardCardTile: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let card: BoardCard
    let key: String
    let columns: [BoardColumn]
    let open: (BoardCard) -> Void
    let move: (BoardCard, String) -> Void
    let reorder: (BoardCard, Int) -> Void
    let workInChat: (BoardCard) -> Void
    let requestDelete: (BoardCard) -> Void
    let drop: ([String]) -> Bool

    @State private var hovering = false

    /// Agents that changed the card in the last few minutes get a quiet mark,
    /// so the user can spot work landing without reading every timeline.
    private var recentAgent: String? {
        guard let entry = card.timeline.last(where: { $0.author.kind == .agent }),
              entry.createdAt > Date().addingTimeInterval(-10 * 60)
        else { return nil }
        return entry.author.name
    }

    private var assigneeIsAgent: Bool {
        guard let assignee = card.assignee else { return false }
        let agents = card.timeline.lazy.filter { $0.author.kind == .agent }.map(\.author.name)
        return ([card.createdBy].filter { $0.kind == .agent }.map(\.name) + agents)
            .contains { $0.caseInsensitiveCompare(assignee) == .orderedSame }
    }

    private var otherColumns: [BoardColumn] {
        columns.filter { $0.id != card.columnID }
    }

    var body: some View {
        Button { open(card) } label: {
            content
        }
        .buttonStyle(.locus(.card))
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityLabel("\(key), \(card.title)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens the card")
        .accessibilityIdentifier("board.card.\(key)")
        .accessibilityActions {
            ForEach(otherColumns) { column in
                Button("Move to \(column.title)") { move(card, column.id) }
            }
            Button("Move Earlier") { reorder(card, -1) }
            Button("Move Later") { reorder(card, 1) }
        }
        .onDeleteCommand { requestDelete(card) }
        .draggable(BoardDragPayload.string(for: card.id)) {
            BoardDragPreview(key: key, title: card.title)
        }
        .modifier(BoardDropTarget(indicator: .above, perform: drop))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(key)
                    .font(.locus(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(viewColors.textSecondary)
                if recentAgent != nil {
                    Image(systemName: "sparkles")
                        .imageScale(.small)
                        .foregroundStyle(viewColors.signalDeep)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                BoardPriorityBadge(priority: card.priority)
            }
            Text(card.title)
                .font(.locus(size: 12, weight: .medium))
                .foregroundStyle(viewColors.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            if !card.labels.isEmpty {
                AgentFlowLayout(spacing: 4) {
                    ForEach(card.labels, id: \.self) { label in
                        BoardLabelPill(label: label)
                    }
                }
            }
            AgentTagLabels(ids: card.agentIDs ?? [])
            if card.assignee != nil || card.commentCount > 0 {
                HStack(spacing: 8) {
                    if let assignee = card.assignee {
                        HStack(spacing: 3) {
                            Image(systemName: assigneeIsAgent ? "sparkles" : "person.crop.circle")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                            Text(assignee)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 4)
                    if card.commentCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "text.bubble")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                            Text("\(card.commentCount)")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                }
                .font(.locus(size: 10))
                .foregroundStyle(viewColors.textSecondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .locusCard(radius: 9)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(viewColors.separatorStrong.opacity(hovering ? 0.7 : 0), lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open") { open(card) }
        Menu("Move to") {
            ForEach(otherColumns) { column in
                Button(column.title) { move(card, column.id) }
            }
        }
        Button("Work on This in Chat") { workInChat(card) }
        Button("Copy Key") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
        }
        Divider()
        Button("Delete…", role: .destructive) { requestDelete(card) }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if card.priority != BoardPriority.none { parts.append("\(card.priority.title) priority") }
        if !card.labels.isEmpty { parts.append("Labels: \(card.labels.joined(separator: ", "))") }
        if let assignee = card.assignee { parts.append("Assigned to \(assignee)") }
        if card.commentCount > 0 {
            parts.append("\(card.commentCount) comment\(card.commentCount == 1 ? "" : "s")")
        }
        if let recentAgent { parts.append("Recently updated by agent \(recentAgent)") }
        return parts.joined(separator: ". ")
    }
}

private struct BoardDragPreview: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let key: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.locus(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(viewColors.textSecondary)
            Text(title)
                .font(.locus(size: 12, weight: .medium))
                .foregroundStyle(viewColors.textPrimary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(width: 200, alignment: .leading)
        .locusCard(radius: 9)
    }
}

/// Highlights a drop target: a capsule in the gap above a card, or an
/// outline around a column or picker chip.
struct BoardDropTarget: ViewModifier {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    enum Indicator {
        case above
        case outline(radius: CGFloat)
    }

    let indicator: Indicator
    let perform: ([String]) -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if targeted, case .above = indicator {
                    Capsule()
                        .fill(viewColors.signalDeep)
                        .frame(height: 3)
                        .padding(.horizontal, 4)
                        .offset(y: -4.5)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if targeted, case .outline(let radius) = indicator {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(viewColors.signalDeep, lineWidth: 2)
                        .background(
                            viewColors.signalDeep.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                perform(items)
            } isTargeted: { isTargeted in
                withAnimation(reduceMotion ? nil : LocusMotion.content) { targeted = isTargeted }
            }
    }
}

// MARK: - Timeline

struct BoardAuthorAvatar: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let author: BoardAuthor

    var body: some View {
        let agent = author.kind == .agent
        Image(systemName: agent ? "sparkles" : "person.fill")
            .imageScale(.small)
            .font(.locus(size: 10, weight: .semibold))
            .foregroundStyle(agent ? viewColors.brandInk : viewColors.textSecondary)
            .frame(width: 24, height: 24)
            .background(agent ? viewColors.accentFill : viewColors.textPrimary.opacity(0.08), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Comments read as messages; activity is a single quieter line. Agent
/// entries say so in text and to VoiceOver, never only through the glyph.
struct BoardTimelineRow: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let entry: BoardTimelineEntry
    let now: Date

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .short
        return formatter
    }()

    /// Relative to the timeline's clock, so "2 min. ago" keeps advancing.
    private var time: String {
        Self.relativeFormatter.localizedString(for: min(entry.createdAt, now), relativeTo: now)
    }

    var body: some View {
        switch entry.kind {
        case .comment:
            HStack(alignment: .top, spacing: 9) {
                BoardAuthorAvatar(author: entry.author)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.author.name)
                            .font(.locus(size: 11, weight: .semibold))
                            .foregroundStyle(viewColors.textPrimary)
                        if entry.author.kind == .agent {
                            Text("Agent")
                                .font(.locus(size: 10, weight: .semibold))
                                .foregroundStyle(viewColors.textSecondary)
                                .padding(.horizontal, 5)
                                .frame(minHeight: 16)
                                .background(viewColors.textPrimary.opacity(0.07), in: Capsule())
                        }
                        Text(time)
                            .font(.locus(size: 10))
                            .foregroundStyle(viewColors.textSecondary)
                            .help(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text(entry.text)
                        .font(.locus(size: 12))
                        .foregroundStyle(viewColors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            entry.author.kind == .agent
                                ? viewColors.accentFill.opacity(0.10) : viewColors.surfaceCard,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(viewColors.separator, lineWidth: 1)
                                .accessibilityHidden(true)
                        }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(entry.author.kind == .agent ? "Agent " : "")\(entry.author.name) commented \(time): \(entry.text)"
            )
        case .activity:
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Group {
                    if entry.author.kind == .agent {
                        Image(systemName: "sparkles")
                            .imageScale(.small)
                    } else {
                        Circle().frame(width: 5, height: 5)
                    }
                }
                .font(.locus(size: 10))
                .foregroundStyle(viewColors.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
                (Text(entry.author.name).fontWeight(.semibold)
                    + Text(entry.author.kind == .agent ? " · Agent" : "")
                    + Text(" · \(entry.text) · \(time)"))
                    .font(.locus(size: 10))
                    .foregroundStyle(viewColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(entry.author.kind == .agent ? "Agent " : "")\(entry.author.name): \(entry.text), \(time)"
            )
        }
    }
}

// MARK: - Small components

/// Type-ahead card creation at the bottom of a column. Focus stays in the
/// field after a card is added, so a list can be typed out in one go.
struct BoardQuickAddField: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let column: BoardColumn
    let onAdd: (String, BoardColumn) -> Bool

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .imageScale(.small)
                .foregroundStyle(viewColors.textSecondary)
                .accessibilityHidden(true)
            TextField("Add a card", text: $text)
                .textFieldStyle(.plain)
                .font(.locus(size: 11))
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand {
                    text = ""
                    focused = false
                }
                .accessibilityLabel("Add a card to \(column.title)")
                .accessibilityIdentifier("board.quickAdd.\(column.id)")
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 30)
        .background(
            focused ? viewColors.surfaceCard : viewColors.textPrimary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(focused ? viewColors.signalDeep : viewColors.separator, lineWidth: 1)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private func submit() {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if onAdd(title, column) {
            text = ""
            focused = true
        }
    }
}

struct BoardCountBadge: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let count: Int
    let total: Int

    var body: some View {
        Text(count == total ? "\(total)" : "\(count)/\(total)")
            .font(.locus(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(viewColors.textSecondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 18)
            .background(viewColors.textPrimary.opacity(0.07), in: Capsule())
            .fixedSize()
            .accessibilityLabel(count == total ? "\(total) cards" : "\(count) of \(total) cards match")
    }
}

struct BoardPriorityBadge: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let priority: BoardPriority

    var body: some View {
        if priority != BoardPriority.none {
            HStack(spacing: 3) {
                Image(systemName: priority.symbol)
                    .imageScale(.small)
                    .fontWeight(.bold)
                    .foregroundStyle(priority.tint)
                Text(priority.title)
                    .font(.locus(size: 10, weight: .semibold))
                    .foregroundStyle(viewColors.textSecondary)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 18)
            .background(priority.tint.opacity(0.14), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(priority.title) priority")
        }
    }
}

struct BoardLabelPill: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Self.tint(for: label))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(label)
                .font(.locus(size: 10, weight: .medium))
                .foregroundStyle(viewColors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 18)
        .background(Self.tint(for: label).opacity(0.12), in: Capsule())
    }

    /// Stable across launches (unlike `hashValue`), so a label keeps its colour.
    static func tint(for label: String) -> Color {
        let palette = [
            LocusTheme.noteBlue, LocusTheme.noteGreen, LocusTheme.notePurple,
            LocusTheme.noteAmber, LocusTheme.noteCoral,
        ]
        let seed = label.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[seed % palette.count]
    }
}

/// Small primary or secondary button face for board actions.
struct BoardButtonLabel: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let title: String
    var symbol: String?
    var prominent = false
    var destructive = false

    var body: some View {
        Group {
            if let symbol {
                Label(title, systemImage: symbol)
            } else {
                Text(title)
            }
        }
        .font(.locus(size: 11, weight: .semibold))
        .foregroundStyle(
            prominent ? viewColors.brandInk
                : destructive ? viewColors.dangerForeground : viewColors.textPrimary
        )
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(
            prominent ? viewColors.accentFill : viewColors.surfaceCard,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            if !prominent {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(viewColors.separator, lineWidth: 1)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
    }
}

/// Empty and unavailable states. Small copy uses `textSecondary` so it
/// passes the 1x contrast audit, unlike `InspectorPlaceholder`.
struct BoardMessage<Actions: View>: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    let symbol: String
    let title: String
    let detail: String
    let identifier: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.locus(size: 20))
                .foregroundStyle(viewColors.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.locus(size: 12, weight: .semibold))
                .foregroundStyle(viewColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.locus(size: 10))
                .foregroundStyle(viewColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

extension BoardMessage where Actions == EmptyView {
    init(symbol: String, title: String, detail: String, identifier: String) {
        self.init(symbol: symbol, title: title, detail: detail, identifier: identifier) { EmptyView() }
    }
}

extension BoardPriority {
    var symbol: String {
        switch self {
        case .none: "minus"
        case .low: "chevron.down"
        case .medium: "equal"
        case .high: "chevron.up"
        case .urgent: "exclamationmark.2"
        }
    }

    var tint: Color {
        switch self {
        case .none, .low: LocusTheme.noteGray
        case .medium: LocusTheme.noteBlue
        case .high: LocusTheme.noteAmber
        case .urgent: LocusTheme.noteCoral
        }
    }
}
