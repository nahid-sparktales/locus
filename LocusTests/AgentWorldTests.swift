import AppKit
import Foundation
import WebKit
import XCTest
@testable import Locus

@MainActor
final class AgentWorldTests: XCTestCase {
    private let screen = ExtensionPluginScreen(id: "agent-world", title: "Agent World", entrypoint: "ui/index.html", version: 1,
                                               capabilities: ["agents.read", "agents.interact", "world.preferences"])

    func testBridgeRejectsUnknownCapabilitiesVersionsAndPayloads() {
        XCTAssertEqual(PluginScreenMessage.decode(["version": 1, "type": "ready"], screen: screen), .ready)
        XCTAssertNil(PluginScreenMessage.decode(["version": true, "type": "ready"], screen: screen))
        XCTAssertNil(PluginScreenMessage.decode(["version": 2, "type": "ready"], screen: screen))
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "ready", "api_key": "never"], screen: screen))
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "send", "text": "Execute code"], screen: screen))
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "selectAgent", "agentID": "bad"], screen: screen))
        let id = UUID().uuidString
        XCTAssertEqual(PluginScreenMessage.decode(["version": 1, "type": "selectAgent", "agentID": id.lowercased()], screen: screen), .selectAgent(id))
        let readOnly = ExtensionPluginScreen(id: screen.id, title: screen.title, entrypoint: screen.entrypoint, version: 1, capabilities: ["agents.read"])
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "selectAgent", "agentID": id], screen: readOnly))
        let unknown = ExtensionPluginScreen(id: screen.id, title: screen.title, entrypoint: screen.entrypoint, version: 1, capabilities: ["credentials.read"])
        XCTAssertFalse(unknown.isSupported)
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
        let model = AgentWorldModel()
        model.configure(extensions: extensions, profiles: { [] }, workspace: { root.path }, availability: { _ in nil },
                        state: { _ in .init() }, create: { _, _ in XCTFail("Appearance changes must not create a conversation"); return "unused" },
                        load: { _ in }, dispatch: { _, _, _, _, _ in XCTFail("Appearance changes must not dispatch work") },
                        stop: { _ in }, open: { _ in }, manage: {}, defaults: defaults)
        model.open(pluginID: pluginID, screenID: first.id)
        XCTAssertEqual(model.residentStyle, "mixed", "Unrecognized saved styles must use the mixed crew default")
        model.setResidentStyle("pandas")
        XCTAssertEqual(model.residentStyle, "pandas")
        XCTAssertEqual(model.snapshot["residentStyle"] as? String, "pandas")
        XCTAssertEqual(defaults.string(forKey: key), "pandas")
        model.setResidentStyle("invalid")
        XCTAssertEqual(model.residentStyle, "pandas")
        model.setTheme("grand-line")
        XCTAssertEqual(model.residentStyle, "pandas", "Changing worlds must preserve the campus appearance preference")
        model.open(pluginID: pluginID, screenID: second.id)
        XCTAssertEqual(model.residentStyle, "mixed", "An unconfigured screen uses the mixed crew default")
        model.setResidentStyle("explorers")
        XCTAssertEqual(defaults.string(forKey: key), "pandas")
        model.open(pluginID: pluginID, screenID: first.id)
        XCTAssertEqual(model.residentStyle, "pandas")
        XCTAssertEqual(model.theme, "grand-line")
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

}
