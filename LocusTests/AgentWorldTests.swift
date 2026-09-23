import AppKit
import Foundation
import WebKit
import ImageIO
import XCTest
@testable import Locus

@MainActor
final class AgentWorldTests: XCTestCase {
    private let screen = ExtensionPluginScreen(id: "agent-world", title: "Agent World", entrypoint: "ui/index.html", version: 1,
                                               capabilities: ["agents.read", "agents.interact", "world.preferences"])

    func testIsolatedProjectIdentityKeepsSelectedSubfolderWithoutChangingExecutionContext() throws {
        let owner = UUID()
        let payload: [String: Any] = [
            "id": "isolated-chat", "name": "isolated-chat", "preview": "", "mtime": 1, "size": 0, "messages": [],
            "cwd": "/tmp/old-location", "workspace_root": "/tmp/repository", "execution_path": "/tmp/checkouts/task-a",
            "agent_profile_id": owner.uuidString,
            "environment": ["type": "worktree", "source_workspace": "/tmp/repository/subproject"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let session = try JSONDecoder().decode(SessionSummary.self, from: data)
        let detail = try JSONDecoder().decode(SessionDetailResponse.self, from: data)
        let crew = try JSONDecoder().decode(AgentCrewChatSessionIdentity.self, from: data)
        XCTAssertEqual(session.workspacePath, SessionSummary.canonicalWorkspacePath("/tmp/repository"))
        for workspace in ["/tmp/repository", "/tmp/repository/subproject"] {
            XCTAssertTrue(session.belongsToWorkspace(workspace))
            XCTAssertTrue(detail.belongsToWorkspace(workspace))
            XCTAssertTrue(crew.matches(sessionID: session.id, profileID: owner, workspace: workspace))
        }
        for workspace in ["/tmp/old-location", "/tmp/checkouts/task-a", "/tmp/repository/another", "/tmp/elsewhere"] {
            XCTAssertFalse(session.belongsToWorkspace(workspace))
            XCTAssertFalse(detail.belongsToWorkspace(workspace))
            XCTAssertFalse(crew.matches(sessionID: session.id, profileID: owner, workspace: workspace))
        }
        XCTAssertFalse(crew.matches(sessionID: session.id, profileID: UUID(), workspace: "/tmp/repository/subproject"))
        XCTAssertEqual(detail.executionQueueContext["workspace_root"] as? String, "/tmp/repository")
        XCTAssertEqual(detail.executionQueueContext["execution_path"] as? String, "/tmp/checkouts/task-a")
        XCTAssertEqual(detail.executionQueueContext["execution_environment"] as? String, "worktree")
        XCTAssertFalse(SessionSummary.matchesWorkspace(root: "/tmp/repository", environment: ["type": "local", "source_workspace": "/tmp/repository/subproject"], requested: "/tmp/repository/subproject"))
        XCTAssertFalse(SessionSummary.matchesWorkspace(root: "/tmp/repository", environment: ["type": "worktree", "source_workspace": "/tmp/repository-other"], requested: "/tmp/repository-other"))
    }

    func testBridgeRejectsUnknownCapabilitiesVersionsAndPayloads() {
        XCTAssertEqual(PluginScreenMessage.decode(["version": 1, "type": "ready"], screen: screen), .ready)
        XCTAssertNil(PluginScreenMessage.decode(["version": true, "type": "ready"], screen: screen))
        XCTAssertNil(PluginScreenMessage.decode(["version": 2, "type": "ready"], screen: screen))
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "ready", "api_key": "never"], screen: screen))
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "send", "text": "Execute code"], screen: screen))
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "selectAgent", "agentID": "bad"], screen: screen))
        let id = UUID().uuidString
        XCTAssertEqual(PluginScreenMessage.decode(["version": 1, "type": "selectAgent", "agentID": id.lowercased()], screen: screen), .selectAgent(id))
        XCTAssertEqual(PluginScreenMessage.decode(["version": 1, "type": "clearSelection"], screen: screen), .clearSelection)
        let readOnly = ExtensionPluginScreen(id: screen.id, title: screen.title, entrypoint: screen.entrypoint, version: 1, capabilities: ["agents.read"])
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "selectAgent", "agentID": id], screen: readOnly))
        let unknown = ExtensionPluginScreen(id: screen.id, title: screen.title, entrypoint: screen.entrypoint, version: 1, capabilities: ["credentials.read"])
        XCTAssertFalse(unknown.isSupported)
    }

    func testResidentPlacementsAreBoundedDisplayMetadata() {
        let id = UUID().uuidString
        let row: [String: Any] = ["agentID": id.lowercased(), "ship": "Going Sherry", "home": "Twin Cache"]
        let payload: [String: Any] = ["version": 1, "type": "residentPlacements", "placements": [row]]
        XCTAssertEqual(PluginScreenMessage.decode(payload, screen: screen),
                       .residentPlacements([.init(agentID: id, ship: "Going Sherry", home: "Twin Cache")]))
        let noRoster = ExtensionPluginScreen(id: screen.id, title: screen.title, entrypoint: screen.entrypoint,
                                            version: 1, capabilities: ["world.preferences"])
        XCTAssertNil(PluginScreenMessage.decode(payload, screen: noRoster))
        for rows in [[row, row], Array(repeating: row, count: 501)] {
            XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "residentPlacements", "placements": rows], screen: screen))
        }
        for replacement: [String: Any] in [
            ["agentID": "not-an-agent", "ship": "Ship", "home": "Port"],
            ["agentID": id, "ship": "Ship", "home": "Port", "sessionID": "private"],
            ["agentID": id, "ship": String(repeating: "a", count: 101), "home": "Port"],
            ["agentID": id, "ship": "Ship", "home": "Port\nspoofed"],
        ] {
            XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "residentPlacements", "placements": [replacement]], screen: screen))
        }
    }

    func testWorldActivityBridgeRequiresReadAccessAndNoExtraPayload() {
        let payload: [String: Any] = ["version": 1, "type": "openActivityCenter"]
        XCTAssertEqual(PluginScreenMessage.decode(payload, screen: screen), .openActivityCenter)
        let noRead = ExtensionPluginScreen(id: screen.id, title: screen.title, entrypoint: screen.entrypoint,
                                          version: 1, capabilities: ["world.preferences"])
        XCTAssertNil(PluginScreenMessage.decode(payload, screen: noRead))
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "openActivityCenter", "sessionID": "untrusted"], screen: screen))
    }

    func testWorldFindsWorkStartedInOtherSavedChatsWithoutCrossingAgentOrProject() {
        let app = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Worker", model: "fixture")
        let other = AgentProfile(name: "Other", model: "fixture")
        app.agentProfiles = [profile, other]
        app.sessions = [
            SessionSummary(id: "earlier-chat", name: "Earlier chat", preview: "", mtime: 1, size: 0,
                           workspaceRoot: "/tmp/world", agentProfileID: profile.id.uuidString),
            SessionSummary(id: "latest-chat", name: "Latest chat", preview: "", mtime: 2, size: 0,
                           workspaceRoot: "/tmp/world", agentProfileID: profile.id.uuidString),
        ]
        app.taskConversationStates["earlier-chat"] = TaskConversationState(sessionID: "earlier-chat", taskID: nil, teamID: nil,
            workerID: nil, runID: "queued-run", state: .queued, updatedAt: Date())
        XCTAssertEqual(app.agentWorldSavedChatActivity(profileID: profile.id, workspace: "/tmp/world")?.status, "queued")
        XCTAssertNil(app.agentWorldSavedChatActivity(profileID: other.id, workspace: "/tmp/world"))
        XCTAssertNil(app.agentWorldSavedChatActivity(profileID: profile.id, workspace: "/tmp/another-world"))
        app.taskConversationStates["earlier-chat"] = nil
        XCTAssertNil(app.agentWorldSavedChatActivity(profileID: profile.id, workspace: "/tmp/world"))
    }

    func testWorldOverviewAndActivityUseNativeControlsWithoutStartingAChat() async throws {
        let fixture = try conversationFixture()
        defer { fixture.close() }
        let app = AppModel(startImmediately: false)
        app.agentProfiles = fixture.profiles
        app.currentSessionID = "unrelated-chat"
        let world = app.agentWorld
        world.configure(extensions: fixture.extensions, profiles: { fixture.profiles }, workspace: { fixture.root.path },
                        availability: { _ in nil }, state: { _ in .init() },
                        create: { _, _ in XCTFail("Opening the overview must not create a chat"); return "unexpected" },
                        load: { _ in XCTFail("Opening the overview must not resume a chat") },
                        dispatch: { _, _, _, _, _ in XCTFail("Inspection must not run an agent") },
                        stop: { _ in }, open: { _ in }, manage: {}, defaults: fixture.defaults)
        world.open(pluginID: fixture.pluginID)
        world.openAgentControls()
        XCTAssertTrue(world.quartersPresented)
        XCTAssertNil(world.selection, "The fleet hub opens without choosing or running an agent")
        world.openAgentControls(fixture.profiles[1].id.uuidString)
        XCTAssertTrue(world.profilePresented)
        XCTAssertEqual(world.selectedProfile?.id, fixture.profiles[1].id)
        XCTAssertEqual(app.currentSessionID, "unrelated-chat")
        world.requestActivityCenter()
        XCTAssertTrue(app.activity.activityCenterPresented)
        XCTAssertEqual(world.activityCenterRequest, 1)
        XCTAssertEqual(app.currentSessionID, "unrelated-chat")
        XCTAssertTrue(world.profilePresented, "Closing activity returns to the selected overview")
        world.quartersPresented = false
        XCTAssertEqual(world.selectedProfile?.id, fixture.profiles[1].id)
    }

    func testShipSelectionOpensWorkspaceWithoutSilentlyCreatingAConversation() async throws {
        let fixture = try conversationFixture()
        defer { fixture.close() }
        let app = AppModel(startImmediately: false)
        app.agentProfiles = fixture.profiles
        app.currentSessionID = "unrelated-chat"
        let world = app.agentWorld
        world.configure(extensions: fixture.extensions, profiles: { fixture.profiles }, workspace: { fixture.root.path },
                        availability: { _ in nil }, state: { _ in .init() },
                        create: { _, _ in XCTFail("Selecting a ship must not create a chat"); return "unexpected" },
                        load: { _ in XCTFail("A ship with no chat must not load one") },
                        dispatch: { _, _, _, _, _ in XCTFail("Selecting a ship must not run an agent") },
                        stop: { _ in XCTFail("Selecting a ship must not stop an agent") }, open: { _ in }, manage: {}, defaults: fixture.defaults)
        world.open(pluginID: fixture.pluginID)
        let id = fixture.profiles[0].id.uuidString
        let firstFocus = world.focusRequest
        world.chooseResident(id)
        XCTAssertEqual(world.selection, id)
        XCTAssertTrue(world.quartersPresented)
        XCTAssertTrue(world.conversationPresented)
        XCTAssertFalse(world.profilePresented)
        XCTAssertFalse(world.preparingConversation)
        XCTAssertEqual(world.focusRequest, firstFocus + 1)
        world.chooseResident(id)
        XCTAssertEqual(world.focusRequest, firstFocus + 2)
        XCTAssertTrue(world.profilePresented, "Selecting the same resident inside the workspace opens its overview")
        world.chooseResident(UUID().uuidString)
        XCTAssertEqual(world.selection, id, "Unknown ships cannot change selection")
        XCTAssertEqual(world.focusRequest, firstFocus + 2)
        world.chooseResident(fixture.profiles[1].id.uuidString)
        XCTAssertEqual(world.selection, fixture.profiles[1].id.uuidString)
        XCTAssertTrue(world.profilePresented, "The crew list still opens agent details inside the quarters")
        world.clearWorldSelection()
        XCTAssertNil(world.selection)
        XCTAssertFalse(world.conversationPresented)
        XCTAssertFalse(world.quartersPresented)
        XCTAssertEqual(app.currentSessionID, "unrelated-chat")
    }

    func testAgentPicturesAreBoundedSquareImagesAndRejectInvalidFiles() throws {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let source = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let data = try AgentAvatarImage.normalized(source)
        XCTAssertLessThanOrEqual(data.count, AgentAvatarImage.maximumStoredBytes)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(bitmap.width, 256)
        XCTAssertEqual(bitmap.height, 256)
        let properties = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any]
        XCTAssertNil(properties?[kCGImagePropertyGPSDictionary])
        XCTAssertThrowsError(try AgentAvatarImage.normalized(Data("not an image".utf8)))
        XCTAssertThrowsError(try AgentAvatarImage.normalized(Data(count: AgentAvatarImage.maximumSourceBytes + 1)))
    }

    func testAgentPicturesPersistSeparatelyAndAreRemovedWithAgent() throws {
        let suite = "AgentWorldAvatarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = AgentProfile(name: "Portrait", model: "fixture")
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = try AgentAvatarImage.normalized(XCTUnwrap(image.representation(using: .png, properties: [:])))
        let model = AgentTeamsModel()
        model.restore(persistenceEnabled: true, defaults: defaults)
        model.saveAgentProfile(profile)
        model.setAgentAvatar(data, profileID: profile.id)
        model.setAgentAvatar(data, profileID: UUID())
        XCTAssertEqual(model.agentAvatarData.count, 1)
        XCTAssertEqual(model.agentProfiles.first, profile)
        let restored = AgentTeamsModel()
        restored.restore(persistenceEnabled: true, defaults: defaults)
        XCTAssertEqual(restored.agentAvatarData[profile.id], data)
        restored.setAgentAvatar(nil, profileID: profile.id)
        XCTAssertTrue(restored.agentAvatarData.isEmpty)
        restored.setAgentAvatar(data, profileID: profile.id)
        XCTAssertTrue(restored.removeAgentProfile(profile))
        let reopened = AgentTeamsModel()
        reopened.restore(persistenceEnabled: true, defaults: defaults)
        XCTAssertTrue(reopened.agentAvatarData.isEmpty)
    }

    func testWorldBoardHandoffRejectsCardsFromAnotherProjectWithoutChangingDraft() async throws {
        let fixture = try conversationFixture()
        defer { fixture.close() }
        let app = AppModel(startImmediately: false)
        app.agentProfiles = fixture.profiles
        app.currentSessionID = "existing-chat"
        app.draftText = "Keep my draft"
        let world = app.agentWorld
        world.configure(extensions: fixture.extensions, profiles: { fixture.profiles }, workspace: { fixture.root.path },
                        availability: { _ in nil }, state: { _ in .init() },
                        create: { _, _ in XCTFail("A foreign board must not create a chat"); return "unexpected" },
                        load: { _ in }, dispatch: { _, _, _, _, _ in XCTFail("A board draft must not send work") },
                        stop: { _ in }, open: { _ in }, manage: {}, defaults: fixture.defaults)
        world.open(pluginID: fixture.pluginID)
        world.openAgentControls(fixture.profiles[0].id.uuidString)
        let foreign = BoardStore.testingStore(workspacePath: fixture.root.appendingPathComponent("other-project").path,
                                             applicationSupport: fixture.root.appendingPathComponent("board-fixture"))
        let card = try foreign.createCard(title: "Another project’s card")
        do {
            try await world.openBoardCard(card, profileID: fixture.profiles[0].id.uuidString)
            XCTFail("Should reject a card absent from this project")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no longer on the project"))
        }
        XCTAssertEqual(app.currentSessionID, "existing-chat")
        XCTAssertEqual(app.draftText, "Keep my draft")
        XCTAssertTrue(world.profilePresented)
    }

    func testNativeWorldCatalogReadsOnlyBoundedConfinedMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ui/themes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AgentWorldModel.AvailableScreen(pluginID: "test", pluginName: "Test", digest: nil, root: root.path, screen: screen)
        let file = root.appendingPathComponent("ui/themes/catalog.json")
        XCTAssertEqual(AgentWorldModel.loadThemeCatalog(for: source), AgentWorldThemeOption.builtIn)
        try Data(#"{"version":1,"themes":[{"id":"forest","name":"The Forest"}]}"#.utf8).write(to: file)
        XCTAssertEqual(AgentWorldModel.loadThemeCatalog(for: source), [.init(id: "forest", name: "The Forest")])
        for text in [
            #"{"version":1,"themes":[{"id":"../escape","name":"Forest"}]}"#,
            #"{"version":1,"themes":[{"id":"forest","name":"Forest"},{"id":"forest","name":"Duplicate"}]}"#,
            String(repeating: " ", count: 32_769),
        ] {
            try Data(text.utf8).write(to: file)
            XCTAssertEqual(AgentWorldModel.loadThemeCatalog(for: source), AgentWorldThemeOption.builtIn)
        }
    }

    func testShipStyleBridgeAcceptsKnownShipsAndExplicitAutomaticOnly() {
        let id = UUID().uuidString
        for style in AgentWorldShipStyle.all {
            XCTAssertEqual(PluginScreenMessage.decode(["version": 1, "type": "setShipStyle", "agentID": id.lowercased(), "shipStyle": style.id], screen: screen),
                           .setShipStyle(agentID: id, style: style.id))
        }
        XCTAssertEqual(PluginScreenMessage.decode(["version": 1, "type": "setShipStyle", "agentID": id, "shipStyle": NSNull()], screen: screen),
                       .setShipStyle(agentID: id, style: nil))
        for invalid: Any in ["automatic", "../ship.glb", "ship_unknown", true, 1] {
            XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "setShipStyle", "agentID": id, "shipStyle": invalid], screen: screen))
        }
        let readOnly = ExtensionPluginScreen(id: screen.id, title: screen.title, entrypoint: screen.entrypoint,
                                            version: 1, capabilities: ["agents.read"])
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "setShipStyle", "agentID": id, "shipStyle": "ship_going_merry"], screen: readOnly))
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "setShipStyle", "agentID": id], screen: screen))
    }

    func testThemeIDsPermitPluginUpdatesWithoutPathsOrScripts() {
        for value in ["outpost", "forest-v2", "underwater"] {
            XCTAssertEqual(PluginScreenMessage.decode(["version": 1, "type": "preferences", "preferences": ["theme": value]], screen: screen), .preferences(value))
        }
        for value in ["", "../secret", "data:alert(1)", "<script>", "UpperCase", String(repeating: "a", count: 65)] {
            XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "preferences", "preferences": ["theme": value]], screen: screen))
        }
    }

    func testWorldActivityActionsRequireInteractiveCapabilityAndExactOpaqueIDs() {
        let id = UUID().uuidString
        let readOnly = ExtensionPluginScreen(id: screen.id, title: screen.title, entrypoint: screen.entrypoint,
                                             version: 1, capabilities: ["agents.read"])
        let actions: [([String: Any], PluginScreenMessage)] = [
            (["version": 1, "type": "openAttention", "requestID": id.lowercased()], .openAttention(id)),
            (["version": 1, "type": "openTransfer", "transferID": id], .openTransfer(id)),
            (["version": 1, "type": "openSharedChat"], .openSharedChat),
            (["version": 1, "type": "createAgent"], .createAgent),
            (["version": 1, "type": "openAgentControls"], .openAgentControls(nil)),
            (["version": 1, "type": "openAgentControls", "agentID": id], .openAgentControls(id)),
        ]
        for (payload, expected) in actions {
            XCTAssertEqual(PluginScreenMessage.decode(payload, screen: screen), expected)
            XCTAssertNil(PluginScreenMessage.decode(payload, screen: readOnly))
            var extra = payload; extra["sessionID"] = "another-conversation"
            XCTAssertNil(PluginScreenMessage.decode(extra, screen: screen))
            var badVersion = payload; badVersion["version"] = true
            XCTAssertNil(PluginScreenMessage.decode(badVersion, screen: screen))
        }
        for type in ["openAttention", "openTransfer", "openAgentControls"] {
            let key = type == "openAttention" ? "requestID" : type == "openTransfer" ? "transferID" : "agentID"
            XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": type, key: "../private"], screen: screen))
        }
    }

    func testWorldCreatesSavedAgentThroughNativeDraftWithoutChangingProjectOrStartingConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ui"), withIntermediateDirectories: true)
        try Data("<!doctype html><html><body>Agent creation fixture</body></html>".utf8)
            .write(to: root.appendingPathComponent("ui/index.html"))
        let title = "Agent World Creation Test " + UUID().uuidString
        defer {
            for window in NSApp.windows where window.title.hasPrefix(title) { window.close() }
            try? FileManager.default.removeItem(at: root)
        }
        let app = AppModel(startImmediately: false)
        app.agentProfiles = []
        app.agentTeamsModel.profilesChanged = {}
        app.initialWorkspacePath = root.path
        let world = app.agentWorld
        var conversationsCreated = 0
        world.configure(extensions: app.extensionsModel, profiles: { [weak app] in app?.agentProfiles ?? [] },
                        workspace: { [weak app] in app?.workspacePath ?? "" }, availability: { _ in nil },
                        state: { _ in .init() }, create: { _, _ in conversationsCreated += 1; return "unused" },
                        load: { _ in }, dispatch: { _, _, _, _, _ in XCTFail("Creating an agent must not dispatch work") },
                        stop: { _ in }, open: { _ in }, manage: {}, defaults: nil)
        let interactive = ExtensionPluginScreen(id: "interactive", title: title, entrypoint: "ui/index.html", version: 1,
                                                capabilities: ["agents.read", "agents.interact"])
        let readOnly = ExtensionPluginScreen(id: "read-only", title: title, entrypoint: "ui/index.html", version: 1,
                                             capabilities: ["agents.read"])
        var plugin = ExtensionPlugin(id: "creation-fixture", name: "creation-fixture", displayName: title, description: nil,
                                     version: "1.0.0", author: nil, digest: "fixture", enabledGlobal: true,
                                     enabledWorkspaces: [], disabledWorkspaces: [], previousVersions: nil,
                                     skills: [], mcpServers: [], scripts: [], unsupported: [], updateAvailable: false, error: nil)
        plugin.root = root.path; plugin.screens = [interactive, readOnly]
        var capabilities = ExtensionCapabilities(); capabilities.pluginScreens = true
        app.extensionsModel.extensions = ExtensionsResponse(capabilities: capabilities, marketplaces: [], plugins: [plugin],
                                                            skills: [], mcpServers: [], mcpPresets: [], errors: [], pendingUpdates: 0)

        world.createAgent()
        XCTAssertNil(world.newAgentDraft, "A closed world cannot open the editor")
        world.open(pluginID: plugin.id, screenID: interactive.id)
        XCTAssertTrue(world.canCreateAgent)
        XCTAssertEqual(world.snapshot["canCreateAgent"] as? Bool, true)
        world.createAgent()
        let cancelledID = try XCTUnwrap(world.newAgentDraft?.id)
        world.createAgent()
        XCTAssertEqual(world.newAgentDraft?.id, cancelledID, "Repeated clicks must retain the current draft")
        world.newAgentDraft = nil
        XCTAssertTrue(app.agentProfiles.isEmpty, "Cancelling must not save a resident")

        world.createAgent()
        var draft = try XCTUnwrap(world.newAgentDraft)
        XCTAssertNotEqual(draft.id, cancelledID)
        XCTAssertEqual(draft.accessCeiling, .readOnly)
        draft.name = "New Captain"; draft.model = "exact-local:7b"
        let foreignDraft = AgentProfile(name: "Unrequested Captain", model: "exact-local:7b")
        world.saveNewAgent(foreignDraft)
        XCTAssertTrue(app.agentProfiles.isEmpty, "Only the native editor's current draft may be saved")
        let pinnedWorkspace = world.workspace
        let foregroundSession = app.currentSessionID
        app.initialWorkspacePath = root.appendingPathComponent("another-project").path
        world.saveNewAgent(draft)
        XCTAssertNil(world.newAgentDraft)
        XCTAssertEqual(app.agentProfiles.map(\.id), [draft.id])
        XCTAssertEqual(app.agentProfiles.first?.model, "exact-local:7b")
        XCTAssertEqual(world.residents.map(\.id), [draft.id.uuidString])
        XCTAssertEqual((world.snapshot["agents"] as? [[String: Any]])?.first?["name"] as? String, "New Captain")
        XCTAssertEqual(world.workspace, pinnedWorkspace)
        XCTAssertEqual(app.currentSessionID, foregroundSession)
        XCTAssertFalse(world.conversationPresented)
        XCTAssertEqual(conversationsCreated, 0)

        world.open(pluginID: plugin.id, screenID: readOnly.id)
        world.createAgent()
        XCTAssertFalse(world.canCreateAgent)
        XCTAssertEqual(world.snapshot["canCreateAgent"] as? Bool, false)
        XCTAssertNil(world.newAgentDraft)

        world.open(pluginID: plugin.id, screenID: interactive.id)
        world.createAgent()
        var revokedDraft = try XCTUnwrap(world.newAgentDraft)
        revokedDraft.name = "Revoked Captain"; revokedDraft.model = "exact-local:7b"
        app.extensionsModel.extensions = .empty
        world.saveNewAgent(revokedDraft)
        XCTAssertFalse(world.canCreateAgent)
        XCTAssertNil(world.newAgentDraft)
        XCTAssertEqual(app.agentProfiles.map(\.id), [draft.id], "Revoking the world must revoke an open editor's save")
    }

    func testResidentAppearanceBridgeAcceptsOnlySupportedStylesAndOnePreferenceAtATime() {
        for style in ["mixed", "pandas", "explorers"] {
            XCTAssertEqual(PluginScreenMessage.decode(["version": 1, "type": "preferences", "preferences": ["residentStyle": style]], screen: screen), .residentStyle(style))
        }
        for style in ["", "Pandas", "Mixed", "panda", "../pandas", "<script>", "outpost"] {
            XCTAssertFalse(AgentWorldModel.isSafeResidentStyle(style))
            XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "preferences", "preferences": ["residentStyle": style]], screen: screen))
        }
        for preferences: [String: Any] in [[:], ["residentStyle": true], ["residentStyle": ["pandas"]],
                                          ["residentStyle": "pandas", "theme": "outpost"],
                                          ["residentStyle": "pandas", "unknown": "value"]] {
            XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "preferences", "preferences": preferences], screen: screen))
        }
        let readOnly = ExtensionPluginScreen(id: screen.id, title: screen.title, entrypoint: screen.entrypoint, version: 1, capabilities: ["agents.read"])
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "preferences", "preferences": ["residentStyle": "pandas"]], screen: readOnly))
    }

    func testResidentAppearanceDefaultsToMixedInTheEmptySnapshot() {
        let model = AgentWorldModel()
        XCTAssertEqual(model.residentStyle, "mixed")
        XCTAssertEqual(model.snapshot["residentStyle"] as? String, "mixed")
        model.setResidentStyle("pandas")
        XCTAssertEqual(model.residentStyle, "mixed", "A closed or revoked world cannot change preferences")
    }

    func testResidentAppearancePersistsPerScreenAndRestoresWithoutChangingTheTheme() throws {
        let suiteName = "AgentWorldAppearanceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let titlePrefix = "Agent World Appearance Test " + UUID().uuidString
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ui"), withIntermediateDirectories: true)
        try Data("<!doctype html><html><body>Local appearance fixture</body></html>".utf8).write(to: root.appendingPathComponent("ui/index.html"))
        defer {
            for window in NSApp.windows where window.title.hasPrefix(titlePrefix) { window.close() }
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let first = ExtensionPluginScreen(id: "first", title: titlePrefix, entrypoint: "ui/index.html", version: 1, capabilities: ["agents.read", "world.preferences"])
        let second = ExtensionPluginScreen(id: "second", title: titlePrefix, entrypoint: "ui/index.html", version: 1, capabilities: ["agents.read", "world.preferences"])
        let readOnly = ExtensionPluginScreen(id: "read-only", title: titlePrefix, entrypoint: "ui/index.html", version: 1, capabilities: ["agents.read"])
        let pluginID = "appearance-fixture"
        var plugin = ExtensionPlugin(id: pluginID, name: pluginID, displayName: "Appearance fixture", description: nil,
                                     version: "1.0.0", author: nil, digest: "fixture", enabledGlobal: true,
                                     enabledWorkspaces: [], disabledWorkspaces: [], previousVersions: nil,
                                     skills: [], mcpServers: [], scripts: [], unsupported: [], updateAvailable: false, error: nil)
        plugin.root = root.path; plugin.screens = [first, second, readOnly]
        var capabilities = ExtensionCapabilities(); capabilities.pluginScreens = true
        let extensions = ExtensionsModel()
        extensions.extensions = ExtensionsResponse(capabilities: capabilities, marketplaces: [], plugins: [plugin], skills: [],
                                                   mcpServers: [], mcpPresets: [], errors: [], pendingUpdates: 0)
        let key = "Locus.AgentWorld.residentStyle.v1." + pluginID + ":" + first.id
        defaults.set("unrecognized-style", forKey: key)
        let captain = AgentProfile(name: "Ship Captain", model: "Fixture model")
        let model = AgentWorldModel()
        model.configure(extensions: extensions, profiles: { [captain] }, workspace: { root.path }, availability: { _ in nil },
                        state: { _ in .init() }, create: { _, _ in XCTFail("Appearance changes must not create a conversation"); return "unused" },
                        load: { _ in }, dispatch: { _, _, _, _, _ in XCTFail("Appearance changes must not dispatch work") },
                        stop: { _ in }, open: { _ in }, manage: {}, defaults: defaults)
        model.open(pluginID: pluginID, screenID: first.id)
        XCTAssertEqual(model.residentStyle, "mixed", "Unrecognized saved styles must use the mixed crew default")
        model.setShipStyle(agentID: UUID().uuidString, style: "ship_garp_battleship")
        XCTAssertTrue(model.shipStyles.isEmpty, "Unknown captains cannot acquire style preferences")
        model.setShipStyle(agentID: captain.id.uuidString, style: "ship_garp_battleship")
        model.setShipStyle(agentID: captain.id.uuidString, style: "../invalid.glb")
        XCTAssertEqual(model.shipStyles[captain.id.uuidString], "ship_garp_battleship")
        XCTAssertEqual((model.snapshot["shipStyles"] as? [String: String])?[captain.id.uuidString], "ship_garp_battleship")
        model.setResidentStyle("pandas")
        XCTAssertEqual(model.residentStyle, "pandas")
        XCTAssertEqual(model.snapshot["residentStyle"] as? String, "pandas")
        XCTAssertEqual(defaults.string(forKey: key), "pandas")
        model.setResidentStyle("invalid")
        XCTAssertEqual(model.residentStyle, "pandas")
        model.setTheme("grand-line")
        XCTAssertEqual(model.residentStyle, "pandas", "Changing worlds must preserve the campus appearance preference")
        model.open(pluginID: pluginID, screenID: second.id)
        XCTAssertTrue(model.shipStyles.isEmpty, "Ship styles are scoped to their world screen")
        model.setShipStyle(agentID: captain.id.uuidString, style: "ship_mihawk_coffin")
        XCTAssertEqual(model.residentStyle, "mixed", "An unconfigured screen uses the mixed crew default")
        model.setResidentStyle("explorers")
        XCTAssertEqual(defaults.string(forKey: key), "pandas")
        model.open(pluginID: pluginID, screenID: first.id)
        XCTAssertEqual(model.residentStyle, "pandas")
        XCTAssertEqual(model.theme, "grand-line")
        XCTAssertEqual(model.shipStyles[captain.id.uuidString], "ship_garp_battleship", "Each captain’s ship survives closing and reopening the world")
        model.setShipStyle(agentID: captain.id.uuidString, style: nil)
        XCTAssertNil(model.shipStyles[captain.id.uuidString], "Automatic clears the explicit override")
        model.open(pluginID: pluginID, screenID: second.id)
        XCTAssertEqual(model.residentStyle, "explorers", "Explicit saved explorer choices survive the new mixed default")
        model.setResidentStyle("mixed")
        XCTAssertEqual(model.snapshot["residentStyle"] as? String, "mixed")
        XCTAssertEqual(defaults.string(forKey: "Locus.AgentWorld.residentStyle.v1." + pluginID + ":" + second.id), "mixed")
        model.open(pluginID: pluginID, screenID: first.id)
        XCTAssertEqual(model.residentStyle, "pandas", "Explicit saved panda choices remain independent of other screens")
        model.open(pluginID: pluginID, screenID: second.id)
        XCTAssertEqual(model.residentStyle, "mixed", "Mixed crew choices restore through the same preference bridge")
        model.open(pluginID: pluginID, screenID: readOnly.id)
        model.setShipStyle(agentID: captain.id.uuidString, style: "ship_garp_battleship")
        XCTAssertTrue(model.shipStyles.isEmpty, "A screen without world preferences cannot change ship styles")
        model.setResidentStyle("pandas")
        XCTAssertEqual(model.residentStyle, "mixed")
        XCTAssertNil(defaults.string(forKey: "Locus.AgentWorld.residentStyle.v1." + pluginID + ":" + readOnly.id))
    }

    func testFilesRejectTraversalAbsolutePathsAndEscapingSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ui"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("<html></html>".utf8).write(to: root.appendingPathComponent("ui/index.html"))
        try Data("private".utf8).write(to: base.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ui/escape"), withDestinationURL: base.appendingPathComponent("outside"))
        XCTAssertEqual(try PluginScreenFiles.file(root: root, path: "ui/index.html").lastPathComponent, "index.html")
        XCTAssertThrowsError(try PluginScreenFiles.file(root: root, path: "ui/escape"))
        for path in ["../outside", "/etc/passwd", "ui/../outside", "ui//index.html", "./ui/index.html", "ui/%2e%2e/outside", "ui\\index.html", "https://example.com/index.html", "ui/index.html?secret"] {
            XCTAssertFalse(PluginScreenFiles.isSafeRelativePath(path), path)
            XCTAssertThrowsError(try PluginScreenFiles.file(root: root, path: path), path)
        }
    }

    func testOlderPluginSnapshotsDecodeWithoutScreenCapability() throws {
        let data = Data(#"{"streamable_http":true,"stdio":false,"oauth":true,"mcp_apps":false,"hooks":false,"sandboxed":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ExtensionCapabilities.self, from: data).pluginScreens)
        let plugin = Data(#"{"id":"legacy","name":"legacy","enabled_global":true,"enabled_workspaces":[],"disabled_workspaces":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(ExtensionPlugin.self, from: plugin)
        XCTAssertNil(decoded.screens)
        XCTAssertNil(decoded.root)
    }

    func testWorkspaceDisableOverridesGlobalEnable() throws {
        let data = Data(#"{"id":"world","name":"world","enabled_global":true,"enabled_workspaces":["/tmp/project"],"disabled_workspaces":["/tmp/project"]}"#.utf8)
        let plugin = try JSONDecoder().decode(ExtensionPlugin.self, from: data)
        XCTAssertFalse(AgentWorldModel.enabled(plugin, workspace: "/tmp/project"))
        XCTAssertTrue(AgentWorldModel.enabled(plugin, workspace: "/tmp/another-project"))
    }

    func testBindingsSeparateProjectsAndProfilesAndReuseConcurrentCreation() async throws {
        let model = AgentWorldModel()
        let profiles = [AgentProfile(name: "Atlas", model: "exact"), AgentProfile(name: "Nova", model: "exact")]
        var creations = 0
        model.configure(extensions: ExtensionsModel(), profiles: { profiles }, workspace: { "/tmp/project" }, availability: { _ in nil },
                        state: { _ in .init() }, create: { _, _ in
            creations += 1
            let id = "session-\(creations)"
            try await Task.sleep(for: .milliseconds(20))
            return id
        }, load: { _ in }, dispatch: { _, _, _, _, _ in }, stop: { _ in }, open: { _ in }, manage: {}, defaults: nil)
        async let first = model.conversation(workspace: "/tmp/project", profile: profiles[0])
        async let second = model.conversation(workspace: "/tmp/project", profile: profiles[0])
        let values = try await [first, second]
        XCTAssertEqual(values[0], values[1])
        XCTAssertEqual(creations, 1)
        let otherAgent = try await model.conversation(workspace: "/tmp/project", profile: profiles[1])
        let otherProject = try await model.conversation(workspace: "/tmp/another-project", profile: profiles[0])
        XCTAssertNotEqual(otherAgent, values[0])
        XCTAssertNotEqual(otherProject, values[0])
        XCTAssertEqual(creations, 3)
        XCTAssertNotEqual(AgentWorldModel.bindingKey(workspace: "/tmp/project", profileID: profiles[0].id.uuidString),
                          AgentWorldModel.bindingKey(workspace: "/tmp/project", profileID: profiles[1].id.uuidString))
        model.dismissConversation()
        XCTAssertFalse(model.conversationBusy)
        XCTAssertEqual(model.pendingCount, 0)
    }
    func testProfileDispatchKeepsExactModelAndRejectsMissingIdentity() throws {
        let model = AppModel(startImmediately: false)
        let profile = AgentProfile(name: "Atlas", model: "exact-local:7b", instructions: "Review carefully", tokenLimit: 4096)
        model.agentProfiles = [profile]
        let dispatch = try model.agentWorldProfileDispatch(profileID: profile.id, mode: .ask)
        XCTAssertTrue(dispatch.profileOnly)
        XCTAssertEqual(dispatch.profile.model, "exact-local:7b")
        XCTAssertEqual(dispatch.mode, .ask)
        XCTAssertEqual(dispatch.provider, "ollama")
        XCTAssertThrowsError(try model.agentWorldProfileDispatch(profileID: UUID(), mode: .work))
        var disconnected = profile
        disconnected.route = .providerAccount(UUID())
        model.agentProfiles = [disconnected]
        XCTAssertThrowsError(try model.agentWorldProfileDispatch(profileID: disconnected.id, mode: .work))
        let payload = AppModel.agentWorldProfileBody(profile)
        XCTAssertEqual(payload["token_limit"] as? Int, 4096)
        XCTAssertEqual(payload["access_ceiling"] as? String, profile.accessCeiling.rawValue)
        XCTAssertEqual(payload["instructions"] as? String, "Review carefully")
        XCTAssertNil(payload["api_key"])
        XCTAssertNil(payload["route"])
    }

    func testLocalSchemeServesSuccessfulFetchAndXHRResponsesForArtwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ui"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><html><head></head><body>Local world</body></html>".utf8)
            .write(to: root.appendingPathComponent("ui/index.html"))
        try Data(#"{"theme":"outpost"}"#.utf8).write(to: root.appendingPathComponent("ui/theme.json"))
        try Data([0x67, 0x6c, 0x54, 0x46]).write(to: root.appendingPathComponent("ui/resident.glb"))
        let handler = PluginScreenSchemeHandler(root: root)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: PluginScreenSchemeHandler.scheme)
        let web = WKWebView(frame: .zero, configuration: configuration)
        let waiter = LoadWaiter()
        web.navigationDelegate = waiter
        defer { handler.revoked = true; web.stopLoading(); web.navigationDelegate = nil }
        web.load(URLRequest(url: try XCTUnwrap(URL(string: "locus-screen://plugin/ui/index.html"))))
        try await waiter.wait()
        let raw = try await web.callAsyncJavaScript("""
            const json = await fetch('./theme.json');
            const theme = await json.json();
            const binary = await fetch('./resident.glb');
            const bytes = Array.from(new Uint8Array(await binary.arrayBuffer()));
            const xhr = await new Promise((resolve, reject) => {
                const request = new XMLHttpRequest();
                request.open('GET', './resident.glb');
                request.responseType = 'arraybuffer';
                request.timeout = 5000;
                request.onload = () => resolve({status: request.status, bytes: Array.from(new Uint8Array(request.response))});
                request.onerror = () => reject(new Error('Local binary XHR failed'));
                request.ontimeout = () => reject(new Error('Local binary XHR timed out'));
                request.send();
            });
            return {jsonOK: json.ok, jsonStatus: json.status, theme: theme.theme,
                    binaryOK: binary.ok, binaryStatus: binary.status, bytes, xhr};
            """, arguments: [:], in: nil, contentWorld: .page)
        let result = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(result["jsonOK"] as? Bool, true)
        XCTAssertEqual(result["jsonStatus"] as? Int, 200)
        XCTAssertEqual(result["theme"] as? String, "outpost")
        XCTAssertEqual(result["binaryOK"] as? Bool, true)
        XCTAssertEqual(result["binaryStatus"] as? Int, 200)
        XCTAssertEqual(result["bytes"] as? [Int], [0x67, 0x6c, 0x54, 0x46])
        let xhr = try XCTUnwrap(result["xhr"] as? [String: Any])
        XCTAssertEqual(xhr["status"] as? Int, 200)
        XCTAssertEqual(xhr["bytes"] as? [Int], [0x67, 0x6c, 0x54, 0x46])
        handler.revoked = true
        let afterRevoke = try await web.callAsyncJavaScript("""
            try { await fetch('./theme.json'); return 'loaded'; }
            catch { return 'revoked'; }
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(afterRevoke as? String, "revoked")
    }

    func testReplacingConversationPreservesProfileHistoryAcrossRestoreAndMigratesLegacyBindings() async throws {
        let suiteName = "AgentWorldTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = AgentProfile(name: "Atlas", model: "exact")
        let workspace = "/tmp/agent-world-project"
        let key = AgentWorldModel.bindingKey(workspace: workspace, profileID: profile.id.uuidString)
        defaults.set(try JSONEncoder().encode([key: "original-session"]), forKey: "Locus.AgentWorld.conversations.v1")
        var creations = 0
        func configure(_ model: AgentWorldModel) {
            model.configure(extensions: ExtensionsModel(), profiles: { [profile] }, workspace: { workspace },
                            availability: { _ in nil }, state: { _ in .init() }, create: { _, _ in
                creations += 1
                return "replacement-session"
            }, load: { _ in }, dispatch: { _, _, _, _, _ in }, stop: { _ in }, open: { _ in }, manage: {}, defaults: defaults)
        }
        let model = AgentWorldModel()
        configure(model)
        XCTAssertEqual(model.boundProfileID(for: "original-session"), profile.id, "Existing current bindings migrate into persistent history")
        XCTAssertTrue(model.resetCurrentConversation(workspace: workspace, profileID: profile.id))
        XCTAssertEqual(model.boundProfileID(for: "original-session"), profile.id)
        let replacement = try await model.conversation(workspace: workspace, profile: profile)
        XCTAssertEqual(replacement, "replacement-session")
        XCTAssertEqual(model.boundProfileID(for: replacement), profile.id)
        XCTAssertEqual(model.boundProfileID(for: "original-session"), profile.id)
        let restored = AgentWorldModel()
        configure(restored)
        XCTAssertEqual(restored.boundProfileID(for: "original-session"), profile.id, "Old history must still use the exact saved profile")
        XCTAssertEqual(restored.boundProfileID(for: replacement), profile.id)
        let current = try await restored.conversation(workspace: workspace, profile: profile)
        XCTAssertEqual(current, replacement)
        XCTAssertEqual(creations, 1, "Restoring must reuse the replacement without creating another chat")
    }

    func testRetryOnHistoricalAgentConversationDoesNotEnterUnprofiledRetryState() throws {
        let suiteName = "AgentWorldTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = AgentProfile(name: "Atlas", model: "exact")
        defaults.set(try JSONEncoder().encode(["historical-session": profile.id.uuidString]), forKey: "Locus.AgentWorld.profileHistory.v1")
        let model = AppModel(startImmediately: false)
        model.agentWorld.configure(extensions: model.extensionsModel, profiles: { [profile] }, workspace: { "/tmp" },
                                   availability: { _ in nil }, state: { _ in .init() }, create: { _, _ in "unused" },
                                   load: { _ in }, dispatch: { _, _, _, _, _ in }, stop: { _ in }, open: { _ in }, manage: {}, defaults: defaults)
        model.currentSessionID = "historical-session"
        model.blocks = [ChatBlock(kind: .user, text: "Review the workspace")]
        model.retryLastResponse()
        XCTAssertFalse(model.pendingRetry)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.toastMessage?.contains("saved profile") == true)
    }

    func testCorruptCurrentBindingCannotBorrowAnotherResidentsChat() async throws {
        let suiteName = "AgentWorldOwnershipTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let jinbei = AgentProfile(name: "Jinbei", model: "fixture")
        let luffy = AgentProfile(name: "Luffy", model: "fixture")
        let key = AgentWorldModel.bindingKey(workspace: "/tmp/world", profileID: jinbei.id.uuidString)
        defaults.set(try JSONEncoder().encode([key: "luffy-session"]), forKey: "Locus.AgentWorld.conversations.v1")
        defaults.set(try JSONEncoder().encode(["luffy-session": luffy.id.uuidString]), forKey: "Locus.AgentWorld.profileHistory.v1")
        let world = AgentWorldModel()
        world.configure(extensions: ExtensionsModel(), profiles: { [jinbei, luffy] }, workspace: { "/tmp/world" },
                        availability: { _ in nil }, state: { _ in .init() },
                        create: { _, _ in XCTFail("A corrupt binding must require explicit recovery"); return "unexpected" },
                        load: { _ in }, dispatch: { _, _, _, _, _ in }, stop: { _ in }, open: { _ in }, manage: {}, defaults: defaults)
        do {
            _ = try await world.conversation(workspace: "/tmp/world", profile: jinbei)
            XCTFail("The saved ownership conflict must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("another agent")) }
        XCTAssertEqual(world.boundProfileID(for: "luffy-session"), luffy.id)
        XCTAssertTrue(world.resetCurrentConversation(workspace: "/tmp/world", profileID: jinbei.id))
        XCTAssertEqual(world.boundProfileID(for: "luffy-session"), luffy.id, "Recovery preserves the original owner's restrictions")
    }

    func testMissingResidentChatRecoversExplicitlyWithoutAdoptingAnotherAgent() async throws {
        let fixture = try conversationFixture()
        defer { fixture.close() }
        let app = AppModel(startImmediately: false)
        app.currentSessionID = "luffy-foreground"
        app.selectedSavedAgentID = fixture.profiles[1].id
        app.agentProfiles = fixture.profiles
        let world = app.agentWorld
        var createdFor: [UUID] = []
        world.configure(extensions: fixture.extensions, profiles: { fixture.profiles }, workspace: { fixture.root.path },
                        availability: { _ in nil }, state: { _ in .init() }, create: { _, profile in
            createdFor.append(profile.id); return "replacement-jinbei"
        }, load: { id in
            if id == "missing-jinbei" { throw NSError(domain: "Locus.Backend", code: 404, userInfo: [NSLocalizedDescriptionKey: "No stored session"]) }
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        }, dispatch: { _, _, _, _, _ in XCTFail("Recovery must not dispatch a turn") }, stop: { _ in XCTFail("Recovery must not stop work") },
                        open: { _ in }, manage: {}, defaults: fixture.defaults)
        world.open(pluginID: fixture.pluginID)
        world.select(fixture.profiles[0].id.uuidString)
        await waitForConversationPreparation(world)
        XCTAssertEqual(world.selectedProfile?.id, fixture.profiles[0].id)
        XCTAssertNil(world.selectedSessionID, "Only a confirmed missing binding is cleared")
        XCTAssertTrue(world.error?.contains("Start a new chat") == true)
        XCTAssertTrue(world.canStartConversation(for: fixture.profiles[0].id.uuidString))
        XCTAssertTrue(createdFor.isEmpty, "Missing history never silently creates or borrows a chat")
        XCTAssertEqual(world.boundProfileID(for: "missing-jinbei"), fixture.profiles[0].id)
        XCTAssertEqual(app.currentSessionID, "luffy-foreground")

        let firstFocus = world.focusRequest
        world.openAgentProfile()
        XCTAssertEqual(world.focusRequest, firstFocus + 1)
        world.openAgentProfile()
        XCTAssertEqual(world.focusRequest, firstFocus + 2, "Clicking the selected resident focuses it again")
        XCTAssertEqual(world.snapshot["focusRequest"] as? Int, world.focusRequest)
        world.adoptForegroundConversation()
        XCTAssertTrue(world.profilePresented)
        XCTAssertEqual(world.selectedProfile?.name, "Jinbei")
        XCTAssertEqual(app.selectedSavedAgentID, fixture.profiles[1].id, "The Vivre card uses its own selected profile")
        XCTAssertEqual(app.currentSessionID, "luffy-foreground")
        XCTAssertTrue(createdFor.isEmpty)

        world.showSelectedTools()
        XCTAssertFalse(world.profilePresented)
        XCTAssertTrue(world.conversationPresented)
        XCTAssertEqual(world.selectedProfile?.name, "Jinbei")
        XCTAssertEqual(app.currentSessionID, "luffy-foreground")
        XCTAssertTrue(createdFor.isEmpty, "Reviewing saved activity must not create a chat")
        world.openAgentProfile()
        XCTAssertTrue(world.profilePresented, "Activity returns to the same resident's overview")

        world.newConversation(for: fixture.profiles[0].id.uuidString)
        await waitForConversationPreparation(world)
        XCTAssertEqual(createdFor, [fixture.profiles[0].id])
        XCTAssertEqual(world.selectedSessionID, "replacement-jinbei", "A network failure must retain the replacement for retry")
        XCTAssertFalse(world.profilePresented)
        XCTAssertEqual(world.boundProfileID(for: "replacement-jinbei"), fixture.profiles[0].id)
        XCTAssertEqual(world.boundProfileID(for: "missing-jinbei"), fixture.profiles[0].id)
        XCTAssertEqual(app.currentSessionID, "luffy-foreground")
        let untouched = try await world.conversation(workspace: fixture.root.path, profile: fixture.profiles[1])
        XCTAssertEqual(untouched, "luffy-foreground")
    }

    func testOpeningVivreCardCancelsStaleRecoveryAndProtectsBusyResident() async throws {
        let fixture = try conversationFixture()
        defer { fixture.close() }
        let world = AgentWorldModel()
        var loads = 0
        var continuation: CheckedContinuation<Void, Never>?
        world.configure(extensions: fixture.extensions, profiles: { fixture.profiles }, workspace: { fixture.root.path },
                        availability: { _ in nil }, state: { id in .init(busy: id == "luffy-foreground") },
                        create: { _, _ in XCTFail("Profile inspection must not create chats"); return "unexpected" },
                        load: { _ in
            loads += 1
            await withCheckedContinuation { continuation = $0 }
            throw NSError(domain: "Locus.Backend", code: 404)
        }, dispatch: { _, _, _, _, _ in }, stop: { _ in }, open: { _ in }, manage: {}, defaults: fixture.defaults)
        world.open(pluginID: fixture.pluginID)
        world.select(fixture.profiles[0].id.uuidString)
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation)
        world.openAgentProfile(fixture.profiles[1].id.uuidString)
        continuation?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(world.profilePresented)
        XCTAssertFalse(world.preparingConversation)
        XCTAssertEqual(world.selectedProfile?.name, "Luffy")
        XCTAssertEqual(world.selectedSessionID, "luffy-foreground")
        XCTAssertNil(world.error, "A previous resident's delayed failure cannot replace the current profile")
        XCTAssertFalse(world.canStartConversation(for: fixture.profiles[1].id.uuidString))
        world.newConversation(for: fixture.profiles[1].id.uuidString)
        XCTAssertTrue(world.profilePresented, "Busy resident actions must not switch the panel")
        XCTAssertFalse(world.canStartConversation(for: UUID().uuidString))
        let previous = try await world.conversation(workspace: fixture.root.path, profile: fixture.profiles[0])
        XCTAssertEqual(previous, "missing-jinbei", "Cancelled loads do not invalidate unseen bindings")
    }

    private func waitForConversationPreparation(_ world: AgentWorldModel) async {
        for _ in 0..<200 {
            if !world.preparingConversation { break }
            await Task.yield()
        }
        XCTAssertFalse(world.preparingConversation, "Conversation preparation should have completed")
    }

    private struct ConversationFixture {
        let root: URL
        let defaults: UserDefaults
        let suiteName: String
        let pluginID: String
        let title: String
        let profiles: [AgentProfile]
        let extensions: ExtensionsModel
        @MainActor func close() {
            for window in NSApp.windows where window.title.hasPrefix(title) { window.close() }
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func conversationFixture() throws -> ConversationFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let title = "Agent World Conversation Recovery " + UUID().uuidString
        let suiteName = "AgentWorldRecoveryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let profiles = [AgentProfile(name: "Jinbei", model: "fixture"), AgentProfile(name: "Luffy", model: "fixture")]
        let bindings = [AgentWorldModel.bindingKey(workspace: root.path, profileID: profiles[0].id.uuidString): "missing-jinbei",
                        AgentWorldModel.bindingKey(workspace: root.path, profileID: profiles[1].id.uuidString): "luffy-foreground"]
        defaults.set(try JSONEncoder().encode(bindings), forKey: "Locus.AgentWorld.conversations.v1")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ui"), withIntermediateDirectories: true)
        try Data("<!doctype html><html><body>Conversation recovery fixture</body></html>".utf8).write(to: root.appendingPathComponent("ui/index.html"))
        let pluginID = "recovery-fixture"
        var plugin = ExtensionPlugin(id: pluginID, name: pluginID, displayName: title, description: nil,
                                     version: "1.0.0", author: nil, digest: "fixture", enabledGlobal: true,
                                     enabledWorkspaces: [], disabledWorkspaces: [], previousVersions: nil,
                                     skills: [], mcpServers: [], scripts: [], unsupported: [], updateAvailable: false, error: nil)
        plugin.root = root.path
        plugin.screens = [ExtensionPluginScreen(id: "recovery", title: title, entrypoint: "ui/index.html", version: 1,
                                               capabilities: ["agents.read", "agents.interact", "world.preferences"])]
        var capabilities = ExtensionCapabilities(); capabilities.pluginScreens = true
        let extensions = ExtensionsModel()
        extensions.extensions = ExtensionsResponse(capabilities: capabilities, marketplaces: [], plugins: [plugin], skills: [],
                                                   mcpServers: [], mcpPresets: [], errors: [], pendingUpdates: 0)
        return ConversationFixture(root: root, defaults: defaults, suiteName: suiteName, pluginID: pluginID, title: title, profiles: profiles, extensions: extensions)
    }

}


@MainActor
final class LocusCalendarTests: XCTestCase {
    private func makeStore() throws -> (LocusCalendarStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocusCalendarTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (LocusCalendarStore(applicationSupport: root, externalCalendarsEnabled: false), root)
    }
    private var createArguments: [String: Any] {
        ["title": "Crew planning", "start": "2026-09-22T10:00:00-04:00", "end": "2026-09-22T11:00:00-04:00"]
    }

    func testBuiltInCalendarWorksWithoutExternalPermissionAndPersistsTags() throws {
        let (store, root) = try makeStore()
        XCTAssertFalse(store.accessState.canRead)
        let agent = UUID()
        var arguments = createArguments
        arguments["agent_ids"] = [agent.uuidString, agent.uuidString]
        let result = store.perform(tool: "calendar_create", arguments: arguments)
        XCTAssertNil(result["error"])
        let id = try XCTUnwrap(result["event_id"] as? String)
        let restored = LocusCalendarStore(applicationSupport: root, externalCalendarsEnabled: false)
        XCTAssertEqual(restored.localEvents.count, 1)
        XCTAssertEqual(restored.localEvents[0].id, id)
        XCTAssertEqual(restored.localEvents[0].agentIDs, [agent])
        let list = restored.perform(tool: "calendar_list", arguments: ["start": "2026-09-22T00:00:00Z", "end": "2026-09-23T00:00:00Z"])
        let events = try XCTUnwrap(list["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["calendar_id"] as? String, "locus")
        XCTAssertEqual(events[0]["agent_ids"] as? [String], [agent.uuidString])
    }

    func testEditingClearingTagsAndDeletingLocalEvent() throws {
        let (store, root) = try makeStore()
        let id = try XCTUnwrap(store.perform(tool: "calendar_create", arguments: createArguments)["event_id"] as? String)
        let agent = UUID()
        XCTAssertNil(store.perform(tool: "calendar_update", arguments: ["event_id": id, "title": "Updated", "agent_ids": [agent.uuidString]])["error"])
        XCTAssertEqual(store.localEvents.first?.title, "Updated")
        XCTAssertEqual(store.localEvents.first?.agentIDs, [agent])
        XCTAssertNil(store.perform(tool: "calendar_update", arguments: ["event_id": id, "agent_ids": [String]()])["error"])
        XCTAssertEqual(store.localEvents.first?.agentIDs, [])
        XCTAssertNil(store.perform(tool: "calendar_delete", arguments: ["event_id": id])["error"])
        XCTAssertTrue(LocusCalendarStore(applicationSupport: root, externalCalendarsEnabled: false).localEvents.isEmpty)
        XCTAssertNotNil(store.perform(tool: "calendar_update", arguments: ["event_id": id, "title": "Gone"])["error"])
    }

    func testInvalidUpdatesDoNotChangeSavedEventOrFallBackToLocal() throws {
        let (store, _) = try makeStore()
        let id = try XCTUnwrap(store.perform(tool: "calendar_create", arguments: createArguments)["event_id"] as? String)
        let before = store.localEvents
        for fields: [String: Any] in [
            ["title": ""], ["end": "2026-09-21T10:00:00Z"], ["start": "not-a-date"],
            ["agent_ids": ["not-an-agent"]], ["calendar_id": "external-account"],
        ] {
            var arguments = fields; arguments["event_id"] = id
            XCTAssertNotNil(store.perform(tool: "calendar_update", arguments: arguments)["error"])
            XCTAssertEqual(store.localEvents, before)
        }
        var external = createArguments; external["calendar_id"] = "external-account"
        XCTAssertNotNil(store.perform(tool: "calendar_create", arguments: external)["error"])
        XCTAssertEqual(store.localEvents, before)
    }

    func testAllDayAndMultiDayEventsRespectExclusiveEndAndVisibility() throws {
        let (store, _) = try makeStore()
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 2, to: start)!
        try store.saveLocalEvent(LocusCalendarEntry(title: "Voyage", startDate: start, endDate: end, isAllDay: true))
        XCTAssertEqual(store.events(on: start).count, 1)
        XCTAssertEqual(store.events(on: start.addingTimeInterval(86400)).count, 1)
        XCTAssertTrue(store.events(on: end).isEmpty)
        store.showsLocalCalendar = false
        XCTAssertTrue(store.events(on: start).isEmpty)
        store.showsLocalCalendar = true
        XCTAssertEqual(store.events(on: start).count, 1)
    }

    func testUnreadableCalendarIsNeverOverwritten() throws {
        let (_, root) = try makeStore()
        let file = root.appendingPathComponent(AppEdition.current.displayName).appendingPathComponent("Calendar/events.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("preserve damaged calendar".utf8)
        try damaged.write(to: file)
        let store = LocusCalendarStore(applicationSupport: root, externalCalendarsEnabled: false)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNotNil(store.perform(tool: "calendar_create", arguments: createArguments)["error"])
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        XCTAssertTrue(store.localEvents.isEmpty)
    }

    func testFailedSaveDoesNotPublishAnUnsavedEvent() throws {
        let (store, root) = try makeStore()
        // A file where the directory belongs forces an ordinary filesystem failure.
        try Data("blocked".utf8).write(to: root.appendingPathComponent(AppEdition.current.displayName))
        XCTAssertNotNil(store.perform(tool: "calendar_create", arguments: createArguments)["error"])
        XCTAssertTrue(store.localEvents.isEmpty)
    }
}
