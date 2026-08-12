import AppKit
import QuartzCore
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var modelPickerPresented = false
    @State private var teamProgressPresented = false
    @State private var createBranchPresented = false
    @State private var branchName = ""

    private var sessionTitle: String {
        model.sessions.first(where: { $0.id == model.currentSessionID })?.displayTitle
            ?? (model.blocks.isEmpty ? "New session" : "Active session")
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.activityCenterPresented {
                ActivityCenterView()
                    .environmentObject(model)
                    .frame(maxHeight: .infinity)
            } else {
                switch model.agentRuntimePhase {
                case .recovering(let message):
                    runtimeBanner(message, recovering: true)
                case .unavailable(let message):
                    runtimeBanner(message, recovering: false)
                case .starting, .online:
                    EmptyView()
                }

                if model.transcriptSearchPresented {
                    TranscriptSearchBar()
                        .environmentObject(model)
                }

                ConversationView(streamingReply: model.streamingReply)
                    .frame(maxHeight: .infinity)

                WorkStatusStrip(streamingReply: model.streamingReply)
                    .environmentObject(model)

                ComposerView()
            }
        }
        .background(LocusTheme.panel)
        .alert("Create Branch in Worktree", isPresented: $createBranchPresented) {
            TextField("feature/name", text: $branchName)
                .accessibilityIdentifier("worktree.branchName")
            Button("Cancel", role: .cancel) { branchName = "" }
            Button("Create") {
                model.createBranchForActiveTask(branchName)
                branchName = ""
            }
            .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The worktree is detached until you deliberately create a branch.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            if model.sidebarCollapsed {
                HeaderIconButton(
                    symbol: "sidebar.left",
                    label: "Show sidebar",
                    identifier: "workspace.showSidebar"
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.sidebarCollapsed = false
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(model.activityCenterPresented
                        ? "ALL WORKSPACES"
                        : URL(fileURLWithPath: model.workspacePath).lastPathComponent)
                    if let branch = model.gitBranch {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 7))
                            Text(branch)
                        }
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityLabel("Git branch \(branch)")
                        .accessibilityIdentifier("workspace.gitBranch")
                    }
                    Text("/")
                    Text("sessions")
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(LocusTheme.muted.opacity(0.8))

                Text(model.activityCenterPresented ? "Activity" : sessionTitle)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
            }

            Spacer()

            if model.selectedAgentTeam != nil {
                Button {
                    teamProgressPresented.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .frame(width: 32, height: 32)
                        Circle()
                            .fill(teamProgressColor)
                            .frame(width: 7, height: 7)
                            .overlay {
                                Circle().stroke(LocusTheme.panel, lineWidth: 1.5)
                            }
                            .offset(x: -3, y: 3)
                    }
                    .background(LocusTheme.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 32, height: 32)
                .help("Team progress · \(teamProgressTitle)")
                .accessibilityLabel("Team progress, \(teamProgressTitle)")
                .accessibilityIdentifier("workspace.teamProgress")
                .popover(isPresented: $teamProgressPresented, arrowEdge: .top) {
                    TeamProgressPopover {
                        teamProgressPresented = false
                    }
                    .environmentObject(model)
                }
            }

            ContextUsageChip()
                .environmentObject(model)

            if model.activeTaskRecord != nil, model.taskHasChanges {
                Button("Review & Land") { model.prepareReviewAndLand() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(LocusTheme.ink)
                    .disabled(model.isBusy)
                    .help("Review this worktree's changes, checks, and landing destination")
                    .accessibilityIdentifier("workspace.reviewAndLand")
            }

            Button {
                modelPickerPresented.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.teamModeEnabled
                        ? "person.3.sequence.fill"
                        : (model.activeAccount == nil ? "bolt.fill" : "cloud.fill"))
                        .font(.system(size: 11))
                        .foregroundStyle(LocusTheme.signalDeep)
                    Text(model.modelPickerLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(LocusTheme.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
                .frame(maxWidth: 190)
            }
            .buttonStyle(.plain)
            .help(model.teamModeEnabled
                ? "Active team: \(model.selectedTeamModelNames.joined(separator: ", "))"
                : "Select model")
            .accessibilityLabel(model.teamModeEnabled
                ? "Active team, \(model.modelPickerLabel)"
                : "Select model")
            .accessibilityIdentifier("workspace.modelPicker")
            .frame(height: 32)
            .popover(isPresented: $modelPickerPresented, arrowEdge: .top) {
                ModelPickerPopover {
                    modelPickerPresented = false
                }
                .environmentObject(model)
            }

            Menu {
                if model.currentExecutionEnvironment == .worktree {
                    Button("Hand Off to Local") { model.handoffCurrentChat(to: .local) }
                        .disabled(model.isBusy || model.hasPendingPermission)
                    if model.activeTaskRecord?.branch == nil {
                        Button("Create Branch Here…") { createBranchPresented = true }
                            .disabled(model.isBusy || model.hasPendingPermission)
                    }
                    if let task = model.activeTaskRecord,
                       !FileManager.default.fileExists(atPath: task.executionPath) {
                        Button("Restore Worktree") { model.restoreActiveTaskCheckout() }
                    }
                } else if model.isGitRepository {
                    Button("Hand Off to Worktree") { model.handoffCurrentChat(to: .worktree) }
                        .disabled(model.isBusy || model.hasPendingPermission)
                }
                if model.activeTaskRecord != nil {
                    Button("Open Checkout") { model.openActiveTaskCheckout() }
                    Button("Reveal in Finder") { model.revealActiveTaskCheckout() }
                }
                Divider()
                // ⌘⇧K lives on the app menu's Clear Chat only — declaring it
                // here as well would register the same shortcut twice.
                Button("Clear Chat…") { model.requestClearChat() }
                    .disabled(model.isBusy || model.hasPendingPermission)
                    .accessibilityIdentifier("workspace.actions.clearChat")
                Menu("Start Worktree Chat From") {
                    Button("Current HEAD") {
                        model.newWorktreeSession(in: model.workspacePath, baseRef: "HEAD")
                    }
                    .accessibilityIdentifier("workspace.actions.worktree.head")
                    ForEach(model.localBranches, id: \.self) { branch in
                        Button(branch) {
                            model.newWorktreeSession(in: model.workspacePath, baseRef: branch)
                        }
                        .accessibilityIdentifier("workspace.actions.worktree.branch.\(branch)")
                    }
                }
                .disabled(!model.isGitRepository)
                .accessibilityIdentifier("workspace.actions.newWorktreeSession")
                Button("Start New Local Chat") {
                    model.newSession(in: model.workspacePath, environment: .local)
                }
                .accessibilityIdentifier("workspace.actions.newLocalSession")
                Divider()
                Button("Export Current Session…") {
                    model.exportCurrentSession()
                }
                .disabled(!model.sessions.contains(where: { $0.id == model.currentSessionID }))
                .accessibilityIdentifier("workspace.actions.export")
                Divider()
                Picker("Thinking", selection: Binding(
                    get: { model.thinkingVisibility },
                    set: { model.thinkingVisibility = $0 }
                )) {
                    ForEach(ThinkingVisibility.allCases) { visibility in
                        Text(visibility.title)
                            .tag(visibility)
                            .accessibilityIdentifier("workspace.actions.thinking.\(visibility.rawValue)")
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 32, height: 32)
                    .background(LocusTheme.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
            .accessibilityLabel("Workspace actions")
            .accessibilityIdentifier("workspace.actions")
            // The inspector-restore button lived here; the always-visible
            // rail's toggle owns that job now.
        }
        .padding(.horizontal, 22)
        .frame(height: 72)
        .background(LocusTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private var teamProgressTitle: String {
        if model.selectedTeamRouteIssue != nil { return "Needs setup" }
        return model.orchestrationState?.title ?? "Ready"
    }

    private var teamProgressColor: Color {
        if model.selectedTeamRouteIssue != nil { return LocusTheme.coral }
        switch model.orchestrationState {
        case .completed: return LocusTheme.success
        case .failed, .interrupted, .cancelled, .discarded: return LocusTheme.coral
        case .waitingPermission, .waitingComputer, .waitingDispatchApproval, .paused:
            return LocusTheme.warning
        case .queued, .dispatching, .running, .reviewing: return LocusTheme.signalDeep
        case nil: return LocusTheme.success
        }
    }

    private func runtimeBanner(_ message: String, recovering: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: recovering ? "arrow.clockwise" : "exclamationmark.triangle.fill")
                .foregroundStyle(recovering ? LocusTheme.warning : LocusTheme.coral)
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer()
            Button("Settings") { model.settingsPresented = true }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold))
                .underline()
                .accessibilityIdentifier("banner.settings")
            Button("Retry") {
                model.retryLocalServices()
            }
            .font(.system(size: 9, weight: .semibold))
            .accessibilityIdentifier("banner.retry")
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background((recovering ? LocusTheme.warning : LocusTheme.coral).opacity(0.09))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill((recovering ? LocusTheme.warning : LocusTheme.coral).opacity(0.25))
                .frame(height: 1)
        }
    }
}

