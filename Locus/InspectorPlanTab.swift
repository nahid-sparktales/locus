import SwiftUI

enum PlanPanelPhase: String, Equatable {
    case idle
    case working
    case planning
    case executing
    case waitingForPermission
    case readyForApproval
    case stopped
    case completed
    case saved
}

struct PlanPanelPresentation: Equatable {
    let phase: PlanPanelPhase
    let stoppedOutcome: TurnCompletion.Outcome?

    static func resolve(
        hasPendingPermission: Bool,
        planApprovalPending: Bool,
        isBusy: Bool,
        dispatchedMode: WorkMode?,
        todos: [TodoItem],
        latestCompletion: TurnCompletion?
    ) -> PlanPanelPresentation {
        if hasPendingPermission {
            return PlanPanelPresentation(phase: .waitingForPermission, stoppedOutcome: nil)
        }
        if planApprovalPending {
            return PlanPanelPresentation(phase: .readyForApproval, stoppedOutcome: nil)
        }
        if isBusy {
            switch dispatchedMode {
            case .plan:
                return PlanPanelPresentation(phase: .planning, stoppedOutcome: nil)
            case .work where !todos.isEmpty:
                // Plan execution rides Work since GSD retired; any busy turn
                // holding a todo list is following it, which is what this
                // phase has always meant.
                return PlanPanelPresentation(phase: .executing, stoppedOutcome: nil)
            default:
                return PlanPanelPresentation(phase: .working, stoppedOutcome: nil)
            }
        }
        if !todos.isEmpty,
           let completion = latestCompletion,
           completion.outcome != .complete,
           completion.mode == .work || completion.mode == .plan || completion.mode == .grill
        {
            return PlanPanelPresentation(
                phase: .stopped,
                stoppedOutcome: completion.outcome
            )
        }
        if !todos.isEmpty, todos.allSatisfy({ $0.status == .completed }) {
            return PlanPanelPresentation(phase: .completed, stoppedOutcome: nil)
        }
        if !todos.isEmpty {
            return PlanPanelPresentation(phase: .saved, stoppedOutcome: nil)
        }
        return PlanPanelPresentation(phase: .idle, stoppedOutcome: nil)
    }
}

struct PlanWorkspaceBriefing: Equatable {
    let folderName: String
    let folderPath: String
    let repositoryDetail: String
    let modelName: String
    let modelDetail: String
    let activityTitle: String
    let activityDetail: String

    static func resolve(
        workspacePath: String,
        modelName: String,
        providerName: String,
        modelStatus: String,
        contextWindowTokens: Int?,
        isGitRepository: Bool,
        branch: String?,
        changedFileCount: Int,
        gitChangeSummary: String,
        ahead: Int,
        behind: Int,
        indexedFileCount: Int,
        messageCount: Int
    ) -> PlanWorkspaceBriefing {
        let folderURL = URL(fileURLWithPath: workspacePath)
        let resolvedFolderName = folderURL.lastPathComponent.nilIfEmpty ?? workspacePath

        var repositoryParts: [String] = []
        if isGitRepository {
            repositoryParts.append(branch?.nilIfEmpty ?? "Detached HEAD")
            repositoryParts.append(
                changedFileCount == 0
                    ? "Clean"
                    : "\(changedFileCount) changed \(changedFileCount == 1 ? "file" : "files")"
            )
            if ahead > 0 { repositoryParts.append("↑\(ahead)") }
            if behind > 0 { repositoryParts.append("↓\(behind)") }
        } else {
            repositoryParts.append("Git not detected")
        }

        var modelParts = [providerName, modelStatus]
        if let contextWindowTokens, contextWindowTokens > 0 {
            modelParts.append("\(contextWindowTokens.formatted()) token window")
        }

        let activityTitle: String
        let activityLead: String
        if changedFileCount > 0 {
            activityTitle = "Workspace has unreviewed changes"
            activityLead = gitChangeSummary
        } else if isGitRepository {
            activityTitle = "Workspace is clean"
            activityLead = "No uncommitted files"
        } else {
            activityTitle = "Workspace indexed"
            activityLead = "Ready for inspection"
        }
        let indexedLabel = "\(indexedFileCount) indexed \(indexedFileCount == 1 ? "file" : "files")"
        let messageLabel = "\(messageCount) \(messageCount == 1 ? "message" : "messages")"

        return PlanWorkspaceBriefing(
            folderName: resolvedFolderName,
            folderPath: workspacePath,
            repositoryDetail: repositoryParts.joined(separator: " · "),
            modelName: modelName,
            modelDetail: modelParts.joined(separator: " · "),
            activityTitle: activityTitle,
            activityDetail: [activityLead, indexedLabel, messageLabel].joined(separator: " · ")
        )
    }
}

