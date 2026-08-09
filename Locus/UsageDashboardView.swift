import SwiftUI

/// The `/api/usage/summary` payload — rollups over data already on disk.
struct UsageSummary: Codable, Hashable {
    struct Orchestration: Codable, Hashable {
        let runs: Int
        let modelCalls: Int
        let meteredTokens: Int
        let estimatedCost: Double

        enum CodingKeys: String, CodingKey {
            case runs
            case modelCalls = "model_calls"
            case meteredTokens = "metered_tokens"
            case estimatedCost = "estimated_cost"
        }
    }

    struct DayRow: Codable, Hashable, Identifiable {
        let day: String
        let runs: Int
        let meteredTokens: Int
        let estimatedCost: Double
        var id: String { day }

        enum CodingKeys: String, CodingKey {
            case day, runs
            case meteredTokens = "metered_tokens"
            case estimatedCost = "estimated_cost"
        }
    }

    struct WorkspaceRow: Codable, Hashable, Identifiable {
        let workspaceRoot: String
        let runs: Int
        let estimatedCost: Double
        var id: String { workspaceRoot }

        enum CodingKeys: String, CodingKey {
            case workspaceRoot = "workspace_root"
            case runs
            case estimatedCost = "estimated_cost"
        }
    }

    struct ModelRow: Codable, Hashable, Identifiable {
        let provider: String
        let model: String
        let attempts: Int
        let promptTokens: Int
        let completionTokens: Int
        var id: String { "\(provider)/\(model)" }

        enum CodingKeys: String, CodingKey {
            case provider, model, attempts
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    struct AgentRow: Codable, Hashable, Identifiable {
        let agentID: String
        let samples: Int
        let estimatedCost: Double
        let local: Bool
        var id: String { agentID }

        enum CodingKeys: String, CodingKey {
            case agentID = "agent_id"
            case samples
            case estimatedCost = "estimated_cost"
            case local
        }
    }

    struct Evaluations: Codable, Hashable {
        let cases: Int
        let estimatedCost: Double

        enum CodingKeys: String, CodingKey {
            case cases
            case estimatedCost = "estimated_cost"
        }
    }

    struct Solo: Codable, Hashable {
        let turns: Int
        let promptTokens: Int
        let completionTokens: Int
        let recordedSince: Double?

        enum CodingKeys: String, CodingKey {
            case turns
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case recordedSince = "recorded_since"
        }
    }

    struct ExpensiveRun: Codable, Hashable, Identifiable {
        let id: String
        let teamName: String?
        let workspaceRoot: String?
        let createdAt: Double
        let state: String
        let estimatedCost: Double

        enum CodingKeys: String, CodingKey {
            case id, state
            case teamName = "team_name"
            case workspaceRoot = "workspace_root"
            case createdAt = "created_at"
            case estimatedCost = "estimated_cost"
        }
    }

    let since: Double
    let generatedAt: Double
    let readOnly: Bool
    let orchestration: Orchestration
    let byDay: [DayRow]
    let byWorkspace: [WorkspaceRow]
    let byModel: [ModelRow]
    let byAgent: [AgentRow]
    let evaluations: Evaluations
    let solo: Solo
    let expensiveRuns: [ExpensiveRun]

    enum CodingKeys: String, CodingKey {
        case since, orchestration, evaluations, solo
        case generatedAt = "generated_at"
        case readOnly = "read_only"
        case byDay = "by_day"
        case byWorkspace = "by_workspace"
        case byModel = "by_model"
        case byAgent = "by_agent"
        case expensiveRuns = "expensive_runs"
    }
}

enum UsageWindow: String, CaseIterable, Identifiable {
    case week = "7d"
    case month = "30d"
    case quarter = "90d"
    case all = "All"

    var id: String { rawValue }