struct ReviewAndLandView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var destination = "local"
    @State private var branchName = ""
    @State private var commitMessage = ""
    @State private var commandsText = ""
    @State private var confirmOverride = false

    private var commands: [String] {
        Array(commandsText.split(separator: "\n", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.prefix(8))
    }

    private var checksAreCurrentAndPassing: Bool {
        guard let check = model.landingCheckRun, let preflight = model.landingPreflight else {
            return false
        }
        return check.passed && check.tree == preflight.tree
    }

    private var branchProblem: String? {
        destination == "branch" ? GitBranchName.validationError(branchName) : nil
    }

    private var canLand: Bool {
        guard let preflight = model.landingPreflight, preflight.patchBytes > 0,
              !model.isLandingOperationRunning else { return false }
        if destination == "local" { return preflight.canApplyLocal }
        return branchProblem == nil
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review & Land")
                        .font(.system(size: 17, weight: .bold))
                    Text("Review the complete worktree delta, verify it, then choose its destination.")
                        .font(.system(size: 10))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        stageHeader("1", "Review changes")
                        if let preflight = model.landingPreflight {
                            HStack {
                                Text("\(preflight.paths.count) file\(preflight.paths.count == 1 ? "" : "s")")
                                Text(ByteCountFormatter.string(
                                    fromByteCount: Int64(preflight.patchBytes), countStyle: .file
                                ))
                                Spacer()
                                Button("Copy Patch") { model.copyActiveTaskPatch() }
                                Button("Open Checkout") { model.openActiveTaskCheckout() }
                            }
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.muted)

                            ScrollView([.horizontal, .vertical]) {
                                Text(model.landingPatch.isEmpty ? "No changes." : model.landingPatch)
                                    .font(.system(size: 9, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                            .frame(height: 210)
                            .background(LocusTheme.paperDeep)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(LocusTheme.line) }
                            .accessibilityIdentifier("landing.diff")
                        }

                        Divider()
                        stageHeader("2", "Review test evidence")
                        Text("Enter one explicit check per line. Locus runs up to eight sequentially in this chat’s worktree; each has a ten-minute limit.")
                            .font(.system(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                        TextEditor(text: $commandsText)
                            .font(.system(size: 10, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 78)
                            .background(LocusTheme.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 8).stroke(LocusTheme.line) }
                            .accessibilityIdentifier("landing.checkCommands")
                        HStack {
                            if model.activeLandingCheckRunID != nil {
                                ProgressView().controlSize(.small)
                                Text("Running checks…")
                                    .font(.system(size: 9))
                                Button("Stop") { model.stopLandingChecks() }
                                    .accessibilityIdentifier("landing.stopChecks")
                            } else {
                                Button("Run Checks") { model.runLandingChecks(commands: commands) }
                                    .disabled(commands.isEmpty || model.isLandingOperationRunning)
                                    .accessibilityIdentifier("landing.runChecks")
                            }
                            Spacer()
                            if checksAreCurrentAndPassing {
                                Label("Checks passed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(LocusTheme.success)
                            } else if let check = model.landingCheckRun {
                                Label(
                                    check.tree == model.landingPreflight?.tree
                                        ? "Checks did not pass" : "Checks are stale",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(LocusTheme.warning)
                            } else {
                                Text("No current check evidence")
                                    .foregroundStyle(LocusTheme.muted)
                            }
                        }
                        .font(.system(size: 9, weight: .semibold))

                        if let run = model.landingCheckRun {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(run.results) { result in
                                    DisclosureGroup {
                                        if !result.output.isEmpty {
                                            Text(result.output)
                                                .font(.system(size: 8, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: result.state == "passed"
                                                ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            Text(result.command).lineLimit(1)
                                            Spacer()
                                            Text(result.state.replacingOccurrences(of: "_", with: " "))
                                            Text("\(result.durationMilliseconds) ms")
                                        }
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(result.state == "passed"
                                            ? LocusTheme.success : LocusTheme.warning)
                                    }
                                }
                            }
                            .padding(10)
                            .background(LocusTheme.white.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        Divider()
                        stageHeader("3", "Choose destination")
                        Picker("Destination", selection: $destination) {
                            Text("Apply to Local").tag("local")
                            Text("Branch, Commit & PR").tag("branch")
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("landing.destination")

                        if destination == "local" {
                            if model.landingPreflight?.canApplyLocal == true {
                                Text("The complete patch will be applied unstaged to Local. This chat remains in its worktree.")
                                    .font(.system(size: 9))
                                    .foregroundStyle(LocusTheme.muted)
                            } else {
                                Label(
                                    model.landingPreflight?.conflict.nilIfEmpty
                                        ?? "The patch conflicts with Local. Both checkouts are unchanged.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.system(size: 9))
                                .foregroundStyle(LocusTheme.coral)
                            }
                        } else if let task = model.activeTaskRecord, task.landingCommit != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Committed on \(task.branch ?? branchName)", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(LocusTheme.success)
                                HStack {
                                    Button("Publish") { model.publishLandedWorktree() }
                                        .disabled(model.isLandingOperationRunning)
                                    Button("Open Pull Request") { model.openLandedPullRequest() }
                                    Text(task.landingCommit?.prefix(10) ?? "")
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                            }
                        } else {
                            TextField("Branch name", text: $branchName)
                                .accessibilityIdentifier("landing.branch")
                            if let branchProblem {
                                Text(branchProblem).font(.system(size: 8)).foregroundStyle(LocusTheme.coral)
                            }
                            TextField("Commit message", text: $commitMessage, axis: .vertical)
                                .lineLimit(2...5)
                                .accessibilityIdentifier("landing.commitMessage")
                            Text("A failed commit hook leaves the new branch and staged index ready to inspect and retry.")
                                .font(.system(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        Color.clear
                            .frame(height: 0)
                            .id("landing.destination.bottom")
                            .accessibilityHidden(true)
                    }
                    .padding(18)
                }
                .onChange(of: destination) { _, destination in
                    guard destination == "branch" else { return }
                    proxy.scrollTo("landing.destination.bottom", anchor: .bottom)
                }
            }

            Divider()
            HStack {
                Text(checksAreCurrentAndPassing
                    ? "Current checks passed."
                    : "Landing without passing current checks requires an explicit confirmation.")
                    .font(.system(size: 9))
                    .foregroundStyle(checksAreCurrentAndPassing ? LocusTheme.success : LocusTheme.warning)
                Spacer()
                if model.activeTaskRecord?.landingCommit != nil && destination == "branch" {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(checksAreCurrentAndPassing ? "Land Changes" : "Land Anyway…") {
                        if checksAreCurrentAndPassing { land(override: false) }
                        else { confirmOverride = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canLand)
                    .accessibilityIdentifier("landing.confirm")
                }
            }
            .padding(14)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 650, idealHeight: 760)
        .background(LocusTheme.panel)
        .onAppear {
            commandsText = model.currentLandingCheckCommands.joined(separator: "\n")
            if let existing = model.activeTaskRecord?.branch { branchName = existing }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await model.refreshLandingReview()
            }
        }
        .alert("Land without passing current checks?", isPresented: $confirmOverride) {
            Button("Cancel", role: .cancel) {}
            Button("Land Anyway", role: .destructive) { land(override: true) }
                .accessibilityIdentifier("landing.overrideConfirm")
        } message: {
            Text("This confirmation is recorded in the run timeline. Review failures or stale evidence before continuing.")
        }
    }

    private func stageHeader(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(LocusTheme.brandInk)
                .frame(width: 22, height: 22)
                .background(LocusTheme.signal)
                .clipShape(Circle())
            Text(title).font(.system(size: 12, weight: .bold))
        }
    }

    private func land(override: Bool) {
        model.landActiveTask(
            destination: destination,
            branch: branchName,
            commitMessage: commitMessage,
            overrideFailedChecks: override
        )
    }
}

private enum ActivityGroup: String, CaseIterable, Identifiable {
    case attention = "Needs Attention"
    case running = "Running"
    case queued = "Queued"
    case recent = "Recent"

    var id: String { rawValue }
}

struct ActivityCenterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Background Activity")
                        .font(.system(size: 15, weight: .bold))
                    Text("Work keeps running when you move between chats.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                if model.visibleActivityRuns.contains(where: { model.activityIsUnseen($0) }) {
                    Button("Mark All Seen") { model.markAllActivitySeen() }
                        .accessibilityIdentifier("activity.markAllSeen")
                }
                if model.visibleActivityRuns.contains(where: {
                    TeamRunState(rawValue: $0.state)?.isTerminal == true
                }) {
                    Button("Clear Finished") { model.clearFinishedActivityRuns() }
                        .accessibilityIdentifier("activity.clearFinished")
                }
                Button {
                    Task { await model.refreshActivityRuns() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("activity.refresh")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(LocusTheme.paperDeep.opacity(0.55))

            if model.visibleActivityRuns.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Queued, running, and recent work appears here across all chats.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("activity.empty")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(ActivityGroup.allCases) { group in
                                let runs = runs(in: group)
                                if !runs.isEmpty {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            Text(group.rawValue.uppercased())
                                                .font(.system(size: 8, weight: .bold))
                                                .tracking(0.8)
                                                .foregroundStyle(group == .attention
                                                    ? LocusTheme.warning : LocusTheme.muted)
                                            Text("\(runs.count)")
                                                .font(.system(size: 8, design: .monospaced))
                                                .foregroundStyle(LocusTheme.muted)
                                        }
                                        ForEach(runs) { run in
                                            activityRow(run, now: context.date)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refreshActivityRuns()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .accessibilityIdentifier("activity.center")
    }

    private func runs(in group: ActivityGroup) -> [OrchestrationRun] {
        let values = model.visibleActivityRuns.filter { activityGroup(for: $0) == group }
        if group == .queued {
            return values.sorted {
                ($0.queuePosition ?? .max, $0.createdAt)
                    < ($1.queuePosition ?? .max, $1.createdAt)
            }
        }
        return values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func activityGroup(for run: OrchestrationRun) -> ActivityGroup {
        switch run.state {
        case "waiting_permission", "waiting_computer", "waiting_dispatch_approval",
             "paused", "interrupted", "failed":
            .attention
        case "running", "dispatching", "reviewing":
            .running
        case "queued":
            .queued
        default:
            .recent
        }
    }

    private func activityRow(_ run: OrchestrationRun, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: run))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color(for: run))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(chatTitle(for: run))
                            .font(.system(size: 11, weight: .bold))
                            .lineLimit(1)
                        Text(run.state.replacingOccurrences(of: "_", with: " ").uppercased())
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(color(for: run))
                        if model.activityIsUnseen(run) {
                            Text("NEW")
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(LocusTheme.brandInk)
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .background(LocusTheme.signal)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        Text(workspaceTitle(for: run))
                        Text("·")
                        Text((run.runKind ?? "solo").replacingOccurrences(of: "_", with: " "))
                        Text("·")
                        Text(run.executionEnvironment == "worktree" ? "Worktree" : "Local")
                        if let position = run.queuePosition {
                            Text("· queue #\(position)")
                        }
                        Text("· \(elapsed(run, now: now))")
                    }
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    Text(run.recoveryReason?.nilIfEmpty ?? meaningfulStatus(for: run))
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Open Chat") { model.openActivityRun(run) }
                Button("Timeline") {
                    model.openActivityRun(run)
                    model.selectInspectorTab(.runs)
                }
                if run.state == "queued" {
                    Button("Top") { model.updateQueuedRun(run, action: "move_top") }
                    Button("Up") { model.updateQueuedRun(run, action: "move_up") }
                    Button("Down") { model.updateQueuedRun(run, action: "move_down") }
                    Button("Remove", role: .destructive) {
                        model.updateQueuedRun(run, action: "cancel")
                    }
                } else if ["running", "dispatching", "reviewing"].contains(run.state) {
                    if run.runKind == "team" {
                        Button("Pause") { model.pauseOrchestration(run.id) }
                    }
                    Button("Stop", role: .destructive) { model.stopActivityRun(run) }
                } else if ["paused", "interrupted"].contains(run.state), run.runKind == "team" {
                    Button("Resume") { model.resumeOrchestration(run) }
                } else if ["failed", "interrupted", "cancelled", "paused"].contains(run.state) {
                    Button("Retry") { model.retryRun(run) }
                }
                if TeamRunState(rawValue: run.state)?.isTerminal == true {
                    Button("Remove") { model.dismissActivityRun(run) }
                        .help("Remove from Activity; the run timeline is preserved")
                        .accessibilityIdentifier("activity.remove.\(run.id)")
                }
                if run.state == "waiting_permission" {
                    Button("Allow Once") { model.answerActivityPermission(run, decision: "once") }
                    Button("Always Allow") { model.answerActivityPermission(run, decision: "always") }
                    Button("Deny", role: .destructive) {
                        model.answerActivityPermission(run, decision: "deny")
                    }
                }
                if ["waiting_computer", "waiting_dispatch_approval"].contains(run.state) {
                    Button(run.state == "waiting_computer" ? "Open Chat to Continue" : "Open Chat to Review") {
                        model.openActivityRun(run)
                    }
                }
                Spacer()
            }
            .font(.system(size: 8, weight: .semibold))
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(LocusTheme.line) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.run.\(run.id)")
    }

    private func chatTitle(for run: OrchestrationRun) -> String {
        guard let sessionID = run.sessionID else { return "Unknown chat" }
        return model.sessions.first(where: { $0.id == sessionID })?.displayTitle ?? "Saved chat"
    }

    private func workspaceTitle(for run: OrchestrationRun) -> String {
        guard let path = run.workspaceRoot, !path.isEmpty else { return "Unknown workspace" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func elapsed(_ run: OrchestrationRun, now: Date) -> String {
        let end = run.completedAt.map(Date.init(timeIntervalSince1970:)) ?? now
        let seconds = max(Int(end.timeIntervalSince1970 - run.createdAt), 0)
        if seconds >= 3_600 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private func meaningfulStatus(for run: OrchestrationRun) -> String {
        switch run.state {
        case "queued": "Waiting for an execution slot"
        case "waiting_permission": "A permission answer is required"
        case "waiting_computer": "Computer Control requires this chat in the foreground"
        case "waiting_dispatch_approval": "The team plan is ready for review"
        case "paused": "Paused and ready to resume"
        case "interrupted": "The worker stopped; this run can be recovered"
        case "failed": "The run failed; inspect its timeline or retry"
        case "completed": "Completed successfully"
        case "cancelled": "Stopped"
        default: "The worker is processing this run"
        }
    }

    private func symbol(for run: OrchestrationRun) -> String {
        switch activityGroup(for: run) {
        case .attention: "exclamationmark.triangle.fill"
        case .running: "waveform.path.ecg"
        case .queued: "clock.fill"
        case .recent: run.state == "completed" ? "checkmark.circle.fill" : "circle.fill"
        }
    }

    private func color(for run: OrchestrationRun) -> Color {
        switch activityGroup(for: run) {
        case .attention: LocusTheme.warning
        case .running: LocusTheme.signalDeep
        case .queued: LocusTheme.blue
        case .recent: run.state == "completed" ? LocusTheme.success : LocusTheme.muted
        }
    }
}

/// A bounded picker instead of a native `Menu`. Provider model identifiers can
/// be hundreds of characters long (especially vLLM repository paths); AppKit's
/// menu adaptor repeatedly recomputed the window layout for those strings and
/// could pin the main thread at 100% CPU. This popover owns its width and lets
/// its contents scroll, so a long route can never resize the app or its menu.
private struct ModelPickerPopover: View {
    @EnvironmentObject private var model: AppModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Model")
                    .font(.system(size: 12, weight: .bold))
                    .accessibilityIdentifier("workspace.modelPicker.popover")
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close model picker")
                .accessibilityIdentifier("workspace.modelPicker.close")
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let team = model.selectedAgentTeam {
                        teamSection(team)
                        Divider()
                    }

                    ForEach(model.modelPickerSections) { section in
                        routeSection(section)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 440)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                pickerAction(
                    "Browse Hugging Face Models…",
                    symbol: "shippingbox",
                    identifier: "workspace.modelPicker.browseHuggingFace"
                ) {
                    dismiss()
                    model.modelLibraryPresented = true
                }
                pickerAction(
                    "Refresh Models",
                    symbol: "arrow.clockwise",
                    identifier: "workspace.modelPicker.refresh"
                ) {
                    Task {
                        await model.refreshMetadata()
                        await model.refreshAccountCatalogs(force: true)
                    }
                }
                pickerAction(
                    "Manage Accounts…",
                    symbol: "person.crop.circle",
                    identifier: "workspace.modelPicker.manageAccounts"
                ) {
                    dismiss()
                    model.settingsPage = .accounts
                    model.settingsPresented = true
                }
                pickerAction(
                    "Manage Agents & Teams…",
                    symbol: "person.3.sequence.fill",
                    identifier: "workspace.modelPicker.manageAgentsTeams"
                ) {
                    dismiss()
                    model.settingsPage = .agents
                    model.settingsPresented = true
                }
            }
            .padding(10)
        }
        .frame(width: 380)
        .background(LocusTheme.panel)
    }

    private func teamSection(_ team: AgentTeam) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("ACTIVE TEAM")
            Text(team.name)
                .font(.system(size: 11, weight: .bold))
            ForEach(model.selectedTeamModelNames, id: \.self) { name in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "cpu")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.signalDeep)
                        .frame(width: 13)
                    Text(name)
                        .font(.system(size: 8, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 14) {
                Button("Manage \(team.name)…") {
                    dismiss()
                    model.settingsPage = .agents
                    model.settingsPresented = true
                }
                .accessibilityIdentifier("workspace.modelPicker.manageTeam")
                Button("Switch to Solo") {
                    model.selectAgentTeam(nil)
                }
                .accessibilityIdentifier("workspace.modelPicker.switchToSolo")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9, weight: .semibold))
        }
    }

    private func routeSection(_ section: ModelPickerSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(model.teamModeEnabled ? "SOLO · \(section.title)" : section.title.uppercased())
            if let message = section.emptyMessage {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(LocusTheme.muted)
            }
            ForEach(section.models, id: \.self) { name in
                Button {
                    if model.teamModeEnabled { model.selectAgentTeam(nil) }
                    model.selectModel(account: section.account, model: name)
                    dismiss()
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: model.isCurrentRoute(account: section.account, model: name)
                            ? "checkmark.circle.fill"
                            : "circle")
                            .font(.system(size: 9))
                            .foregroundStyle(model.isCurrentRoute(account: section.account, model: name)
                                ? LocusTheme.signalDeep
                                : LocusTheme.muted)
                            .frame(width: 13)
                        Text(name)
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(name) from \(section.title)")
            }
        }
    }

    private func pickerAction(
        _ title: String,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(height: 26)
        .accessibilityIdentifier(identifier)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(LocusTheme.muted)
    }
}

private struct TeamActivityPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Image(systemName: "person.3.sequence.fill")
                        .foregroundStyle(LocusTheme.signalDeep)
                    Text("TEAM ACTIVITY")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.7)
                    if let state = model.orchestrationState {
                        Text(state.title)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    Spacer()
                    if let task = model.activeTaskRecord {
                        Text(URL(fileURLWithPath: task.executionPath).lastPathComponent)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
                .foregroundStyle(LocusTheme.ink)
                .padding(.horizontal, 24)
                .frame(height: 31)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("teamActivity.toggle")

            if expanded {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(model.agentActivities) { activity in
                            AgentActivityRow(
                                activity: activity,
                                thinkingVisibility: model.thinkingVisibility
                            )
                        }
                        if let task = model.activeTaskRecord {
                            taskActions(task)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 180)
            }
        }
        .background(LocusTheme.paperDeep.opacity(0.75))
        .overlay(alignment: .top) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private func taskActions(_ task: TaskRecord) -> some View {
        HStack(spacing: 8) {
            Label(
                model.taskHasChanges
                    ? "\(ByteCountFormatter.string(fromByteCount: Int64(model.taskPatchBytes), countStyle: .file)) ready"
                    : "Private checkout",
                systemImage: "arrow.triangle.branch"
            )
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(LocusTheme.muted)
            Spacer()
            Button("Review & Land") { model.prepareReviewAndLand() }
                .disabled(model.isBusy || !model.taskHasChanges)
            Button("Copy Patch") { model.copyActiveTaskPatch() }
                .disabled(model.isBusy || !model.taskHasChanges)
            Menu {
                Button("Open Checkout") { model.openActiveTaskCheckout() }
                Button("Reveal in Finder") { model.revealActiveTaskCheckout() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.top, 3)
        .accessibilityIdentifier("teamActivity.taskActions")
    }
}

private struct AgentActivityRow: View {
    let activity: AgentActivity
    let thinkingVisibility: ThinkingVisibility
    @State private var outputExpanded = false
    @State private var reasoningExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if !activity.output.isEmpty { outputExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: stateSymbol)
                        .foregroundStyle(stateColor)
                        .frame(width: 13)
                    Text(activity.agentName)
                        .font(.system(size: 9, weight: .semibold))
                    if let position = activity.writerPosition, let total = activity.writerTotal {
                        Text("Coding \(position)/\(total)")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LocusTheme.signalDeep)
                    }
                    Text("\(activity.provider) · \(activity.model)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(1)
                    Spacer()
                    Text("\(activity.elapsedMilliseconds / 1_000)s · \((activity.promptTokens + activity.completionTokens).formatted()) tok")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(activity.goal)
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineLimit(2)
            if outputExpanded, !activity.output.isEmpty {
                Text(activity.output)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .textSelection(.enabled)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LocusTheme.white.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if thinkingVisibility != .hidden,
               let reasoning = activity.reasoningText,
               !reasoning.isEmpty
            {
                if thinkingVisibility == .collapsed {
                    Button {
                        reasoningExpanded.toggle()
                    } label: {
                        Label(reasoningExpanded ? "Hide reasoning" : "Show reasoning", systemImage: "brain")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                if reasoningExpanded || thinkingVisibility == .expanded {
                    Text(reasoning)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .textSelection(.enabled)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LocusTheme.paperDeep.opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(7)
        .background(LocusTheme.white.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var stateSymbol: String {
        switch activity.state {
        case .completed: "checkmark.circle.fill"
        case .failed, .interrupted: "xmark.circle.fill"
        case .waitingPermission, .waitingComputer: "pause.circle.fill"
        default: "circle.dotted"
        }
    }

    private var stateColor: Color {
        switch activity.state {
        case .completed: LocusTheme.success
        case .failed, .interrupted: LocusTheme.coral
        case .waitingPermission, .waitingComputer: LocusTheme.warning
        default: LocusTheme.signalDeep
        }
    }
}

private struct WorkStatusStrip: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var streamingReply: StreamingReplyState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isBusy ? LocusTheme.signalDeep : LocusTheme.success)
                    .frame(width: 6, height: 6)
                Text(model.currentWorkPhase)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if model.isBusy, let started = model.activeWorkStartedAt {
                    Text(elapsed(from: started, to: context.date))
                        .monospacedDigit()
                }
                Spacer()
                if model.isBusy {
                    Text("~\(model.estimatedStreamingTokens.formatted()) streamed tokens")
                }
                if model.orchestrationState != nil {
                    Text("\(model.teamModelCalls.formatted()) team calls")
                    if model.teamMeteredTokens > 0 {
                        Text("\(model.teamMeteredTokens.formatted()) hosted tokens")
                    }
                }
                if let info = model.sessionInfo {
                    Text("provider · \(info.promptTokens.formatted()) in / \(info.completionTokens.formatted()) out")
                }
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(LocusTheme.muted)
            .padding(.horizontal, 24)
            .frame(height: 25)
            .background(LocusTheme.panel)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workspace.workStatus")
        }
    }

    private func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(Int(end.timeIntervalSince(start)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Codex-style Chat/Work segmented control. This intentionally uses custom
/// capsule styling instead of the native macOS segmented picker so it matches
/// the compact dark control used in Codex.
struct JustChatControl: View {
    let isChatSelected: Bool
    let setChatSelected: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(
                title: "Chat",
                selected: isChatSelected,
                identifier: "workspace.mode.chat"
            ) {
                setChatSelected(true)
            }

            segment(
                title: "Work",
                selected: !isChatSelected,
                identifier: "workspace.mode.work"
            ) {
                setChatSelected(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(LocusTheme.paperDeep)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .shadow(color: LocusTheme.ink.opacity(0.08), radius: 2, y: 1)
        .layoutPriority(2)
        .animation(.easeInOut(duration: 0.16), value: isChatSelected)
        .help(
            isChatSelected
                ? "Just Chat is on — no workspace files, commands, skills, or MCP tools"
                : "Work mode can plan, inspect, and change the workspace"
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat or Work mode")
        .accessibilityValue(isChatSelected ? "Chat" : "Work")
        .accessibilityIdentifier("workspace.justChat")
    }

    private func segment(
        title: String,
        selected: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? LocusTheme.white : LocusTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if selected {
                        Capsule()
                            .fill(LocusTheme.inkSoft)
                            .shadow(color: LocusTheme.ink.opacity(0.16), radius: 1, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

struct TranscriptFollowState: Equatable {
    var isNearBottom = true
    var isFollowingOutput = true

    /// `isFollowingOutput` is the explicit pin. A layout pass can temporarily
    /// move the bottom marker more than 24 points before the matching scroll
    /// callback runs; that content growth must not masquerade as user intent.
    var permitsAutomaticScroll: Bool { isFollowingOutput }
    var showsJumpToLatest: Bool { !isNearBottom || !isFollowingOutput }

    mutating func userScrolled(upward: Bool) {
        if upward {
            isFollowingOutput = false
        } else if isNearBottom {
            isFollowingOutput = true
        }
    }

    mutating func updateBottom(isNear: Bool) {
        isNearBottom = isNear
    }

    mutating func jumpToLatest() {
        isNearBottom = true
        isFollowingOutput = true
    }

    mutating func detach() {
        isFollowingOutput = false
    }
}

private struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    let streamingReply: StreamingReplyState
    @StateObject private var scrollCoordinator = TranscriptScrollCoordinator()

    private let bottomID = "conversation-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if model.blocks.isEmpty {
                        EmptyConversationView()
                            .environmentObject(model)
                    } else {
                        ForEach(model.blocks) { block in
                            VStack(alignment: .leading, spacing: 12) {
                                if block.kind == .assistant,
                                   block.id == model.activeStreamingAssistantID
                                {
                                    ActiveAssistantBlockView(
                                        reply: streamingReply,
                                        thinkingVisibility: model.thinkingVisibility
                                    )
                                    .id(block.id)
                                } else {
                                    MessageBlockView(
                                        block: block,
                                        thinkingVisibility: model.thinkingVisibility,
                                        actionsDisabled: model.isBusy || model.hasPendingPermission,
                                        canRewind: model.canRewind(to: block),
                                        canRegenerate: model.canRegenerate(block),
                                        onCopy: { model.copyMessage(block.text) },
                                        onUseAsDraft: { model.useAsDraft(block.text) },
                                        onRewind: { model.rewind(to: block) },
                                        onRegenerate: { model.retryLastResponse() }
                                    )
                                    .equatable()
                                }
                                if block.kind == .user, let runID = block.teamRunID {
                                    TeamRunBoardView(runID: runID, request: block.text)
                                        .environmentObject(model)
                                        .id("team-board-\(runID)")
                                }
                            }
                            .overlay {
                                if let style = model.transcriptMatchStyle(for: block.id) {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(
                                            style == .current
                                                ? LocusTheme.signalDeep
                                                : LocusTheme.lineStrong.opacity(0.7),
                                            lineWidth: style == .current ? 2 : 1
                                        )
                                        .padding(-7)
                                        .allowsHitTesting(false)
                                }
                            }
                            .id(block.id)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .frame(maxWidth: 740)
                .padding(.horizontal, 28)
                .padding(.top, model.blocks.isEmpty ? 0 : 26)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("conversation.scroll")
            .background {
                TranscriptScrollBridge(coordinator: scrollCoordinator)
            }
            .chatAttachmentDropTarget()
            .overlay(alignment: .bottom) {
                if scrollCoordinator.followState.showsJumpToLatest, !model.blocks.isEmpty {
                    Button {
                        scrollCoordinator.jumpToLatest(animated: true)
                    } label: {
                        Label("Jump to Latest", systemImage: "arrow.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(LocusTheme.white)
                            .clipShape(Capsule())
                            .overlay { Capsule().stroke(LocusTheme.line, lineWidth: 1) }
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("conversation.jumpToLatest")
                }
            }
            .onChange(of: model.blocks.count) {
                scrollCoordinator.contentMayHaveChanged()
            }
            .onChange(of: model.transcriptSearchSelection) {
                scrollCoordinator.detach()
                scrollToCurrentMatch(proxy)
            }
            .onChange(of: model.transcriptSearchQuery) {
                scrollCoordinator.detach()
                scrollToCurrentMatch(proxy)
            }
        }
    }

    private func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let match = model.currentTranscriptMatch else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            proxy.scrollTo(match, anchor: .center)
        }
    }
}

struct TranscriptScrollMetrics {
    static func bottomDistance(
        documentBounds: CGRect,
        visibleRect: CGRect,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return max(documentBounds.maxY - visibleRect.maxY, 0)
        }
        return max(visibleRect.minY - documentBounds.minY, 0)
    }

    static func bottomOriginY(
        documentBounds: CGRect,
        viewportHeight: CGFloat,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return max(documentBounds.maxY - viewportHeight, documentBounds.minY)
        }
        return documentBounds.minY
    }
}

/// Owns the underlying NSScrollView. Streaming height changes are pinned once
/// per display refresh by adjusting the clip-view origin directly; no SwiftUI
/// scrollTo transaction is created for tokens or reasoning.
@MainActor
final class TranscriptScrollCoordinator: ObservableObject {
    @Published private(set) var followState = TranscriptFollowState()

    private weak var scrollView: NSScrollView?
    private weak var documentView: NSView?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var displayLink: CADisplayLink?
    private var pinPending = false
    private var isProgrammaticScroll = false
    private var isUserLiveScrolling = false
    private var isRoutingVerticalWheel = false
    private var lastOriginY: CGFloat = 0

    func attach(from anchor: NSView) {
        guard let candidate = anchor.enclosingScrollView else { return }
        if scrollView === candidate, documentView === candidate.documentView { return }
        detachObservers()
        scrollView = candidate
        documentView = candidate.documentView
        candidate.contentView.postsBoundsChangedNotifications = true
        candidate.documentView?.postsFrameChangedNotifications = true
        lastOriginY = candidate.contentView.bounds.origin.y

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: candidate.documentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.documentFrameChanged() }
        })
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: candidate.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.boundsChanged() }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.liveScrollStarted() }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.userViewportChanged() }
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: candidate,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.liveScrollEnded() }
        })

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self, weak candidate] event in
            guard let self, let candidate,
                  let window = candidate.window, event.window === window
            else { return event }
            let point = candidate.convert(event.locationInWindow, from: nil)
            guard candidate.bounds.contains(point) else { return event }

            let vertical = abs(event.scrollingDeltaY)
            let horizontal = abs(event.scrollingDeltaX)
            if vertical > 0, vertical >= horizontal {
                self.isRoutingVerticalWheel = true
                self.wheelMoved(deltaY: event.scrollingDeltaY)
            }
            guard self.isRoutingVerticalWheel else { return event }

            // SwiftUI can place selectable text and horizontal code views in
            // their own scroll responders. Letting those receive a vertical
            // trackpad gesture makes the transcript appear to stop at every
            // reasoning/tool block. Route the complete vertical gesture to
            // the transcript's one native scroll view; horizontal-dominant
            // gestures still reach code blocks normally.
            candidate.scrollWheel(with: event)
            let phaseEnded = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            let momentumEnded = event.momentumPhase.contains(.ended)
                || event.momentumPhase.contains(.cancelled)
            if phaseEnded || momentumEnded
                || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
                self.isRoutingVerticalWheel = false
            }
            return nil
        }
        updateNearBottom()
        contentMayHaveChanged()
    }

    func contentMayHaveChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.followState.permitsAutomaticScroll {
                self.schedulePin()
            } else {
                self.updateNearBottom()
            }
        }
    }

    func detach() {
        pinPending = false
        displayLink?.isPaused = true
        mutateState { $0.detach() }
    }

    func jumpToLatest(animated: Bool) {
        mutateState { $0.jumpToLatest() }
        pinPending = false
        displayLink?.isPaused = true
        scrollToBottom(animated: animated)
    }

    func detachAll() {
        isRoutingVerticalWheel = false
        detachObservers()
        scrollView = nil
        documentView = nil
    }

    private func wheelMoved(deltaY: CGFloat) {
        updateNearBottom()
        if deltaY > 0 {
            detach()
        } else {
            mutateState { $0.userScrolled(upward: false) }
        }
    }

    private func liveScrollStarted() {
        isUserLiveScrolling = true
        pinPending = false
        displayLink?.isPaused = true
        lastOriginY = scrollView?.contentView.bounds.origin.y ?? lastOriginY
    }

    private func liveScrollEnded() {
        userViewportChanged()
        isUserLiveScrolling = false
    }

    private func userViewportChanged() {
        guard let scrollView, !isProgrammaticScroll else { return }
        let origin = scrollView.contentView.bounds.origin.y
        let movedTowardBottom = documentView?.isFlipped == false
            ? origin < lastOriginY
            : origin > lastOriginY
        lastOriginY = origin
        updateNearBottom()
        if movedTowardBottom, followState.isNearBottom {
            mutateState { $0.userScrolled(upward: false) }
        } else if !movedTowardBottom {
            detach()
        }
    }

    private func boundsChanged() {
        guard let scrollView else { return }
        let origin = scrollView.contentView.bounds.origin.y
        if isProgrammaticScroll {
            lastOriginY = origin
            updateNearBottom()
        } else if isUserLiveScrolling {
            userViewportChanged()
        } else {
            lastOriginY = origin
            updateNearBottom()
        }
    }

    private func documentFrameChanged() {
        if followState.permitsAutomaticScroll {
            schedulePin()
        } else {
            updateNearBottom()
        }
    }

    private func updateNearBottom() {
        guard let scrollView, let documentView else { return }
        let distance = TranscriptScrollMetrics.bottomDistance(
            documentBounds: documentView.bounds,
            visibleRect: scrollView.documentVisibleRect,
            isFlipped: documentView.isFlipped
        )
        mutateState { $0.updateBottom(isNear: distance <= 24) }
    }

    private func schedulePin() {
        guard followState.permitsAutomaticScroll, let scrollView else { return }
        pinPending = true
        if displayLink == nil {
            let link = scrollView.displayLink(target: self, selector: #selector(displayTick(_:)))
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard pinPending, followState.permitsAutomaticScroll else {
            link.isPaused = true
            return
        }
        pinPending = false
        link.isPaused = true
        scrollToBottom(animated: false)
    }

    private func scrollToBottom(animated: Bool) {
        guard let scrollView, let documentView else { return }
        let origin = NSPoint(
            x: scrollView.contentView.bounds.origin.x,
            y: TranscriptScrollMetrics.bottomOriginY(
                documentBounds: documentView.bounds,
                viewportHeight: scrollView.contentView.bounds.height,
                isFlipped: documentView.isFlipped
            )
        )
        isProgrammaticScroll = true
        let finish = { [weak self, weak scrollView] in
            guard let self else { return }
            if let scrollView {
                scrollView.reflectScrolledClipView(scrollView.contentView)
                self.lastOriginY = scrollView.contentView.bounds.origin.y
            }
            self.isProgrammaticScroll = false
            self.updateNearBottom()
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.contentView.animator().setBoundsOrigin(origin)
            } completionHandler: {
                DispatchQueue.main.async(execute: finish)
            }
        } else {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            finish()
        }
    }

    private func mutateState(_ mutation: (inout TranscriptFollowState) -> Void) {
        var next = followState
        mutation(&next)
        if next != followState { followState = next }
    }

    private func detachObservers() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        displayLink?.invalidate()
        displayLink = nil
        pinPending = false
        isRoutingVerticalWheel = false
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        displayLink?.invalidate()
    }
}

