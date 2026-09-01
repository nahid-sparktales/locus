import Combine
import XCTest

@testable import Locus

@MainActor
final class SessionCatalogModelTests: XCTestCase {
    private func profile(
        _ path: String,
        lastOpened: TimeInterval
    ) -> WorkspaceProfile {
        WorkspaceProfile(
            path: path,
            lastOpened: Date(timeIntervalSince1970: lastOpened),
            model: "",
            accountID: nil,
            mode: .work,
            previewURL: "",
            contextFiles: [],
            draft: ""
        )
    }

    private func session(
        _ id: String,
        title: String? = nil,
        preview: String = "",
        mtime: TimeInterval,
        pinned: Bool = false,
        archived: Bool = false,
        workspace: String? = nil,
        folderID: String? = nil,
        sortOrder: Int? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            name: "\(id).jsonl",
            preview: preview,
            mtime: mtime,
            size: 1,
            title: title,
            pinned: pinned,
            archived: archived,
            cwd: workspace,
            folderID: folderID,
            sortOrder: sortOrder
        )
    }

    private func folder(
        _ id: String,
        workspace: String,
        parentID: String? = nil,
        name: String,
        order: Int
    ) -> ChatFolderRecord {
        ChatFolderRecord(
            id: id,
            workspace: workspace,
            parentID: parentID,
            name: name,
            order: order
        )
    }

    func testWorkspaceOrderingKeepsEmptyProfilesAndLegacyChats() {
        let alpha = "/tmp/locus-catalog-alpha"
        let beta = "/tmp/locus-catalog-beta"
        let catalog = SessionCatalogModel { $0 != beta }
        catalog.replaceWorkspaceProfiles([
            profile(alpha, lastOpened: 10),
            profile(beta, lastOpened: 20),
        ])
        catalog.setActiveWorkspacePath(alpha)
        catalog.replaceSessions([
            session("alpha-chat", preview: "Alpha", mtime: 30, workspace: alpha),
            session("legacy-chat", preview: "Legacy", mtime: 5),
        ])

        let groups = catalog.snapshot.sidebarGroups
        XCTAssertEqual(groups.map(\.id), [alpha, beta, SessionCatalogModel.otherWorkspaceID])
        XCTAssertEqual(groups[0].group.chats.map(\.id), ["alpha-chat"])
        XCTAssertTrue(groups[1].group.chats.isEmpty, "empty saved workspaces remain visible")
        XCTAssertFalse(groups[1].group.isAvailable)
        XCTAssertEqual(groups[2].group.title, "Other Chats")
        XCTAssertEqual(groups[2].unfiledChats.map(\.id), ["legacy-chat"])
        XCTAssertEqual(catalog.snapshot.recentWorkspaceProfiles.map(\.path), [beta, alpha])
        XCTAssertEqual(catalog.snapshot.workspaceAvailabilityByProfileID[alpha], true)
        XCTAssertEqual(catalog.snapshot.workspaceAvailabilityByProfileID[beta], false)

        catalog.setSearchQuery("not-present")
        XCTAssertEqual(catalog.snapshot.workspaceAvailabilityByProfileID[alpha], true)
        XCTAssertEqual(catalog.snapshot.workspaceAvailabilityByProfileID[beta], false)
    }

    func testPinnedOrderingAndArchivedVisibility() {
        let workspace = "/tmp/locus-catalog-ordering"
        let catalog = SessionCatalogModel(fileExists: { _ in true })
        catalog.replaceSessions([
            session("recent", mtime: 30, workspace: workspace, sortOrder: 2),
            session("ordered", mtime: 10, workspace: workspace, sortOrder: 1),
            session("pinned", mtime: 1, pinned: true, workspace: workspace, sortOrder: 9),
            session("archived", mtime: 100, archived: true, workspace: workspace),
        ])

        let visible = catalog.snapshot.sidebarGroups.first { $0.id == workspace }
        XCTAssertEqual(visible?.unfiledChats.map(\.id), ["pinned", "ordered", "recent"])
        XCTAssertFalse(catalog.snapshot.filteredSessions.contains { $0.id == "archived" })

        catalog.setShowArchivedSessions(true)

        XCTAssertTrue(catalog.snapshot.filteredSessions.contains { $0.id == "archived" })
        XCTAssertTrue(
            catalog.snapshot.sidebarGroups
                .first { $0.id == workspace }?
                .unfiledChats.contains { $0.id == "archived" } == true
        )
    }

    func testSessionAndNestedFolderSearchPreserveAncestors() {
        let workspace = "/tmp/locus-catalog-search"
        let catalog = SessionCatalogModel(fileExists: { _ in true })
        catalog.replaceRemoteCatalog(
            sessions: [
                session(
                    "direct", title: "Needle discussion", mtime: 10,
                    workspace: workspace
                ),
                session(
                    "nested", title: "Unrelated", mtime: 20,
                    workspace: workspace, folderID: "sources"
                ),
            ],
            chatFolders: [
                folder("research", workspace: workspace, name: "Research", order: 0),
                folder(
                    "sources", workspace: workspace, parentID: "research",
                    name: "Sources", order: 0
                ),
            ]
        )

        catalog.setSearchQuery("needle")
        XCTAssertEqual(catalog.snapshot.filteredSessions.map(\.id), ["direct"])
        XCTAssertTrue(catalog.snapshot.sidebarGroups[0].rootFolders.isEmpty)

        catalog.setSearchQuery("Research")
        XCTAssertEqual(catalog.snapshot.filteredSessions.map(\.id), ["nested"])
        let research = catalog.snapshot.sidebarGroups[0].rootFolders
        XCTAssertEqual(research.map(\.id), ["research"])
        XCTAssertEqual(research[0].children.map(\.id), ["sources"])
        XCTAssertEqual(research[0].children[0].chats.map(\.id), ["nested"])

        catalog.setSearchQuery("Sources")
        XCTAssertEqual(catalog.snapshot.sidebarGroups[0].rootFolders.map(\.id), ["research"])
        XCTAssertEqual(
            catalog.snapshot.sidebarGroups[0].rootFolders[0].children.map(\.id),
            ["sources"]
        )
    }

    func testNestedFolderTreeAndChatOrderingArePrebuilt() {
        let workspace = "/tmp/locus-catalog-tree"
        let catalog = SessionCatalogModel(fileExists: { _ in true })
        catalog.replaceRemoteCatalog(
            sessions: [
                session(
                    "child-new", mtime: 30, workspace: workspace,
                    folderID: "child-a", sortOrder: 1
                ),
                session(
                    "child-pinned", mtime: 1, pinned: true, workspace: workspace,
                    folderID: "child-a", sortOrder: 9
                ),
                session("unfiled-late", mtime: 30, workspace: workspace, sortOrder: 2),
                session("unfiled-first", mtime: 10, workspace: workspace, sortOrder: 1),
            ],
            chatFolders: [
                folder("root-later", workspace: workspace, name: "Later", order: 2),
                folder("root-first", workspace: workspace, name: "First", order: 1),
                folder(
                    "child-b", workspace: workspace, parentID: "root-first",
                    name: "B", order: 2
                ),
                folder(
                    "child-a", workspace: workspace, parentID: "root-first",
                    name: "A", order: 1
                ),
            ]
        )

        let group = catalog.snapshot.sidebarGroups[0]
        XCTAssertEqual(group.rootFolders.map(\.id), ["root-first", "root-later"])
        XCTAssertEqual(group.rootFolders[0].children.map(\.id), ["child-a", "child-b"])
        XCTAssertEqual(
            group.rootFolders[0].children[0].chats.map(\.id),
            ["child-pinned", "child-new"]
        )
        XCTAssertEqual(group.unfiledChats.map(\.id), ["unfiled-first", "unfiled-late"])
        XCTAssertEqual(
            catalog.snapshot.folderMoveTargetsByFolderID["root-first"]?.map(\.id),
            ["root-later"]
        )
    }

    func testExpansionPersistenceFocusRequestsAndSearchCallback() {
        let suiteName = "SessionCatalogModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var queries: [String] = []
        let catalog = SessionCatalogModel(fileExists: { _ in true })
        catalog.configure(
            persistenceEnabled: true,
            defaults: defaults,
            searchQueryDidChange: { queries.append($0) }
        )
        catalog.setWorkspaceExpanded("workspace", expanded: true)
        catalog.setChatFolderExpanded("folder", expanded: true)
        catalog.setSearchQuery("needle")
        catalog.setSearchQuery("needle")
        let focusToken = catalog.snapshot.sidebarSearchFocusToken
        catalog.requestSearchFocus()

        XCTAssertEqual(queries, ["needle"])
        XCTAssertNotEqual(catalog.snapshot.sidebarSearchFocusToken, focusToken)
        XCTAssertEqual(defaults.stringArray(forKey: "Locus.expandedWorkspaces"), ["workspace"])
        XCTAssertEqual(defaults.stringArray(forKey: "Locus.expandedChatFolders"), ["folder"])

        let restored = SessionCatalogModel(fileExists: { _ in true })
        restored.configure(
            persistenceEnabled: true,
            defaults: defaults,
            searchQueryDidChange: { _ in }
        )
        XCTAssertEqual(restored.snapshot.expandedWorkspaceIDs, ["workspace"])
        XCTAssertEqual(restored.snapshot.expandedChatFolderIDs, ["folder"])
    }

    func testInjectedAvailabilityRunsOnlyDuringSnapshotRebuilds() {
        let first = "/tmp/locus-catalog-available"
        let second = "/tmp/locus-catalog-unavailable"
        var checkedPaths: [String] = []
        let catalog = SessionCatalogModel { path in
            checkedPaths.append(path)
            return path == first
        }
        catalog.replaceWorkspaceProfiles([
            profile(first, lastOpened: 2),
            profile(second, lastOpened: 1),
        ])
        let rebuilds = catalog.snapshotBuildCountForTesting
        let availabilityChecks = checkedPaths.count

        for _ in 0..<20 {
            _ = catalog.snapshot.sidebarGroups
            _ = catalog.snapshot.sessionsByID
        }

        XCTAssertEqual(catalog.snapshotBuildCountForTesting, rebuilds)
        XCTAssertEqual(checkedPaths.count, availabilityChecks)
        XCTAssertEqual(
            catalog.snapshot.sidebarGroups.first { $0.id == first }?.group.isAvailable,
            true
        )
        XCTAssertEqual(
            catalog.snapshot.sidebarGroups.first { $0.id == second }?.group.isAvailable,
            false
        )
    }

    func testCombinedRemoteReplacementBuildsAndPublishesExactlyOnce() {
        let workspace = "/tmp/locus-catalog-transaction"
        let catalog = SessionCatalogModel(fileExists: { _ in true })
        let baseline = catalog.snapshotBuildCountForTesting
        var publications = 0
        let subscription = catalog.objectWillChange.sink { publications += 1 }

        catalog.replaceRemoteCatalog(
            sessions: [session("chat", mtime: 1, workspace: workspace)],
            chatFolders: [
                folder("folder", workspace: workspace, name: "Folder", order: 0),
            ]
        )

        XCTAssertEqual(catalog.snapshotBuildCountForTesting, baseline + 1)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(catalog.snapshot.sessions.map(\.id), ["chat"])
        XCTAssertEqual(catalog.snapshot.chatFolders.map(\.id), ["folder"])
        withExtendedLifetime(subscription) {}
    }

    func testUnrelatedAppAndChildPublicationsDoNotRebuildCatalog() {
        let app = AppModel(startImmediately: false)
        let baseline = app.sessionCatalog.snapshotBuildCountForTesting

        app.backendLogHint = "changed"
        app.toastCenter.objectWillChange.send()

        XCTAssertEqual(app.sessionCatalog.snapshotBuildCountForTesting, baseline)
    }

    func testCatalogChangesDoNotPublishAppModel() {
        let app = AppModel(startImmediately: false)
        var appPublications = 0
        let subscription = app.objectWillChange.sink { appPublications += 1 }

        app.sessionCatalog.replaceSessions([
            session("isolated", mtime: 1, workspace: "/tmp/locus-catalog-isolated"),
        ])
        app.sessionCatalog.setSearchQuery("catalog")

        XCTAssertEqual(appPublications, 0)
        app.transcriptSearch.cancelAll()
        withExtendedLifetime(subscription) {}
    }

    func testBenchmarkInitialConstructionWithBackendMaximumFixture() {
        let fixture = benchmarkFixture()
        measure(metrics: [XCTClockMetric()]) {
            let catalog = SessionCatalogModel(fileExists: { _ in true })
            catalog.replaceWorkspaceProfiles(fixture.profiles)
            catalog.replaceRemoteCatalog(
                sessions: fixture.sessions,
                chatFolders: fixture.folders
            )
            _ = catalog.snapshot.sidebarGroups.count
        }
    }

    func testBenchmarkSearchUpdatesWithBackendMaximumFixture() {
        let fixture = benchmarkFixture()
        let catalog = SessionCatalogModel(fileExists: { _ in true })
        catalog.replaceWorkspaceProfiles(fixture.profiles)
        catalog.replaceRemoteCatalog(
            sessions: fixture.sessions,
            chatFolders: fixture.folders
        )
        var useMatchingQuery = false

        measure(metrics: [XCTClockMetric()]) {
            useMatchingQuery.toggle()
            catalog.setSearchQuery(useMatchingQuery ? "needle" : "not-present")
            _ = catalog.snapshot.filteredSessions.count
        }
    }

    private func benchmarkFixture() -> (
        profiles: [WorkspaceProfile],
        folders: [ChatFolderRecord],
        sessions: [SessionSummary]
    ) {
        var profiles: [WorkspaceProfile] = []
        var folders: [ChatFolderRecord] = []
        var sessions: [SessionSummary] = []
        for workspaceIndex in 0..<20 {
            let workspace = "/tmp/locus-catalog-benchmark-\(workspaceIndex)"
            let rootID = "root-\(workspaceIndex)"
            let childID = "child-\(workspaceIndex)"
            profiles.append(profile(workspace, lastOpened: TimeInterval(workspaceIndex)))
            folders.append(
                folder(rootID, workspace: workspace, name: "Research", order: 0)
            )
            folders.append(
                folder(
                    childID, workspace: workspace, parentID: rootID,
                    name: "Sources", order: 0
                )
            )
            for chatIndex in 0..<25 {
                let id = "chat-\(workspaceIndex)-\(chatIndex)"
                let destination: String? = switch chatIndex % 3 {
                case 0: childID
                case 1: rootID
                default: nil
                }
                sessions.append(
                    session(
                        id,
                        title: chatIndex.isMultiple(of: 10) ? "Needle \(id)" : "Chat \(id)",
                        mtime: TimeInterval(workspaceIndex * 100 + chatIndex),
                        pinned: chatIndex.isMultiple(of: 17),
                        workspace: workspace,
                        folderID: destination,
                        sortOrder: chatIndex
                    )
                )
            }
        }
        XCTAssertEqual(sessions.count, 500)
        return (profiles, folders, sessions)
    }
}
