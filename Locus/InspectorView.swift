import AppKit
import SwiftUI

/// The right-hand inspector: a dynamic, closable tab shell around workspace
/// run state, files, instructions, terminal and checkpoints, with a drag
/// handle on its leading edge.
struct InspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.openInspectorTabs.isEmpty {
                InspectorOpenTabBar()
                    .environmentObject(model)
                    // Browser and Terminal install native AppKit surfaces.
                    // Keep the title-bar controls above those siblings for
                    // hit-testing as well as drawing.
                    .zIndex(1)
            }

            Group {
                switch model.inspectorTab {
                case .plan:
                    InspectorPlanTab()
                case .changes:
                    InspectorChangesTab()
                case .files:
                    InspectorFilesTab()
                case .terminal:
                    InspectorTerminalTab()
                case .preview:
                    InspectorBrowserTab()
                case .notes:
                    InspectorNotesTab(
                        workspacePath: model.workspacePath,
                        sessionID: model.currentSessionID,
                        scope: model.settings.resolvedNotesScope
                    )
                    .id(NotesStore.storageIdentity(
                        workspacePath: model.workspacePath,
                        sessionID: model.currentSessionID,
                        scope: model.settings.resolvedNotesScope
                    ))
                case .checkpoints:
                    InspectorCheckpointsTab()
                case .runs:
                    InspectorRunsTab()
                case .agents:
                    InspectorAgentsTab()
                }
            }
            .environmentObject(model)
            .frame(maxHeight: .infinity)
            .clipped()
        }
        .locusSurface(
            .structural,
            radius: model.inspectorZoomed ? 12 : 0
        )
        .clipShape(RoundedRectangle(
            cornerRadius: model.inspectorZoomed ? 12 : 0,
            style: .continuous
        ))
        .overlay {
            if model.inspectorZoomed {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
        }
        .overlay(alignment: .leading) {
            InspectorResizeHandle()
                .environmentObject(model)
        }
        .padding(model.inspectorZoomed ? 8 : 0)
        // The outer surface reaches into the hidden title-bar area. Match it
        // to the inspector when docked; only expanded mode needs the paper
        // color as a contrasting margin around its rounded panel.
        .background(model.inspectorZoomed ? LocusTheme.paper : Color.clear)
    }
}

/// Only panels the user has opened appear here. The rail and overflow menu are
/// launchers; this bar is the durable, ordered workspace for switching and
/// closing panels without the permanent icon row competing for space.
private struct InspectorOpenTabBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                tabItems
            }
            .onAppear {
                proxy.scrollTo(model.inspectorTab.id, anchor: .center)
            }
            .onChange(of: model.inspectorTab) { _, tab in
                proxy.scrollTo(tab.id, anchor: .center)
            }
        }
        .frame(height: 31)
        .clipped()
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.tabBar")
    }

    private var tabItems: some View {
        HStack(spacing: 3) {
            ForEach(model.openInspectorTabs) { tab in
                InspectorOpenTabItem(tab: tab, width: tabWidth(tab))
                    .environmentObject(model)
                    .id(tab.id)
            }
        }
        .padding(.horizontal, 7)
    }

    private func tabWidth(_ tab: InspectorTab) -> CGFloat {
        let labelWidth = ceil((tab.title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ]).width)
        let badgeWidth = InspectorOpenTabItem.reservedBadgeWidth(for: tab)
        // Text, optional status, and close control each get a stable slot. This
        // avoids the loose label/X spacing that made the old row feel uneven.
        return min(104, max(55, labelWidth + badgeWidth + 35))
    }

}

/// Kept as its own identity-bearing view so rebuilding the selected panel can
/// never leave another tab's click closure attached to this tab's label.
private struct InspectorOpenTabItem: View {
    @EnvironmentObject private var model: AppModel
    let tab: InspectorTab
    let width: CGFloat
    @State private var isHovering = false

    private var selected: Bool { model.inspectorTab == tab }
    private var labelWidth: CGFloat {
        ceil((tab.title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ]).width)
    }

    static func reservedBadgeWidth(for tab: InspectorTab) -> CGFloat {
        tab == .changes ? 18 : (tab == .plan ? 7 : 0)
    }

    var body: some View {
        HStack(spacing: 3) {
            InspectorTabActivationButton(
                title: tab.title,
                selected: selected,
                accessibilityIdentifier: "inspector.tab.\(tab.rawValue)",
                action: focus
            )
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)

            if Self.reservedBadgeWidth(for: tab) > 0 {
                InspectorTextTabBadge(tab: tab)
                    .environmentObject(model)
                    .frame(width: Self.reservedBadgeWidth(for: tab))
                    .allowsHitTesting(false)
            }

            InspectorTabCloseButton(tab: tab, emphasized: selected || isHovering)
                .environmentObject(model)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(width: width, height: 28)
        .background(
            isHovering ? LocusTheme.white.opacity(selected ? 0.28 : 0.38) : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if selected {
                Capsule()
                    .fill(LocusTheme.ink)
                    .frame(height: 2)
                    .frame(width: min(labelWidth + 2, width - 30))
                    .padding(.leading, 8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private func focus() {
        guard !selected || model.inspectorCollapsed else { return }
        model.selectInspectorTab(tab)
    }
}

/// The close affordance stays quiet until its tab is active or hovered, but
/// its hit target never changes size. Tabs therefore remain calm and do not
/// shift as the pointer moves across the bar.
private struct InspectorTabCloseButton: View {
    @EnvironmentObject private var model: AppModel
    let tab: InspectorTab
    let emphasized: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            model.closeInspectorTab(tab)
        } label: {
            Image(systemName: "xmark")
                .font(.locus(size: 6.5, weight: .bold))
                .foregroundStyle(LocusTheme.inkSoft)
                .frame(width: 16, height: 18)
                .background(isHovering ? LocusTheme.ink.opacity(0.08) : Color.clear)
                .clipShape(Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .opacity(emphasized || isHovering ? 0.9 : 0.42)
        .onHover { isHovering = $0 }
        .help("Close \(tab.title)")
        .accessibilityLabel("Close \(tab.title) tab")
        .accessibilityIdentifier("inspector.tab.close.\(tab.rawValue)")
    }
}

/// A title-bar control must accept the first mouse event even when a native
/// editor, web view, or PTY currently owns first responder. SwiftUI's macOS
/// Button does not guarantee that when it is moved into the hidden title-bar
/// safe area, which makes the first tab switch appear to do nothing.
private struct InspectorTabActivationButton: NSViewRepresentable {
    let title: String
    let selected: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    final class FirstMouseButton: NSButton {
        var mouseDownAction: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // Browser and Terminal can change first responder during the same
            // event transaction. Dispatch from the control that was hit
            // instead of relying on mouse-up tracking to finish later.
            mouseDownAction?()
        }
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func activate() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> FirstMouseButton {
        let button = FirstMouseButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.activate)
        )
        button.isBordered = false
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.setButtonType(.momentaryChange)
        button.mouseDownAction = context.coordinator.activate
        return button
    }

    func updateNSView(_ button: FirstMouseButton, context: Context) {
        context.coordinator.action = action
        // The selected-state rebuild can give an existing NSButton a fresh
        // representable coordinator. NSControl does not retain its target, so
        // refresh both pieces instead of leaving the button pointed at the
        // coordinator from the previous panel transaction.
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate)
        button.mouseDownAction = context.coordinator.activate
        button.title = title
        let font = NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .medium)
        let titleColor = InspectorTabAppearance.titleColor(
            colorScheme: context.environment.colorScheme,
            selected: selected
        )
        // contentTintColor does not reliably color an NSButton title in the
        // dark title-bar material. An attributed title keeps every open tab
        // white instead of only the selected or hovered one.
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: titleColor]
        )
        button.contentTintColor = titleColor
        button.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel("\(title) inspector tab")
        button.setAccessibilityValue(selected ? "Selected" : "Not selected")
    }
}

enum InspectorTabAppearance {
    static func titleColor(colorScheme: ColorScheme, selected: Bool) -> NSColor {
        if colorScheme == .dark { return .white }
        return selected ? .labelColor : .secondaryLabelColor.withAlphaComponent(0.86)
    }
}

/// Compact attention state for text tabs. Destination symbols stay on the
/// vertical rail; the top bar uses only labels, badges, and close controls.
private struct InspectorTextTabBadge: View {
    @EnvironmentObject private var model: AppModel
    let tab: InspectorTab