private struct TranscriptScrollBridge: NSViewRepresentable {
    let coordinator: TranscriptScrollCoordinator

    func makeNSView(context: Context) -> TranscriptScrollAnchorView {
        let view = TranscriptScrollAnchorView(frame: .zero)
        view.transcriptCoordinator = coordinator
        DispatchQueue.main.async { coordinator.attach(from: view) }
        return view
    }

    func updateNSView(_ view: TranscriptScrollAnchorView, context: Context) {
        view.transcriptCoordinator = coordinator
        DispatchQueue.main.async { coordinator.attach(from: view) }
    }

    static func dismantleNSView(_ nsView: TranscriptScrollAnchorView, coordinator: ()) {
        nsView.transcriptCoordinator?.detachAll()
        nsView.transcriptCoordinator = nil
    }
}

private final class TranscriptScrollAnchorView: NSView {
    weak var transcriptCoordinator: TranscriptScrollCoordinator?
}

/// ⌘F search over the current conversation. Matches whole blocks (tool cards
/// excluded); ↵ and ⇧↵ walk matches with wrap-around, esc closes.
private struct TranscriptSearchBar: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    private var countText: String {
        let matches = model.transcriptSearchMatches
        if matches.isEmpty {
            return model.transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : "0 results"
        }
        let current = min(max(model.transcriptSearchSelection, 0), matches.count - 1)
        return "\(current + 1) of \(matches.count)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)

