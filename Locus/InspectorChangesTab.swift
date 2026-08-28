import SwiftUI

/// What actually changed on disk, from the workspace's git status — not what
/// the current conversation happened to touch.
struct InspectorChangesTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var gitWorkspace: GitWorkspaceModel
    @State private var newBranchPresented = false
    @State private var newBranchName = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            if gitWorkspace.gitChanges.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(gitWorkspace.gitChanges.enumerated()), id: \.element.id) { index, change in
                            GitChangeRow(
                                gitWorkspace: gitWorkspace,
                                change: change,
                                index: index,
                                isSelected: gitWorkspace.selectedChangePath == change.path
                            )
                            .environmentObject(model)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .accessibilityIdentifier("changes.scroll")

                commitArea
            }

            if gitWorkspace.isGitRepository, !GitRemoteFeatures.isAvailable {
                Text(
                    "Push and pull need your SSH agent, which the App Store sandbox "
                    + "cannot reach — use the direct build or a terminal. Locus never uses Keychain."
                )
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .accessibilityIdentifier("changes.remoteUnavailable")
            }
        }
        .task(id: model.workspacePath) {
            gitWorkspace.refreshStatus()
        }
        .alert(
            "Discard changes to \(gitWorkspace.pendingDiscard?.name ?? "this file")?",
            isPresented: Binding(
                get: { gitWorkspace.pendingDiscard != nil },
                set: { if !$0 { gitWorkspace.pendingDiscard = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { gitWorkspace.discardConfirmed() }
                .accessibilityIdentifier("changes.discard.confirm")
        } message: {
            Text(gitWorkspace.pendingDiscard?.status == .untracked
                ? "This file is not tracked by git — it will move to the Trash."
                : "Staged and unstaged edits to this file will be restored to the last committed version.")
        }
        .alert(
            "Discard this hunk?",
            isPresented: Binding(
                get: { gitWorkspace.pendingHunkDiscard != nil },
                set: { if !$0 { gitWorkspace.pendingHunkDiscard = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { gitWorkspace.discardHunkConfirmed() }
                .accessibilityIdentifier("changes.discardHunk.confirm")
        } message: {
            Text(
                "This hunk's edits will be removed from the file on disk. "
                + "This confirmation is the only recovery gate."
            )
        }
        .alert("New Branch", isPresented: $newBranchPresented) {
            TextField("Branch name", text: $newBranchName)
                .accessibilityIdentifier("changes.branch.create.input")
            Button("Cancel", role: .cancel) { newBranchName = "" }
            Button("Create") {
                gitWorkspace.createBranch(newBranchName)
                newBranchName = ""
            }
            .disabled(GitBranchName.validationError(newBranchName) != nil)
            .accessibilityIdentifier("changes.branch.create.confirm")
        } message: {
            Text("Created from the current HEAD; working-tree edits ride along.")
        }
    }

    /// Message field, AI draft, and commit — the write half of the tab.
    private var commitArea: some View {
        VStack(spacing: 8) {
            TextField("Commit message", text: $gitWorkspace.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.locus(size: 10))
                .lineLimit(1...3)
                .padding(8)
                .background(LocusTheme.paperDeep.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityIdentifier("changes.commitMessage")

            HStack(spacing: 8) {
                Button {
                    gitWorkspace.draftCommitMessage()
                } label: {
                    HStack(spacing: 5) {
                        if gitWorkspace.isDraftingCommitMessage {
                            ProgressView().controlSize(.mini)
                            Text("Drafting…")
                        } else {
                            Image(systemName: "wand.and.stars")
                            Text("Draft with AI")
                        }
                    }
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
                }
                .buttonStyle(.locus())
                .disabled(gitWorkspace.stagedChangeCount == 0 && !gitWorkspace.isDraftingCommitMessage)
                .help("Draft a message from the staged diff with the local model")
                .accessibilityIdentifier("changes.draftMessage")

                Spacer()

                Text("\(gitWorkspace.stagedChangeCount) staged")
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)

                Button("Commit") {
                    gitWorkspace.commitStaged()
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .controlSize(.small)
                .disabled(
                    gitWorkspace.stagedChangeCount == 0
                        || gitWorkspace.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || gitWorkspace.isPerformingGitAction
                )
                .accessibilityIdentifier("changes.commit")
            }
        }
        .padding(10)
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if gitWorkspace.isGitRepository {
                    branchControl
                } else {
                    Text("WORKING TREE")
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                }
                Text(gitWorkspace.gitChangeSummary)
                    .font(.locus(size: 11, weight: .bold))
                    .lineLimit(1)
                    .accessibilityIdentifier("changes.summary")
            }
            Spacer(minLength: 4)

            syncCluster

            if gitWorkspace.lastGitRefreshFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.warning)
                    .help("The last refresh failed — this list may be stale")
                    .accessibilityLabel("Change list may be stale")
                    .accessibilityIdentifier("changes.staleWarning")
            }
            if gitWorkspace.isRefreshingGitStatus {
                ProgressView().controlSize(.small)
            }
            Button {
                gitWorkspace.refreshStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.locus())
            .foregroundStyle(LocusTheme.muted)
            .help("Refresh from git")
            .accessibilityLabel("Refresh changes")
            .accessibilityIdentifier("changes.refresh")

            Button {
                model.openWorkspaceInFinder()
            } label: {
                Image(systemName: "folder")
                    .accessibilityHidden(true)
            }
            .buttonStyle(.locus())
            .foregroundStyle(LocusTheme.muted)
            .help("Reveal workspace in Finder")
            .accessibilityLabel("Reveal workspace in Finder")
            .accessibilityIdentifier("changes.reveal")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    /// The current branch as a switch/create menu; a detached HEAD renders
    /// the short SHA and the menu is disabled — there is no branch to leave.
    @ViewBuilder
    private var branchControl: some View {
        if gitWorkspace.gitDetached {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(gitWorkspace.gitBranch ?? "detached HEAD")
            }
            .font(.locus(size: 8, weight: .bold))
            .foregroundStyle(LocusTheme.muted)
            .help("Detached HEAD — check out a branch from a terminal to switch here")
            .accessibilityIdentifier("changes.branch")
        } else {
            Menu {
                ForEach(gitWorkspace.localBranches, id: \.self) { branch in
                    Button {
                        gitWorkspace.switchBranch(branch)
                    } label: {
                        if branch == gitWorkspace.gitBranch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                    .disabled(branch == gitWorkspace.gitBranch)
                }
                Divider()
                Button("New Branch…") { newBranchPresented = true }
                    .accessibilityIdentifier("changes.branch.create")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(gitWorkspace.gitBranch ?? "no branch")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.locus(size: 6, weight: .bold))
                }
                .font(.locus(size: 8, weight: .bold))
                .foregroundStyle(LocusTheme.muted)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Menus have no will-open hook; hover precedes the click that
            // opens one, so the list is fresh by the time it shows.
            .onHover { hovering in
                if hovering { gitWorkspace.loadLocalBranches() }
            }
            .disabled(gitWorkspace.isPerformingGitAction)
            .help("Switch or create a branch")
            .accessibilityLabel("Branch \(gitWorkspace.gitBranch ?? "unknown")")
            .accessibilityIdentifier("changes.branch")
        }
    }

    @ViewBuilder
    private var syncCluster: some View {
        if gitWorkspace.isGitRepository, !gitWorkspace.gitDetached {
            if gitWorkspace.gitAhead > 0 || gitWorkspace.gitBehind > 0 {
                Text("↑\(gitWorkspace.gitAhead) ↓\(gitWorkspace.gitBehind)")
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .help("\(gitWorkspace.gitAhead) to push, \(gitWorkspace.gitBehind) to pull")
                    .accessibilityIdentifier("changes.sync.counts")
            }
            if gitWorkspace.isSyncingRemote {
                ProgressView().controlSize(.mini)
            }
            if GitRemoteFeatures.isAvailable {
                headerButton(
                    symbol: "arrow.down.circle",
                    help: "Fetch from the remote",
                    identifier: "changes.fetch"
                ) { gitWorkspace.fetchRemote() }
                    .disabled(gitWorkspace.isSyncingRemote)
                headerButton(
                    symbol: "arrow.down.to.line",
                    help: "Pull (fast-forward only)",
                    identifier: "changes.pull"
                ) { gitWorkspace.pullFastForwardOnly() }
                    .disabled(gitWorkspace.isSyncingRemote || gitWorkspace.gitBehind == 0)
                headerButton(
                    symbol: "arrow.up.circle",
                    help: gitWorkspace.gitUpstream == nil
                        ? "Publish this branch to origin"
                        : "Push to \(gitWorkspace.gitUpstream ?? "the upstream")",
                    identifier: "changes.push"
                ) { gitWorkspace.pushCurrentBranch() }
                    .disabled(gitWorkspace.isSyncingRemote || !gitWorkspace.gitHasCommits)
            }
            if gitWorkspace.originIsGitHub, gitWorkspace.gitUpstream != nil {
                headerButton(
                    symbol: "arrow.triangle.pull",
                    help: "Open a pull request on GitHub",
                    identifier: "changes.pr"
                ) { gitWorkspace.openPullRequest() }
            }
        }
    }

    private func headerButton(
        symbol: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 10, weight: .semibold))
        }
        .buttonStyle(.locus())
        .foregroundStyle(LocusTheme.muted)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }

    private var emptyState: some View {
        InspectorPlaceholder(
            symbol: gitWorkspace.isGitRepository ? "checkmark.circle" : "doc.text.magnifyingglass",
            title: gitWorkspace.isGitRepository ? "Nothing changed" : "Not a git repository",
            message: gitWorkspace.isGitRepository
                ? "Edits to files in this workspace show up here, whoever made them."
                : "Changes are read from git. Initialize a repository to review edits here.",
            identifier: "changes.empty"
        )
    }
}