    @ViewBuilder
    var body: some View {
        if tab == .changes, model.changedFileCount > 0 {
            Text(model.changedFileCount > 99 ? "99+" : "\(model.changedFileCount)")
                .font(.locus(size: 7, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 3)
                .frame(minHeight: 16)
                .background(model.changesHaveUnseenUpdate ? LocusTheme.coral : LocusTheme.muted)
                .clipShape(Capsule())
                .accessibilityHidden(true)
        } else if tab == .plan, model.planHasUnseenUpdate {
            Circle()
                .fill(LocusTheme.coral)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }
}

/// Shared empty state for inspector tabs.
struct InspectorPlaceholder: View {
    let symbol: String
    let title: String
    let message: String
    let identifier: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.locus(size: 23))
                .foregroundStyle(LocusTheme.muted)
            Text(title)
                .font(.locus(size: 11, weight: .bold))
            Text(message)
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }
}

/// Attention badge on the rail's icons, so a collapsed inspector keeps
/// asking for eyes exactly the way an open panel does.
struct InspectorTabBadge: View {
    @EnvironmentObject private var model: AppModel
    let tab: InspectorTab

    var body: some View {
        if tab == .changes, model.changedFileCount > 0 {
            // Coral only while the change is still unseen; once you have opened
            // the tab the count stays but stops asking for attention.
            let unseen = model.changesHaveUnseenUpdate
            Text(model.changedFileCount > 99 ? "99+" : "\(model.changedFileCount)")
                .font(.locus(size: 7, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 3)
                .frame(minHeight: 16)
                .background(unseen ? LocusTheme.coral : LocusTheme.muted)
                .clipShape(Capsule())
                .offset(x: 9, y: -5)
                .accessibilityElement()
                .accessibilityLabel(
                    unseen
                        ? "\(model.changedFileCount) changed files, new since you last looked"
                        : "\(model.changedFileCount) changed files"
                )
                .accessibilityIdentifier("inspector.tab.changes.badge")
        } else if tab == .plan, model.planHasUnseenUpdate {
            Circle()
                .fill(LocusTheme.coral)
                .frame(width: 5, height: 5)
                .offset(x: 5, y: -3)
                .accessibilityElement()
                .accessibilityLabel("Plan updated")
                .accessibilityIdentifier("inspector.tab.plan.badge")
        }
    }
}

/// Drag target on the inspector's leading divider.
private struct InspectorResizeHandle: View {
    @EnvironmentObject private var model: AppModel
    @State private var startWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(LocusTheme.line)
            .frame(width: 1)
            .overlay {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))

                    if model.inspectorZoomed {
                        Capsule()
                            .fill(
                                LocusTheme.ink.opacity(isHovering ? 0.52 : 0.28)
                            )
                            .frame(width: 3, height: 44)
                    }
                }
                    .frame(width: 14)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        isHovering = inside
                        // `.set()` rather than push/pop: an unbalanced pair is
                        // the classic way to leave the cursor stuck.
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                // Accumulate from a captured start width so the
                                // panel cannot drift over a long drag. Zoomed,
                                // the panel fills the remainder, so the same
                                // divider drags the chat column instead —
                                // rightward widens chat in both readings.
                                if model.inspectorZoomed {
                                    let start = startWidth ?? model.zoomedChatWidth
                                    if startWidth == nil { startWidth = start }
                                    model.setZoomedChatWidth(start + value.translation.width)
                                } else {
                                    let start = startWidth ?? model.inspectorWidth
                                    if startWidth == nil { startWidth = start }
                                    model.setInspectorWidth(start - value.translation.width)
                                }
                            }
                            .onEnded { _ in
                                startWidth = nil
                                if model.inspectorZoomed {
                                    model.commitZoomedChatWidth()
                                } else {
                                    model.commitInspectorWidth()
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        if model.inspectorZoomed {
                            model.setZoomedChatWidth(AppSettings.defaultZoomedChatWidth)
                            model.commitZoomedChatWidth()
                        } else {
                            model.setInspectorWidth(AppSettings.defaultInspectorWidth)
                            model.commitInspectorWidth()
                        }
                    }
                    .accessibilityRepresentation {
                        Slider(
                            value: Binding(
                                get: {
                                    Double(
                                        model.inspectorZoomed
                                            ? model.zoomedChatWidth
                                            : model.inspectorWidth
                                    )
                                },
                                set: { value in
                                    if model.inspectorZoomed {
                                        model.setZoomedChatWidth(CGFloat(value))
                                        model.commitZoomedChatWidth()
                                    } else {
                                        model.setInspectorWidth(CGFloat(value))
                                        model.commitInspectorWidth()
                                    }
                                }
                            ),
                            in: model.inspectorZoomed
                                ? AppSettings.minimumZoomedChatWidth...AppSettings.maximumZoomedChatWidth
                                : AppSettings.minimumInspectorWidth...AppSettings.maximumInspectorWidth
                        ) {
                            Text(
                                model.inspectorZoomed
                                    ? "Expanded panel width"
                                    : "Inspector width"
                            )
                        }
                        .accessibilityHint("Adjust the panel width. Double-click the divider to reset it.")
                        .accessibilityIdentifier("inspector.resizeHandle")
                    }
            }
    }
}

private enum RunsStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case attention
    case finished

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Any status"
        case .active: "Active"
        case .attention: "Needs attention"
        case .finished: "Finished"
        }
    }

    func includes(_ run: OrchestrationRun) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            ["queued", "dispatching", "running", "reviewing"].contains(run.state)
        case .attention:
            ["waiting_permission", "waiting_computer", "waiting_dispatch_approval",
             "paused", "interrupted", "failed"].contains(run.state)
        case .finished:
            TeamRunState(rawValue: run.state)?.isTerminal == true
        }
    }
}