    /// The unix cutoff this window starts at, or 0 for everything.
    var since: Double {
        let days: Double? = switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
        guard let days else { return 0 }
        return Date().addingTimeInterval(-days * 86_400).timeIntervalSince1970
    }
}

struct UsageDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var window: UsageWindow = .month

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LocusTheme.line)
            if let summary = model.usageSummary {
                content(summary)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading the run store…")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 780, height: 620)
        .background(LocusTheme.panel)
        .onAppear { model.refreshUsageSummary(since: window.since) }
        .onChange(of: window) {
            model.refreshUsageSummary(since: window.since)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Usage & Costs")
                    .font(.system(size: 15, weight: .bold))
                Text(
                    "Estimates computed from the per-agent rates you entered. "
                    + "Local Ollama runs are free. This is not a bill."
                )
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
            }
            Spacer()
            Picker("Window", selection: $window) {
                ForEach(UsageWindow.allCases) { window in
                    Text(window.rawValue).tag(window)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .accessibilityIdentifier("usage.window")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .accessibilityLabel("Close usage")
            .accessibilityIdentifier("usage.close")
        }
        .padding(16)
    }

    private func content(_ summary: UsageSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                totals(summary)
                if !summary.expensiveRuns.isEmpty {
                    expensiveRuns(summary.expensiveRuns)
                }
                if !summary.byAgent.isEmpty {
                    agentTable(summary.byAgent)
                }
                if !summary.byModel.isEmpty {
                    modelTable(summary.byModel)
                }
                if !summary.byWorkspace.isEmpty {
                    workspaceTable(summary.byWorkspace)
                }
                soloSection(summary.solo)
                if summary.evaluations.cases > 0 {
                    HStack(spacing: 6) {
                        sectionLabel("EVALUATIONS")
                        Text(
                            "\(summary.evaluations.cases) graded cases · "
                            + summary.evaluations.estimatedCost
                                .formatted(.currency(code: "USD"))
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func totals(_ summary: UsageSummary) -> some View {
        HStack(spacing: 10) {
            totalTile(
                "Estimated cost",
                summary.orchestration.estimatedCost.formatted(.currency(code: "USD")),
                id: "usage.total.cost"
            )
            totalTile(
                "Hosted tokens",
                summary.orchestration.meteredTokens.formatted(.number.notation(.compactName)),
                id: "usage.total.tokens"
            )
            totalTile(
                "Model calls",
                summary.orchestration.modelCalls.formatted(),
                id: "usage.total.calls"
            )
            totalTile(
                "Team runs",
                summary.orchestration.runs.formatted(),
                id: "usage.total.runs"
            )
        }
    }

    private func totalTile(_ caption: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
            Text(value)
                .font(.system(size: 17, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LocusTheme.white)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .accessibilityIdentifier(id)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(LocusTheme.muted)
    }

    private func expensiveRuns(_ runs: [UsageSummary.ExpensiveRun]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("MOST EXPENSIVE RUNS")
            ForEach(runs.filter { $0.estimatedCost > 0 }) { run in
                Button {
                    model.usageDashboardPresented = false
                    model.selectInspectorTab(.runs, selecting: run.id)
                } label: {
                    HStack {
                        Text(run.teamName?.nilIfEmpty ?? "Team run")
                            .font(.system(size: 10, weight: .semibold))
                        Text(run.state)
                            .font(.system(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                        Spacer()
                        Text(
                            Date(timeIntervalSince1970: run.createdAt)
                                .formatted(.relative(presentation: .named))
                        )
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        Text(run.estimatedCost.formatted(.currency(code: "USD")))
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(LocusTheme.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("usage.run.\(run.id)")
            }
        }
    }

    private func agentTable(_ rows: [UsageSummary.AgentRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BY AGENT")
            tableCard(rows) { row in
                HStack {
                    Text(agentName(row.agentID))
                        .font(.system(size: 10, weight: .semibold))
                    if row.local {
                        Text("local · $0")
                            .font(.system(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    Spacer()
                    Text("\(row.samples) calls")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                    Text(
                        row.local
                            ? Double.zero.formatted(.currency(code: "USD"))
                            : row.estimatedCost.formatted(.currency(code: "USD"))
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 82, alignment: .trailing)
                }
            }
        }
    }

    private func modelTable(_ rows: [UsageSummary.ModelRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BY MODEL")
            Text("Token counts from team-run job attempts. Dollar estimates exist only where a run's agent had rates.")
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.muted)
            tableCard(rows) { row in
                HStack {
                    Text(row.model.nilIfEmpty ?? "unknown model")
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Text(row.provider)
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                    Spacer()
                    Text("\(row.attempts) jobs")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                    Text(
                        "\((row.promptTokens + row.completionTokens).formatted(.number.notation(.compactName))) tok"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 82, alignment: .trailing)
                }
            }
        }
    }

    private func workspaceTable(_ rows: [UsageSummary.WorkspaceRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BY WORKSPACE")
            tableCard(rows) { row in
                HStack {
                    Text(
                        row.workspaceRoot.nilIfEmpty
                            .map { ($0 as NSString).abbreviatingWithTildeInPath }
                            ?? "No workspace"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Spacer()
                    Text("\(row.runs) runs")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                    Text(row.estimatedCost.formatted(.currency(code: "USD")))
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 82, alignment: .trailing)
                }
            }
        }
    }

    private func soloSection(_ solo: UsageSummary.Solo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("SOLO CHAT")
            if solo.turns == 0 {
                Text("No solo turns recorded in this window yet.")
                    .font(.system(size: 9))
                    .foregroundStyle(LocusTheme.muted)
            } else {
                HStack(spacing: 12) {
                    Text("\(solo.turns) turns")
                        .font(.system(size: 10, weight: .semibold))
                    Text(
                        "\(solo.promptTokens.formatted(.number.notation(.compactName))) prompt · "
                        + "\(solo.completionTokens.formatted(.number.notation(.compactName))) reply tokens"
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                }
                .accessibilityIdentifier("usage.solo")
            }
            if let since = solo.recordedSince {
                Text(
                    "Recorded since "
                    + Date(timeIntervalSince1970: since).formatted(date: .abbreviated, time: .omitted)
                    + ". Turns before this release were not recorded, and solo pricing "
                    + "is unknown, so solo rows show tokens, never dollars."
                )
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.muted)
            }
        }
    }

    private func tableCard<Row: Identifiable, Content: View>(
        _ rows: [Row],
        @ViewBuilder content: @escaping (Row) -> Content
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                content(row)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                if index < rows.count - 1 {
                    Divider().overlay(LocusTheme.line.opacity(0.6))
                }
            }
        }
        .background(LocusTheme.white)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
    }

    private func agentName(_ agentID: String) -> String {
        model.agentProfiles.first { $0.id.uuidString == agentID }?.name ?? "Removed agent"
    }
}