extension AppModel {
    var planPanelPresentation: PlanPanelPresentation {
        PlanPanelPresentation.resolve(
            hasPendingPermission: hasPendingPermission,
            planApprovalPending: planApprovalPending,
            isBusy: isBusy,
            dispatchedMode: turnDispatchedMode,
            todos: todos,
            latestCompletion: latestTurnCompletion
        )
    }

    var planPanelActiveToolSummary: String? {
        guard let tool = blocks.reversed().compactMap(\.tool).first(where: {
            $0.status == .running || $0.status == .awaitingPermission
        }) else { return nil }
        let summary = tool.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return summary }
        return tool.detail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private var latestTurnCompletion: TurnCompletion? {
        blocks.reversed().compactMap(\.completion).first
    }
}

struct InspectorPlanTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SessionOverviewView(session: model.sessionOverview)
            .environmentObject(model)
    }
}

/// A detailed view of the runtime's context budget, separate from Overview.
struct InspectorContextTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Chat context")
                    .font(.locus(size: 16, weight: .semibold))
                ContextWindowInfoCard()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("inspector.context")
    }
}

struct ContextWindowInfoCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedCategories: Set<String> = []

    private var usage: ContextUsagePresentation {
        .init(breakdown: model.sessionInfo?.contextBreakdown,
              conversationTokens: model.sessionInfo?.approxTokens ?? 0,
              streamingTokens: model.estimatedStreamingTokens,
              window: model.contextWindowTokens, usable: model.contextUsableTokens)
    }

    var body: some View {
        let usage = usage
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Context window")
                    .font(.locus(size: 12, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("≈\(compactTokens(usage.used))")
                        .font(.locus(size: 20, weight: .semibold))
                    Text(usage.window.map { "/ \(compactTokens($0))" } ?? "/ Unknown")
                        .font(.locus(size: 13))
                        .foregroundStyle(LocusTheme.muted)
                    Spacer(minLength: 0)
                    if let fraction = usage.fraction {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(.locus(size: 12, weight: .semibold))
                            .foregroundStyle(fraction > 0.8 ? LocusTheme.warning : LocusTheme.ink)
                    }
                }
                .monospacedDigit()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("context.usage")
                segmentedBar(usage)
            }

            VStack(spacing: 3) {
                ForEach(usage.categories) { category in
                    categoryRow(category, window: usage.window)
                }
                Divider().padding(.vertical, 5)
                if let reserved = usage.reserved {
                    valueRow(id: "buffer", title: usage.hasBreakdown ? "Compaction buffer" : "Reserved capacity",
                             tokens: reserved, window: usage.window)
                }
                valueRow(id: "free", title: "Free space", tokens: usage.free, window: usage.window)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("context.breakdown")

            if !usage.deferred.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Available on demand")
                        .font(.locus(size: 11, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                    ForEach(usage.deferred) { category in
                        categoryRow(category, window: nil)
                    }
                    Text("Deferred tools do not use context until loaded.")
                        .font(.locus(size: 11))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(usage.note)
                .font(.locus(size: 11))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.contextWindowProvenance.label)
                .font(.locus(size: 10))
                .foregroundStyle(LocusTheme.muted)
        }
        .padding(12)
        .locusCard(radius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan.contextWindow.details")
        .onChange(of: model.currentSessionID) { expandedCategories = [] }
    }

    private func categoryRow(_ category: ContextUsageCategory, window: Int?) -> some View {
        let isExpanded = expandedCategories.contains(category.id)
        return VStack(alignment: .leading, spacing: 0) {
            Group {
                if category.children.isEmpty {
                    categoryLabel(category, isExpanded: false, window: window)
                } else {
                    Button {
                        if isExpanded { expandedCategories.remove(category.id) }
                        else { expandedCategories.insert(category.id) }
                    } label: {
                        categoryLabel(category, isExpanded: isExpanded, window: window)
                    }
                    .buttonStyle(.locus())
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(category.label + ", approximately \(category.tokens.formatted()) tokens")
            .accessibilityValue(category.children.isEmpty ? "" : isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("context.category.\(category.id)")

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(category.children) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.label)
                                .font(.locus(size: 11))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Text(compactTokens(max(item.tokens, 0)))
                                .font(.locus(size: 11, design: .monospaced))
                        }
                        .foregroundStyle(LocusTheme.muted)
                    }
                }
                .padding(.leading, 24)
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("context.details.\(category.id)")
            }
        }
    }

    private func categoryLabel(_ category: ContextUsageCategory, isExpanded: Bool, window: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.locus(size: 8, weight: .semibold))
                .frame(width: 8)
                .opacity(category.children.isEmpty ? 0 : 1)
            swatch(category.id)
            Text(category.label)
                .font(.locus(size: 12))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            tokenColumns(category.tokens, window: window)
        }
        .foregroundStyle(LocusTheme.ink)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func valueRow(id: String, title: String, tokens: Int?, window: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear.frame(width: 8, height: 8)
            swatch(id)
            Text(title).font(.locus(size: 12))
            Spacer(minLength: 2)
            tokenColumns(tokens, window: window)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("context.\(id)")
    }

    private func tokenColumns(_ tokens: Int?, window: Int?) -> some View {
        HStack(spacing: 7) {
            Text(tokens.map(compactTokens) ?? "Unknown")
                .foregroundStyle(LocusTheme.muted)
            Text(percentage(tokens, window: window))
                .foregroundStyle(LocusTheme.ink)
                .frame(width: 43, alignment: .trailing)
        }
        .font(.locus(size: 11, design: .monospaced))
        .fixedSize()
    }

    private func percentage(_ tokens: Int?, window: Int?) -> String {
        guard let tokens, let window, window > 0 else { return "—" }
        return (Double(tokens) / Double(window)).formatted(.percent.precision(.fractionLength(1)))
    }

    private func compactTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        return tokens.formatted()
    }

    private func swatch(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(color(id)).frame(width: 8, height: 8)
    }

    private func color(_ id: String) -> Color {
        switch id {
        case "messages", "provider_context": .blue
        case "system_tools": .orange
        case "mcp_tools": .green
        case "skills": .yellow
        case "system_prompt": .purple
        case "agent_instructions": .pink
        case "workspace_instructions": .teal
        case "memory": .indigo
        case "free": LocusTheme.line
        default: LocusTheme.muted.opacity(0.5)
        }
    }

    private func segmentedBar(_ usage: ContextUsagePresentation) -> some View {
        let items = usage.categories + [
            .init(id: "buffer", label: "Reserved", tokens: usage.reserved ?? 0),
            .init(id: "free", label: "Free", tokens: usage.free ?? 0),
        ]
        let total = max(usage.window ?? 0, items.reduce(0) { $0 + $1.tokens }, 1)
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(items.filter { $0.tokens > 0 }) { item in
                    color(item.id)
                        .frame(width: geometry.size.width * Double(item.tokens) / Double(total))
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(LocusTheme.paper).frame(width: 1)
                        }
                }
            }
            .background(LocusTheme.line)
            .clipShape(Capsule())
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}
