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
            case .build where !todos.isEmpty:
                return PlanPanelPresentation(phase: .executing, stoppedOutcome: nil)
            default:
                return PlanPanelPresentation(phase: .working, stoppedOutcome: nil)
            }
        }
        if !todos.isEmpty,
           let completion = latestCompletion,
           completion.outcome != .complete,
           completion.mode == .work || completion.mode == .plan || completion.mode == .build
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

/// The established Locus context card. It stays pinned beneath the dynamic
/// session overview so context details remain available without changing the
/// visual language used by the rest of the inspector.
struct ContextWindowInfoCard: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("Locus.contextWindowInfo.collapsed") private var isCollapsed = false

    private var fraction: Double? { model.contextWindowUsageFraction }

    private var accent: Color {
        (fraction ?? 0) > 0.8 ? LocusTheme.warning : LocusTheme.signalDeep
    }

    private var remainingTokens: Int? {
        guard let usable = model.contextUsableTokens else { return nil }
        return max(usable - model.contextUsedTokens, 0)
    }

    private var isAssumed: Bool {
        !model.contextWindowProvenance.isMeasured && fraction != nil
    }

    private var usageLabel: String {
        guard let fraction else { return "WINDOW UNKNOWN" }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return (isAssumed ? "≈ " : "") + percent + " USED"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isCollapsed.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "circle.dotted.circle")
                    Text("Context window")
                    Spacer()
                    Text(usageLabel)
                        .font(.locus(size: 7, weight: .bold, design: .monospaced))
                        .tracking(0.45)
                        .foregroundStyle(accent)
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.locus(size: 7, weight: .bold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .font(.locus(size: 9, weight: .bold))
            .foregroundStyle(LocusTheme.inkSoft)
            .accessibilityLabel(isCollapsed ? "Expand context window" : "Collapse context window")
            .accessibilityIdentifier("plan.contextWindow.toggle")

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 10) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(LocusTheme.line)
                            if let fraction {
                                Capsule()
                                    .fill(accent)
                                    .frame(width: proxy.size.width * fraction)
                            }
                        }
                    }
                    .frame(height: 5)

                    VStack(spacing: 7) {
                        statRow("This conversation", "~\(model.contextUsedTokens.formatted()) tokens")
                        statRow(
                            "Remaining",
                            remainingTokens.map { "~\($0.formatted()) tokens" } ?? "Unknown"
                        )
                        statRow(
                            "Model window",
                            model.contextWindowTokens.map { "\($0.formatted()) tokens" } ?? "Unknown"
                        )
                        statRow("Source", model.contextWindowProvenance.label)
                        if let usable = model.contextUsableTokens,
                           let window = model.contextWindowTokens,
                           usable < window {
                            statRow("Usable for chat", "\(usable.formatted()) tokens")
                        }
                        statRow(
                            "Context pack next send",
                            "\(model.includedContextTokens.formatted()) · \(model.includedContextCount) files"
                        )
                        statRow("Messages", "\(model.sessionInfo?.messages ?? 0)")
                    }

                    Text("Locus compacts the conversation when it reaches the usable limit, preserving room for tools and the next response.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("plan.contextWindow.details")
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context window information")
        .accessibilityIdentifier("plan.contextWindow")
        .animation(LocusMotion.spatial, value: isCollapsed)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.locus(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(LocusTheme.inkSoft)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

struct InspectorCheckpointsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var title = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SESSION CHECKPOINTS")
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                    Text("Save and restore this session")
                        .font(.locus(size: 11, weight: .bold))
                    Text("Checkpoints preserve the conversation, active plan, workspace, model, and context pack.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    TextField("Checkpoint name (optional)", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("checkpointTab.title")
                    Button {
                        model.createCheckpoint(title: title)
                        title = ""
                    } label: {
                        Label("Create Checkpoint", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(model.isBusy || model.hasPendingPermission)
                    .accessibilityIdentifier("checkpointTab.create")
                }

                Divider().overlay(LocusTheme.line)

                if model.checkpoints.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.locus(size: 25))
                            .foregroundStyle(LocusTheme.muted)
                        Text("No checkpoints yet")
                            .font(.locus(size: 10, weight: .semibold))
                        Text("Create one before a risky or exploratory turn.")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .locusCard(radius: 9)
                    .accessibilityIdentifier("checkpointTab.empty")
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(model.checkpoints) { checkpoint in
                            checkpointRow(checkpoint)
                        }
                    }
                }
            }
            .padding(17)
        }
        .accessibilityIdentifier("checkpointTab.content")
    }

    private func checkpointRow(_ checkpoint: SessionCheckpoint) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.locus(size: 14, weight: .semibold))
                .foregroundStyle(LocusTheme.signal)
                .frame(width: 34, height: 34)
                .background(LocusTheme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(checkpoint.title)
                    .font(.locus(size: 9, weight: .bold))
                    .lineLimit(1)
                Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.locus(size: 7))
                    .foregroundStyle(LocusTheme.muted)
            }
            Spacer(minLength: 4)
            Button {
                model.restore(checkpoint)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.locus())
            .disabled(model.isBusy || model.hasPendingPermission)
            .help("Restore this session checkpoint")
            .accessibilityLabel("Restore \(checkpoint.title)")
            .accessibilityIdentifier("checkpointTab.restore.\(checkpoint.id)")
            Button {
                model.delete(checkpoint)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(LocusTheme.coral)
            }
            .buttonStyle(.locus())
            .disabled(model.isBusy || model.hasPendingPermission)
            .help("Delete this checkpoint")
            .accessibilityLabel("Delete \(checkpoint.title)")
            .accessibilityIdentifier("checkpointTab.delete.\(checkpoint.id)")
        }
        .padding(10)
        .locusCard(radius: 9)
    }
}
