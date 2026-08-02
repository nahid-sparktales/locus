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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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

                Divider().overlay(LocusTheme.line)

                HStack {
                    Text("SESSION CHECKPOINTS")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                    Spacer()
                    Button {
                        model.checkpointPresented = true
                    } label: {
                        Label("Manage", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityIdentifier("plan.manageCheckpoints")
                }

                if let latest = model.checkpoints.first {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LocusTheme.signal)
                            .frame(width: 34, height: 34)
                            .background(LocusTheme.ink)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(latest.title)
                                .font(.system(size: 9, weight: .bold))
                                .lineLimit(1)
                            Text(latest.createdAt, style: .relative)
                                .font(.system(size: 7))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        Spacer()
                        Button {
                            model.restore(latest)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Restore this session checkpoint")
                        .accessibilityLabel("Restore latest checkpoint")
                        .accessibilityIdentifier("plan.restoreLatest")
                    }
                    .padding(10)
                    .locusCard(radius: 9)
                } else {
                    Button {
                        model.createCheckpoint()
                    } label: {
                        Label("Create the first checkpoint", systemImage: "plus")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .locusCard(radius: 8)
                    .accessibilityIdentifier("plan.createCheckpoint")
                }

                PermissionGuardCard()
                    .environmentObject(model)
            }
            .padding(17)
        }
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
        mode.isRisky ? LocusTheme.coral : Color(red: 0.42, green: 0.31, blue: 0.25)
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
                .foregroundStyle(Color(red: 0.52, green: 0.42, blue: 0.36))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if !model.allowedTools.isEmpty {
                Text("Always allowed this session: \(model.allowedTools.joined(separator: ", "))")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(red: 0.52, green: 0.42, blue: 0.36))
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
        .background(
            mode.isRisky
                ? LocusTheme.coral.opacity(0.1)
                : Color(red: 0.953, green: 0.91, blue: 0.875)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    mode.isRisky
                        ? LocusTheme.coral.opacity(0.4)
                        : Color(red: 0.84, green: 0.78, blue: 0.73),
                    lineWidth: 1
                )
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
        todo.status == .inProgress ? LocusTheme.ink : Color(red: 0.906, green: 0.949, blue: 0.792)
    }

    private var symbolBorder: Color {
        todo.status == .inProgress ? LocusTheme.ink : LocusTheme.signalDeep.opacity(0.45)
    }
}
