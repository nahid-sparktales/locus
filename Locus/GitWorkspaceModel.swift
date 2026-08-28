import Combine
import Foundation

/// Feature-owned state for source-control inspection and quick actions.
///
/// AppModel temporarily forwards these values while callers migrate to this
/// boundary. Keeping the asynchronous work handles here prevents a future
/// workspace switch from leaving Git tasks owned by the application root.
@MainActor
final class GitWorkspaceModel: ObservableObject {
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
}