            TextField("Find in conversation", text: $model.transcriptSearchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($focused)
                .accessibilityIdentifier("search.field")
                .onKeyPress(keys: [.return]) { press in
                    model.advanceTranscriptSearch(press.modifiers.contains(.shift) ? -1 : 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    model.closeTranscriptSearch()
                    return .handled
                }

            if !countText.isEmpty {
                Text(countText)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityIdentifier("search.count")
            }

            Button {
                model.advanceTranscriptSearch(-1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LocusTheme.muted)
            .disabled(model.transcriptSearchMatches.isEmpty)
            .help("Previous match (⇧↵)")
            .accessibilityLabel("Previous match")
            .accessibilityIdentifier("search.prev")

            Button {
                model.advanceTranscriptSearch(1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LocusTheme.muted)
            .disabled(model.transcriptSearchMatches.isEmpty)
            .help("Next match (↵)")
            .accessibilityLabel("Next match")
            .accessibilityIdentifier("search.next")

            Button {
                model.closeTranscriptSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LocusTheme.muted)
            .help("Close search (esc)")
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("search.close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(LocusTheme.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .onAppear { focused = true }
    }
}

private struct EmptyConversationView: View {
    @EnvironmentObject private var model: AppModel

    private let suggestions = [
        ("sparkles", "Polish an existing interface without changing its behavior"),
        ("doc.text.magnifyingglass", "Audit this project and identify the three highest-risk areas"),
        ("checklist", "Find every TODO and turn them into an implementation plan"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(runtimeColor)
                    .frame(width: 7, height: 7)
                Text(runtimeStatus)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.top, 48)

            Text("What are we making\nbetter today?")
                .font(.system(size: 40, weight: .medium))
                .tracking(-1.8)
                .foregroundStyle(LocusTheme.ink)
                .padding(.top, 15)

            Text("Locus works inside your selected workspace with local Ollama models. You stay in control of every file change and command.")
                .font(.system(size: 11))
                .foregroundStyle(LocusTheme.muted)
                .lineSpacing(4)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, 15)

            Rectangle()
                .fill(LocusTheme.line)
                .frame(height: 1)
                .padding(.vertical, 30)

            VStack(spacing: 8) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                    Button {
                        model.send(item.1)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.0)
                                .font(.system(size: 13))
                                .foregroundStyle(index == 0 ? LocusTheme.ink : LocusTheme.muted)
                                .frame(width: 28, height: 28)
                                .background(index == 0 ? LocusTheme.signal : LocusTheme.paperDeep)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(item.1)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(LocusTheme.inkSoft)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(LocusTheme.muted.opacity(0.7))
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 46)
                        .locusCard(radius: 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("suggestion.\(index)")
                }
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    private var activeRuntimePhase: RuntimePhase {
        model.isAgentOnline ? model.modelRuntimePhase : model.agentRuntimePhase
    }

    private var runtimeColor: Color {
        switch activeRuntimePhase {
        case .starting, .recovering: LocusTheme.warning
        case .online: LocusTheme.success
        case .unavailable: LocusTheme.coral
        }
    }

    private var runtimeStatus: String {
        switch activeRuntimePhase {
        case .starting: "LOCAL SERVICES · STARTING"
        case .online: "LOCAL SERVICES · READY WHEN YOU ARE"
        case .recovering: "LOCAL SERVICES · RECOVERING"
        case .unavailable: "LOCAL SERVICES · UNAVAILABLE"
        }
    }
}

/// An immutable transcript row. Keeping the observable AppModel out of this
/// view is what prevents a token publication for the active reply from
/// invalidating every completed Markdown row above it.
private struct ActiveAssistantBlockView: View {
    @ObservedObject var reply: StreamingReplyState
    let thinkingVisibility: ThinkingVisibility

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            BrandMark(compact: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Locus")
                    .font(.system(size: 10, weight: .bold))
                StreamingMessageContentView(
                    reply: reply,
                    thinkingVisibility: thinkingVisibility
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("message.streamingAssistant")
    }
}

private struct MessageBlockView: View, Equatable {
    let block: ChatBlock
    let thinkingVisibility: ThinkingVisibility
    let actionsDisabled: Bool
    let canRewind: Bool
    let canRegenerate: Bool
    let onCopy: () -> Void
    let onUseAsDraft: () -> Void
    let onRewind: () -> Void
    let onRegenerate: () -> Void
    @State private var isHovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block
            && lhs.thinkingVisibility == rhs.thinkingVisibility
            && lhs.actionsDisabled == rhs.actionsDisabled
            && lhs.canRewind == rhs.canRewind
            && lhs.canRegenerate == rhs.canRegenerate
    }

    var body: some View {
        Group {
            switch block.kind {
            case .user:
                conversationRow(name: "You", avatar: userAvatar) {
                    Text(block.text)
                        .font(.system(size: 12))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }

            case .assistant:
                conversationRow(name: "Locus", avatar: AnyView(BrandMark(compact: true))) {
                    if block.text.isEmpty,
                       (block.reasoningText?.isEmpty ?? true),
                       block.isStreaming
                    {
                        ThinkingDots()
                    } else {
                        MessageContentView(
                            text: block.text,
                            isStreaming: block.isStreaming,
                            reasoningText: block.reasoningText,
                            thinkingVisibility: thinkingVisibility
                        )
                        if block.isStreaming {
                            Capsule()
                                .fill(LocusTheme.signalDeep)
                                .frame(width: 9, height: 2)
                                .opacity(0.8)
                        }
                    }
                }

            case .tool:
                if let tool = block.tool {
                    ToolCardView(tool: tool)
                        .padding(.leading, 43)
                }

            case .note:
                if let completion = block.completion {
                    TurnCompletionMarker(completion: completion)
                } else {
                    Label(block.text, systemImage: "info.circle")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LocusTheme.paperDeep.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

            case .error:
                Label(block.text, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LocusTheme.coral)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LocusTheme.coral.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.coral.opacity(0.28), lineWidth: 1)
                    }
            }
        }
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(blockAccessibilityIdentifier)
        .contextMenu {
            if block.kind == .user || block.kind == .assistant {
                Button("Copy Message", action: onCopy)
                Button("Use as Draft", action: onUseAsDraft)
                    .disabled(actionsDisabled)
            }
            if block.kind == .user {
                Button("Rewind to This Message", action: onRewind)
                    .disabled(!canRewind)
            }
            if canRegenerate {
                Divider()
                Button("Regenerate Response", action: onRegenerate)
            }
        }
    }

    private var blockAccessibilityIdentifier: String {
        if block.kind == .tool, let tool = block.tool {
            return "tool.\(tool.toolID).toggle"
        }
        return block.completion == nil
            ? "message.\(block.id.uuidString)"
            : "turnCompletion.\(block.id.uuidString)"
    }

    private var userAvatar: AnyView {
        AnyView(
            Text("N")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 30, height: 30)
                .background(LocusTheme.paperDeep)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
        )
    }

    private func conversationRow<Content: View>(
        name: String,
        avatar: AnyView,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            avatar
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 10, weight: .bold))
                    Spacer()
                    if isHovering {
                        messageActions
                            .transition(.opacity)
                    }
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var messageActions: some View {
        if block.kind == .user || block.kind == .assistant {
            actionButton("doc.on.doc", help: "Copy message", identifier: "copy") {
                onCopy()
            }
            actionButton("arrow.turn.down.right", help: "Use as draft", identifier: "useAsDraft") {
                onUseAsDraft()
            }
            .disabled(actionsDisabled)
        }
        if block.kind == .user {
            actionButton("arrow.counterclockwise", help: "Rewind to this message", identifier: "rewind") {
                onRewind()
            }
            .disabled(!canRewind)
        }
        if canRegenerate {
            actionButton("arrow.clockwise", help: "Regenerate response", identifier: "regenerate") {
                onRegenerate()
            }
        }
    }

