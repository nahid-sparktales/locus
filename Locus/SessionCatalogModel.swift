import Combine
import Foundation
import os

struct SessionSidebarFolderSnapshot: Identifiable, Equatable {
    let folder: ChatFolderRecord
    let children: [SessionSidebarFolderSnapshot]
    let chats: [SessionSummary]

    var id: String { folder.id }
}

struct SessionSidebarGroupSnapshot: Identifiable, Equatable {
    let group: WorkspaceChatGroup
    let rootFolders: [SessionSidebarFolderSnapshot]
    let unfiledChats: [SessionSummary]

    var id: String { group.id }
}

struct SessionCatalogSnapshot: Equatable {
    let sessions: [SessionSummary]
    let chatFolders: [ChatFolderRecord]
    let workspaceProfiles: [WorkspaceProfile]
    let sessionsByID: [String: SessionSummary]
    let foldersByID: [String: ChatFolderRecord]
    let workspaceIDBySessionID: [String: String]
    let foldersByWorkspaceID: [String: [ChatFolderRecord]]
    let folderMoveTargetsByFolderID: [String: [ChatFolderRecord]]
    let recentWorkspaceProfiles: [WorkspaceProfile]
    let availableWorkspaceIDs: Set<String>
    let workspaceAvailabilityByProfileID: [String: Bool]
    let availableExecutionSessionIDs: Set<String>
    let filteredSessions: [SessionSummary]
    let sidebarGroups: [SessionSidebarGroupSnapshot]
    let activeWorkspaceID: String
    let showArchivedSessions: Bool
    let searchQuery: String
    let expandedWorkspaceIDs: Set<String>
    let expandedChatFolderIDs: Set<String>
    let sidebarSearchFocusToken: UUID

    static let empty = SessionCatalogSnapshot(
        sessions: [],
        chatFolders: [],
        workspaceProfiles: [],
        sessionsByID: [:],
        foldersByID: [:],
        workspaceIDBySessionID: [:],
        foldersByWorkspaceID: [:],
        folderMoveTargetsByFolderID: [:],
        recentWorkspaceProfiles: [],
        availableWorkspaceIDs: [],
        workspaceAvailabilityByProfileID: [:],
        availableExecutionSessionIDs: [],
        filteredSessions: [],
        sidebarGroups: [],
        activeWorkspaceID: "",
        showArchivedSessions: false,
        searchQuery: "",
        expandedWorkspaceIDs: [],
        expandedChatFolderIDs: [],
        sidebarSearchFocusToken: UUID()
    )
}

/// Authoritative session/sidebar state. It publishes one complete, immutable
/// snapshot only when catalog inputs change, so SwiftUI never rebuilds the
/// workspace hierarchy while evaluating an unrelated AppModel publication.
@MainActor
final class SessionCatalogModel: ObservableObject {
    typealias FileExists = (String) -> Bool
    static let otherWorkspaceID = "locus.other-chats"

    private struct State: Equatable {
        var sessions: [SessionSummary] = []
        var chatFolders: [ChatFolderRecord] = []
        var workspaceProfiles: [WorkspaceProfile] = []
        var activeWorkspaceID = ""
        var showArchivedSessions = false
        var searchQuery = ""
        var expandedWorkspaceIDs: Set<String> = []
        var expandedChatFolderIDs: Set<String> = []
        var sidebarSearchFocusToken = UUID()
    }

    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "io.sparktales.locus",
        category: "Session Catalog"
    )

    @Published private(set) var snapshot = SessionCatalogSnapshot.empty

    /// Deterministic structural metric used by tests. Timings stay advisory;
    /// this counter is the CI gate for accidental rebuilds.
#if DEBUG
    private(set) var snapshotBuildCountForTesting = 0
