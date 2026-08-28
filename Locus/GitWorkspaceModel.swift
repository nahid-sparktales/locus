import AppKit
import Combine
import Foundation

/// Feature-owned state for source-control inspection and quick actions.
///
/// AppModel temporarily forwards these values while callers migrate to this
/// boundary. Keeping the asynchronous work handles here prevents a future
/// workspace switch from leaving Git tasks owned by the application root.
@MainActor
final class GitWorkspaceModel: ObservableObject {
    struct CommitDraftContext {
        let useLocalModel: Bool
        let host: String
        let modelName: String
    }

    @Published var gitChanges: [GitChange] = []
    @Published var isRefreshingGitStatus = false
    @Published var isGitRepository = false
    @Published var lastGitRefreshFailed = false
    @Published var commitMessage = ""
    @Published var isPerformingGitAction = false
    @Published var isDraftingCommitMessage = false
    @Published var pendingDiscard: GitChange?
    @Published var changesHaveUnseenUpdate = false
    @Published var selectedChangePath: String?
    @Published var selectedChangeDiff: String?
    @Published var selectedChangeParsedDiff: ParsedFileDiff?
    @Published var selectedChangeShowsStaged = false
    @Published var gitUpstream: String?
    @Published var gitAhead = 0
    @Published var gitBehind = 0
    @Published var gitDetached = false
    @Published var gitHasCommits = true
    @Published var localBranches: [String] = []
    @Published var pendingHunkDiscard: DiffHunk?
    @Published var isSyncingRemote = false
    @Published var originIsGitHub = false
    @Published var gitBranch: String?

    var originCheckedForWorkspace: String?
    var statusTask: Task<Void, Never>?
    var diffTask: Task<Void, Never>?
    var commitDraftTask: Task<Void, Never>?

    private var backend: BackendService?
    private var isUITesting = false
    private var workspacePathProvider: () -> String = {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
    private var changesTabVisibleProvider: () -> Bool = { false }
    private var commitDraftContextProvider: () -> CommitDraftContext = {
        CommitDraftContext(useLocalModel: false, host: "", modelName: "")
    }
    private var toastHandler: (String) -> Void = { _ in }
    private var statusHandler: ([String: GitChange], [GitChange]) -> Void = { _, _ in }

    func configure(
        backend: BackendService,
        isUITesting: Bool,
        workspacePath: @escaping () -> String,
        changesTabVisible: @escaping () -> Bool,
        commitDraftContext: @escaping () -> CommitDraftContext,
        showToast: @escaping (String) -> Void,
        didApplyStatus: @escaping ([String: GitChange], [GitChange]) -> Void
    ) {
        self.backend = backend
        self.isUITesting = isUITesting
        workspacePathProvider = workspacePath
        changesTabVisibleProvider = changesTabVisible
        commitDraftContextProvider = commitDraftContext
        toastHandler = showToast
        statusHandler = didApplyStatus
    }

    var changedFileCount: Int { gitChanges.count }

    var gitChangeSummary: String {
        guard !gitChanges.isEmpty else { return "No changes" }
        var parts: [String] = []
        let staged = gitChanges.filter(\.staged).count
        let unstaged = gitChanges.filter { $0.unstaged && $0.status != .untracked }.count
        let untracked = gitChanges.filter { $0.status == .untracked }.count
        if staged > 0 { parts.append("\(staged) staged") }
        if unstaged > 0 { parts.append("\(unstaged) modified") }
        if untracked > 0 { parts.append("\(untracked) untracked") }
        return parts.joined(separator: " · ")
    }

    var stagedChangeCount: Int {
        gitChanges.filter(\.staged).count
    }

    private var workspacePath: String { workspacePathProvider() }

    private var gitClient: GitClient {
        GitClient(workspaceRoot: workspacePath)
    }

    func refreshBranch() {
        let root = workspacePath
        Task { [weak self] in
            let branch = await Task.detached(priority: .utility) {
                Self.branch(at: root)
            }.value
            guard let self, self.workspacePath == root else { return }
            gitBranch = branch
        }
    }

    nonisolated static func branch(at root: String) -> String? {
        var gitURL = URL(fileURLWithPath: root).appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        if !isDirectory.boolValue {
            guard let pointer = try? String(contentsOf: gitURL, encoding: .utf8),
                  let path = pointer
                      .split(separator: "\n")
                      .first(where: { $0.hasPrefix("gitdir:") })?
                      .dropFirst("gitdir:".count)
                      .trimmingCharacters(in: .whitespaces)
            else { return nil }
            gitURL = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: root).appending(path: path).standardizedFileURL
        }
        guard let head = try? String(
            contentsOf: gitURL.appending(path: "HEAD"),
            encoding: .utf8
        ) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
    }

