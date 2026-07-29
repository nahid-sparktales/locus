import SwiftUI

/// What actually changed on disk, from the workspace's git status — not what
/// the current conversation happened to touch.
struct InspectorChangesTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.gitChanges.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(model.gitChanges.enumerated()), id: \.element.id) { index, change in
                            GitChangeRow(
                                change: change,
                                index: index,
                                isSelected: model.selectedChangePath == change.path
                            )
                            .environmentObject(model)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }

                commitArea
            }
        }
        .task(id: model.workspacePath) {
            model.refreshGitStatus()
        }
        .alert(
            "Discard changes to \(model.pendingDiscard?.name ?? "this file")?",
            isPresented: Binding(
                get: { model.pendingDiscard != nil },
                set: { if !$0 { model.pendingDiscard = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) { model.discardConfirmed() }
                .accessibilityIdentifier("changes.discard.confirm")
        } message: {
            Text(model.pendingDiscard?.status == .untracked
                ? "This file is not tracked by git — it will move to the Trash."
                : "Staged and unstaged edits to this file will be restored to the last committed version.")
        }
    }

    /// Message field, AI draft, and commit — the write half of the tab.
    private var commitArea: some View {
        VStack(spacing: 8) {
            TextField("Commit message", text: $model.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 10))
                .lineLimit(1...3)
                .padding(8)
                .background(LocusTheme.paperDeep.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityIdentifier("changes.commitMessage")

            HStack(spacing: 8) {
                Button {
                    model.draftCommitMessage()
                } label: {
                    HStack(spacing: 5) {
                        if model.isDraftingCommitMessage {
                            ProgressView().controlSize(.mini)
                            Text("Drafting…")
                        } else {
                            Image(systemName: "wand.and.stars")
                            Text("Draft with AI")
                        }
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
                }
                .buttonStyle(.plain)
                .disabled(model.stagedChangeCount == 0 && !model.isDraftingCommitMessage)
                .help("Draft a message from the staged diff with the local model")
                .accessibilityIdentifier("changes.draftMessage")

                Spacer()

                Text("\(model.stagedChangeCount) staged")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)

                Button("Commit") {
                    model.commitStaged()
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .controlSize(.small)
                .disabled(
                    model.stagedChangeCount == 0
                        || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isPerformingGitAction
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
                Text("WORKING TREE")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(LocusTheme.muted)
                Text(model.gitChangeSummary)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .accessibilityIdentifier("changes.summary")
            }
            Spacer(minLength: 4)

            if model.lastGitRefreshFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.warning)
                    .help("The last refresh failed — this list may be stale")
                    .accessibilityLabel("Change list may be stale")
                    .accessibilityIdentifier("changes.staleWarning")
            }
            if model.isRefreshingGitStatus {
                ProgressView().controlSize(.small)
            }
            Button {
                model.refreshGitStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(LocusTheme.muted)
            .help("Refresh from git")
            .accessibilityLabel("Refresh changes")
            .accessibilityIdentifier("changes.refresh")

            Button {
                model.openWorkspaceInFinder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
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

    private var emptyState: some View {
        InspectorPlaceholder(
            symbol: model.isGitRepository ? "checkmark.circle" : "doc.text.magnifyingglass",
            title: model.isGitRepository ? "Nothing changed" : "Not a git repository",
            message: model.isGitRepository
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
    let change: GitChange
    let index: Int
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    if isSelected {
                        model.clearSelectedChange()
                    } else {
                        model.loadDiff(for: change)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(change.status.marker)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(markerColor)
                            .frame(width: 14)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LocusTheme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !change.directory.isEmpty {
                                Text(change.directory)
                                    .font(.system(size: 8))
                                    .foregroundStyle(LocusTheme.muted)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }

                        Spacer(minLength: 4)

                        if !showsActions, let summary = change.changeSummary {
                            Text(summary)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                    if let diff = model.selectedChangeDiff {
                        // Bounded height, so this row's size does not change
                        // as the enclosing lazy stack materializes it.
                        DiffTextView(text: diff, maxHeight: 420)
                            .accessibilityIdentifier("changes.file.\(index).diff")
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading the diff…")
                                .font(.system(size: 9))
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

    private var actionCluster: some View {
        HStack(spacing: 5) {
            if change.staged {
                actionButton(
                    symbol: "minus.circle",
                    help: "Unstage",
                    identifier: "changes.file.\(index).unstage"
                ) { model.unstageChange(change) }
            }
            if change.unstaged || change.status == .untracked {
                actionButton(
                    symbol: "plus.circle",
                    help: "Stage",
                    identifier: "changes.file.\(index).stage"
                ) { model.stageChange(change) }
            }
            actionButton(
                symbol: "arrow.uturn.backward",
                help: change.status == .untracked ? "Move to Trash…" : "Discard changes…",
                identifier: "changes.file.\(index).discard"
            ) { model.requestDiscard(change) }
        }
        .disabled(model.isPerformingGitAction)
    }

    private func actionButton(
        symbol: String,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