    private func actionButton(
        _ symbol: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 24, height: 22)
                .background(LocusTheme.paperDeep.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier("message.\(block.id.uuidString).\(identifier)")
    }
}

private struct TurnCompletionMarker: View {
    let completion: TurnCompletion

    private var color: Color {
        switch completion.outcome {
        case .complete: LocusTheme.success
        case .interrupted, .maxIterations, .modelCallBudget: LocusTheme.warning
        case .error: LocusTheme.coral
        }
    }

    private var symbol: String {
        switch completion.outcome {
        case .complete: "checkmark.circle.fill"
        case .interrupted: "stop.circle.fill"
        case .maxIterations, .modelCallBudget: "exclamationmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(LocusTheme.line)
                .frame(height: 1)

            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)

            Text(completion.title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.inkSoft)
                .fixedSize()

            Text("· Worked for \(completion.durationText)")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize()

            Rectangle()
                .fill(LocusTheme.line)
                .frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(completion.title). Worked for \(completion.durationText).")
    }
}

/// The bordered icon button used for the panel-restore controls in the header.
/// Shared so the two cannot drift apart.
private struct HeaderIconButton: View {
    let symbol: String
    let label: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private struct ContextUsageChip: View {
    @EnvironmentObject private var model: AppModel
    @State private var detailPresented = false

    /// nil when no window is known — the chip then shows a token count
    /// instead of pretending to know a percentage.
    private var fraction: Double? {
        model.contextWindowUsageFraction
    }

    /// True when the percentage is being divided by a number nothing measured,
    /// which the chip marks rather than presenting as fact.
    private var isAssumed: Bool {
        !model.contextWindowProvenance.isMeasured && fraction != nil
    }

    private var chipText: String {
        if let fraction {
            let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
            return isAssumed ? "≈" + percent : percent
        }
        return "~" + model.contextUsedTokens.formatted(.number.notation(.compactName))
    }

    private var helpText: String {
        if fraction == nil { return "Context used — the model's window is unknown" }
        if isAssumed {
            return "Context window usage — assumed from the published window for this model"
        }
        return "Context window usage"
    }

    var body: some View {
        Button {
            detailPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .trim(from: 0, to: fraction.map { max($0, 0.02) } ?? 0)
                    .stroke(
                        (fraction ?? 0) > 0.8 ? LocusTheme.warning : LocusTheme.signalDeep,
                        // Dashed for a window nobody measured: the ring reads as
                        // precise, and this one is only as good as a vendor's
                        // documentation for a model id.
                        style: isAssumed
                            ? StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 2])
                            : StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .background {
                        Circle().stroke(LocusTheme.line, lineWidth: 2.5)
                    }
                    .frame(width: 12, height: 12)
                Text(chipText)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(LocusTheme.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(
            fraction == nil
                ? "Context used \(chipText) tokens, window unknown"
                : "Context window \(chipText) used"
        )
        .accessibilityIdentifier("workspace.contextUsage")
        .popover(isPresented: $detailPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CONTEXT WINDOW")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(LocusTheme.muted)
                statRow(
                    "Model window",
                    model.contextWindowTokens.map { "\($0.formatted()) tokens" } ?? "Unknown"
                )
                statRow("Source", model.contextWindowProvenance.label)
                statRow("Session so far", "~\(model.contextUsedTokens.formatted()) tokens")
                if let usable = model.contextUsableTokens,
                   let window = model.contextWindowTokens, usable < window {
                    statRow("Usable for the conversation", "\(usable.formatted()) tokens")
                }
                // Cumulative across every model call this session, so they
                // routinely exceed the window above — labelled, because
                // unlabelled they read as a broken meter.
                statRow(
                    "Prompt tokens (session total)",
                    "\((model.sessionInfo?.promptTokens ?? 0).formatted())"
                )
                statRow(
                    "Completion tokens (session total)",
                    "\((model.sessionInfo?.completionTokens ?? 0).formatted())"
                )
                statRow(
                    "Context pack (next send)",
                    "\(model.includedContextTokens.formatted()) tokens · \(model.includedContextCount) files"
                )
                statRow("Messages", "\(model.sessionInfo?.messages ?? 0)")
            }
            .padding(14)
            .frame(width: 250)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
    }
}

private struct ThinkingDots: View {
    @State private var active = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(LocusTheme.muted)
                    .frame(width: 4, height: 4)
                    .offset(y: active ? (index == 1 ? -3 : 0) : (index == 1 ? 0 : -2))
            }
            Text("Thinking")
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .padding(.leading, 3)
        }
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: active)
        .onAppear { active = true }
    }
}