    /// Reloads the workspace's git status. Overlapping requests collapse onto
    /// the newest workspace and request generation.
    func refreshStatus() {
        guard !isUITesting, let backend else { return }
        statusTask?.cancel()
        let root = workspacePath
        isRefreshingGitStatus = true
        statusTask = Task { [weak self, backend] in
            defer { if !Task.isCancelled { self?.isRefreshingGitStatus = false } }
            do {
                let response = try await backend.get(
                    "/api/git/status",
                    query: [URLQueryItem(name: "untracked", value: "all")],
                    as: GitStatusResponse.self
                )
                guard !Task.isCancelled, let self, self.workspacePath == root else { return }
                applyStatus(response)
            } catch {
                guard !Task.isCancelled, let self, self.workspacePath == root else { return }
                applyStatusFailure()
            }
        }
    }

    func applyStatus(_ response: GitStatusResponse) {
        let previous = Set(gitChanges.map(\.path))
        let previousChanges = Dictionary(uniqueKeysWithValues: gitChanges.map { ($0.path, $0) })
        gitChanges = response.files
        isGitRepository = response.isRepo
        lastGitRefreshFailed = false
        if response.isRepo, let branch = response.branch {
            gitBranch = branch
        }
        gitUpstream = response.upstream
        gitAhead = response.ahead ?? 0
        gitBehind = response.behind ?? 0
        gitDetached = response.detached
        gitHasCommits = response.hasCommits
        if response.isRepo, originCheckedForWorkspace != workspacePath {
            originCheckedForWorkspace = workspacePath
            refreshOriginKind()
        }
        if Self.changesAreUnseen(
            previous: previous,
            current: response.files,
            changesTabVisible: changesTabVisibleProvider()
        ) {
            changesHaveUnseenUpdate = true
        }
        statusHandler(previousChanges, response.files)
    }

    func applyStatusFailure() {
        lastGitRefreshFailed = true
    }

    func stageChange(_ change: GitChange) {
        performGitAction(["add", "--", change.path])
    }

    func unstageChange(_ change: GitChange) {
        performGitAction(
            ["restore", "--staged", "--", change.path],
            fallback: ["rm", "--cached", "-q", "--", change.path]
        )
    }

    func requestDiscard(_ change: GitChange) {
        pendingDiscard = change
    }

    func discardConfirmed() {
        guard let change = pendingDiscard else { return }
        pendingDiscard = nil
        if change.status == .untracked {
            let url = URL(fileURLWithPath: workspacePath).appending(path: change.path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                toastHandler("Moved \(change.name) to the Trash")
            } catch {
                toastHandler(error.localizedDescription)
            }
            refreshStatus()
        } else {
            performGitAction(
                ["restore", "--staged", "--worktree", "--", change.path],
                success: "Discarded changes to \(change.name)"
            )
        }
    }

    func loadLocalBranches() {
        guard isGitRepository else { return }
        let client = gitClient
        Task { [weak self] in
            let result = try? await client.run([
                "for-each-ref", "refs/heads",
                "--format=%(refname:short)", "--sort=-committerdate",
            ])
            guard let self, let result else { return }
            localBranches = result.stdout
                .split(separator: "\n")
                .prefix(100)
                .map(String.init)
        }
    }

    func createBranch(_ name: String) {
        let branch = name.trimmingCharacters(in: .whitespaces)
        if let problem = GitBranchName.validationError(branch) {
            toastHandler(problem)
            return
        }
        guard isGitRepository, !isPerformingGitAction else { return }
        isPerformingGitAction = true
        let client = gitClient
        Task { [weak self] in
            do {
                try await client.run(["check-ref-format", "--branch", branch])
                try await client.run(["switch", "-c", branch])
                self?.toastHandler("Created and switched to \(branch)")
            } catch {
                self?.toastHandler(error.localizedDescription)
            }
            self?.isPerformingGitAction = false
            self?.refreshStatus()
        }
    }

    func switchBranch(_ name: String) {
        guard isGitRepository, !isPerformingGitAction, name != gitBranch else { return }
        performGitAction(["switch", name], success: "Switched to \(name)")
    }

    func pushCurrentBranch() {
        guard GitRemoteFeatures.isAvailable, isGitRepository,
              !gitDetached, gitHasCommits, !isSyncingRemote,
              let branch = gitBranch
        else { return }
        isSyncingRemote = true
        let client = gitClient
        let args = GitPushPlan.arguments(branch: branch, upstream: gitUpstream)
        Task { [weak self] in
            do {
                try await client.run(args, timeout: 120)
                self?.toastHandler(
                    self?.gitUpstream == nil ? "Published \(branch)" : "Pushed \(branch)"
                )
            } catch {
                var message = error.localizedDescription
                if message.contains("rejected") || message.contains("non-fast-forward") {
                    message += " — Fetch/pull first, or push from a terminal."
                }
                self?.toastHandler(message)
            }
            self?.isSyncingRemote = false
            self?.refreshStatus()
        }
    }