#endif

    private var state = State()
    private let fileExists: FileExists
    private var persistenceEnabled = false
    private var defaults: UserDefaults = .standard
    private var searchQueryDidChange: (String) -> Void = { _ in }

    init(fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) }) {
        self.fileExists = fileExists
        rebuildSnapshot()
    }

    func configure(
        persistenceEnabled: Bool,
        defaults: UserDefaults = .standard,
        searchQueryDidChange: @escaping (String) -> Void
    ) {
        self.persistenceEnabled = persistenceEnabled
        self.defaults = defaults
        self.searchQueryDidChange = searchQueryDidChange
        guard persistenceEnabled else { return }
        commit { state in
            state.expandedWorkspaceIDs = Set(
                defaults.stringArray(forKey: "Locus.expandedWorkspaces") ?? []
            )
            state.expandedChatFolderIDs = Set(
                defaults.stringArray(forKey: "Locus.expandedChatFolders") ?? []
            )
        }
    }

    func replaceRemoteCatalog(
        sessions: [SessionSummary],
        chatFolders: [ChatFolderRecord]?
    ) {
        commit { state in
            state.sessions = sessions
            if let chatFolders { state.chatFolders = chatFolders }
        }
    }

    func replaceSessions(_ sessions: [SessionSummary]) {
        commit { $0.sessions = sessions }
    }

    func replaceChatFolders(_ folders: [ChatFolderRecord]) {
        commit { $0.chatFolders = folders }
    }

    func replaceWorkspaceProfiles(_ profiles: [WorkspaceProfile]) {
        commit { $0.workspaceProfiles = profiles }
    }

    func replaceExpandedWorkspaceIDs(_ ids: Set<String>) {
        commit { $0.expandedWorkspaceIDs = ids }
    }

    func replaceExpandedChatFolderIDs(_ ids: Set<String>) {
        commit { $0.expandedChatFolderIDs = ids }
    }

    func setActiveWorkspacePath(_ path: String) {
        let canonical = path.isEmpty ? "" : SessionSummary.canonicalWorkspacePath(path)
        commit { $0.activeWorkspaceID = canonical }
    }

    func setShowArchivedSessions(_ value: Bool) {
        commit { $0.showArchivedSessions = value }
    }

    func setSearchQuery(_ value: String) {
        let previous = state.searchQuery
        commit { $0.searchQuery = value }
        if value != previous { searchQueryDidChange(value) }
    }

    func requestSearchFocus() {
        commit { $0.sidebarSearchFocusToken = UUID() }
    }

    func replaceSidebarSearchFocusToken(_ token: UUID) {
        commit { $0.sidebarSearchFocusToken = token }
    }

    func setWorkspaceExpanded(_ id: String, expanded: Bool) {
        let changed = commit { state in
            if expanded {
                state.expandedWorkspaceIDs.insert(id)
            } else {
                state.expandedWorkspaceIDs.remove(id)
            }
        }
        if changed { persistExpansionState() }
    }

    func setChatFolderExpanded(_ id: String, expanded: Bool) {
        let changed = commit { state in
            if expanded {
                state.expandedChatFolderIDs.insert(id)
            } else {
                state.expandedChatFolderIDs.remove(id)
            }
        }
        if changed { persistExpansionState() }
    }

    func persistExpansionState() {
        guard persistenceEnabled else { return }
        defaults.set(
            Array(state.expandedWorkspaceIDs).sorted(),
            forKey: "Locus.expandedWorkspaces"
        )
        defaults.set(
            Array(state.expandedChatFolderIDs).sorted(),
            forKey: "Locus.expandedChatFolders"
        )
    }

    @discardableResult
    private func commit(_ update: (inout State) -> Void) -> Bool {
        let previous = state
        update(&state)
        guard state != previous else { return false }
        rebuildSnapshot()
        return true
    }

    private func rebuildSnapshot() {
        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "Build Sidebar Snapshot",
            id: signpostID,
            "sessions=\(self.state.sessions.count) folders=\(self.state.chatFolders.count)"
        )
        defer { Self.signposter.endInterval("Build Sidebar Snapshot", interval) }

#if DEBUG
        snapshotBuildCountForTesting += 1
