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
        for window in NSApp.windows where window.title.hasPrefix(fixture.title) { window.close() }
        fixture.defaults.set("east", forKey: "Locus.AgentWorld.sailingArea.v1.fixture:agent-world")
        fixture.world.open(pluginID: "fixture")
        XCTAssertTrue(fixture.world.worldPreferences.isEmpty, "An explicit v2 reset is not reimported from older appearance settings")
        XCTAssertEqual(fixture.defaults.data(forKey: "Locus.AgentWorld.conversations.v1"), bindings)
    }

    func testCorruptVisualNamespaceIsNotReimportedOrWrittenOver() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let key = AgentWorldModel.worldPreferenceStorageKey(screenID: "fixture:agent-world", workspace: fixture.root.path)
        let corrupt = Data("malformed preferences retained for recovery".utf8)
        fixture.defaults.set(corrupt, forKey: key)
        fixture.defaults.set("east", forKey: "Locus.AgentWorld.sailingArea.v1.fixture:agent-world")
        fixture.configure(profiles: [])
        fixture.world.open(pluginID: "fixture")
        XCTAssertTrue(fixture.world.worldPreferences.isEmpty)
        XCTAssertEqual(fixture.defaults.data(forKey: key), corrupt)
    }

    func testVisualSettingsAndResetAreIsolatedToTheirCanonicalWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let profile = AgentProfile(name: "Current", model: "native:1")
        let foreign = UUID().uuidString
        fixture.defaults.set([profile.id.uuidString: "ship_going_merry", foreign: "ship_thousand_sunny"], forKey: "Locus.AgentWorld.shipStyles.v1.fixture:agent-world")
        let oldV2Key = "Locus.AgentWorlds.preferences.v2.fixture:agent-world"
        let oldV2 = Data("{\"unscoped\":true}".utf8)
        fixture.defaults.set(oldV2, forKey: oldV2Key)
        fixture.configure(profiles: [profile])
        fixture.world.open(pluginID: "fixture")
        XCTAssertEqual(Set((fixture.world.worldPreferences["ship-styles"] as? [String: String] ?? [:]).keys), [profile.id.uuidString])
        XCTAssertNil(fixture.world.worldPreferences["unscoped"])
        try fixture.world.updateWorldPreference(key: "camera", value: "workspace-a")
        for window in NSApp.windows where window.title.hasPrefix(fixture.title) { window.close() }
        fixture.workspaceOverride = fixture.root.appendingPathComponent("workspace-b").path
        fixture.world.open(pluginID: "fixture")
        XCTAssertNil(fixture.world.worldPreferences["camera"])
        try fixture.world.updateWorldPreference(key: "camera", value: "workspace-b")
        try fixture.world.resetWorldPreferences()
        for window in NSApp.windows where window.title.hasPrefix(fixture.title) { window.close() }
        fixture.workspaceOverride = nil
        fixture.world.open(pluginID: "fixture")
        XCTAssertEqual(fixture.world.worldPreferences["camera"] as? String, "workspace-a")
        XCTAssertEqual(fixture.defaults.data(forKey: oldV2Key), oldV2)
        XCTAssertEqual((fixture.defaults.dictionary(forKey: "Locus.AgentWorld.shipStyles.v1.fixture:agent-world") as? [String: String])?.count, 2)
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

    func testNativeQueuesSurviveWorldDisableUpgradeAndWorkspaceRevocation() async throws {
        for cause in ["disable", "upgrade", "workspace"] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let service = SavedAgentConversationService()
            let profile = AgentProfile(name: "Retained agent", model: "native:1")
            var dispatched: [String] = []
            service.configure(defaults: fixture.defaults, state: { _ in .init() }, create: { _, _ in "native-chat" },
                              dispatch: { _, _, _, text, _ in
                try await Task.sleep(for: .milliseconds(80))
                dispatched.append(text)
            })
            service.bind("native-chat", workspace: fixture.root.path, profileID: profile.id)
            fixture.configure(profiles: [profile], conversations: service)
            fixture.world.open(pluginID: "fixture")
            let coordinator = PluginScreenHost.Coordinator(model: fixture.world, screen: try XCTUnwrap(fixture.world.activeScreen))
            try service.enqueue(text: "first", mode: .work, sessionID: "native-chat", workspace: fixture.root.path, profileID: profile.id)
            try service.enqueue(text: "second", mode: .work, sessionID: "native-chat", workspace: fixture.root.path, profileID: profile.id)
            if cause == "workspace" {
                fixture.workspaceOverride = fixture.root.appendingPathComponent("another-project").path
                fixture.world.refresh()
            } else if cause == "disable" {
                fixture.extensions.extensions = .empty
            } else {
                let data = try JSONEncoder().encode(fixture.extensions.extensions)
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                var plugins = try XCTUnwrap(json["plugins"] as? [[String: Any]])
                plugins[0]["digest"] = "upgraded"
                json["plugins"] = plugins
                fixture.extensions.extensions = try JSONDecoder().decode(ExtensionsResponse.self, from: JSONSerialization.data(withJSONObject: json))
            }
            coordinator.sendSnapshot()
            XCTAssertNil(fixture.world.activeScreen, cause)
            XCTAssertTrue(service.hasPendingWork(profileID: profile.id), cause)
            for _ in 0..<100 where service.hasPendingWork(profileID: profile.id) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(dispatched, ["first", "second"], cause)
            XCTAssertEqual(service.boundProfileID(for: "native-chat"), profile.id, cause)
            coordinator.revoke()
        }
    }

    func testHandshakeDeadlineAndRendererFailureOfferBoundedExplicitRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.configure(profiles: [])
        fixture.world.open(pluginID: "fixture")
        let coordinator = PluginScreenHost.Coordinator(model: fixture.world, screen: try XCTUnwrap(fixture.world.activeScreen))
        coordinator.startLifecycleMonitoring(handshakeTimeout: .milliseconds(20))
        for _ in 0..<100 where !coordinator.bridge.revoked { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(coordinator.bridge.revoked)
        XCTAssertTrue(coordinator.files.revoked)
        XCTAssertNotNil(fixture.world.graphicsError)
        let epoch = fixture.world.renderEpoch
        for attempt in 1...3 {
            XCTAssertTrue(fixture.world.canRetryWorldScreen)
            fixture.world.retryWorldScreen()
            XCTAssertEqual(fixture.world.renderEpoch, epoch + attempt)
            fixture.world.graphicsError = "Renderer failed"
        }
        XCTAssertFalse(fixture.world.canRetryWorldScreen)
        fixture.world.retryWorldScreen()
        XCTAssertEqual(fixture.world.renderEpoch, epoch + 3)
    }

    func testRealWebKitLoadExceptionAndEventLoopFailuresRevokeOnlyTheRenderer() async throws {
        for failure in ["load", "exception", "hang"] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let profile = AgentProfile(name: "Retained", model: "native:1")
            let service = SavedAgentConversationService()
            service.configure(defaults: fixture.defaults, state: { _ in .init() }, create: { _, _ in "saved" }, dispatch: { _, _, _, _, _ in })
            service.bind("saved", workspace: fixture.root.path, profileID: profile.id)
            fixture.configure(profiles: [profile], conversations: service)
            fixture.world.open(pluginID: "fixture")
            let coordinator = PluginScreenHost.Coordinator(model: fixture.world, screen: try XCTUnwrap(fixture.world.activeScreen))
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(coordinator.files, forURLScheme: PluginScreenSchemeHandler.scheme)
            config.userContentController.add(coordinator, name: "locusScreen")
            config.userContentController.addUserScript(WKUserScript(source: PluginScreenHost.Coordinator.failureMonitorScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let web = WKWebView(frame: .zero, configuration: config)
            coordinator.web = web; web.navigationDelegate = coordinator
            defer { coordinator.revoke() }
            if failure == "load" { try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("ui/index.html")) }
            if failure == "exception" {
                try Data("throw new Error('Injected renderer failure');".utf8).write(to: fixture.root.appendingPathComponent("ui/exception.js"))
                try Data("<html><head></head><body><script src='exception.js'></script></body></html>".utf8).write(to: fixture.root.appendingPathComponent("ui/index.html"))
            }
            web.load(URLRequest(url: try XCTUnwrap(URL(string: "locus-screen://plugin/ui/index.html"))))
            if failure != "load" {
                for _ in 0..<100 {
                    if (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                if failure == "exception" {
                    for _ in 0..<100 {
                        if (try? await web.evaluateJavaScript("window.__locusScreenFailure")) as? Bool == true { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                } else {
                    web.evaluateJavaScript("while(true){}", completionHandler: nil)
                }
                coordinator.checkRendererHealth(timeout: .milliseconds(100))
            }
            for _ in 0..<200 where !coordinator.files.revoked { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(coordinator.files.revoked, failure)
            XCTAssertNotNil(fixture.world.graphicsError, failure)
            XCTAssertEqual(service.boundProfileID(for: "saved"), profile.id, failure)
            XCTAssertFalse(service.hasPendingWork(profileID: profile.id), failure)
        }
    }

    func testPackagedWorldRendersInsideSecuredWebKitAndReleasesItsLifecycle() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOCUS_AGENT_WORLDS_TEST_PLUGIN"] else {
            throw XCTSkip("Set LOCUS_AGENT_WORLDS_TEST_PLUGIN to an extracted, verified Agent Worlds artifact for the packaged WK acceptance gate.")
        }
        let fixture = try Fixture(pluginRoot: URL(fileURLWithPath: path))
        defer { fixture.close() }
        let profiles = ["Luffy", "Zoro", "Nami", "Sanji", "Robin", "Jinbei"].map { AgentProfile(name: $0, model: "private-provider:private-model") }
        fixture.statuses = Dictionary(uniqueKeysWithValues: zip(profiles.map { $0.id.uuidString }, ["working", "needs_attention", "idle", "queued", "failed", "idle"]))
        fixture.configure(profiles: profiles)
        fixture.world.open(pluginID: "fixture")
        func findWeb(_ view: NSView?) -> WKWebView? {
            guard let view else { return nil }
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(findWeb).first
        }
        var mountedWeb: WKWebView?
        for _ in 0..<50 where mountedWeb == nil {
            mountedWeb = NSApp.windows.first(where: { $0.title.hasPrefix(fixture.title) }).flatMap { findWeb($0.contentView) }
            if mountedWeb == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let web = try XCTUnwrap(mountedWeb)
        NSApp.setActivationPolicy(.regular)
        web.window?.makeKeyAndOrderFront(nil)
        web.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        let coordinator = try XCTUnwrap(web.navigationDelegate as? PluginScreenHost.Coordinator)
        var display: [String: Any] = [:]
        let probe = """
        JSON.stringify({labels:document.querySelectorAll('.agent-label').length,rows:document.querySelectorAll('.resident-row').length,
          connected:document.getElementById('host-connection')?.hidden===true,demo:document.body.dataset.demo,
          nativeChrome:document.body.dataset.nativeChrome,environment:document.body.dataset.environment,
          canvas:!!document.getElementById('world'),hidden:document.hidden,visibleLabels:document.querySelectorAll('.agent-label[data-label-visible="true"]').length,assetFailure:document.getElementById('asset-notice')?.hidden===false,
          graphicsFailure:document.getElementById('graphics-fallback')?.hidden===false,loading:document.getElementById('asset-loading')?.hidden===false})
        """
        for _ in 0..<200 {
            for _ in 0..<32 {
                guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else { break }
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            if let raw = try? await web.evaluateJavaScript(probe) as? String,
               let data = raw.data(using: .utf8), let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                display = state
                if state["connected"] as? Bool == true, state["labels"] as? Int == 6, state["loading"] as? Bool == false,
                   (state["visibleLabels"] as? Int ?? 0) > 0 { break }
            }
            if fixture.world.graphicsError != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertNil(fixture.world.graphicsError, String(describing: display))
        XCTAssertEqual(display["hidden"] as? Bool, false, String(describing: display))
        XCTAssertGreaterThan(display["visibleLabels"] as? Int ?? 0, 0, String(describing: display))
        XCTAssertTrue(coordinator.bridge.connected, String(describing: display))
        XCTAssertEqual(display["labels"] as? Int, 6)
        XCTAssertEqual(display["rows"] as? Int, 6)
        XCTAssertEqual(display["demo"] as? String, "false")
        XCTAssertEqual(display["nativeChrome"] as? String, "true")
        XCTAssertEqual(display["environment"] as? String, "ocean")
        XCTAssertEqual(display["canvas"] as? Bool, true)
        XCTAssertEqual(display["graphicsFailure"] as? Bool, false)
        XCTAssertEqual(display["assetFailure"] as? Bool, false)
        XCTAssertEqual(fixture.world.residentPlacements.count, 6, "Renderer placement descriptions cross the generic bounded bridge")
        let rosterStatuses = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.resident-row')).map(row=>row.dataset.status)") as? [String]
        XCTAssertEqual(rosterStatuses, ["working", "needs_attention", "idle", "queued", "failed", "idle"])
        let snapshot = try await web.takeSnapshot(configuration: nil)
        let bitmap = try XCTUnwrap(snapshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let evidence = ProcessInfo.processInfo.environment["LOCUS_AGENT_WORLDS_TEST_SNAPSHOT"] ?? "/tmp/locus-agent-worlds-packaged-wk.png"
        try png.write(to: URL(fileURLWithPath: evidence))
        XCTAssertGreaterThan(png.count, 10_000)
        _ = try await web.evaluateJavaScript("document.querySelector('.resident-row')?.click()")
        for _ in 0..<50 where fixture.world.selection == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fixture.world.selection, profiles[0].id.uuidString)
        XCTAssertNil(fixture.world.selectedSessionID, "Clicking a renderer resident opens native controls without executing work")
        XCTAssertTrue(fixture.world.openPluginPresentation("wano"))
        XCTAssertEqual(fixture.world.pluginSurface?.title, "Wano")
        XCTAssertNotNil(fixture.world.pluginAssetImage(try XCTUnwrap(fixture.world.pluginSurface?.backgroundAsset)))
        let metadata = try XCTUnwrap(fixture.world.pluginPresentation)
        for surface in metadata.presentations.values { XCTAssertNotNil(fixture.world.pluginAssetImage(surface.backgroundAsset), surface.title) }
        for style in metadata.styles { XCTAssertNotNil(fixture.world.pluginAssetImage(style.previewAsset), style.name) }
        fixture.world.openAgentControls()
        XCTAssertNil(fixture.world.selectedPresentationID)
        XCTAssertTrue(fixture.world.openPluginPresentation("wano"))
        try fixture.world.updateWorldPreference(key: metadata.contextEnabledPreferenceKey, value: false)
        XCTAssertNil(fixture.world.selectedPresentationID)
        XCTAssertFalse(fixture.world.openPluginPresentation("wano"))
        try fixture.world.resetWorldPreferences()
        fixture.world.quartersPresented = false
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new PageTransitionEvent('pagehide')); true")
        for _ in 0..<50 {
            if (try? await web.evaluateJavaScript("document.querySelectorAll('.agent-label').length")) as? Int == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let disposedLabelCount = try await web.evaluateJavaScript("document.querySelectorAll('.agent-label').length") as? Int
        XCTAssertEqual(disposedLabelCount, 0)
        coordinator.webViewWebContentProcessDidTerminate(web)
        XCTAssertTrue(coordinator.bridge.revoked)
        XCTAssertTrue(coordinator.files.revoked)
        XCTAssertTrue(fixture.world.canRetryWorldScreen)
        XCTAssertNil(fixture.world.selectedSessionID)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        let extensions = ExtensionsModel()
        let world = AgentWorldModel()
        let title = "Agent Worlds V2 Test " + UUID().uuidString
        var workspaceOverride: String?
        var statuses: [String: String] = [:]
        private let ownsRoot: Bool
        init(pluginRoot: URL? = nil) throws {
            ownsRoot = pluginRoot == nil
            root = pluginRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = "AgentWorldBridgeTests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            if ownsRoot {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("ui"), withIntermediateDirectories: true)
                try Data("<html><head></head><body>fixture</body></html>".utf8).write(to: root.appendingPathComponent("ui/index.html"))
            }
        }
        func configure(profiles: [AgentProfile], conversations: SavedAgentConversationService? = nil) {
            world.configure(extensions: extensions, conversations: conversations, profiles: { profiles }, workspace: { self.workspaceOverride ?? self.root.path }, availability: { _ in nil }, state: { _ in .init() },
                            create: { _, _ in XCTFail("Display must not create a chat"); return "unexpected" }, load: { _ in },
                            activity: { profile, _ in .init(status: self.statuses[profile.id.uuidString] ?? "idle") },
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
            if ownsRoot { try? FileManager.default.removeItem(at: root) }
        }
    }
}
