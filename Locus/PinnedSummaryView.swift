import AppKit
import SwiftUI

// MARK: - Keys and navigation

/// One collapsible section of the pinned summary. The raw value doubles as
/// the accessibility identifier suffix and the collapse-state storage key.
enum SummarySectionKey: String, CaseIterable {
    case plan
    case activity
    case outputs
    case subagents
    case processes
    case sources

    var storageKey: String { "Locus.sessionOverview.section.\(rawValue).collapsed" }
    var identifier: String { "plan.section.\(rawValue)" }
}

/// Pages the Overview tab can push over the summary card, standing in for the
/// side-panel tabs Codex opens for "View all" and the plan.
enum SummaryDetail: Hashable {
    case sources
    case plan
}

// MARK: - Card

/// Codex's pinned summary: Plan → Activity → Outputs → Subagents →
/// Background processes → Sources, each a collapsible section, each present
/// only while it has something to say (Outputs and Sources always show so
/// their "+" actions stay discoverable).
struct PinnedSummaryCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: SessionStateEmitter
    @ObservedObject var browser: BrowserService
    let openDetail: (SummaryDetail) -> Void

    private var state: SessionState { session.state }
    private var planRow: PinnedSummary.PlanRow? { PinnedSummary.plan(state: state, document: model.activePlan) }
    private var activity: [PinnedSummary.ActivityRow] { PinnedSummary.activity(state: state) }
    private var outputs: [PinnedSummary.OutputRow] { PinnedSummary.outputs(state: state) }
    private var sources: [PinnedSummary.SourceRow] { PinnedSummary.sources(state: state) }
    private var processes: [BackgroundServiceRecord] {
        PinnedSummary.backgroundProcesses(model.backgroundServicesModel.backgroundServices)
    }
    private var subagents: [PinnedSummary.SubagentRow] {
        PinnedSummary.subagents(
            activities: model.teamRunLive.agentActivities,
            runs: model.visibleActivityRuns,
            sessionID: model.currentSessionID
        )
    }
    private var visibility: [Bool] {
        [planRow != nil, !activity.isEmpty, !subagents.isEmpty, !processes.isEmpty]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let planRow {
                planSection(planRow)
                    .transition(LocusMotion.transition(edge: .top, reduceMotion: reduceMotion))
            }
            if !activity.isEmpty {
                activitySection
                    .transition(LocusMotion.transition(edge: .top, reduceMotion: reduceMotion))
            }
            outputsSection
            if !subagents.isEmpty {
                subagentsSection
                    .transition(LocusMotion.transition(edge: .top, reduceMotion: reduceMotion))
            }
            if !processes.isEmpty {
                processesSection
                    .transition(LocusMotion.transition(edge: .top, reduceMotion: reduceMotion))
            }
            sourcesSection
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .summaryCardChrome()
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: visibility)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned summary")
        .accessibilityIdentifier("plan.summary")
    }

    // MARK: Plan

    private func planSection(_ plan: PinnedSummary.PlanRow) -> some View {
        // Codex's plan row is glyph + title only; progress lives in the
        // accessibility label and on the detail page.
        SummarySection(key: .plan, title: "Plan") {
            SummaryRow(
                icon: .plan,
                label: plan.title,
                identifier: "plan.plan.row",
                accessibilityLabel: "\(plan.title), \(plan.completed) of \(plan.steps.count) steps done",
                help: "Open the plan"
            ) {
                openDetail(.plan)
            }
        }
    }

    // MARK: Activity

    /// What the request in flight — or the last one to finish — actually did.
    /// It survives the turn on purpose: a run that ends leaves the Overview
    /// describing it until the next request replaces the list.
    private var activitySection: some View {
        SummarySection(key: .activity, title: "Activity", count: activity.count) {
            SummaryList(activity, identifierPrefix: "plan.activity", noun: "activity rows") { index, row in
                activityRow(row, index: index)
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ row: PinnedSummary.ActivityRow, index: Int) -> some View {
        switch row.kind {
        case .command(let failed):
            SummaryRow(
                icon: .process,
                label: row.label,
                meta: row.meta,
                metaColor: failed ? LocusTheme.danger : LocusTheme.muted,
                identifier: "plan.activity.row.\(index)",
                accessibilityLabel: [row.label, row.meta].compactMap { $0 }.joined(separator: ", "),
                help: row.label,
                // A command reads left to right: the binary and its first
                // arguments are what identify it, not the tail.
                truncation: .tail
            )
            .contextMenu {
                // Without the "$ " the label carries, what lands on the
                // clipboard is a command that can just be run.
                Button("Copy Command") {
                    model.copyMessage(
                        row.label.hasPrefix("$ ") ? String(row.label.dropFirst(2)) : row.label
                    )
                }
            }
        case .file:
            SummaryRow(
                icon: .forPath(row.target ?? row.label),
                label: row.label,
                meta: row.meta,
                identifier: "plan.activity.row.\(index)",
                accessibilityLabel: [row.label, row.meta].compactMap { $0 }.joined(separator: ", "),
                help: row.target ?? row.label
            ) {
                if let target = row.target { model.openSessionFile(target) }
            }
            .contextMenu {
                if let target = row.target {
                    Button("Reveal in Finder") { model.revealInFinder(target) }
                    Button("Copy Path") { model.copyMessage(target) }
                    Divider()
                    Button("Add to Context") { model.addWorkspaceFileToContext(target) }
                }
            }
        }
    }

    // MARK: Outputs

    private var outputsSection: some View {
        SummarySection(key: .outputs, title: "Outputs", count: outputs.count) {
            SummaryHeaderMenu(
                symbol: "plus",
                label: "Create a file or site",
                identifier: "plan.section.outputs.add"
            ) {
                creationMenuItems
            }
        } content: {
            if outputs.isEmpty {
                SummaryEmptyRow(title: "Create a file or site", identifier: "plan.outputs.empty") {
                    creationMenuItems
                }
            } else {
                SummaryList(outputs, identifierPrefix: "plan.outputs", noun: "outputs") { index, row in
                    outputRow(row, index: index)
                }
            }
        }
    }

    @ViewBuilder
    private var creationMenuItems: some View {
        ForEach(SummaryCreationKind.allCases) { kind in
            Button(kind.title, systemImage: kind.symbol) { model.insertCreationPrompt(kind) }
        }
    }

    @ViewBuilder
    private func outputRow(_ row: PinnedSummary.OutputRow, index: Int) -> some View {
        switch row.kind {
        case .file, .localSite:
            SummaryRow(
                icon: row.kind == .localSite ? .web : .forPath(row.target),
                label: row.label,
                identifier: "plan.outputs.row.\(index)",
                accessibilityLabel: row.label,
                help: row.target
            ) {
                model.openSummaryOutput(row)
            }
            .contextMenu {
                if row.kind == .localSite {
                    Button("Show in Files") { model.openSessionFile(row.target) }
                }
                Button("Reveal in Finder") { model.revealInFinder(row.target) }
                Button("Open in Default App") {
                    NSWorkspace.shared.open(model.sessionFileURL(row.target))
                }
                Button("Copy Path") { model.copyMessage(row.target) }
                Divider()
                Button("Add to Context") { model.addWorkspaceFileToContext(row.target) }
            }
        case .website:
            SummaryRow(
                icon: .forURL(URL(string: row.target), favicon: browser.favicon(forPageURL: URL(string: row.target))),
                label: row.label,
                meta: row.meta,
                identifier: "plan.outputs.row.\(index)",
                accessibilityLabel: [row.label, row.meta].compactMap { $0 }.joined(separator: ", "),
                help: row.target
            ) {
                model.openSummaryOutput(row)
            }
            .contextMenu {
                Button("Open in Browser Tab") { model.openSummaryOutput(row) }
                Button("Open in Default Browser") {
                    if let url = URL(string: row.target) { NSWorkspace.shared.open(url) }
                }
                Button("Copy URL") { model.copyMessage(row.target) }
            }
        }
    }

    // MARK: Subagents

    private var subagentsSection: some View {
        SummarySection(
            key: .subagents,
            title: "Subagents",
            count: subagents.count,
            autoCollapse: PinnedSummary.autoCollapsesSubagents(subagents)
        ) {
            VStack(spacing: 2) {
                ForEach(subagents) { row in
                    SummaryRow(
                        icon: .subagent,
                        label: row.name,
                        meta: row.status == .working ? "is working" : row.status.title,
                        metaColor: subagentColor(row.status),
                        identifier: "plan.subagents.row.\(row.id)",
                        accessibilityLabel: "\(row.name), \(row.status.title)",
                        help: row.name
                    ) {
                        model.openSummarySubagent(row)
                    }
                }
            }
        }
    }

    private func subagentColor(_ status: PinnedSummary.SubagentStatus) -> Color {
        switch status {
        case .working: LocusTheme.success
        case .waiting: LocusTheme.warning
        case .done: LocusTheme.muted
        case .failed: LocusTheme.danger
        }
    }

    // MARK: Background processes

    private var processesSection: some View {
        SummarySection(key: .processes, title: "Background processes", count: processes.count) {
            SummaryHeaderButton(
                symbol: "stop.circle",
                label: "Stop all background processes",
                identifier: "plan.processes.stopAll"
            ) {
                model.backgroundServicesModel.stopAllBackgroundServices()
            }
        } content: {
            VStack(spacing: 2) {
                ForEach(Array(processes.enumerated()), id: \.element.id) { index, service in
                    SummaryRow(
                        icon: .process,
                        label: PinnedSummary.processLabel(service),
                        meta: service.port.map { "localhost:\($0)" },
                        identifier: "plan.processes.row.\(index)",
                        accessibilityLabel: [
                            PinnedSummary.processLabel(service),
                            service.port.map { "port \($0)" },
                        ].compactMap { $0 }.joined(separator: ", "),
                        help: service.command
                    ) {
                        model.openTerminal()
                    }
                    .contextMenu {
                        if let port = service.port, let url = URL(string: "http://localhost:\(port)") {
                            Button("Open in Browser Tab") { model.openURLInBrowserTab(url) }
                        }
                        Button("Stop") { model.backgroundServicesModel.stopBackgroundService(service) }
                    }
                }
            }
        }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        SummarySection(key: .sources, title: "Sources", count: sources.count, isLast: true) {
            SummaryHeaderMenu(
                symbol: "plus",
                label: "Attach files or connect apps",
                identifier: "plan.section.sources.add"
            ) {
                sourcesMenuItems
            }
        } content: {
            if sources.isEmpty {
                SummaryEmptyRow(title: "Attach files or connect apps", identifier: "plan.sources.empty") {
                    sourcesMenuItems
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(sources.prefix(PinnedSummary.visibleSourceLimit).enumerated()), id: \.element.id) { index, row in
                        sourceRow(row, index: index)
                    }
                    SummaryRow(
                        icon: .viewAll,
                        label: "View all",
                        identifier: "plan.sources.viewAll",
                        accessibilityLabel: "View all sources",
                        help: "Show the complete source list"
                    ) {
                        openDetail(.sources)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sourcesMenuItems: some View {
        Button("Attach files or folders", systemImage: "paperclip") { model.addContext() }
        Button("Skills & MCP", systemImage: "puzzlepiece.extension") {
            model.presentSettings(.extensions)
        }
    }

    @ViewBuilder
    private func sourceRow(_ row: PinnedSummary.SourceRow, index: Int) -> some View {
        let source = row.source
        switch source.kind {
        case .webSearch:
            SummaryRow(
                icon: .web,
                label: source.label,
                identifier: "plan.sources.row.\(index)",
                accessibilityLabel: "\(source.label), \(row.detailLines.joined(separator: ", "))",
                help: row.detailLines.first
            )
        default:
            SummaryRow(
                icon: sourceIcon(source),
                label: source.label,
                identifier: "plan.sources.row.\(index)",
                accessibilityLabel: "\(source.label), \(row.detailLines.joined(separator: ", "))",
                help: row.meta ?? source.label
            ) {
                model.openSummarySource(source)
            }
        }
    }

    private func sourceIcon(_ source: SessionSource) -> SummaryIcon {
        switch source.kind {
        case .file: .forPath(source.target ?? source.label)
        case .image: .symbol("photo")
        case .application: .symbol("macwindow")
        case .simulator: .symbol("iphone")
        case .url:
            .forURL(
                source.target.flatMap(URL.init(string:)),
                favicon: browser.favicon(forPageURL: source.target.flatMap(URL.init(string:)))
            )
        case .tool: .logo(name: source.label)
        case .webSearch: .web
        }
    }
}

// MARK: - Section

/// Codex's `q.Section` in accordion mode: title toggles, count shows while
/// collapsed, chevron shows on hover, trailing action stays put, and a
/// hairline separates it from the next section.
struct SummarySection<Trailing: View, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The person's own choice, persisted per section like Codex's
    /// `thread-summary-panel-section-expanded-<key>`.
    @AppStorage private var collapsed: Bool
    /// Codex keeps auto-collapse apart from the persisted preference: it is
    /// transient, lifts as soon as the section has live content again, and
    /// never fires a second time once the person has touched the section.
    @State private var autoCollapsed = false
    @State private var autoCollapseCanceled = false
    @State private var hovering = false

    private var isCollapsed: Bool { collapsed || (autoCollapse && autoCollapsed) }

    let key: SummarySectionKey
    let title: String
    let count: Int?
    let autoCollapse: Bool
    let isLast: Bool
    let trailing: () -> Trailing
    let content: () -> Content

    init(
        key: SummarySectionKey,
        title: String,
        count: Int? = nil,
        autoCollapse: Bool = false,
        isLast: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.key = key
        self.title = title
        self.count = count
        self.autoCollapse = autoCollapse
        self.isLast = isLast
        self.trailing = trailing
        self.content = content
        _collapsed = AppStorage(wrappedValue: false, key.storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Clip only the collapsible region, with a few points of slack so
            // the design-system focus ring (which overhangs its control) is
            // not cut off while the top-edge transition stays contained.
            VStack(spacing: 0) {
                if !isCollapsed {
                    content()
                        .padding(.bottom, 4)
                        .transition(LocusMotion.transition(edge: .top, reduceMotion: reduceMotion))
                }
            }
            .padding(4)
            .clipped()
            .padding(-4)
            if !isLast {
                Rectangle()
                    .fill(LocusTheme.line)
                    .frame(height: 1)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: isCollapsed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(key.identifier)
        .onChange(of: autoCollapse) {
            // Live content again (a new subagent started): lift the auto
            // collapse and let the next finish auto-collapse once more.
            if !autoCollapse {
                autoCollapsed = false
                autoCollapseCanceled = false
            }
        }
        .task(id: autoCollapse && !collapsed && !autoCollapsed && !autoCollapseCanceled) {
            // Codex collapses a finished section after ~30 s unless the person
            // touched it; the task cancels itself when any input flips.
            guard autoCollapse, !collapsed, !autoCollapsed, !autoCollapseCanceled else { return }
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            autoCollapsed = true
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                // Any touch cancels auto-collapse for this section instance;
                // an auto-collapsed section simply reopens without writing
                // the persisted preference.
                autoCollapseCanceled = true
                if autoCollapse, autoCollapsed {
                    autoCollapsed = false
                } else {
                    collapsed.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.locus(size: 9, weight: .bold))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(1)
                    if isCollapsed, let count, count > 0 {
                        Text("\(count)")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                        .opacity(hovering || isCollapsed ? 1 : 0)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") \(title)")
            .accessibilityValue(count.map { "\($0) \($0 == 1 ? "item" : "items")" } ?? "")
            .accessibilityIdentifier("\(key.identifier).toggle")

            trailing()
        }
        .onHover { hovering = $0 }
    }
}

extension SummarySection where Trailing == EmptyView {
    init(
        key: SummarySectionKey,
        title: String,
        count: Int? = nil,
        autoCollapse: Bool = false,
        isLast: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            key: key,
            title: title,
            count: count,
            autoCollapse: autoCollapse,
            isLast: isLast,
            trailing: { EmptyView() },
            content: content
        )
    }
}

// MARK: - Header actions

/// The 27×27 "+" in a section header that drops a menu.
struct SummaryHeaderMenu<Items: View>: View {
    let symbol: String
    let label: String
    let identifier: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: symbol)
                .font(.locus(size: 11, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 27, height: 27)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

struct SummaryHeaderButton: View {
    let symbol: String
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 11, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 27, height: 27)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.locus(.icon))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - List with "Show N more"

/// Codex's `q.List`: the first six rows, then "Show N more" (up to 50 at a
/// time) that turns into "Show less" once everything is out.
struct SummaryList<Item: Identifiable, Row: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var extraVisible = 0

    let items: [Item]
    let limit: Int
    let identifierPrefix: String
    let noun: String
    let row: (Int, Item) -> Row

    init(
        _ items: [Item],
        limit: Int = PinnedSummary.visibleItemLimit,
        identifierPrefix: String,
        noun: String,
        @ViewBuilder row: @escaping (Int, Item) -> Row
    ) {
        self.items = items
        self.limit = limit
        self.identifierPrefix = identifierPrefix
        self.noun = noun
        self.row = row
    }

    private var visibleCount: Int { min(items.count, limit + extraVisible) }
    private var remaining: Int { items.count - visibleCount }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(items.prefix(visibleCount).enumerated()), id: \.element.id) { index, item in
                row(index, item)
            }
            if items.count > limit {
                Button {
                    if remaining == 0 {
                        extraVisible = 0
                    } else {
                        extraVisible += min(remaining, PinnedSummary.visibleItemIncrement)
                    }
                } label: {
                    Text(remaining == 0 ? "Show less" : "Show \(min(remaining, PinnedSummary.visibleItemIncrement)) more")
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.locus())
                // Starts with the visible text so Voice Control's "Click Show
                // less" / "Click Show 2 more" match (WCAG label-in-name).
                .accessibilityLabel(
                    remaining == 0
                        ? "Show less"
                        : "Show \(min(remaining, PinnedSummary.visibleItemIncrement)) more \(noun)"
                )
                .accessibilityIdentifier("\(identifierPrefix).showMore")
            }
        }
        .animation(reduceMotion ? nil : LocusMotion.content, value: extraVisible)
    }
}

// MARK: - Rows

/// Leading glyph, label, optional trailing meta, optional chevron; the whole
/// row is one button when it has an action.
struct SummaryRow: View {
    let icon: SummaryIcon
    let label: String
    var meta: String? = nil
    var metaColor: Color = LocusTheme.muted
    var showsChevron = false
    let identifier: String
    var accessibilityLabel: String? = nil
    var help: String? = nil
    /// Middle by default, because most rows are paths and the tail — the file
    /// name — is what identifies them. A row whose label reads left to right,
    /// like a shell command, needs the head kept instead.
    var truncation: Text.TruncationMode = .middle
    var action: (() -> Void)? = nil

    init(
        icon: SummaryIcon,
        label: String,
        meta: String? = nil,
        metaColor: Color = LocusTheme.muted,
        showsChevron: Bool = false,
        identifier: String,
        accessibilityLabel: String? = nil,
        help: String? = nil,
        truncation: Text.TruncationMode = .middle,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.label = label
        self.meta = meta
        self.metaColor = metaColor
        self.showsChevron = showsChevron
        self.identifier = identifier
        self.accessibilityLabel = accessibilityLabel
        self.help = help
        self.truncation = truncation
        self.action = action
    }

    private var spokenLabel: String {
        accessibilityLabel ?? [label, meta].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        if let action {
            Button(action: action) { rowLabel }
                .buttonStyle(.locus())
                .help(help ?? label)
                .accessibilityLabel(spokenLabel)
                .accessibilityIdentifier(identifier)
        } else {
            rowLabel
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenLabel)
                .accessibilityIdentifier(identifier)
                .help(help ?? label)
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            icon.view
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(label)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.ink)
                .lineLimit(1)
                .truncationMode(truncation)
            Spacer(minLength: 6)
            if let meta {
                Text(meta)
                    .font(.locus(size: 8))
                    .foregroundStyle(metaColor)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.locus(size: 8, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Codex's empty state is the section's own action rendered as a full-width
/// row — a `Menu` styled like `SummaryRow`.
struct SummaryEmptyRow<Items: View>: View {
    let title: String
    /// Codex's empty rows are text-only; pass a symbol to lead with a glyph.
    var symbol: String?
    let identifier: String
    @ViewBuilder let items: () -> Items

    init(
        title: String,
        symbol: String? = nil,
        identifier: String,
        @ViewBuilder items: @escaping () -> Items
    ) {
        self.title = title
        self.symbol = symbol
        self.identifier = identifier
        self.items = items
    }

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.locus(size: 11, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.locus(size: 10, weight: .semibold))
                    .foregroundStyle(LocusTheme.inkSoft)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Icons

enum SummaryIcon {
    case symbol(String)
    case image(NSImage)
    case logo(name: String)

    static let plan = SummaryIcon.symbol("checklist")
    static let web = SummaryIcon.symbol("globe")
    static let tool = SummaryIcon.symbol("puzzlepiece.extension")
    static let process = SummaryIcon.symbol("terminal")
    static let subagent = SummaryIcon.symbol("person.crop.circle")
    static let viewAll = SummaryIcon.symbol("link")

    static func forPath(_ path: String) -> SummaryIcon {
        .symbol(symbolName(forPath: path))
    }

    static func forURL(_ url: URL?, favicon: NSImage?) -> SummaryIcon {
        favicon.map(SummaryIcon.image) ?? .web
    }

    static func symbolName(forPath path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html", "htm": "globe"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp", "tiff": "photo"
        case "md", "markdown", "docx", "doc", "rtf", "pages", "pdf", "txt": "doc.richtext"
        case "csv", "tsv", "xlsx", "xls", "numbers": "tablecells"
        case "pptx", "ppt", "key": "play.rectangle"
        case "sh", "zsh", "bash", "fish", "ps1", "bat", "command": "terminal"
        case "swift", "ts", "tsx", "js", "jsx", "py", "rb", "go", "rs", "java", "kt",
             "c", "cpp", "h", "m", "mm", "cs", "php": "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "plist", "xml": "curlybraces"
        default: "doc.text"
        }
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .symbol(let name):
            Image(systemName: name)
                .font(.locus(size: 11, weight: .medium))
                .foregroundStyle(LocusTheme.muted)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        case .logo(let name):
            MCPLogo(name: name, size: 18)
        }
    }
}

// MARK: - Card chrome

private struct SummaryCardChrome: ViewModifier {
    /// Cards fill their column; a chrome-wrapped control that sits in a row
    /// beside others opts out so it can hug its own content instead.
    var stretches = true

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: stretches ? .infinity : nil, alignment: .leading)
            .background(LocusTheme.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
    }
}

extension View {
    /// The same card treatment as `ContextWindowInfoCard`, so the summary and
    /// the pinned context card read as siblings.
    func summaryCardChrome(stretches: Bool = true) -> some View {
        modifier(SummaryCardChrome(stretches: stretches))
    }
}