#endif
        snapshot = Self.makeSnapshot(state: state, fileExists: fileExists)
    }

    private static func makeSnapshot(
        state: State,
        fileExists: FileExists
    ) -> SessionCatalogSnapshot {
        let query = state.searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let archiveFiltered = state.sessions
            .filter { state.showArchivedSessions || !$0.isArchived }
            .sorted(by: sessionSort)

        let filteredSessions: [SessionSummary]
        if query.isEmpty {
            filteredSessions = archiveFiltered
        } else {
            let directlyMatchingFolders = Set(state.chatFolders.filter {
                $0.name.lowercased().contains(query)
            }.map(\.id))
            var matchingFolderTree = directlyMatchingFolders
            var changed = true
            while changed {
                changed = false
                for folder in state.chatFolders
                where folder.parentID.map(matchingFolderTree.contains) == true {
                    if matchingFolderTree.insert(folder.id).inserted { changed = true }
                }
            }
            filteredSessions = archiveFiltered.filter {
                "\($0.displayTitle) \($0.name)".lowercased().contains(query)
                    || $0.folderID.map(matchingFolderTree.contains) == true
            }
        }

        let workspaceIDBySessionID = Dictionary(
            state.sessions.compactMap { session in
                session.workspacePath.map { (session.id, $0) }
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        var chatsByPath = Dictionary(
            grouping: filteredSessions.compactMap { session -> (String, SessionSummary)? in
                guard let path = workspaceIDBySessionID[session.id] else { return nil }
                return (path, session)
            },
            by: \.0
        ).mapValues { $0.map(\.1) }

        var profilesByPath: [String: WorkspaceProfile] = [:]
        for profile in state.workspaceProfiles {
            let path = SessionSummary.canonicalWorkspacePath(profile.path)
            if let existing = profilesByPath[path], existing.lastOpened >= profile.lastOpened {
                continue
            }
            profilesByPath[path] = profile
        }
        let foldersByID = Dictionary(
            state.chatFolders.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
        let foldersByWorkspaceID = Dictionary(
            grouping: state.chatFolders,
            by: { SessionSummary.canonicalWorkspacePath($0.workspace) }
        ).mapValues { folders in
            folders.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        var folderMoveTargetsByFolderID: [String: [ChatFolderRecord]] = [:]
        for folder in state.chatFolders {
            let workspaceID = SessionSummary.canonicalWorkspacePath(folder.workspace)
            folderMoveTargetsByFolderID[folder.id] = (foldersByWorkspaceID[workspaceID] ?? [])
                .filter {
                    canMoveFolder(folder, into: $0, foldersByID: foldersByID)
                }
        }
        let availableExecutionSessionIDs: Set<String> = Set(
            state.sessions.compactMap { session -> String? in
                guard session.executionEnvironment == .worktree,
                      let task = session.task,
                      fileExists(task.executionPath)
                else { return nil }
                return session.id
            }
        )

        var paths = Set(profilesByPath.keys)
        paths.formUnion(chatsByPath.keys)
        if !state.activeWorkspaceID.isEmpty { paths.insert(state.activeWorkspaceID) }

        let availableWorkspaceIDs = Set(paths.filter(fileExists))
        var sidebarGroups = paths.compactMap { path -> SessionSidebarGroupSnapshot? in
            let chats = (chatsByPath.removeValue(forKey: path) ?? []).sorted(by: sessionSort)
            let workspaceFolders = foldersByWorkspaceID[path] ?? []
            let folderNameMatches = !query.isEmpty && workspaceFolders.contains {
                $0.name.localizedCaseInsensitiveContains(query)
            }
            if !query.isEmpty && chats.isEmpty && !folderNameMatches { return nil }

            let profile = profilesByPath[path]
            let chatDate = chats.map(\.date).max() ?? .distantPast
            let isAvailable = availableWorkspaceIDs.contains(path)
            let group = WorkspaceChatGroup(
                id: path,
                path: path,
                title: URL(fileURLWithPath: path).lastPathComponent,
                chats: chats,
                lastOpened: max(profile?.lastOpened ?? .distantPast, chatDate),
                isAvailable: isAvailable,
                isOther: false
            )
            return SessionSidebarGroupSnapshot(
                group: group,
                rootFolders: folderTree(
                    folders: workspaceFolders,
                    chats: chats,
                    parentID: nil,
                    query: query
                ),
                unfiledChats: sortedChats(chats.filter { $0.folderID == nil })
            )
        }
        sidebarGroups.sort { lhs, rhs in
            if lhs.id == state.activeWorkspaceID { return true }
            if rhs.id == state.activeWorkspaceID { return false }
            return lhs.group.lastOpened > rhs.group.lastOpened
        }

        let otherChats = filteredSessions
            .filter { workspaceIDBySessionID[$0.id] == nil }
            .sorted(by: sessionSort)
        if !otherChats.isEmpty {
            let group = WorkspaceChatGroup(
                id: otherWorkspaceID,
                path: nil,
                title: "Other Chats",
                chats: otherChats,
                lastOpened: otherChats.map(\.date).max() ?? .distantPast,
                isAvailable: true,
                isOther: true
            )
            sidebarGroups.append(SessionSidebarGroupSnapshot(
                group: group,
                rootFolders: [],
                unfiledChats: sortedChats(otherChats)
            ))
        }

        let workspaceAvailabilityByProfileID = Dictionary(
            state.workspaceProfiles.map { profile in
                let workspaceID = SessionSummary.canonicalWorkspacePath(profile.path)
                return (profile.id, availableWorkspaceIDs.contains(workspaceID))
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        return SessionCatalogSnapshot(
            sessions: state.sessions,
            chatFolders: state.chatFolders,
            workspaceProfiles: state.workspaceProfiles,
            sessionsByID: Dictionary(
                state.sessions.map { ($0.id, $0) },
                uniquingKeysWith: { existing, _ in existing }
            ),
            foldersByID: foldersByID,
            workspaceIDBySessionID: workspaceIDBySessionID,
            foldersByWorkspaceID: foldersByWorkspaceID,
            folderMoveTargetsByFolderID: folderMoveTargetsByFolderID,
            recentWorkspaceProfiles: Array(
                state.workspaceProfiles.sorted { $0.lastOpened > $1.lastOpened }.prefix(8)
            ),
            availableWorkspaceIDs: availableWorkspaceIDs,
            workspaceAvailabilityByProfileID: workspaceAvailabilityByProfileID,
            availableExecutionSessionIDs: availableExecutionSessionIDs,
            filteredSessions: filteredSessions,
            sidebarGroups: sidebarGroups,
            activeWorkspaceID: state.activeWorkspaceID,
            showArchivedSessions: state.showArchivedSessions,
            searchQuery: state.searchQuery,
            expandedWorkspaceIDs: state.expandedWorkspaceIDs,
            expandedChatFolderIDs: state.expandedChatFolderIDs,
            sidebarSearchFocusToken: state.sidebarSearchFocusToken
        )
    }

    private static func folderTree(
        folders: [ChatFolderRecord],
        chats: [SessionSummary],
        parentID: String?,
        query: String
    ) -> [SessionSidebarFolderSnapshot] {
        folders
            .filter { $0.parentID == parentID }
            .sorted(by: folderSort)
            .compactMap { folder in
                let children = folderTree(
                    folders: folders,
                    chats: chats,
                    parentID: folder.id,
                    query: query
                )
                let folderChats = sortedChats(chats.filter { $0.folderID == folder.id })
                guard query.isEmpty
                        || folder.name.lowercased().contains(query)
                        || !children.isEmpty
                        || !folderChats.isEmpty
                else { return nil }
                return SessionSidebarFolderSnapshot(
                    folder: folder,
                    children: children,
                    chats: folderChats
                )
            }
    }

    private static func sessionSort(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return lhs.mtime > rhs.mtime
    }

    private static func sortedChats(_ chats: [SessionSummary]) -> [SessionSummary] {
        chats.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.sortOrder != rhs.sortOrder {
                return (lhs.sortOrder ?? .max) < (rhs.sortOrder ?? .max)
            }
            return lhs.mtime > rhs.mtime
        }
    }

    private static func folderSort(_ lhs: ChatFolderRecord, _ rhs: ChatFolderRecord) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func canMoveFolder(
        _ folder: ChatFolderRecord,
        into target: ChatFolderRecord,
        foldersByID: [String: ChatFolderRecord]
    ) -> Bool {
        guard folder.id != target.id,
              SessionSummary.canonicalWorkspacePath(folder.workspace)
                == SessionSummary.canonicalWorkspacePath(target.workspace)
        else { return false }
        var cursor: ChatFolderRecord? = target
        var visited: Set<String> = []
        while let current = cursor, visited.insert(current.id).inserted {
            if current.id == folder.id { return false }
            cursor = current.parentID.flatMap { foldersByID[$0] }
        }
        return true
    }
}
