import AppKit
import Foundation
import WebKit
import XCTest
@testable import Locus

@MainActor
final class AgentWorldBridgeTests: XCTestCase {
    func testSharedWireFixturesMatchThePinnedSDK() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("ProtocolFixtures/agent-worlds/wire-v2.json"))
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for vector in try XCTUnwrap(fixture["vectors"] as? [[String: Any]]) {
            let body = try XCTUnwrap(vector["message"])
            let actual = vector["direction"] as? String == "client"
                ? AgentWorldBridgeContract.decode(body) != nil : AgentWorldBridgeContract.validHostMessage(body)
            XCTAssertEqual(actual, vector["valid"] as? Bool, vector["id"] as? String ?? "fixture")
        }
    }

    func testVersionTwoCannotExecuteLegacyMessagesOrNativeSocialScreen() {
        let screen = ExtensionPluginScreen(id: "agent-world", title: "Agent Worlds", entrypoint: "ui/index.html", version: 2,
                                           capabilities: ["agents.read", "agents.interact", "world.preferences"])
        XCTAssertTrue(screen.isSupported)
        XCTAssertNil(PluginScreenMessage.decode(["version": 1, "type": "createAgent"], screen: screen))
        XCTAssertFalse(ExtensionPluginScreen(id: "social-studio", title: "Social", entrypoint: "ui/index.html", version: 2,
                                            capabilities: ["social.workspace"]).isSupported)
    }

    func testSessionBindsInstalledDigestWorkspaceAndGrantAndNeverReplaysIntent() throws {
        let identity = AgentWorldBridgeSession.Identity(pluginID: "plugin", digest: "one", root: "/plugin", workspace: "/workspace", capabilities: ["agents.read", "agents.interact"])
        let session = AgentWorldBridgeSession(identity: identity)
        var calls = 0
        let action: (AgentWorldBridgeContract.Request) throws -> [String: Any] = { _ in calls += 1; return [:] }
        let hello = AgentWorldBridgeContract.Hello(requestID: "hello", protocols: [2], runtimeVersion: "0.2.0", sdkVersion: 1, required: ["agents.read"], optional: ["agents.interact"])
        _ = session.handle(.hello(hello), current: identity, hostVersion: "1", execute: action)
        let request = AgentWorldBridgeContract.Client.request(.init(requestID: "create", sessionID: session.sessionID, scopeID: session.scopeID, command: "agents.create", arguments: [:]))
        XCTAssertEqual(session.handle(request, current: identity, hostVersion: "1", execute: action)["ok"] as? Bool, true)
        XCTAssertEqual(session.handle(request, current: identity, hostVersion: "1", execute: action)["ok"] as? Bool, true)
        XCTAssertEqual(calls, 1)
        for changed in [
            AgentWorldBridgeSession.Identity(pluginID: "plugin", digest: "two", root: "/plugin", workspace: "/workspace", capabilities: identity.capabilities),
            AgentWorldBridgeSession.Identity(pluginID: "plugin", digest: "one", root: "/plugin", workspace: "/another", capabilities: identity.capabilities),
            AgentWorldBridgeSession.Identity(pluginID: "plugin", digest: "one", root: "/plugin", workspace: "/workspace", capabilities: ["agents.read"]),
        ] {
            XCTAssertEqual((session.handle(request, current: changed, hostVersion: "1", execute: action)["error"] as? [String: Any])?["code"] as? String, "stale_session")
        }
        session.revoke()
        XCTAssertEqual((session.handle(request, current: identity, hostVersion: "1", execute: action)["error"] as? [String: Any])?["code"] as? String, "stale_session")
        XCTAssertEqual(calls, 1)
    }

    func testVisualPreferenceMigrationAndResetPreserveCanonicalBindings() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let profile = AgentProfile(name: "Captain", model: "configured:1")
        let canonical = AgentWorldModel.bindingKey(workspace: fixture.root.path, profileID: profile.id.uuidString)
        let bindings = try JSONEncoder().encode([canonical: "saved-chat"])
        let history = try JSONEncoder().encode(["saved-chat": profile.id.uuidString])
        fixture.defaults.set(bindings, forKey: "Locus.AgentWorld.conversations.v1")
        fixture.defaults.set(history, forKey: "Locus.AgentWorld.profileHistory.v1")
        fixture.defaults.set("outpost", forKey: "Locus.AgentWorld.theme.v1.fixture:agent-world")
        fixture.defaults.set("pandas", forKey: "Locus.AgentWorld.residentStyle.v1.fixture:agent-world")
        fixture.configure(profiles: [profile])
        fixture.world.open(pluginID: "fixture")
        XCTAssertEqual(fixture.world.worldPreferences["theme"] as? String, "local-line")
        XCTAssertNil(fixture.world.worldPreferences["resident-style"])
        try fixture.world.updateWorldPreference(key: "camera", value: ["zoom": 1.0])
        XCTAssertThrowsError(try fixture.world.updateWorldPreference(key: "large", value: String(repeating: "x", count: 33_000)))
        try fixture.world.resetWorldPreferences()
        XCTAssertTrue(fixture.world.worldPreferences.isEmpty)
        XCTAssertEqual(fixture.defaults.data(forKey: "Locus.AgentWorld.conversations.v1"), bindings)
        XCTAssertEqual(fixture.defaults.data(forKey: "Locus.AgentWorld.profileHistory.v1"), history)
        XCTAssertEqual(fixture.defaults.string(forKey: "Locus.AgentWorld.theme.v1.fixture:agent-world"), "outpost")
        XCTAssertEqual(fixture.world.boundProfileID(for: "saved-chat"), profile.id)
        XCTAssertTrue(AgentWorldBridgeContract.validDisplayState(fixture.world.worldDisplayState(capabilities: ["agents.read"])))
    }

    func testActualWebKitV2HandshakePublishesOnlyTheScopedProjection() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.configure(profiles: [AgentProfile(name: "Agent", model: "secret-provider-model")])
        let javascript = """
        window.received=[];
        window.locusAgentWorld={receive(message){window.received.push(message)}};
        window.webkit.messageHandlers.locusScreen.postMessage({version:2,type:'hello',requestID:'hello',protocols:[2],runtimeVersion:'0.2.0',sdkVersion:1,requiredCapabilities:['agents.read'],optionalCapabilities:[]});
        """
        try Data(javascript.utf8).write(to: fixture.root.appendingPathComponent("ui/fixture.js"))
        try Data("<html><head></head><body><script src='fixture.js'></script></body></html>".utf8).write(to: fixture.root.appendingPathComponent("ui/index.html"))
        fixture.world.open(pluginID: "fixture")
        let screen = try XCTUnwrap(fixture.world.activeScreen)
        let coordinator = PluginScreenHost.Coordinator(model: fixture.world, screen: screen)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(coordinator.files, forURLScheme: PluginScreenSchemeHandler.scheme)
        config.userContentController.add(coordinator, name: "locusScreen")
        let web = WKWebView(frame: .zero, configuration: config)
        coordinator.web = web; web.navigationDelegate = coordinator
        defer { coordinator.revoke() }
        web.load(URLRequest(url: URL(string: "locus-screen://plugin/ui/index.html")!))
        var messages: [[String: Any]] = []
        for _ in 0..<100 {
            if let value = try? await web.evaluateJavaScript("window.received || []"), let received = value as? [[String: Any]], received.count >= 2 {
                messages = received; break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(messages.first?["type"] as? String, "welcome")
        let snapshot = try XCTUnwrap(messages.first(where: { $0["type"] as? String == "snapshot" }))
        XCTAssertTrue(AgentWorldBridgeContract.validHostMessage(snapshot))
        let state = try XCTUnwrap(snapshot["state"] as? [String: Any])
        XCTAssertEqual((state["agents"] as? [[String: Any]])?.count, 1)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self).contains("secret-provider-model"))
        XCTAssertNil(fixture.world.selectedSessionID)
        XCTAssertNil(fixture.world.newAgentDraft)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let extensions = ExtensionsModel()
        let world = AgentWorldModel()
        let title = "Agent Worlds V2 Test " + UUID().uuidString
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = "AgentWorldBridgeTests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: root.appendingPathComponent("ui"), withIntermediateDirectories: true)
            try Data("<html><head></head><body>fixture</body></html>".utf8).write(to: root.appendingPathComponent("ui/index.html"))
        }
        func configure(profiles: [AgentProfile]) {
            world.configure(extensions: extensions, profiles: { profiles }, workspace: { self.root.path }, availability: { _ in nil }, state: { _ in .init() },
                            create: { _, _ in XCTFail("Display must not create a chat"); return "unexpected" }, load: { _ in },
                            dispatch: { _, _, _, _, _ in XCTFail("Display must not execute a task") }, stop: { _ in }, open: { _ in }, manage: {}, defaults: defaults)
            var plugin = ExtensionPlugin(id: "fixture", name: "agent-world", displayName: title, description: nil, version: "0.2.0", author: nil, digest: "fixture", enabledGlobal: true,
                                         enabledWorkspaces: [], disabledWorkspaces: [], previousVersions: nil, skills: [], mcpServers: [], scripts: [], unsupported: [], updateAvailable: false, error: nil)
            plugin.root = root.path
            plugin.screens = [.init(id: "agent-world", title: title, entrypoint: "ui/index.html", version: 2, capabilities: ["agents.read", "agents.interact", "world.preferences"])]
            var capabilities = ExtensionCapabilities(); capabilities.pluginScreens = true
            extensions.extensions = ExtensionsResponse(capabilities: capabilities, marketplaces: [], plugins: [plugin], skills: [], mcpServers: [], mcpPresets: [], errors: [], pendingUpdates: 0)
        }
        func close() {
            for window in NSApp.windows where window.title.hasPrefix(title) { window.close() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