struct InspectorRunsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var scope: RunScope = .all
    @State private var statusFilter: RunsStatusFilter = .all
    @State private var runSearch = ""
    @State private var showingRunDetail = false
    @State private var detailRunID: String?
    @State private var viewMode = "overview"
    @State private var filter = ""
    @State private var draftPlan: DispatchPlan?
    @State private var showTechnicalLog = false
    @State private var telemetryContentRunID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let plan = draftPlan, model.pendingDispatchPlan != nil {
                dispatchEditor(plan)
            } else if showingRunDetail,
                      let detailRunID,
                      let run = model.runRecord(for: detailRunID) {
                runBody(run)
            } else if showingRunDetail {
                ProgressView("Loading run…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                runList
            }
        }
        .task(id: model.currentSessionID) {
            if !model.isLoadingOrchestrationRuns {
                await model.refreshOrchestrationRuns()
            }
        }
        .onChange(of: model.pendingDispatchPlan) { _, value in draftPlan = value }
        .task(id: model.runsNavigationRequest?.id) {
            guard let request = model.runsNavigationRequest else {
                showingRunDetail = false
                detailRunID = nil
                return
            }
            detailRunID = request.runID
            await model.loadOrchestrationRun(request.runID)
            if let run = model.runRecord(for: request.runID) {
                scope = run.isSoloSwarm ? .soloSwarm : (run.runKind == "team" ? .teams : .all)
                showingRunDetail = true
            }
        }
        .onAppear { draftPlan = model.pendingDispatchPlan }
        .confirmationDialog(
            "Include visible content in this trace?",
            isPresented: Binding(
                get: { telemetryContentRunID != nil },
                set: { if !$0 { sendMetadataInsteadOfContent() } }
            ),
            titleVisibility: .visible
        ) {
            if let runID = telemetryContentRunID {
                Button("Send Content Trace") {
                    telemetryContentRunID = nil
                    Task { await model.exportRunToOTLP(runID, includeContent: true) }
                }
            }
            Button("Send Metadata Only", role: .cancel) {
                sendMetadataInsteadOfContent()
            }
        } message: {
            Text("This one export may contain prompts, visible responses, and tool content. Credentials and authorization values remain excluded. Dismissing sends metadata only.")
        }
    }

    private func sendMetadataInsteadOfContent() {
        guard let runID = telemetryContentRunID else { return }
        telemetryContentRunID = nil
        Task { await model.exportRunToOTLP(runID) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(LocusTheme.signalDeep)
                Text("RUNS")
                    .font(.locus(size: 8, weight: .bold))
                    .tracking(0.7)
                Spacer()
                Button {
                    Task { await model.refreshOrchestrationRuns() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.locus())
                    .help("Refresh run history")
            }
            Picker("Run type", selection: Binding(
                get: { scope },
                set: { newScope in
                    scope = newScope
                    showingRunDetail = false
                    detailRunID = nil
                }
            )) {
                ForEach(RunScope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("runs.scope")

            if scope == .soloSwarm {
                soloSwarmControl
            }

            if !showingRunDetail {
                HStack(spacing: 7) {
                    TextField("Search runs", text: $runSearch)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("runs.search")
                    Menu {
                        ForEach(RunsStatusFilter.allCases) { item in
                            Button {
                                statusFilter = item
                            } label: {
                                Label(item.title, systemImage: statusFilter == item ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help(statusFilter.title)
                    .accessibilityLabel("Filter by status")
                    .accessibilityValue(statusFilter.title)
                    .accessibilityIdentifier("runs.statusFilter")
                }
            }
        }
        .padding(13)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private var runPickerRuns: [OrchestrationRun] {
        AppModel.orchestrationPickerRuns(
            model.orchestrationRuns,
            selected: model.selectedOrchestrationRun
        )
    }

    private func runTitle(_ run: OrchestrationRun) -> String {
        if let name = run.teamName?.nilIfEmpty { return name }
        if run.isSoloSwarm { return "Solo Swarm" }
        switch run.runKind {
        case "solo": return "Solo run"
        case "evaluation": return "Evaluation"
        case "verification": return "Verification"
        case "memory_review": return "Memory review"
        default: return "Team run"
        }
    }

    private func runCategoryTitle(_ run: OrchestrationRun) -> String {
        if run.isSoloSwarm { return "Solo Swarm" }
        if run.runKind == "team" { return "Team" }
        return (run.runKind ?? "solo")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func runSymbol(_ run: OrchestrationRun) -> String {
        if run.isSoloSwarm { return "circle.hexagongrid.fill" }
        if run.runKind == "team" { return "person.2.fill" }
        return "person.fill"
    }

    private func runStateColor(_ run: OrchestrationRun) -> Color {
        switch TeamRunState(rawValue: run.state) {
        case .completed: LocusTheme.success
        case .failed, .interrupted, .cancelled, .discarded: LocusTheme.coral
        case .paused, .waitingComputer, .waitingPermission, .waitingDispatchApproval:
            LocusTheme.warning
        default: LocusTheme.signalDeep
        }
    }

    private func runProgress(_ run: OrchestrationRun) -> String? {
        let total = run.jobCount ?? 0
        guard total > 0 else { return nil }
        let unit = run.isSoloSwarm ? "workers" : "jobs"
        return "\(run.completedJobCount ?? 0)/\(total) \(unit)"
    }

    private var filteredRuns: [OrchestrationRun] {
        let query = runSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return runPickerRuns
            .filter { scope.includes($0) && statusFilter.includes($0) }
            .filter { run in
                query.isEmpty || [runTitle(run), run.request, run.state, run.runKind ?? ""]
                    .joined(separator: " ").lowercased().contains(query)
            }
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.updatedAt > $1.updatedAt
            }
    }

    private var soloSwarmControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use Solo Swarm for the next turn", isOn: Binding(
                get: { model.soloSwarmEnabled },
                set: { model.selectSoloRoute(swarm: $0) }
            ))
            .font(.locus(size: 9, weight: .semibold))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityIdentifier("runs.soloSwarm.toggle")
            Text("Temporary read-only workers share the selected model and fixed safety limits.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.signal.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LocusTheme.signalDeep.opacity(0.24), lineWidth: 1)
        }
    }

    private var runList: some View {
        Group {
            if model.isLoadingOrchestrationRuns && runPickerRuns.isEmpty {
                ProgressView("Loading runs…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRuns.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: scope == .soloSwarm
                        ? "circle.hexagongrid" : "clock.arrow.circlepath")
                        .font(.locus(size: 24))
                        .foregroundStyle(LocusTheme.muted)
                    Text(scope == .soloSwarm ? "No Solo Swarm runs yet" : "No matching runs")
                        .font(.locus(size: 11, weight: .bold))
                    Text(scope == .soloSwarm
                        ? "Turn on Solo Swarm above, then send a Work, Plan, or Build request. The run appears even if no workers are delegated."
                        : "Try another run type, status, or search term.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(scope == .soloSwarm
                    ? "runs.soloSwarm.empty" : "runs.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredRuns) { run in
                            runListRow(run)
                        }
                    }
                    .padding(12)
                }
                .accessibilityIdentifier("runs.list")
            }
        }
    }

    private func runListRow(_ run: OrchestrationRun) -> some View {
        Button {
            detailRunID = run.id
            viewMode = "overview"
            filter = ""
            showingRunDetail = true
            Task { await model.loadOrchestrationRun(run.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: runSymbol(run))
                        .foregroundStyle(runStateColor(run))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(runTitle(run))
                                .font(.locus(size: 10, weight: .bold))
                                .lineLimit(1)
                            if run.pinned {
                                Image(systemName: "pin.fill")
                                    .font(.locus(size: 7))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                        }
                        Text(run.request.isEmpty ? "No request was recorded." : run.request)
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text(run.state.replacingOccurrences(of: "_", with: " ").uppercased())
                        .font(.locus(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(runStateColor(run))
                }
                HStack(spacing: 5) {
                    Text(runCategoryTitle(run))
                    Text("·")
                    Text(Date(timeIntervalSince1970: run.updatedAt), style: .relative)
                    if let progress = runProgress(run) {
                        Text("·")
                        Text(progress)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LocusTheme.white.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(LocusTheme.line) }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.locus())
        .accessibilityIdentifier("runs.row.\(run.id)")
    }

    private func runBody(_ run: OrchestrationRun) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    showingRunDetail = false
                    detailRunID = nil
                } label: {
                    Label(scope.title, systemImage: "chevron.left")
                }
                .buttonStyle(.locus())
                .font(.locus(size: 8, weight: .semibold))
                .accessibilityIdentifier("runs.back")
                Spacer()
                Text(runCategoryTitle(run).uppercased())
                    .font(.locus(size: 7, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 31)
            .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
            runSummary(run)
            Picker("View", selection: $viewMode) {
                Text("Overview")
                    .accessibilityIdentifier("runs.view.overview")
                    .tag("overview")
                Text("Activity")
                    .accessibilityIdentifier("runs.view.activity")
                    .tag("activity")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if viewMode == "overview" {
                if run.isSoloSwarm {
                    soloSwarmOverview(run)
                } else if run.runKind == "team" {
                    overview(run)
                } else {
                    soloOverview(run)
                }
            } else {
                activity(run)
            }
        }
    }

    private func runSummary(_ run: OrchestrationRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(runTitle(run))
                        .font(.locus(size: 11, weight: .bold))
                    Text(runStateTitle(run))
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("runs.state")
                }
                Spacer()
                runPrimaryAction(run)
                runActions(run)
            }
            let presentation = model.teamRunPresentation(for: run.id, durable: run)
            if let reason = run.recoveryReason, presentation.canRecover {
                Label(reason, systemImage: "arrow.clockwise.circle.fill")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let task = model.activeTaskRecord, task.id == run.taskID {
                HStack(spacing: 7) {
                    Button("Review & Land") { model.prepareReviewAndLand() }
                        .disabled(model.isBusy || !model.taskHasChanges)
                    Button("Copy Patch") { model.copyActiveTaskPatch() }
                        .disabled(model.isBusy || !model.taskHasChanges)
                    Menu {
                        Button("Open Checkout") { model.openActiveTaskCheckout() }
                        Button("Reveal in Finder") { model.revealActiveTaskCheckout() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                }
                .buttonStyle(.locus())
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(LocusTheme.paperDeep.opacity(0.5))
    }

    @ViewBuilder
    private func runPrimaryAction(_ run: OrchestrationRun) -> some View {
        let presentation = model.teamRunPresentation(for: run.id, durable: run)
        if presentation.canStop, run.runKind == "solo" {
            Button("Stop") { model.cancelOrchestration(run.id) }
                .buttonStyle(.locus())
                .font(.locus(size: 8, weight: .semibold))
                .foregroundStyle(LocusTheme.coral)
                .accessibilityIdentifier("runs.stop")
        } else if run.runKind == "solo",
                  ["failed", "interrupted", "cancelled", "paused"].contains(run.state) {
            Button("Retry") { model.retryRun(run) }
                .buttonStyle(.locus())
                .font(.locus(size: 8, weight: .semibold))
                .accessibilityIdentifier("runs.retry")
        } else if presentation.canRecover, run.runKind == "team" {
            if run.checkpoint?.state["fallback_action"]?.string == "run_with_locus" {
                Button("Run with Locus") { model.runOrchestrationWithLocus(run) }
                    .buttonStyle(.locus())
                    .font(.locus(size: 8, weight: .semibold))
                    .accessibilityIdentifier("runs.runWithLocus")
            } else {
                Button("Resume") { model.resumeOrchestration(run) }
                    .buttonStyle(.locus())
                    .font(.locus(size: 8, weight: .semibold))
                    .accessibilityIdentifier("runs.resume")
            }
        } else if presentation.canPause, run.runKind == "team" {
            Button("Pause") { model.pauseOrchestration(run.id) }
                .buttonStyle(.locus())
                .font(.locus(size: 8, weight: .semibold))
                .accessibilityIdentifier("runs.pause")
        }
    }

    @ViewBuilder
    private func runActions(_ run: OrchestrationRun) -> some View {
        let presentation = model.teamRunPresentation(for: run.id, durable: run)
        Menu {
            Button(run.pinned ? "Unpin Run" : "Pin Run") {
                model.setOrchestrationPinned(run, pinned: !run.pinned)
            }
            if presentation.canRecover, run.runKind != "solo" {
                if run.checkpoint?.state["fallback_action"]?.string == "run_with_locus" {
                    Button("Run with Locus") { model.runOrchestrationWithLocus(run) }
                } else {
                    Button("Resume") { model.resumeOrchestration(run) }
                }
            }
            if run.runKind == "solo",
               ["failed", "interrupted", "cancelled", "paused"].contains(run.state) {
                Button("Retry Run") { model.retryRun(run) }
            }
            if run.taskID != nil && !run.legacy {
                Button("Replay Same Baseline") { model.replayOrchestration(run) }
            }
            if !run.legacy {
                Button("Duplicate from Current Workspace") { model.duplicateOrchestration(run) }
            }
            if presentation.canPause {
                Button("Pause at Safe Boundary") { model.pauseOrchestration(run.id) }
            }
            if presentation.canStop {
                Button("Stop Run", role: .destructive) { model.cancelOrchestration(run.id) }
            }
            Menu("Export") {
                Button("Redacted .locusrun") {
                    Task { await model.exportOrchestration(run.id, includeContent: false) }
                }
                Button("Include Visible Content…") {
                    Task { await model.exportOrchestration(run.id, includeContent: true) }
                }
                if model.settings.otlpExportEnabled,
                   !model.settings.otlpEndpoint.trimmingCharacters(
                    in: .whitespacesAndNewlines
                   ).isEmpty
                {
                    Divider()
                    Button(
                        run.exportState == "failed"
                            ? "Retry Metadata Trace" : "Send Metadata Trace"
                    ) {
                        Task { await model.exportRunToOTLP(run.id) }
                    }
                    Button("Send Content Trace…") {
                        telemetryContentRunID = run.id
                    }
                }
            }
            Divider()
            Button("Discard Run", role: .destructive) { model.discardOrchestration(run.id) }
                .disabled(
                    presentation.isActivelyOwned
                        || (!presentation.state.isTerminal && !presentation.canRecover)
                )
            if run.taskID != nil && ["discarded", "cancelled", "completed", "failed"].contains(run.state) {
                Button("Clean Up Managed Checkout", role: .destructive) {
                    model.cleanupOrchestrationCheckout(run)
                }
                .disabled(model.isBusy)
            }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
    }

    private func overview(_ run: OrchestrationRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewCard("REQUEST", symbol: "text.bubble") {
                    Text(run.request.isEmpty ? "No request was recorded." : run.request)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(8)
                }

                overviewCard("PROGRESS", symbol: "chart.bar.fill") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(runPhases(run).enumerated()), id: \.offset) { index, phase in
                            HStack(spacing: 8) {
                                Image(systemName: phase.done
                                    ? "checkmark.circle.fill"
                                    : phase.active ? "circle.inset.filled" : "circle")
                                    .foregroundStyle(phase.done
                                        ? LocusTheme.success
                                        : phase.active ? LocusTheme.signalDeep : LocusTheme.lineStrong)
                                    .frame(width: 13)
                                Text(phase.title)
                                    .font(.locus(size: 9, weight: phase.active ? .bold : .regular))
                                Spacer()
                                if phase.active {
                                    Text("Current")
                                        .font(.locus(size: 7, weight: .semibold))
                                        .foregroundStyle(LocusTheme.signalDeep)
                                }
                            }
                            if index < runPhases(run).count - 1 {
                                Rectangle().fill(phase.done ? LocusTheme.success.opacity(0.4) : LocusTheme.line)
                                    .frame(width: 1, height: 7)
                                    .padding(.leading, 6)
                            }
                        }
                    }
                }

                teamAgentsAndJobs(run)

                overviewCard("RESULTS", symbol: "checkmark.seal") {
                    VStack(alignment: .leading, spacing: 6) {
                        metricRow("Jobs", "\(run.completedJobCount ?? 0) of \(run.jobCount ?? 0) completed")
                        metricRow("Duration", runDuration(run))
                        if let calls = run.usage?["model_calls"]?.integer {
                            metricRow("Model calls", calls.formatted())
                        }
                        if run.id == model.orchestrationRunID, !model.gitChanges.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Changed files")
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.muted)
                                ForEach(model.gitChanges.prefix(8)) { change in
                                    Text("\(change.status.marker)  \(change.path)")
                                        .font(.locus(size: 7, design: .monospaced))
                                        .lineLimit(1)
                                }
                                if model.gitChanges.count > 8 {
                                    Text("+ \(model.gitChanges.count - 8) more")
                                        .font(.locus(size: 7))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                            }
                        }
                        let presentation = model.teamRunPresentation(for: run.id, durable: run)
                        if let reason = run.recoveryReason,
                           !reason.isEmpty,
                           presentation.canRecover || presentation.state.isTerminal
                        {
                            Label(reason, systemImage: presentation.canRecover
                                ? "arrow.clockwise.circle.fill" : "exclamationmark.circle.fill")
                                .font(.locus(size: 8))
                                .foregroundStyle(presentation.canRecover
                                    ? LocusTheme.warning : LocusTheme.coral)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Run ID · \(run.id)")
                        Text("Saved events · \(run.lastSequence)")
                        if let checkpoint = run.checkpoint {
                            Text("Checkpoint · \(checkpoint.kind.replacingOccurrences(of: "_", with: " "))")
                        }
                    }
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .padding(.top, 6)
                }
                .font(.locus(size: 8, weight: .semibold))
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.overview")
    }

    private func teamAgentsAndJobs(_ run: OrchestrationRun) -> some View {
        let attempts = agentTreeAttempts(run)
        let attemptedJobIDs = Set(attempts.map(\.jobID))
        let waitingJobs = (run.plan?.jobs ?? []).filter { !attemptedJobIDs.contains($0.id) }
        return overviewCard("AGENTS & JOBS", symbol: "person.2.fill") {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = run.plan?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.locus(size: 9, weight: .medium))
                }
                if attempts.isEmpty && waitingJobs.isEmpty {
                    Text("No jobs were assigned for this run.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                } else {
                    ForEach(attempts) { attempt in
                        agentTreeRow(attempt, run: run)
                    }
                    ForEach(waitingJobs) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: "circle")
                                    .foregroundStyle(LocusTheme.lineStrong)
                                Text(job.agentID.isEmpty ? friendlyJobKind(job.kind) : job.agentID)
                                    .font(.locus(size: 8, weight: .bold))
                                Text("· waiting")
                                    .font(.locus(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                            Text(job.goal)
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.inkSoft)
                                .lineLimit(3)
                            if !job.dependencies.isEmpty {
                                Text("Runs after: \(job.dependencies.joined(separator: ", "))")
                                    .font(.locus(size: 7))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                        }
                        .padding(.leading, 3)
                    }
                }
            }
            .accessibilityIdentifier("runs.agentTree")
        }
    }

    private func soloSwarmOverview(_ run: OrchestrationRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewCard("REQUEST", symbol: "text.bubble") {
                    Text(run.request.isEmpty ? "No request was recorded." : run.request)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(8)
                }

                overviewCard("SWARM STATUS", symbol: "circle.hexagongrid.fill") {
                    VStack(alignment: .leading, spacing: 6) {
                        metricRow("State", run.state.replacingOccurrences(of: "_", with: " ").capitalized)
                        metricRow("Workers", "\(swarmCompletedCount(run)) of \(swarmWorkerCount(run)) completed")
                        metricRow("Duration", runDuration(run))
                        if let calls = swarmModelCalls(run) {
                            metricRow("Model calls", calls.formatted())
                        }
                        if let tokens = swarmTotalTokens(run) {
                            metricRow("Total tokens", tokens.formatted())
                        }
                    }
                }

                overviewCard("WORKERS", symbol: "person.fill") {
                    if usesLiveSwarmWorkers(run) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.agentActivities.filter { $0.depth == 1 }) { activity in
                                liveSwarmWorkerRow(activity)
                            }
                        }
                    } else if !agentTreeAttempts(run).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(agentTreeAttempts(run)) { attempt in
                                swarmAttemptRow(attempt)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(run.state == "running"
                                ? "No workers delegated yet"
                                : "This run did not delegate any workers")
                                .font(.locus(size: 9, weight: .semibold))
                            Text("The primary agent can finish a Solo Swarm request itself when parallel investigation would not help.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier("runs.soloSwarm.noWorkers")
                    }
                }

                if swarmHasUsageBreakdown(run) {
                    overviewCard("USAGE", symbol: "gauge") {
                        VStack(alignment: .leading, spacing: 6) {
                            metricRow(
                                "Primary agent",
                                "\(swarmRootTokens(run).formatted()) tokens"
                            )
                            metricRow(
                                "Read-only workers",
                                "\(swarmWorkerTokens(run).formatted()) tokens"
                            )
                            if let calls = run.usage?["worker_model_calls"]?.integer {
                                metricRow("Worker model calls", calls.formatted())
                            }
                        }
                    }
                }

                technicalDetails(run)
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.soloSwarm.overview")
    }

    private func soloOverview(_ run: OrchestrationRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overviewCard("REQUEST", symbol: "text.bubble") {
                    Text(run.request.isEmpty ? "No request was recorded." : run.request)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(8)
                }
                overviewCard("RESULT", symbol: "checkmark.seal") {
                    VStack(alignment: .leading, spacing: 6) {
                        metricRow("State", run.state.replacingOccurrences(of: "_", with: " ").capitalized)
                        metricRow("Duration", runDuration(run))
                        if let calls = run.usage?["model_calls"]?.integer {
                            metricRow("Model calls", calls.formatted())
                        }
                        if let prompt = run.usage?["prompt_tokens"]?.integer,
                           let completion = run.usage?["completion_tokens"]?.integer {
                            metricRow("Tokens", (prompt + completion).formatted())
                        }
                    }
                }
                technicalDetails(run)
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.solo.overview")
    }

    private func technicalDetails(_ run: OrchestrationRun) -> some View {
        DisclosureGroup("Technical details") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Run ID · \(run.id)")
                Text("Saved events · \(run.lastSequence)")
                if let checkpoint = run.checkpoint {
                    Text("Checkpoint · \(checkpoint.kind.replacingOccurrences(of: "_", with: " "))")
                }
            }
            .font(.locus(size: 7, design: .monospaced))
            .foregroundStyle(LocusTheme.muted)
            .padding(.top, 6)
        }
        .font(.locus(size: 8, weight: .semibold))
    }

    private func usesLiveSwarmWorkers(_ run: OrchestrationRun) -> Bool {
        run.id == model.orchestrationRunID
            && model.isBusy
            && model.agentActivities.contains { $0.depth == 1 }
    }

    private func liveSwarmWorkerRow(_ activity: AgentActivity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: activity.state == .completed
                    ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(activity.state == .completed
                        ? LocusTheme.success : LocusTheme.signalDeep)
                Text(activity.agentName)
                    .font(.locus(size: 9, weight: .semibold))
                Spacer()
                Text(activity.state.title)
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            Text(activity.goal)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineLimit(3)
            Text([activity.provider, activity.model,
                  activity.executionEngine.replacingOccurrences(of: "_", with: " ")]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
                .lineLimit(1)
            if !activity.output.isEmpty, activity.output != "Branch started" {
                Text(activity.output)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(LocusTheme.white.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func swarmAttemptRow(_ attempt: AgentJobAttempt) -> some View {
        let accessibleDetails = [
            attempt.output,
            attempt.evidence.isEmpty ? nil : "Evidence: \(attempt.evidence.joined(separator: ", "))",
            attempt.uncertainties.isEmpty ? nil : "Uncertainties: \(attempt.uncertainties.joined(separator: ", "))",
            "\(attempt.modelCalls) calls, \(attempt.promptTokens + attempt.completionTokens) tokens"
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: attempt.state == "completed"
                    ? "checkmark.circle.fill"
                    : attempt.state == "failed" ? "exclamationmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(attempt.state == "completed"
                        ? LocusTheme.success
                        : attempt.state == "failed" ? LocusTheme.coral : LocusTheme.signalDeep)
                Text(attempt.agentName ?? attempt.agentID ?? "Worker")
                    .font(.locus(size: 9, weight: .semibold))
                Spacer()
                Text(attempt.state.replacingOccurrences(of: "_", with: " "))
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            Text(attempt.goal)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineLimit(3)
            Text([attempt.provider, attempt.model,
                  attempt.resolvedExecutionEngine.replacingOccurrences(of: "_", with: " ")]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
                .lineLimit(1)
            if let output = attempt.output, !output.isEmpty {
                Text(output)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            if !attempt.evidence.isEmpty {
                Text("Evidence · \(attempt.evidence.joined(separator: ", "))")
                    .font(.locus(size: 7))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(4)
            }
            if !attempt.uncertainties.isEmpty {
                Text("Uncertainties · \(attempt.uncertainties.joined(separator: ", "))")
                    .font(.locus(size: 7))
                    .foregroundStyle(LocusTheme.warning)
                    .lineLimit(4)
            }
            Text("\(attempt.modelCalls) calls · \((attempt.promptTokens + attempt.completionTokens).formatted()) tokens")
                .font(.locus(size: 7, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
        }
        .padding(8)
        .background(LocusTheme.white.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityValue(accessibleDetails)
        .accessibilityIdentifier("runs.soloSwarm.worker.\(attempt.resolvedNodeID)")
    }

    private func swarmWorkerCount(_ run: OrchestrationRun) -> Int {
        if usesLiveSwarmWorkers(run) {
            return Set(model.agentActivities.filter { $0.depth == 1 }.map { $0.nodeID ?? $0.id }).count
        }
        return agentTreeAttempts(run).count
    }

    private func swarmCompletedCount(_ run: OrchestrationRun) -> Int {
        if usesLiveSwarmWorkers(run) {
            return model.agentActivities.filter { $0.depth == 1 && $0.state == .completed }.count
        }
        return agentTreeAttempts(run).filter { $0.state == "completed" }.count
    }

    private func swarmModelCalls(_ run: OrchestrationRun) -> Int? {
        if usesLiveSwarmWorkers(run), model.teamModelCalls > 0 { return model.teamModelCalls }
        return run.usage?["model_calls"]?.integer
    }

    private func swarmTotalTokens(_ run: OrchestrationRun) -> Int? {
        if usesLiveSwarmWorkers(run), model.teamMeteredTokens > 0 { return model.teamMeteredTokens }
        if let total = run.usage?["metered_tokens"]?.integer { return total }
        guard let prompt = run.usage?["prompt_tokens"]?.integer,
              let completion = run.usage?["completion_tokens"]?.integer else { return nil }
        return prompt + completion
    }

    private func swarmRootTokens(_ run: OrchestrationRun) -> Int {
        (run.usage?["root_prompt_tokens"]?.integer ?? 0)
            + (run.usage?["root_completion_tokens"]?.integer ?? 0)
    }

    private func swarmWorkerTokens(_ run: OrchestrationRun) -> Int {
        (run.usage?["worker_prompt_tokens"]?.integer ?? 0)
            + (run.usage?["worker_completion_tokens"]?.integer ?? 0)
    }

    private func swarmHasUsageBreakdown(_ run: OrchestrationRun) -> Bool {
        run.usage?["root_prompt_tokens"] != nil || run.usage?["worker_prompt_tokens"] != nil
    }

    private func activity(_ run: OrchestrationRun) -> some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter run activity", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("runs.filter")
                Toggle("Technical log", isOn: $showTechnicalLog)
                    .toggleStyle(.checkbox)
                    .font(.locus(size: 8, weight: .semibold))
                    .accessibilityIdentifier("runs.technicalLog")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 7)
            if showTechnicalLog {
                timeline(run, showsFilter: false)
            } else {
                ScrollView {
                    if activityGroups.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.locus(size: 20))
                                .foregroundStyle(LocusTheme.muted)
                            Text(filter.isEmpty ? "No activity recorded" : "No matching activity")
                                .font(.locus(size: 9, weight: .semibold))
                            Text(filter.isEmpty
                                ? "Events will appear here as this run progresses."
                                : "Try a different search term or open the technical log.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(activityGroups) { group in
                                Text(group.title.uppercased())
                                    .font(.locus(size: 7, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundStyle(LocusTheme.muted)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)
                                ForEach(group.events) { event in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: friendlyEventSymbol(event))
                                            .foregroundStyle(color(for: event.type))
                                            .frame(width: 14)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(friendlyEventTitle(event))
                                                .font(.locus(size: 9, weight: .semibold))
                                            Text(friendlyEventDetail(event))
                                                .font(.locus(size: 8))
                                                .foregroundStyle(LocusTheme.inkSoft)
                                                .lineLimit(6)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    Divider().padding(.leading, 34)
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.activity")
    }

    private func overviewCard<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.locus(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(LocusTheme.muted)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.white.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(LocusTheme.line) }
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(LocusTheme.muted)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.locus(size: 8))
    }

    private func agentTreeAttempts(_ run: OrchestrationRun) -> [AgentJobAttempt] {
        var latest: [String: AgentJobAttempt] = [:]
        for attempt in run.attempts ?? [] {
            let node = attempt.resolvedNodeID
            if latest[node] == nil || attempt.attempt > (latest[node]?.attempt ?? 0) {
                latest[node] = attempt
            }
        }
        return latest.values.sorted {
            if $0.resolvedDepth != $1.resolvedDepth {
                return $0.resolvedDepth < $1.resolvedDepth
            }
            let left = $0.startedAt ?? 0
            let right = $1.startedAt ?? 0
            return left == right ? $0.resolvedNodeID < $1.resolvedNodeID : left < right
        }
    }

    private func agentTreeRow(_ attempt: AgentJobAttempt, run: OrchestrationRun) -> some View {
        let presentation = model.teamRunPresentation(for: run.id, durable: run)
        let isCoding = model.isCodingAttempt(attempt, in: run)
        let branchError = attempt.result?["error"]?.string
        return HStack(alignment: .top, spacing: 7) {
            HStack(spacing: 3) {
                if attempt.resolvedDepth > 0 {
                    Rectangle()
                        .fill(LocusTheme.lineStrong)
                        .frame(width: 1, height: 20)
                    Image(systemName: "arrow.turn.down.right")
                        .font(.locus(size: 7))
                        .foregroundStyle(LocusTheme.muted)
                }
                Image(systemName: attempt.state == "completed"
                    ? "checkmark.circle.fill"
                    : attempt.state == "stopped" ? "stop.circle.fill"
                    : attempt.state == "failed" ? "exclamationmark.circle.fill"
                    : "circle.dotted")
                    .foregroundStyle(attempt.state == "completed"
                        ? LocusTheme.success
                        : ["failed", "stopped"].contains(attempt.state)
                            ? LocusTheme.coral : LocusTheme.signalDeep)
            }
            .frame(width: CGFloat(attempt.resolvedDepth * 14 + 17), alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(attempt.agentName ?? attempt.agentID ?? "Agent")
                        .font(.locus(size: 8, weight: .bold))
                    Text("· \(attempt.state.replacingOccurrences(of: "_", with: " "))")
                        .font(.locus(size: 7, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
                Text("\(attempt.provider ?? "Unknown provider") · \(attempt.model ?? "Unknown model") · \(attempt.resolvedExecutionEngine.replacingOccurrences(of: "_", with: " "))")
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(1)
                Text(attempt.goal)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineLimit(3)
                if let branchError, !branchError.isEmpty {
                    Text(branchError)
                        .font(.locus(size: 7))
                        .foregroundStyle(LocusTheme.coral)
                        .lineLimit(3)
                }
                if !attempt.evidence.isEmpty {
                    Text("Evidence · \(attempt.evidence.joined(separator: ", "))")
                        .font(.locus(size: 7))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(3)
                }
                Text("\(attempt.modelCalls) calls · \(attempt.promptTokens + attempt.completionTokens) tokens · \(attempt.elapsedMilliseconds) ms")
                    .font(.locus(size: 7, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            Spacer(minLength: 0)
            if !run.isSoloSwarm,
               presentation.isActivelyOwned, attempt.state == "running", !isCoding {
                Button("Stop") { model.stopOrchestrationBranch(attempt, in: run) }
                    .buttonStyle(.locus())
                    .font(.locus(size: 7, weight: .semibold))
                    .foregroundStyle(LocusTheme.coral)
                    .accessibilityIdentifier("runs.agentTree.stop.\(attempt.resolvedNodeID)")
            } else if !run.isSoloSwarm,
                      presentation.canRecover,
                      ["failed", "stopped", "paused"].contains(attempt.state),
                      !isCoding {
                Button("Retry") { model.retryOrchestrationBranch(attempt, in: run) }
                    .buttonStyle(.locus())
                    .font(.locus(size: 7, weight: .semibold))
                    .accessibilityIdentifier("runs.agentTree.retry.\(attempt.resolvedNodeID)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.agentTree.node.\(attempt.resolvedNodeID)")
    }

    private func timeline(_ run: OrchestrationRun, showsFilter: Bool = true) -> some View {
        VStack(spacing: 0) {
            if showsFilter {
                TextField("Filter agent, event, state, or attempt", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("runs.filter")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 7)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredEvents) { event in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(event.sequence)")
                                .font(.locus(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                                .frame(width: 30, alignment: .trailing)
                            Circle().fill(color(for: event.type)).frame(width: 6, height: 6).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.type.replacingOccurrences(of: "_", with: " "))
                                    .font(.locus(size: 8, weight: .bold))
                                Text(event.title)
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.inkSoft)
                                    .lineLimit(4)
                                if let detail = event.detail, detail != event.title {
                                    Text(detail)
                                        .font(.locus(size: 7, design: .monospaced))
                                        .foregroundStyle(LocusTheme.muted)
                                        .lineLimit(12)
                                        .textSelection(.enabled)
                                }
                                if let job = event.jobID {
                                    Text("job \(job)\(event.attemptID.map { " · \($0)" } ?? "")")
                                        .font(.locus(size: 7, design: .monospaced))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        Divider().padding(.leading, 54)
                    }
                }
            }
        }
    }

    private func dependencyView(_ run: OrchestrationRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(run.attempts ?? []) { attempt in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: attempt.state == "completed" ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(attempt.state == "completed" ? LocusTheme.success : LocusTheme.signalDeep)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(attempt.agentName ?? attempt.agentID ?? "Agent")
                                    .font(.locus(size: 9, weight: .bold))
                                Text("attempt \(attempt.attempt)")
                                    .font(.locus(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                                Spacer()
                                if model.teamRunPresentation(
                                    for: run.id, durable: run
                                ).canRecover,
                                   attempt.state != "running"
                                    && !model.isCodingAttempt(attempt, in: run) {
                                    Menu {
                                        Button("Retry with Same Agent") {
                                            model.retryOrchestrationJob(attempt, in: run)
                                        }
                                        let candidates = model.reassignmentCandidates(
                                            for: attempt, in: run
                                        )
                                        if !candidates.isEmpty {
                                            Menu("Reassign") {
                                                ForEach(candidates) { profile in
                                                    Button(profile.name) {
                                                        model.reassignOrchestrationJob(
                                                            attempt, in: run, to: profile
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "arrow.clockwise.circle")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                }
                            }
                            Text(attempt.goal).font(.locus(size: 8)).lineLimit(4)
                            Text("\(attempt.role ?? "specialist") · \(attempt.state)")
                                .font(.locus(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                            if let provider = attempt.provider, !provider.isEmpty {
                                Text("\(provider) · \(attempt.model ?? "")")
                                    .font(.locus(size: 7, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                            if let output = attempt.output, !output.isEmpty {
                                Text(output)
                                    .font(.locus(size: 8))
                                    .lineLimit(12)
                                    .textSelection(.enabled)
                            }
                            if let reasoning = attempt.reasoningText,
                               !reasoning.isEmpty,
                               model.thinkingVisibility != .hidden
                            {
                                DisclosureGroup("Reasoning") {
                                    Text(reasoning)
                                        .font(.locus(size: 8))
                                        .foregroundStyle(LocusTheme.inkSoft)
                                        .textSelection(.enabled)
                                }
                                .font(.locus(size: 8, weight: .semibold))
                            }
                            if !attempt.evidence.isEmpty {
                                Text("Evidence · \(attempt.evidence.joined(separator: ", "))")
                                    .font(.locus(size: 7))
                                    .foregroundStyle(LocusTheme.muted)
                                    .lineLimit(4)
                            }
                            Text("\(attempt.elapsedMilliseconds) ms · \(attempt.promptTokens + attempt.completionTokens) tokens")
                                .font(.locus(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }
                    .padding(9)
                    .background(LocusTheme.white.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(12)
        }
    }

    private func dispatchEditor(_ plan: DispatchPlan) -> some View {
        let validationErrors = model.dispatchPlanErrors(draftPlan ?? plan)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Review dispatch plan", systemImage: "checkmark.shield")
                    .font(.locus(size: 11, weight: .bold))
                Text("Edit goals, assignments, and dependencies. Coding jobs must form an explicit order; Locus runs them one at a time in the shared checkout.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    TextField("Plan summary", text: planBinding(\.summary))
                    if draftPlan?.budget != nil {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("RUN BUDGET")
                                .font(.locus(size: 7, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(LocusTheme.muted)
                            Stepper(
                                "Jobs · \(draftPlan?.budget?.maxJobs ?? 0)",
                                value: budgetBinding(\.maxJobs), in: 1...16
                            )
                            Stepper(
                                "Rounds · \(draftPlan?.budget?.maxRounds ?? 0)",
                                value: budgetBinding(\.maxRounds), in: 1...8
                            )
                            Picker("Call budget", selection: callBudgetModeBinding) {
                                ForEach(OrchestrationBudget.CallBudgetMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            if draftPlan?.budget?.callBudgetMode == .fixed {
                                Stepper(
                                    "Model calls · \(draftPlan?.budget?.maxModelCalls ?? 0)",
                                    value: budgetBinding(\.maxModelCalls), in: 1...100
                                )
                            }
                            Stepper(
                                "Concurrent calls · \(draftPlan?.budget?.maxConcurrentCalls ?? 0)",
                                value: budgetBinding(\.maxConcurrentCalls), in: 1...8
                            )
                            Stepper(
                                "Hosted tokens · \(draftPlan?.budget?.maxMeteredTokens ?? 0)",
                                value: budgetBinding(\.maxMeteredTokens),
                                in: 1_000...2_000_000,
                                step: 50_000
                            )
                            TextField(
                                "Maximum estimated cost (0 disables)",
                                value: maximumCostBinding,
                                format: .number.precision(.fractionLength(0...4))
                            )
                        }
                        .font(.locus(size: 8))
                        .padding(9)
                        .background(LocusTheme.white.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    ForEach(Array(plan.jobs.enumerated()), id: \.element.id) { index, job in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(job.kind == "writer" ? "Coding" : job.kind.capitalized)
                                    .font(.locus(size: 8, weight: .bold))
                                Spacer()
                                Button(role: .destructive) {
                                    draftPlan?.jobs.remove(at: index)
                                } label: { Image(systemName: "trash") }
                                    .buttonStyle(.locus())
                            }
                            TextField("Goal", text: jobBinding(index, \.goal), axis: .vertical)
                            Picker("Agent", selection: jobBinding(index, \.agentID)) {
                                ForEach(eligibleProfiles(for: job)) { profile in
                                    Text(profile.name).tag(profile.id.uuidString)
                                }
                            }
                            TextField("Dependencies", text: dependencyBinding(index), prompt: Text("job ids, comma separated"))
                        }
                        .padding(9)
                        .background(LocusTheme.white.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    HStack {
                        Button {
                            addJob(kind: "specialist")
                        } label: { Label("Add Specialist Job", systemImage: "plus") }
                            .buttonStyle(.locus())
                        Button {
                            addJob(kind: "writer")
                        } label: { Label("Add Coding Job", systemImage: "hammer") }
                            .buttonStyle(.locus())
                            .accessibilityIdentifier("runs.addCodingJob")
                    }
                }
                .padding(12)
            }
            HStack {
                if let error = validationErrors.first {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.coral)
                        .lineLimit(2)
                }
                Button("Cancel") { model.decideDispatch("cancel") }
                Button("Re-dispatch") { model.decideDispatch("redispatch") }
                Spacer()
                Button("Run Plan") { model.decideDispatch("run", editedPlan: draftPlan) }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!validationErrors.isEmpty)
            }
            .padding(12)
            .overlay(alignment: .top) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
        }
    }

    private func eligibleProfiles(for job: DispatchJob) -> [AgentProfile] {
        guard let team = model.selectedAgentTeam else { return [] }
        return model.agentProfiles.filter { profile in
            guard team.memberIDs.contains(profile.id) else { return false }
            switch job.kind {
            case "writer":
                return profile.accessCeiling.canWrite
            case "reviewer":
                return !profile.accessCeiling.canWrite && profile.role == .reviewer
            default:
                return !profile.accessCeiling.canWrite
            }
        }
    }

    private func addJob(kind: String) {
        guard let plan = draftPlan else { return }
        let template = DispatchJob(
            id: "job-\(plan.jobs.count + 1)",
            agentID: "",
            goal: "",
            dependencies: [],
            kind: kind
        )
        guard let profile = eligibleProfiles(for: template).first else { return }
        var job = template
        job.agentID = profile.id.uuidString
        if kind == "writer",
           let priorWriter = plan.jobs.last(where: { $0.kind == "writer" })
        {
            job.dependencies = [priorWriter.id]
        }
        draftPlan?.jobs.append(job)
    }

    private var filteredEvents: [OrchestrationEvent] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let durableEvents = model.orchestrationEvents.filter { !$0.isTransientStream }
        guard !query.isEmpty else { return durableEvents }
        return durableEvents.filter { event in
            [
                event.type, event.title, event.jobID, event.attemptID,
                event.text("agent_name"), event.text("agent_id"),
                event.text("state"), event.text("provider"), event.text("model"),
                event.text("reason"),
            ]
                .compactMap { $0 }.joined(separator: " ").lowercased().contains(query)
        }
    }

    private func planBinding(_ keyPath: WritableKeyPath<DispatchPlan, String>) -> Binding<String> {
        Binding(
            get: { draftPlan?[keyPath: keyPath] ?? "" },
            set: { draftPlan?[keyPath: keyPath] = $0 }
        )
    }

    private func jobBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<DispatchJob, String>
    ) -> Binding<String> {
        Binding(
            get: {
                guard let plan = draftPlan, plan.jobs.indices.contains(index) else { return "" }
                return plan.jobs[index][keyPath: keyPath]
            },
            set: { value in
                guard var plan = draftPlan, plan.jobs.indices.contains(index) else { return }
                plan.jobs[index][keyPath: keyPath] = value
                draftPlan = plan
            }
        )
    }

    private func dependencyBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let plan = draftPlan, plan.jobs.indices.contains(index) else { return "" }
                return plan.jobs[index].dependencies.joined(separator: ", ")
            },
            set: { value in
                guard var plan = draftPlan, plan.jobs.indices.contains(index) else { return }
                plan.jobs[index].dependencies = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                draftPlan = plan
            }
        )
    }

    private func budgetBinding(
        _ keyPath: WritableKeyPath<OrchestrationBudget, Int>
    ) -> Binding<Int> {
        Binding(
            get: { draftPlan?.budget?[keyPath: keyPath] ?? 1 },
            set: { value in
                guard var plan = draftPlan, var budget = plan.budget else { return }
                budget[keyPath: keyPath] = value
                budget.clamp()
                plan.budget = budget
                draftPlan = plan
            }
        )
    }

    private var maximumCostBinding: Binding<Double> {
        Binding(
            get: { draftPlan?.maximumEstimatedCost ?? 0 },
            set: { value in
                guard var plan = draftPlan else { return }
                plan.maximumEstimatedCost = min(max(value, 0), 100_000)
                draftPlan = plan
            }
        )
    }

    private var callBudgetModeBinding: Binding<OrchestrationBudget.CallBudgetMode> {
        Binding(
            get: { draftPlan?.budget?.callBudgetMode ?? .fixed },
            set: { value in
                guard var plan = draftPlan, var budget = plan.budget else { return }
                budget.callBudgetMode = value
                if value == .automatic { budget.maxModelCalls = 100 }
                plan.budget = budget
                draftPlan = plan
            }
        )
    }

    private struct RunPhase {
        let title: String
        let done: Bool
        let active: Bool
    }

    private struct ActivityGroup: Identifiable {
        let title: String
        let events: [OrchestrationEvent]
        var id: String { title }
    }

    private var activityGroups: [ActivityGroup] {
        let visible = filteredEvents.filter(isUserFacingEvent)
        let order = ["Solo Swarm", "Planning", "Approval", "Specialists", "Coding jobs", "Review", "Complete"]
        let grouped = Dictionary(grouping: visible, by: activityPhase)
        return order.compactMap { title in
            guard let events = grouped[title], !events.isEmpty else { return nil }
            return ActivityGroup(title: title, events: events)
        }
    }

    private func runPhases(_ run: OrchestrationRun) -> [RunPhase] {
        let state = model.teamRunPresentation(for: run.id, durable: run).state
        let current: Int = switch state {
        case .queued, .dispatching: 0
        case .waitingDispatchApproval: 1
        case .running, .waitingPermission, .waitingComputer:
            (run.attempts ?? []).contains { model.isCodingAttempt($0, in: run) } ? 3 : 2
        case .reviewing: 4
        case .completed: 5
        case .paused, .failed, .interrupted, .cancelled, .discarded:
            phaseIndex(for: run)
        }
        return ["Planning", "Plan approval", "Specialists", "Coding jobs", "Review", "Complete"]
            .enumerated().map { index, title in
                RunPhase(
                    title: title,
                    done: state == .completed || index < current,
                    active: state != .completed && index == current
                )
            }
    }

    private func phaseIndex(for run: OrchestrationRun) -> Int {
        let kind = run.checkpoint?.kind.lowercased() ?? ""
        if kind.contains("synthesis") { return 5 }
        if kind.contains("review") || kind.contains("revision") { return 4 }
        if kind.contains("writer") { return 3 }
        if kind.contains("dispatch") { return 2 }
        return run.plan == nil ? 0 : 2
    }

    private func runStateTitle(_ run: OrchestrationRun) -> String {
        let state = model.teamRunPresentation(for: run.id, durable: run).state.title
        let total = run.jobCount ?? 0
        guard total > 0 else { return state }
        let unit = run.isSoloSwarm ? "workers" : "jobs"
        return "\(state) · \(run.completedJobCount ?? 0) of \(total) \(unit)"
    }

    private func runDuration(_ run: OrchestrationRun) -> String {
        let end = run.completedAt ?? run.updatedAt
        let seconds = max(Int(end - run.createdAt), 0)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private func friendlyJobKind(_ kind: String) -> String {
        switch kind {
        case "writer": "Coding job"
        case "reviewer": "Review"
        default: "Specialist"
        }
    }

    private func isUserFacingEvent(_ event: OrchestrationEvent) -> Bool {
        event.type == "error"
            || ["run_started", "agent_spawned", "agent_branch_stopped",
                "swarm_telemetry", "turn_done", "note"].contains(event.type)
            || event.type == "permission_request"
            || event.type == "dispatch_plan_ready"
            || event.type == "dispatcher_plan_rejected"
            || event.type == "task_changes"
            || event.type.hasPrefix("agent_job_")
            || event.type.hasPrefix("orchestration_")
    }

    private func activityPhase(_ event: OrchestrationEvent) -> String {
        let isSoloSwarm = model.selectedOrchestrationRun?.isSoloSwarm == true
        if isSoloSwarm,
           ["run_started", "agent_spawned", "agent_branch_stopped",
            "swarm_telemetry", "turn_done", "note"].contains(event.type)
                || event.type.hasPrefix("agent_job_") {
            return "Solo Swarm"
        }
        switch event.type {
        case "dispatch_plan_ready", "dispatch_plan", "dispatch_decision":
            return "Approval"
        case "dispatcher_plan_rejected":
            return "Planning"
        case "task_changes", "orchestration_completed":
            return "Complete"
        case "permission_request", "agent_job_continuing", "agent_job_incomplete":
            return "Coding jobs"
        case "agent_job_started", "agent_job_completed":
            if event.text("writer_position") != nil || event.text("writer_job_id") != nil {
                return "Coding jobs"
            }
            if event.text("role")?.lowercased() == "reviewer" {
                return "Review"
            }
            return "Specialists"
        case "orchestration_state":
            return event.text("state") == "reviewing" ? "Review" : "Planning"
        case "error", "orchestration_paused":
            return model.orchestrationState == .reviewing ? "Review" : "Coding jobs"
        default:
            return "Planning"
        }
    }

    private func friendlyEventTitle(_ event: OrchestrationEvent) -> String {
        let isSoloSwarm = model.selectedOrchestrationRun?.isSoloSwarm == true
        return switch event.type {
        case "run_started": isSoloSwarm ? "Solo Swarm run started" : "Run started"
        case "agent_spawned": isSoloSwarm ? "Read-only worker started" : "Agent started"
        case "agent_branch_stopped": isSoloSwarm ? "Read-only worker stopped" : "Agent branch stopped"
        case "swarm_telemetry": "Worker batch completed"
        case "turn_done": isSoloSwarm ? "Solo Swarm run completed" : "Run completed"
        case "note": "Run note"
        case "orchestration_started": "Team run started"
        case "orchestration_state": event.text("state") == "reviewing" ? "Review started" : "Team progressed"
        case "dispatch_plan_ready": "Plan ready for your approval"
        case "dispatcher_plan_rejected": "Correcting dispatcher plan"
        case "agent_job_started": event.text("writer_position").map {
            "Coding job \($0) started"
        } ?? "Specialist started"
        case "agent_job_continuing": "Coding job is continuing"
        case "agent_job_incomplete": "Coding job needs more capacity"
        case "agent_job_completed": "Job completed"
        case "permission_request": "Waiting for permission"
        case "orchestration_paused": "Run paused safely"
        case "orchestration_completed": event.text("state") == "completed"
            ? "Team run completed" : "Team run stopped"
        case "task_changes": "Workspace changes are ready"
        case "error": "Run error"
        default: event.title
        }
    }

    private func friendlyEventDetail(_ event: OrchestrationEvent) -> String {
        let agent = event.text("agent_name")
        let model = event.text("model")
        let route = [agent, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return event.text("message")?.nilIfEmpty
            ?? event.text("text")?.nilIfEmpty
            ?? event.text("goal")?.nilIfEmpty
            ?? event.text("reason")?.nilIfEmpty
            ?? event.detail?.nilIfEmpty
            ?? route.nilIfEmpty
            ?? event.title
    }

    private func friendlyEventSymbol(_ event: OrchestrationEvent) -> String {
        if event.type.contains("completed") { return "checkmark.circle.fill" }
        if event.type.contains("incomplete") || event.type.contains("paused") { return "pause.circle.fill" }
        if event.type.contains("error") || event.type.contains("rejected") { return "exclamationmark.circle.fill" }
        if event.type.contains("permission") { return "lock.circle.fill" }
        if event.type.contains("plan") { return "list.bullet.clipboard.fill" }
        return "circle.inset.filled"
    }

    private func color(for type: String) -> Color {
        if type.contains("error") || type.contains("failed") { return LocusTheme.coral }
        if type.contains("completed") { return LocusTheme.success }
        if type.contains("waiting") || type.contains("permission") { return LocusTheme.warning }
        return LocusTheme.signalDeep
    }
}