    func fetchRemote() {
        guard GitRemoteFeatures.isAvailable, isGitRepository, !isSyncingRemote else { return }
        isSyncingRemote = true
        let client = gitClient
        Task { [weak self] in
            do {
                try await client.run(["fetch"], timeout: 60)
                self?.toastHandler("Fetched from the remote")
            } catch {
                self?.toastHandler(error.localizedDescription)
            }
            self?.isSyncingRemote = false
            self?.refreshStatus()
        }
    }

    func pullFastForwardOnly() {
        guard GitRemoteFeatures.isAvailable, isGitRepository, !isSyncingRemote else { return }
        isSyncingRemote = true
        let client = gitClient
        Task { [weak self] in
            do {
                let result = try await client.run(["pull", "--ff-only"], timeout: 120)
                let summary = result.stdout.split(separator: "\n").last.map(String.init)
                self?.toastHandler(summary?.nilIfEmpty ?? "Pulled fast-forward")
            } catch {
                self?.toastHandler(error.localizedDescription)
            }
            self?.isSyncingRemote = false
            self?.refreshStatus()
        }
    }

    func openPullRequest() {
        guard let branch = gitBranch else { return }
        let client = gitClient
        Task { [weak self] in
            guard let remote = try? await client.run(["remote", "get-url", "origin"]),
                  let url = GitRemoteURL.githubCompareURL(
                      remote: remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                      branch: branch
                  )
            else {
                self?.toastHandler("The origin remote is not a GitHub repository")
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    func refreshOriginKind() {
        guard isGitRepository else { return }
        let client = gitClient
        Task { [weak self] in
            let remote = (try? await client.run(["remote", "get-url", "origin"]))?
                .stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let self else { return }
            originIsGitHub = GitRemoteURL.githubCompareURL(remote: remote, branch: "x") != nil
        }
    }

    func stageHunk(_ hunk: DiffHunk) {
        performHunkAction(hunk, scope: .unstaged, apply: ["apply", "--cached"])
    }

    func unstageHunk(_ hunk: DiffHunk) {
        guard gitHasCommits else { return }
        performHunkAction(hunk, scope: .staged, apply: ["apply", "--cached", "-R"])
    }

    func requestDiscardHunk(_ hunk: DiffHunk) {
        pendingHunkDiscard = hunk
    }

    func discardHunkConfirmed() {
        guard let hunk = pendingHunkDiscard else { return }
        pendingHunkDiscard = nil
        performHunkAction(hunk, scope: .unstaged, apply: ["apply", "-R"])
    }

    private enum HunkScope {
        case staged
        case unstaged
    }

    private func performHunkAction(
        _ hunk: DiffHunk,
        scope: HunkScope,
        apply applyArgs: [String]
    ) {
        guard isGitRepository, !isPerformingGitAction,
              let path = selectedChangePath,
              let change = gitChanges.first(where: { $0.path == path })
        else { return }
        isPerformingGitAction = true
        let client = gitClient
        let diffArgs = scope == .staged
            ? ["diff", "-U3", "--cached", "--", path]
            : ["diff", "-U3", "--", path]
        Task { [weak self] in
            defer {
                self?.isPerformingGitAction = false
                self?.refreshStatus()
                self?.loadDiff(for: change)
            }
            do {
                let fresh = try await client.run(diffArgs)
                guard let parsed = ParsedFileDiff.parse(fresh.stdout),
                      let located = parsed.matching(hunk),
                      let patch = parsed.minimalPatch(for: located)
                else {
                    self?.toastHandler(
                        "That change moved since the diff was read — review the refreshed diff"
                    )
                    return
                }
                do {
                    try await client.run(applyArgs, stdin: Data(patch.utf8))
                } catch {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    try await client.run(applyArgs, stdin: Data(patch.utf8))
                }
            } catch {
                self?.toastHandler(error.localizedDescription)
            }
        }
    }

    func commitStaged() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, stagedChangeCount > 0, !isPerformingGitAction else { return }
        isPerformingGitAction = true
        let client = gitClient
        Task { [weak self] in
            do {
                let result = try await client.run(["commit", "-m", message])
                self?.commitMessage = ""
                let summary = result.stdout
                    .split(separator: "\n")
                    .first.map(String.init) ?? "Committed"
                self?.toastHandler(summary)
            } catch {
                self?.toastHandler(error.localizedDescription)
            }
            self?.isPerformingGitAction = false
            self?.refreshStatus()
        }
    }

    func draftCommitMessage() {
        if isDraftingCommitMessage {
            commitDraftTask?.cancel()
            isDraftingCommitMessage = false
            return
        }
        let staged = gitChanges.filter(\.staged)
        guard !staged.isEmpty else {
            toastHandler("Stage a file first — the draft describes staged changes")
            return
        }
        isDraftingCommitMessage = true
        let client = gitClient
        let context = commitDraftContextProvider()
        commitDraftTask = Task { [weak self] in
            var draft: String?
            if context.useLocalModel {
                let stat = (try? await client.run(["diff", "--cached", "--stat"]))?.stdout ?? ""
                let diff = (try? await client.run(["diff", "--cached"]))?.stdout ?? ""
                draft = await CommitMessageDrafter.draft(
                    host: context.host,
                    model: context.modelName,
                    stat: stat,
                    diff: String(diff.prefix(8_000))
                )
            }
            guard let self, !Task.isCancelled else { return }
            if draft == nil {
                draft = CommitMessageDrafter.template(for: staged)
                toastHandler(context.useLocalModel
                    ? "The local model could not draft — used a summary instead"
                    : "Drafted a summary — an AI draft needs local Ollama")
            }
            if let draft, !draft.isEmpty {
                commitMessage = draft
            }
            isDraftingCommitMessage = false
        }
    }

    private func performGitAction(
        _ args: [String],
        fallback: [String]? = nil,
        success: String? = nil
    ) {
        guard isGitRepository, !isPerformingGitAction else { return }
        isPerformingGitAction = true
        let client = gitClient
        Task { [weak self] in
            do {
                do {
                    try await client.run(args)
                } catch {
                    guard let fallback else { throw error }
                    try await client.run(fallback)
                }
                if let success { self?.toastHandler(success) }
            } catch {
                self?.toastHandler(error.localizedDescription)
            }
            self?.isPerformingGitAction = false
            self?.refreshStatus()
        }
    }

    nonisolated static func changesAreUnseen(
        previous: Set<String>,
        current: [GitChange],
        changesTabVisible: Bool
    ) -> Bool {
        guard !changesTabVisible else { return false }
        return current.contains { !previous.contains($0.path) }
    }

    func clearSelection() {
        diffTask?.cancel()
        selectedChangePath = nil
        selectedChangeDiff = nil
        selectedChangeParsedDiff = nil
    }

    func loadDiff(for change: GitChange, staged: Bool? = nil) {
        if let staged {
            selectedChangeShowsStaged = staged
        } else if selectedChangePath != change.path {
            selectedChangeShowsStaged = change.staged && !change.unstaged
        }
        selectedChangePath = change.path
        selectedChangeDiff = nil
        selectedChangeParsedDiff = nil
        diffTask?.cancel()
        guard !isUITesting else {
            seedUITestDiff(for: change)
            return
        }
        guard let backend else { return }
        let wantsStaged = change.staged && (!change.unstaged || selectedChangeShowsStaged)
        diffTask = Task { [weak self, backend] in
            do {
                let response = try await backend.get(
                    "/api/git/diff",
                    query: [
                        URLQueryItem(name: "path", value: change.path),
                        URLQueryItem(name: "staged", value: wantsStaged ? "true" : "false"),
                    ],
                    as: GitDiffResponse.self
                )
                guard !Task.isCancelled, let self else { return }
                guard selectedChangePath == change.path else { return }
                selectedChangeDiff = Self.cappedDiff(response)
                if !response.truncated, !response.binary, let raw = response.raw {
                    selectedChangeParsedDiff = ParsedFileDiff.parse(raw)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.selectedChangeDiff = "Could not load the diff: \(error.localizedDescription)"
            }
        }
    }

    nonisolated static func cappedDiff(
        _ response: GitDiffResponse,
        maxLines: Int = 2_000
    ) -> String {
        if response.binary { return "Binary file — no textual diff." }
        guard let raw = response.raw, !raw.isEmpty else {
            return response.ok ? "No changes to show." : "Could not load the diff."
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else {
            return response.truncated ? raw + "\n… diff truncated by the agent." : raw
        }
        return lines.prefix(maxLines).joined(separator: "\n")
            + "\n… \(lines.count - maxLines) more lines — open the file to see the rest."
    }

    private func seedUITestDiff(for change: GitChange) {
        let raw = """
        diff --git a/\(change.path) b/\(change.path)
        index 1111111..2222222 100644
        --- a/\(change.path)
        +++ b/\(change.path)
        @@ -1,3 +1,3 @@
         let first = 1
        -let second = 2
        +let second = 22
         let third = 3
        @@ -10,3 +10,3 @@
         let tenth = 10
        -let eleventh = 11
        +let eleventh = 111
         let twelfth = 12
        """
        selectedChangeDiff = raw
        selectedChangeParsedDiff = ParsedFileDiff.parse(raw)
    }
}
