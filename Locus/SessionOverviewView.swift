import Combine
import SwiftUI

/// The Overview tab: Codex's pinned summary card (Plan, Outputs, Subagents,
/// Background processes, Sources) with the Locus context window card pinned
/// beneath it. "View all" and the plan row push an in-tab detail page over
/// the card — the closest Locus has to Codex's side-panel tabs.
struct SessionOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: SessionStateEmitter
    @State private var detail: SummaryDetail?

    private var state: SessionState { session.state }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch detail {
                case nil:
                    summaryPage
                case .sources:
                    SourcesDetailView(sources: PinnedSummary.sources(state: state), browser: model.browser) {
                        detail = nil
                    }
                case .plan:
                    PlanDetailView(session: session) { detail = nil }
                }
            }
            .id(detail)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(LocusMotion.transition(edge: .trailing, reduceMotion: reduceMotion))

            Divider().overlay(LocusTheme.line)
            VStack(spacing: 10) {
                SummaryShortcutsBar(workspace: state.workspace)
                VStack {
                    ContextWindowInfoCard()
                }
                    .accessibilityIdentifier("plan.context")
            }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(LocusTheme.paperDeep)
        .foregroundStyle(LocusTheme.ink)
        .font(.locus(size: 11))
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: detail)
        .onChange(of: model.currentSessionID) { detail = nil }
        .onChange(of: state.plan.isEmpty) {
            if state.plan.isEmpty, detail == .plan { detail = nil }
        }
    }

    private var summaryPage: some View {
        ScrollView {
            PinnedSummaryCard(session: session, browser: model.browser) { detail = $0 }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Detail pages

/// Back button plus an eyebrow title, mirroring the Runs tab's push header.
struct SummaryDetailHeader: View {
    let title: String
    let count: Int?
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Label("Summary", systemImage: "chevron.left")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 27)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel("Back to summary")
            .accessibilityIdentifier("plan.summary.back")
            Spacer(minLength: 4)
            Text(count.map { "\(title.uppercased()) · \($0)" } ?? title.uppercased())
                .font(.locus(size: 7, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(LocusTheme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 31)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }
}

/// Codex's complete source list: icon, label, muted meta, and the activity
/// lines that explain how each source was used.
struct SourcesDetailView: View {
    let sources: [PinnedSummary.SourceRow]
    @ObservedObject var browser: BrowserService
    let onBack: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SummaryDetailHeader(title: "Sources", count: sources.count, onBack: onBack)
            ScrollView {
                VStack(spacing: 0) {
                    if sources.isEmpty {
                        Text("No sources yet")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, row in
                        SourceDetailRow(row: row, index: index, icon: icon(for: row.source)) {
                            model.openSummarySource(row.source)
                        }
                        if index < sources.count - 1 {
                            Rectangle().fill(LocusTheme.line).frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .summaryCardChrome()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sources")
                .accessibilityIdentifier("plan.sources.panel")
                .padding(14)
            }
        }
    }

    private func icon(for source: SessionSource) -> SummaryIcon {
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

private struct SourceDetailRow: View {
    let row: PinnedSummary.SourceRow
    let index: Int
    let icon: SummaryIcon
    let action: () -> Void

    private var opensSomething: Bool { row.source.kind != .webSearch }

    private var spoken: String {
        ([row.source.label] + row.detailLines).joined(separator: ". ")
    }

    var body: some View {
        if opensSomething {
            Button(action: action) { content }
                .buttonStyle(.locus())
                .help(row.meta ?? row.source.label)
                .accessibilityLabel(spoken)
                .accessibilityIdentifier("plan.sources.panel.row.\(index)")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityIdentifier("plan.sources.panel.row.\(index)")
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.view
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.source.label)
                    .font(.locus(size: 10, weight: .semibold))
                    .foregroundStyle(LocusTheme.ink)
                    .lineLimit(2)
                if let meta = row.meta {
                    Text(meta)
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ForEach(row.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The plan as a checklist, opened from the summary's plan row.
struct PlanDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: SessionStateEmitter
    let onBack: () -> Void
    @State private var now = Date()

    private let timestampTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private var state: SessionState { session.state }
    private var title: String {
        model.activePlan?.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Plan"
    }

    var body: some View {
        VStack(spacing: 0) {
            SummaryDetailHeader(title: title, count: nil, onBack: onBack)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(state.completedStepCount) of \(state.plan.count) steps done")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .padding(.horizontal, 4)
                        VStack(spacing: 3) {
                            ForEach(state.plan) { step in
                                SessionPlanStepRow(step: step, now: now)
                                    .id(step.id)
                            }
                        }
                        .padding(6)
                        .summaryCardChrome()
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Plan steps")
                        .accessibilityIdentifier("plan.plan.detail")
                    }
                    .padding(14)
                }
                .onAppear { scrollToRunningStep(proxy) }
                .onChange(of: state.plan.first(where: { $0.state == .running })?.id) {
                    scrollToRunningStep(proxy)
                }
            }
        }
        .onReceive(timestampTimer) { now = $0 }
    }

    private func scrollToRunningStep(_ proxy: ScrollViewProxy) {
        guard let id = state.plan.first(where: { $0.state == .running })?.id else { return }
        withAnimation(reduceMotion ? nil : LocusMotion.scroll) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

private struct SessionPlanStepRow: View {
    let step: SessionPlanStep
    let now: Date

    var body: some View {
        HStack(spacing: 9) {
            stepIcon.frame(width: 17)
            Text(step.label)
                .font(.locus(size: 10, weight: step.state == .running ? .semibold : .regular))
                .strikethrough(step.state == .done)
                .foregroundStyle(labelColor)
                .lineLimit(2)
            Spacer(minLength: 8)
            if step.state == .running, let started = step.startedAt {
                Text(elapsed(from: started))
                    .font(.locus(size: 8.5, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(step.state == .running ? LocusTheme.successSoft : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // `.ignore` (not `.combine`): with only an image and a text child,
        // AppKit collapses a combined row onto the text and drops the label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.label), \(step.state.rawValue)")
        .accessibilityIdentifier("plan.plan.detail.step.\(step.id)")
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(LocusTheme.success)
        case .running:
            ProgressView().controlSize(.small).tint(LocusTheme.signalDeep)
        case .pending:
            Image(systemName: "circle").foregroundStyle(LocusTheme.muted)
        case .failed:
            Image(systemName: "xmark").fontWeight(.bold).foregroundStyle(LocusTheme.danger)
        }
    }

    private var labelColor: Color {
        switch step.state {
        case .done: LocusTheme.muted
        case .running: LocusTheme.ink
        case .pending: LocusTheme.inkSoft
        case .failed: LocusTheme.danger
        }
    }

    private func elapsed(from milliseconds: Int) -> String {
        let seconds = max(Int(now.timeIntervalSince1970) - milliseconds / 1_000, 0)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

// MARK: - Pinned shortcuts

/// The Overview's pinned shortcuts. They sit beside the context card rather
/// than inside the summary so they never scroll away and never compete with
/// the sections, which appear only while they hold live session content.
private struct SummaryShortcutsBar: View {
    @EnvironmentObject private var model: AppModel
    let workspace: SessionWorkspaceIdentity

    private struct Shortcut: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let help: String
        var disabled = false
        let action: () -> Void
    }

    private var shortcuts: [Shortcut] {
        [
            Shortcut(
                id: "plan.shortcuts.finder",
                title: "Finder",
                symbol: "folder",
                help: workspace.path.isEmpty
                    ? "This chat has no workspace folder yet"
                    : "Reveal \(workspace.name) in Finder",
                disabled: workspace.path.isEmpty
            ) {
                model.revealSessionWorkspace()
            },
            Shortcut(
                id: "plan.shortcuts.accounts",
                title: "Accounts",
                symbol: "person.crop.circle",
                help: "Add or edit provider accounts and their API keys"
            ) {
                model.presentSettings(.accounts)
            },
            Shortcut(
                id: "plan.shortcuts.extensions",
                title: "Plugins & MCP",
                symbol: "puzzlepiece.extension",
                help: "Manage plugins, MCP servers, and skills"
            ) {
                model.presentSettings(.extensions)
            },
        ]
    }

    var body: some View {
        // Widest layout first. One row while the inspector is wide enough for
        // three labels, then two rows, and finally glyphs alone — the labels
        // shrink away rather than truncating "Plugins & MCP" mid-word.
        ViewThatFits(in: .horizontal) {
            singleRow
            stackedRows
            glyphRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Overview shortcuts")
        .accessibilityIdentifier("plan.shortcuts")
    }

    /// Buttons hug their text here, so the row's slack goes to the gaps
    /// between them instead of squeezing the longest label.
    private var singleRow: some View {
        HStack(spacing: 6) {
            ForEach(shortcuts) { shortcut in
                if shortcut.id != shortcuts.first?.id {
                    Spacer(minLength: 0)
                }
                button(shortcut, showsTitle: true, stretches: false)
            }
        }
    }

    private var stackedRows: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(shortcuts.prefix(2))) { shortcut in
                    button(shortcut, showsTitle: true, stretches: true)
                }
            }
            ForEach(Array(shortcuts.dropFirst(2))) { shortcut in
                button(shortcut, showsTitle: true, stretches: true)
            }
        }
    }

    private var glyphRow: some View {
        HStack(spacing: 6) {
            ForEach(shortcuts) { shortcut in
                button(shortcut, showsTitle: false, stretches: true)
            }
        }
    }

    private func button(
        _ shortcut: Shortcut,
        showsTitle: Bool,
        stretches: Bool
    ) -> some View {
        Button(action: shortcut.action) {
            HStack(spacing: 6) {
                Image(systemName: shortcut.symbol)
                    .font(.locus(size: 11, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityHidden(true)
                if showsTitle {
                    Text(shortcut.title)
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: stretches ? .infinity : nil, minHeight: 30)
            .summaryCardChrome(stretches: stretches)
        }
        .buttonStyle(.locus(.card))
        .disabled(shortcut.disabled)
        .help(shortcut.help)
        // Starts with the visible text so Voice Control's "Click Finder"
        // matches (WCAG label-in-name).
        .accessibilityLabel(shortcut.title)
        .accessibilityIdentifier(shortcut.id)
    }
}