/// One changed file: status marker, path, line counts, stage/discard actions,
/// and its diff inline.
private struct GitChangeRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var gitWorkspace: GitWorkspaceModel
    let change: GitChange
    let index: Int
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    if isSelected {
                        gitWorkspace.clearSelection()
                    } else {
                        gitWorkspace.loadDiff(for: change)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(change.status.marker)
                            .font(.locus(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(markerColor)
                            .frame(width: 14)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.name)
                                .font(.locus(size: 10, weight: .semibold))
                                .foregroundStyle(LocusTheme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !change.directory.isEmpty {
                                Text(change.directory)
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.muted)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }

                        Spacer(minLength: 4)

                        if !showsActions, let summary = change.changeSummary {
                            Text(summary)
                                .font(.locus(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                            .font(.locus(size: 8, weight: .semibold))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.locus())
                .accessibilityLabel("\(change.status.rawValue) \(change.path)")
                .accessibilityIdentifier("changes.file.\(index)")

                if showsActions {
                    actionCluster
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .onHover { isHovering = $0 }

            if isSelected {
                Divider().overlay(LocusTheme.line)
                Group {
                    if change.staged, change.unstaged {
                        diffScopePicker
                    }
                    if let diff = gitWorkspace.selectedChangeDiff {
                        if let parsed = gitWorkspace.selectedChangeParsedDiff,
                           !parsed.hunks.isEmpty, !parsed.isRenameOrCopy {
                            hunkList(parsed)
                        } else {
                            // Bounded height, so this row's size does not
                            // change as the lazy stack materializes it.
                            DiffTextView(text: diff, maxHeight: 420)
                                .accessibilityIdentifier("changes.file.\(index).diff")
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading the diff…")
                                .font(.locus(size: 9))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                }
                .background(LocusTheme.ink.opacity(0.04))
            }
        }
        .background(isSelected ? LocusTheme.white : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? LocusTheme.line : Color.clear, lineWidth: 1)
        }
        .contextMenu {
            Button("Reveal in Finder") { model.revealInFinder(change.path) }
            Button("Copy Path") { model.copyMessage(change.path) }
            Button("Add to Context") { model.addWorkspaceFileToContext(change.path) }
        }
    }

    /// Visible on hover or selection — selection matters because hover alone
    /// is unreachable for accessibility and UI tests.
    private var showsActions: Bool {
        isHovering || isSelected
    }

    /// "Unstaged | Staged" for a file with both kinds of edits, so per-hunk
    /// actions always operate on the side the user is looking at.
    private var diffScopePicker: some View {
        Picker("Diff scope", selection: Binding(
            get: { gitWorkspace.selectedChangeShowsStaged },
            set: { gitWorkspace.loadDiff(for: change, staged: $0) }
        )) {
            Text("Unstaged").tag(false)
            Text("Staged").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .accessibilityIdentifier("changes.file.\(index).diffScope")
    }

    /// The parsed diff as one section per hunk, each with its own actions.
    /// Reverse-applying from the staged side would need `--cached` semantics
    /// the worktree copy may not match, so discard stays unstaged-only.
    private func hunkList(_ parsed: ParsedFileDiff) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(parsed.hunks.enumerated()), id: \.element.id) { position, hunk in
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text(hunk.header)
                            .font(.locus(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.blue)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // Keep the list marker on one leaf. Applying it to
                            // the outer VStack makes AppKit inherit that ID onto
                            // every hunk button and hides their stage/discard IDs.
                            .accessibilityIdentifier(
                                position == 0
                                    ? "changes.file.\(index).hunks"
                                    : "changes.file.\(index).hunk.\(position).header"
                            )
                        Spacer(minLength: 4)
                        if gitWorkspace.selectedChangeShowsStaged {
                            hunkButton(
                                symbol: "minus.circle",
                                help: "Unstage this hunk",
                                identifier: "changes.file.\(index).hunk.\(position).unstage"
                            ) { gitWorkspace.unstageHunk(hunk) }
                                .disabled(!gitWorkspace.gitHasCommits)
                        } else {
                            hunkButton(
                                symbol: "plus.circle",
                                help: "Stage this hunk",
                                identifier: "changes.file.\(index).hunk.\(position).stage"
                            ) { gitWorkspace.stageHunk(hunk) }
                            hunkButton(
                                symbol: "arrow.uturn.backward",
                                help: "Discard this hunk…",
                                identifier: "changes.file.\(index).hunk.\(position).discard"
                            ) { gitWorkspace.requestDiscardHunk(hunk) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(LocusTheme.paperDeep.opacity(0.5))
                    .focusable()

                    DiffTextView(
                        text: hunk.lines.joined(separator: "\n"),
                        maxHeight: 260
                    )
                }
                if position < parsed.hunks.count - 1 {
                    Divider().overlay(LocusTheme.line.opacity(0.6))
                }
            }
        }
        .disabled(gitWorkspace.isPerformingGitAction)
    }

    private func hunkButton(
        symbol: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }

    private var actionCluster: some View {
        HStack(spacing: 5) {
            if change.staged {
                actionButton(
                    symbol: "minus.circle",
                    help: "Unstage",
                    identifier: "changes.file.\(index).unstage"
                ) { gitWorkspace.unstageChange(change) }
            }
            if change.unstaged || change.status == .untracked {
                actionButton(
                    symbol: "plus.circle",
                    help: "Stage",
                    identifier: "changes.file.\(index).stage"
                ) { gitWorkspace.stageChange(change) }
            }
            actionButton(
                symbol: "arrow.uturn.backward",
                help: change.status == .untracked ? "Move to Trash…" : "Discard changes…",
                identifier: "changes.file.\(index).discard"
            ) { gitWorkspace.requestDiscard(change) }
        }
        .disabled(gitWorkspace.isPerformingGitAction)
    }

    private func actionButton(
        symbol: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }

    private var markerColor: Color {
        switch change.status {
        case .added, .untracked: LocusTheme.success
        case .deleted: LocusTheme.coral
        case .unmerged: LocusTheme.warning
        default: LocusTheme.blue
        }
    }
}
