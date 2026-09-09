import Combine
import SwiftUI

/// A floating request summary. It appears when work starts and can be
/// minimized without moving keyboard focus. Opening a workspace panel takes
/// its place on the right until that panel closes.
struct SessionOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: SessionStateEmitter
    @State private var detail: SummaryDetail?
    @State private var summaryHeight: CGFloat = 170
    var maximumHeight: CGFloat = 520

    private var state: SessionState { session.state }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    if model.isBusy {
                        ProgressView().controlSize(.small).scaleEffect(0.8)
                    } else {
                        Image(systemName: "rectangle.grid.2x2")
                    }
                    Text(model.hasPendingPermission ? "Needs attention" : model.isBusy ? "Working" : "Overview")
                }
                .font(.locus(size: 13, weight: .semibold))
                Spacer()
                if let chat = model.sessionCatalog.snapshot.sessionsByID[model.currentSessionID],
                   let agent = chat.agentReference(in: model.agentDefinitions) {
                    Button("View agent") {
                        model.dismissOverview()
                        model.selectAgent(agent)
                    }
                    .buttonStyle(.locus())
                    .font(.locus(size: 11, weight: .medium))
                    .accessibilityIdentifier("plan.agentOverview")
                }
                Button { model.overviewPresented = false } label: {
                    Image(systemName: "minus")
                        .font(.locus(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.locus())
                .help("Minimize request overview")
                .accessibilityLabel("Minimize request overview")
                .accessibilityIdentifier("workspace.overview.minimize")
                Button { model.dismissOverview() } label: {
                    Image(systemName: "xmark")
                        .font(.locus(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.locus())
                .help("Close overview (Esc)")
                .accessibilityLabel("Close overview")
                .accessibilityIdentifier("workspace.overview.close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
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
        }
        .frame(height: detail == nil ? min(maximumHeight, summaryHeight + 46) : maximumHeight)
        .background(LocusTheme.paperDeep)
        .foregroundStyle(LocusTheme.ink)
        .font(.locus(size: 11))
        .animation(reduceMotion ? nil : LocusMotion.spatial, value: detail)
        .onChange(of: model.currentSessionID) { detail = nil }
        .onExitCommand { model.dismissOverview() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.overview.popover")
        .onChange(of: state.plan.isEmpty) {
            if state.plan.isEmpty, detail == .plan { detail = nil }
        }
    }

    private var summaryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PinnedSummaryCard(session: session, browser: model.browser) { detail = $0 }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: OverviewContentHeightKey.self, value: geometry.size.height)
                }
            }
        }
        .onPreferenceChange(OverviewContentHeightKey.self) { if $0 > 0 { summaryHeight = $0 } }
    }
}

struct RequestOverviewActivity: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locusWorkspaceGeometry) private var geometry
    @ObservedObject var session: SessionStateEmitter

    private var title: String {
        if model.hasPendingPermission { return "Needs attention" }
        if model.isBusy { return "Working…" }
        return "Request overview"
    }

    var body: some View {
        Group {
            if model.overviewPresented {
                SessionOverviewView(
                    session: session,
                    maximumHeight: min(380, max(220, geometry.workspaceHeight - 150))
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(LocusTheme.lineStrong, lineWidth: 1) }
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
            } else {
                HStack(spacing: 0) {
                    Button { model.presentRequestOverview() } label: {
                        HStack(spacing: 8) {
                            if model.isBusy {
                                ProgressView().controlSize(.small).scaleEffect(0.8)
                            } else {
                                Image(systemName: "rectangle.grid.2x2")
                            }
                            Text(title).font(.locus(size: 12, weight: .semibold))
                            Image(systemName: "chevron.down").font(.locus(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.locus())
                    .help("Show request overview (⌘1)")
                    .accessibilityLabel("Show request overview")
                    .accessibilityIdentifier("workspace.overview")
                    Button { model.dismissOverview() } label: {
                        Image(systemName: "xmark").font(.locus(size: 10, weight: .semibold))
                            .frame(width: 30, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.locus())
                    .help("Dismiss request overview")
                    .accessibilityLabel("Dismiss request overview")
                }
                .foregroundStyle(LocusTheme.inkSoft)
                .locusSurface(.floating, radius: 10)
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(LocusTheme.lineStrong, lineWidth: 1) }
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct OverviewContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
                Label("Overview", systemImage: "chevron.left")
                    .font(.locus(size: 11, weight: .semibold))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 27)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel("Back to chat overview")
            .accessibilityIdentifier("plan.summary.back")
            Spacer(minLength: 4)
            Text(count.map { "\(title.uppercased()) · \($0)" } ?? title.uppercased())
                .font(.locus(size: 9, weight: .bold))
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
                            .font(.locus(size: 11))
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
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.ink)
                    .lineLimit(2)
                if let meta = row.meta {
                    Text(meta)
                        .font(.locus(size: 10))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ForEach(row.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.locus(size: 11))
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
                            .font(.locus(size: 11))
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
                .font(.locus(size: 12, weight: step.state == .running ? .semibold : .regular))
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