private struct ToolCardView: View {
    let tool: ToolPayload
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                    Image(systemName: statusSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text(tool.tool)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                    Text(tool.summary)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                        .lineLimit(1)
                    Spacer()
                    Text(statusLabel.uppercased())
                        .font(.system(size: 7, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 39)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tool.tool), \(statusLabel), \(expanded ? "collapse" : "expand")")
            .accessibilityIdentifier("tool.\(tool.toolID).toggle")

            if expanded || tool.status == .awaitingPermission {
                VStack(alignment: .leading, spacing: 10) {
                    if !tool.detail.isEmpty {
                        ToolOutputText(text: tool.detail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(LocusTheme.paperDeep.opacity(0.65))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }

                    if let result = tool.result, !result.isEmpty {
                        if DiffDetector.isDiff(result) {
                            DiffTextView(text: result)
                        } else {
                            Text(result)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                                .lineLimit(14)
                                .textSelection(.enabled)
                        }
                    }

                    if tool.status == .awaitingPermission {
                        // The decision itself lives in the composer panel;
                        // the card only points there.
                        Label(
                            "Waiting for your decision in the composer below",
                            systemImage: "arrow.down.to.line"
                        )
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.warning)
                    }
                }
                .padding(11)
                .overlay(alignment: .top) {
                    Rectangle().fill(LocusTheme.line).frame(height: 1)
                }
            }
        }
        .locusCard(radius: 9)
    }

    private var statusSymbol: String {
        switch tool.status {
        case .awaitingPermission: "shield.lefthalf.filled.badge.checkmark"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .done: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .denied: "nosign"
        }
    }

    private var statusColor: Color {
        switch tool.status {
        case .awaitingPermission: LocusTheme.warning
        case .running: LocusTheme.blue
        case .done: LocusTheme.success
        case .error: LocusTheme.coral
        case .denied: LocusTheme.muted
        }
    }

    private var statusLabel: String {
        switch tool.status {
        case .awaitingPermission: "needs approval"
        case .running: "running"
        case .done: "done"
        case .error: "error"
        case .denied: "denied"
        }
    }
}
