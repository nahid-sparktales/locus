import SwiftUI

struct InspectorPlanTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var suggestionsPresented = false

    private var completedCount: Int {
        model.todos.filter { $0.status == .completed }.count
    }

    private var progress: Double {
        guard !model.todos.isEmpty else { return 0 }
        return Double(completedCount) / Double(model.todos.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ContextWindowInfoCard()
                        .environmentObject(model)

                    Divider().overlay(LocusTheme.line)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CURRENT RUN")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(LocusTheme.muted)
                            Text(model.todos.isEmpty ? "No active plan" : "Agent implementation plan")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("plan.activePlan")

                    if model.todos.isEmpty {
                        VStack(spacing: 11) {
                            Image(systemName: "list.bullet.clipboard")
                                .font(.system(size: 23))
                                .foregroundStyle(LocusTheme.muted)
                            Text("Plans appear here as the agent breaks work into steps.")
                                .font(.system(size: 9))
                                .foregroundStyle(LocusTheme.muted)
                                .multilineTextAlignment(.center)
                            Button("Create a plan") {
                                suggestionsPresented = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(LocusTheme.ink)
                            .controlSize(.small)
                            .disabled(model.isBusy || model.hasPendingPermission)
                            .accessibilityIdentifier("plan.create")
                            .popover(isPresented: $suggestionsPresented, arrowEdge: .bottom) {
                                PlanSuggestionsPopover { prompt in
                                    suggestionsPresented = false
                                    model.requestPlan(prompt: prompt)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .locusCard(radius: 9)
                    } else {
                        VStack(spacing: 6) {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(LocusTheme.line)
                                    Capsule()
                                        .fill(LocusTheme.signalDeep)
                                        .frame(width: proxy.size.width * progress)
                                }
                            }
                            .frame(height: 4)
                            HStack {
                                Text("\(completedCount) of \(model.todos.count) complete")
                                Spacer()
                                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                            }
                            .font(.system(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                        }

                        VStack(spacing: 0) {
                            ForEach(Array(model.todos.enumerated()), id: \.element.id) { index, todo in
                                PlanRow(todo: todo, isLast: index == model.todos.count - 1)
                            }
                        }
                    }
                }
                .padding(17)
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(LocusTheme.line)

            PermissionGuardCard()
                .environmentObject(model)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .padding(.horizontal, 17)
                .padding(.top, 12)
                .padding(.bottom, 17)
                .background(LocusTheme.paperDeep)
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
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                    Text("Save and restore this session")
                        .font(.system(size: 11, weight: .bold))
                    Text("Checkpoints preserve the conversation, active plan, workspace, model, and context pack.")
                        .font(.system(size: 8))
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
                            .font(.system(size: 25))
                            .foregroundStyle(LocusTheme.muted)
                        Text("No checkpoints yet")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Create one before a risky or exploratory turn.")
                            .font(.system(size: 9))
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LocusTheme.signal)
                .frame(width: 34, height: 34)
                .background(LocusTheme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(checkpoint.title)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 7))
                    .foregroundStyle(LocusTheme.muted)
            }
            Spacer(minLength: 4)
            Button {
                model.restore(checkpoint)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
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
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.hasPendingPermission)
            .help("Delete this checkpoint")
            .accessibilityLabel("Delete \(checkpoint.title)")
            .accessibilityIdentifier("checkpointTab.delete.\(checkpoint.id)")
        }
        .padding(10)
        .locusCard(radius: 9)
    }
}

/// Offered when the user asks for a plan without having described one:
/// five ready-made prompts, each sent to the agent in Plan mode.
struct PlanSuggestionsPopover: View {
    let choose: (String) -> Void

    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WHAT SHOULD THE PLAN COVER?")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(LocusTheme.muted)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(Array(PlanPromptSuggestion.curated.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    choose(suggestion.prompt)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(suggestion.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LocusTheme.ink)
                        Text(suggestion.prompt)
                            .font(.system(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                            .lineSpacing(1)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(hovered == suggestion.id ? LocusTheme.paperDeep : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hovered = hovering ? suggestion.id : (hovered == suggestion.id ? nil : hovered)
                }
                .accessibilityLabel(suggestion.title)
                .accessibilityIdentifier("plan.suggestion.\(index)")
            }
        }
        .padding(6)
        .frame(width: 264)
    }
}

struct PermissionGuardCard: View {
    @EnvironmentObject private var model: AppModel

    private var mode: PermissionMode { model.permissionMode }

    private var ink: Color {
        mode.isRisky ? LocusTheme.coral : LocusTheme.permissionInk
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: mode.isRisky ? "exclamationmark.shield.fill" : "shield.lefthalf.filled")
                Text("Permissions")
                Spacer()
                Text(mode.shortTitle.uppercased())
                    .font(.system(size: 7, weight: .bold))
                    .tracking(0.6)
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(ink)

            Picker("Permission mode", selection: Binding(
                get: { mode },
                set: { model.setPermissionMode($0) }
            )) {
                ForEach(PermissionMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityIdentifier("plan.permissionMode")

            Text(mode.detail)
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.permissionMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if !model.allowedTools.isEmpty {
                Text("Always allowed this session: \(model.allowedTools.joined(separator: ", "))")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.permissionMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if !model.allowedTools.isEmpty || mode != .ask {
                    Button("Reset") { model.resetPermissions() }
                        .buttonStyle(.plain)
                        .font(.system(size: 8, weight: .bold))
                        .underline()
                        .accessibilityIdentifier("plan.permissionReset")
                }
                Button("Review settings") {
                    model.settingsPresented = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 8, weight: .bold))
                .underline()
                .accessibilityIdentifier("plan.permissionSettings")
            }
        }
        .padding(11)
        .background(LocusTheme.paperDeep)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    mode.isRisky
                        ? LocusTheme.coral.opacity(0.4)
                        : LocusTheme.line,
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan.permissions")
    }
}

struct ContextWindowInfoCard: View {
    @EnvironmentObject private var model: AppModel

    private var fraction: Double? { model.contextWindowUsageFraction }

    private var accent: Color {
        (fraction ?? 0) > 0.8 ? LocusTheme.warning : LocusTheme.signalDeep
    }

    private var remainingTokens: Int? {
        guard let usable = model.contextUsableTokens else { return nil }
        return max(usable - model.contextUsedTokens, 0)
    }

    /// The window is a vendor's published figure rather than anything observed.
    private var isAssumed: Bool {
        !model.contextWindowProvenance.isMeasured && fraction != nil
    }

    private var usageLabel: String {
        guard let fraction else {
            // The one honest signal this card has when nothing is known. It has
            // to survive: a percentage here would be invented.
            return "WINDOW UNKNOWN"
        }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return (isAssumed ? "≈ " : "") + percent + " USED"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "circle.dotted.circle")
                Text("Context window")
                Spacer()
                Text(usageLabel)
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.45)
                    .foregroundStyle(accent)
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(LocusTheme.inkSoft)

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
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context window information")
        .accessibilityIdentifier("plan.contextWindow")
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.muted)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(LocusTheme.inkSoft)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct PlanRow: View {
    let todo: TodoItem
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(symbolColor)
                    .frame(width: 23, height: 23)
                    .background(symbolBackground)
                    .clipShape(Circle())
                    .overlay {
                        Circle().stroke(symbolBorder, lineWidth: 1)
                    }
                if !isLast {
                    Rectangle()
                        .fill(LocusTheme.lineStrong)
                        .frame(width: 1, height: 25)
                }
            }
            Text(todo.content)
                .font(.system(size: 9, weight: todo.status == .inProgress ? .bold : .medium))
                .foregroundStyle(todo.status == .completed ? LocusTheme.muted : LocusTheme.ink)
                .strikethrough(todo.status == .completed, color: LocusTheme.muted)
                .padding(.top, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var symbol: String {
        switch todo.status {
        case .completed: "checkmark"
        case .inProgress: "play.fill"
        case .pending: "circle"
        }
    }

    private var symbolColor: Color {
        todo.status == .inProgress ? LocusTheme.signal : LocusTheme.success
    }

    private var symbolBackground: Color {
        todo.status == .inProgress ? LocusTheme.ink : LocusTheme.successSoft
    }

    private var symbolBorder: Color {
        todo.status == .inProgress ? LocusTheme.ink : LocusTheme.signalDeep.opacity(0.45)
    }
}
