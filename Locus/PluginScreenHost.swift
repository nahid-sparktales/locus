import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Shared by installation presentation and the resource handler. Decoding is
/// performed by URL exactly once; encoded separators/escapes are rejected so
/// no alternate spelling can bypass confinement.
enum PluginScreenFiles {
    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 1024 && !path.hasPrefix("/") && !path.contains("\\")
            && !path.contains("%") && !path.contains(":") && !path.contains("?") && !path.contains("#")
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func file(root: URL, path: String) throws -> URL {
        guard root.isFileURL, isSafeRelativePath(path) else { throw CocoaError(.fileReadNoPermission) }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let file = canonicalRoot.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(canonicalRoot.path + "/"),
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadNoPermission)
        }
        return file
    }
}

enum PluginScreenMessage: Equatable {
    case ready
    case selectAgent(String)
    case clearSelection
    case preferences(String)
    case residentStyle(String)
    case sailingArea(String)
    case openAttention(String)
    case openTransfer(String)
    case openSharedChat
    case openActivityCenter
    case openAgentControls(String?)
    case openIslandQuarters(AgentWorldQuartersIsland)
    case islandQuartersEnabled(Bool)
    case createAgent
    case residentPlacements([AgentWorldResidentPlacement])
    case setShipStyle(agentID: String, style: String?)

    static func decode(_ body: Any, screen: ExtensionPluginScreen) -> PluginScreenMessage? {
        guard screen.isSupported, screen.version == 1, let value = body as? [String: Any],
              let version = value["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let type = value["type"] as? String else { return nil }
        let keys = Set(value.keys)
        switch type {
        case "ready":
            guard keys == ["version", "type"] else { return nil }
            return .ready
        case "selectAgent":
            guard keys == ["version", "type", "agentID"], screen.capabilities.contains("agents.interact"),
                  let id = value["agentID"] as? String, let uuid = UUID(uuidString: id) else { return nil }
            return .selectAgent(uuid.uuidString)
        case "clearSelection":
            guard keys == ["version", "type"], screen.capabilities.contains("agents.interact") else { return nil }
            return .clearSelection
        case "openAttention", "openTransfer":
            let field = type == "openAttention" ? "requestID" : "transferID"
            guard keys == ["version", "type", field], screen.capabilities.contains("agents.interact"),
                  let id = value[field] as? String, let uuid = UUID(uuidString: id) else { return nil }
            return type == "openAttention" ? .openAttention(uuid.uuidString) : .openTransfer(uuid.uuidString)
        case "openActivityCenter":
            guard keys == ["version", "type"], screen.capabilities.contains("agents.read") else { return nil }
            return .openActivityCenter
        case "openSharedChat":
            guard keys == ["version", "type"], screen.capabilities.contains("agents.interact") else { return nil }
            return .openSharedChat
        case "createAgent":
            guard keys == ["version", "type"], screen.capabilities.contains("agents.interact") else { return nil }
            return .createAgent
        case "openAgentControls":
            guard screen.capabilities.contains("agents.interact") else { return nil }
            if keys == ["version", "type"] { return .openAgentControls(nil) }
            guard keys == ["version", "type", "agentID"], let id = value["agentID"] as? String,
                  let uuid = UUID(uuidString: id) else { return nil }
            return .openAgentControls(uuid.uuidString)
        case "openIslandQuarters":
            guard keys == ["version", "type", "islandID"], screen.capabilities.contains("agents.interact"),
                  let id = value["islandID"] as? String, let island = AgentWorldQuartersIsland(rawValue: id) else { return nil }
            return .openIslandQuarters(island)
        case "setShipStyle":
            guard keys == ["version", "type", "agentID", "shipStyle"], screen.capabilities.contains("world.preferences"),
                  let rawID = value["agentID"] as? String, let id = UUID(uuidString: rawID)?.uuidString else { return nil }
            if value["shipStyle"] is NSNull { return .setShipStyle(agentID: id, style: nil) }
            guard let style = value["shipStyle"] as? String, AgentWorldShipStyle.isSupported(style) else { return nil }
            return .setShipStyle(agentID: id, style: style)
        case "residentPlacements":
            guard keys == ["version", "type", "placements"], screen.capabilities.contains("agents.read"),
                  let rows = value["placements"] as? [[String: Any]], rows.count <= 500 else { return nil }
            var seen = Set<String>()
            var placements: [AgentWorldResidentPlacement] = []
            for row in rows {
                guard Set(row.keys) == ["agentID", "ship", "home"],
                      let rawID = row["agentID"] as? String, let id = UUID(uuidString: rawID)?.uuidString,
                      seen.insert(id).inserted,
                      let ship = row["ship"] as? String, let home = row["home"] as? String,
                      [ship, home].allSatisfy({ text in
                          !text.isEmpty && text.count <= 100
                              && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                      }) else { return nil }
                placements.append(.init(agentID: id, ship: ship, home: home))
            }
            return .residentPlacements(placements)
        case "preferences":
            guard keys == ["version", "type", "preferences"], screen.capabilities.contains("world.preferences"),
                  let preferences = value["preferences"] as? [String: Any] else { return nil }
            if Set(preferences.keys) == ["theme"], let theme = preferences["theme"] as? String,
               AgentWorldModel.isSafeThemeID(theme) { return .preferences(theme) }
            if Set(preferences.keys) == ["residentStyle"], let style = preferences["residentStyle"] as? String,
               AgentWorldModel.isSafeResidentStyle(style) { return .residentStyle(style) }
            if Set(preferences.keys) == ["sailingArea"], let area = preferences["sailingArea"] as? String,
               AgentWorldModel.isSafeSailingArea(area) { return .sailingArea(area) }
            if Set(preferences.keys) == ["islandQuartersEnabled"], let enabled = preferences["islandQuartersEnabled"] as? NSNumber,
               CFGetTypeID(enabled) == CFBooleanGetTypeID() { return .islandQuartersEnabled(enabled.boolValue) }
            return nil
        default: return nil
        }
    }
}

final class PluginScreenSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "locus-screen"
    static let host = "plugin"
    // CSP is prepended before plugin markup, including markup without <head>.
    // Rule-list network blocking is an additional barrier for every resource.
    static let contentPolicy = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self' blob:; font-src 'self' data:; media-src 'self' blob:; worker-src blob:; child-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
    let root: URL
    var revoked = false
    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard !revoked, let url = urlSchemeTask.request.url,
                  url.scheme == Self.scheme, url.host == Self.host,
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  urlSchemeTask.request.httpMethod == nil || urlSchemeTask.request.httpMethod == "GET",
                  let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                  !encodedPath.lowercased().contains("%2f"), !encodedPath.lowercased().contains("%5c"),
                  !encodedPath.lowercased().contains("%2e"), !encodedPath.lowercased().contains("%25") else {
                throw CocoaError(.fileReadNoPermission)
            }
            let path = String(url.path.dropFirst())
            let file = try PluginScreenFiles.file(root: root, path: path)
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 256 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let ext = file.pathExtension.lowercased()
            var data = try Data(contentsOf: file, options: .mappedIfSafe)
            if ["html", "htm"].contains(ext) {
                guard let html = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(Self.contentPolicy)\">"
                if let head = html.range(of: "<head>", options: .caseInsensitive) {
                    var protected = html; protected.insert(contentsOf: policy, at: head.upperBound)
                    data = Data(protected.utf8)
                } else { data = Data((policy + html).utf8) }
            }
            let mime: String
            switch ext {
            case "js", "mjs": mime = "text/javascript"
            case "css": mime = "text/css"
            case "html", "htm": mime = "text/html"
            case "glb": mime = "model/gltf-binary"
            case "gltf": mime = "model/gltf+json"
            case "json": mime = "application/json"
            case "wasm": mime = "application/wasm"
            default: mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            }
            guard !revoked else { throw CocoaError(.fileReadNoPermission) }
            // WebKit exposes a plain URLResponse as status 0. Fetch callers
            // then see response.ok == false, and model loaders reject valid
            // local artwork. Supply HTTP semantics on the custom local scheme.
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
                "Content-Security-Policy": Self.contentPolicy,
                "X-Content-Type-Options": "nosniff",
            ]) else { throw CocoaError(.fileReadUnknown) }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

struct PluginScreenHost: NSViewRepresentable {
    @ObservedObject var model: AgentWorldModel
    let screen: AgentWorldModel.AvailableScreen
    func makeCoordinator() -> Coordinator { Coordinator(model: model, screen: screen) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(context.coordinator.files, forURLScheme: PluginScreenSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: "locusScreen")
        if screen.screen.version == 2 {
            config.userContentController.addUserScript(WKUserScript(source: Coordinator.failureMonitorScript,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        context.coordinator.startLifecycleMonitoring()
        model.visibilityChanged = { [weak coordinator = context.coordinator] visible in
            coordinator?.sendVisibility(visible)
        }
        let rules = "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}},{\"trigger\":{\"url-filter\":\"^wss?://\"},\"action\":{\"type\":\"block\"}}]"
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "LocusPluginScreenLocalOnlyV1", encodedContentRuleList: rules) { [weak coordinator = context.coordinator] rules, error in
            Task { @MainActor in
                guard let coordinator, !coordinator.files.revoked else { return }
                guard let rules, error == nil else { coordinator.failRenderer("The local screen could not be secured. Use the resident list to continue."); return }
                web.configuration.userContentController.add(rules)
                guard let url = URL(string: "locus-screen://plugin/" + screen.screen.entrypoint) else { return }
                web.load(URLRequest(url: url))
            }
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        guard model.activeScreen == screen else { context.coordinator.revoke(); return }
        context.coordinator.sendSnapshot()
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { coordinator.revoke() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var model: AgentWorldModel?
        weak var web: WKWebView?
        let screen: AgentWorldModel.AvailableScreen
        let files: PluginScreenSchemeHandler
        private var ready = false
        private var lastSnapshot: Data?
        let bridge: AgentWorldBridgeSession
        private var receivedV2Snapshot = false
        private var loadDeadline: Task<Void, Never>?
        private var healthTask: Task<Void, Never>?
        private var healthDeadline: Task<Void, Never>?
        private var healthProbeID: UUID?
        private var isVisible = true
        static let failureMonitorScript = """
        window.__locusScreenFailure = false;
        window.addEventListener('error', event => { if (event instanceof ErrorEvent) window.__locusScreenFailure = true; });
        window.addEventListener('unhandledrejection', () => { window.__locusScreenFailure = true; });
        """
        func startLifecycleMonitoring(handshakeTimeout: Duration = .seconds(30)) {
            guard screen.screen.version == 2, !files.revoked else { return }
            loadDeadline?.cancel()
            loadDeadline = Task { [weak self] in
                try? await Task.sleep(for: handshakeTimeout)
                guard let self, !Task.isCancelled, !self.bridge.connected else { return }
                self.failRenderer("The world did not connect in time. Retry the world or continue from the resident list.")
            }
        }
        private func startHealthChecks() {
            guard screen.screen.version == 2, bridge.connected, isVisible, !files.revoked, healthTask == nil else { return }
            healthTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.checkRendererHealth()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
        /// This checks the JS event loop only; canonical data is not polled.
        func checkRendererHealth(timeout: Duration = .seconds(3)) {
            guard screen.screen.version == 2, !files.revoked, isVisible, healthProbeID == nil, let web else { return }
            let probe = UUID(); healthProbeID = probe
            healthDeadline = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, !Task.isCancelled, self.healthProbeID == probe else { return }
                self.failRenderer("The world stopped responding. Retry the world or continue from the resident list.")
            }
            web.callAsyncJavaScript("return window.__locusScreenFailure !== true", arguments: [:], in: nil, in: .page) { [weak self] result in
                guard let self, self.healthProbeID == probe, !self.files.revoked else { return }
                self.healthDeadline?.cancel(); self.healthDeadline = nil; self.healthProbeID = nil
                if case .success(let value) = result, value as? Bool == true { return }
                self.failRenderer("The world encountered a graphics error. Retry the world or continue from the resident list.")
            }
        }
        func failRenderer(_ message: String) {
            guard !files.revoked else { return }
            if model?.activeScreen == screen { model?.graphicsError = message }
            revoke()
        }
        init(model: AgentWorldModel, screen: AgentWorldModel.AvailableScreen) {
            self.model = model; self.screen = screen
            bridge = AgentWorldBridgeSession(identity: .init(pluginID: screen.pluginID, digest: screen.digest, root: screen.root,
                                                              workspace: model.workspace, capabilities: Set(screen.screen.capabilities)))
            files = PluginScreenSchemeHandler(root: URL(fileURLWithPath: screen.root))
        }
        func revoke() {
            loadDeadline?.cancel(); loadDeadline = nil
            healthTask?.cancel(); healthTask = nil
            healthDeadline?.cancel(); healthDeadline = nil; healthProbeID = nil
            if bridge.connected {
                var message = bridge.scope("revoked"); message["reason"] = "The installed plugin connection was closed."
                sendWire(message)
            }
            bridge.revoke()
            files.revoked = true; ready = false
            web?.stopLoading()
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "locusScreen")
            web?.navigationDelegate = nil; web?.uiDelegate = nil
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !files.revoked, model?.activeScreen == screen, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.scheme == PluginScreenSchemeHandler.scheme,
                  message.frameInfo.request.url?.host == PluginScreenSchemeHandler.host else { return }
            if screen.screen.version == 2 { receiveV2(message.body); return }
            guard let action = PluginScreenMessage.decode(message.body, screen: screen.screen) else { return }
            switch action {
            case .ready: ready = true; lastSnapshot = nil; sendSnapshot()
            case .selectAgent(let id): model?.chooseResident(id)
            case .clearSelection: model?.clearWorldSelection()
            case .preferences(let theme): model?.setTheme(theme)
            case .residentStyle(let style): model?.setResidentStyle(style)
            case .sailingArea(let area): model?.setSailingArea(area)
            case .openAttention(let id): model?.openAttention(id)
            case .openTransfer(let id): model?.openTransfer(id)
            case .openSharedChat: model?.openSharedChat()
            case .openActivityCenter: model?.requestActivityCenter()
            case .openAgentControls(let id): model?.openAgentControls(id)
            case .openIslandQuarters(let island): model?.openIslandQuarters(island)
            case .islandQuartersEnabled(let enabled): model?.setIslandQuartersEnabled(enabled)
            case .createAgent: model?.createAgent()
            case .residentPlacements(let placements): model?.receiveResidentPlacements(placements)
            case .setShipStyle(let id, let style): model?.setShipStyle(agentID: id, style: style)
            }
        }
        func sendSnapshot() {
            if screen.screen.version == 2 { sendV2Projection(); return }
            guard let model, model.activeScreen == screen,
                  let data = try? JSONSerialization.data(withJSONObject: model.snapshot, options: [.sortedKeys]), data != lastSnapshot else { return }
            guard ready else { return }
            lastSnapshot = data; send(model.snapshot)
        }
        private func currentBridgeIdentity() -> AgentWorldBridgeSession.Identity? {
            guard let model, !files.revoked else { return nil }
            guard model.activeScreen == screen, model.workspace == bridge.identity.workspace else { return nil }
            if let app = model.appModel,
               SessionSummary.canonicalWorkspacePath(app.workspacePath) != bridge.identity.workspace { return nil }
            return .init(pluginID: screen.pluginID, digest: screen.digest, root: screen.root,
                         workspace: model.workspace, capabilities: Set(screen.screen.capabilities))
        }
        private func receiveV2(_ body: Any) {
            guard let client = AgentWorldBridgeContract.decode(body) else {
                if let value = body as? [String: Any], AgentWorldBridgeContract.isToken(value["requestID"]), let id = value["requestID"] as? String {
                    sendWire(bridge.failure(id, code: "invalid_request", message: "The world request does not match the supported contract.", scoped: bridge.connected))
                }
                return
            }
            model?.refresh() // Refresh authorization before an invocation, never from a SwiftUI update.
            let current = currentBridgeIdentity()
            let response = bridge.handle(client, current: current, hostVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", execute: executeV2)
            sendWire(response)
            if current != bridge.identity { revoke(); return }
            if case .hello = client, response["type"] as? String == "welcome" {
                loadDeadline?.cancel(); loadDeadline = nil
                ready = true; lastSnapshot = nil; receivedV2Snapshot = false; sendV2Projection(force: true)
                startHealthChecks()
            } else if case .request(let request) = client, response["ok"] as? Bool == true {
                sendV2Projection(force: request.command == "host.snapshot")
            }
        }
        private func executeV2(_ request: AgentWorldBridgeContract.Request) throws -> [String: Any] {
            guard let model, currentBridgeIdentity() == bridge.identity else {
                throw AgentWorldBridgeContract.Failure(code: "stale_session", message: "The plugin or project changed before the action.")
            }
            func agent(_ raw: Any?) throws -> String {
                guard let raw = raw as? String, let id = UUID(uuidString: raw)?.uuidString,
                      model.residents.contains(where: { $0.id == id }) else {
                    throw AgentWorldBridgeContract.Failure(code: "not_found", message: "The requested agent is not available in this world.")
                }
                return id
            }
            switch request.command {
            case "host.snapshot": break
            case "agents.open": model.chooseResident(try agent(request.arguments["agentID"]))
            case "agents.create":
                guard model.canCreateAgent else { throw AgentWorldBridgeContract.Failure(code: "unavailable", message: "Agent creation is unavailable.") }
                model.createAgent()
            case "selection.clear": model.clearWorldSelection()
            case "attention.open":
                guard let raw = request.arguments["requestID"] as? String, let id = UUID(uuidString: raw)?.uuidString else {
                    throw AgentWorldBridgeContract.Failure(code: "invalid_request", message: "An attention ID is required.")
                }
                guard model.attentionRequests.contains(where: { $0.id == id }) else { throw AgentWorldBridgeContract.Failure(code: "not_found", message: "This attention request is no longer available.") }
                model.openAttention(id)
            case "transfers.open":
                guard let raw = request.arguments["transferID"] as? String, let id = UUID(uuidString: raw)?.uuidString else {
                    throw AgentWorldBridgeContract.Failure(code: "invalid_request", message: "A transfer ID is required.")
                }
                guard model.transfers.contains(where: { $0.id == id }) else { throw AgentWorldBridgeContract.Failure(code: "not_found", message: "This transfer is no longer available.") }
                model.openTransfer(id)
            case "chats.openShared":
                guard model.appModel != nil else { throw AgentWorldBridgeContract.Failure(code: "unavailable", message: "The native chat is unavailable.") }
                model.openSharedChat()
            case "navigation.open":
                let id = try request.arguments["agentID"].map(agent)
                guard let surface = request.arguments["surface"] as? String else { throw AgentWorldBridgeContract.Failure(code: "invalid_request", message: "A native surface is required.") }
                model.openWorldNativeSurface(surface, agentID: id)
            case "presentation.open":
                guard let id = request.arguments["presentationID"] as? String else { throw AgentWorldBridgeContract.Failure(code: "invalid_request", message: "A presentation ID is required.") }
                try model.openWorldPresentation(id)
            case "preferences.set":
                guard let key = request.arguments["key"] as? String, let value = request.arguments["value"] else { throw AgentWorldBridgeContract.Failure(code: "invalid_request", message: "A preference key and value are required.") }
                try model.updateWorldPreference(key: key, value: value)
            case "preferences.reset": try model.resetWorldPreferences()
            case "placements.set":
                guard let rows = request.arguments["placements"] as? [[String: Any]] else { throw AgentWorldBridgeContract.Failure(code: "invalid_request", message: "Display placements are required.") }
                let placements = try rows.map { row in
                    guard let primary = row["primary"] as? String, let secondary = row["secondary"] as? String else {
                        throw AgentWorldBridgeContract.Failure(code: "invalid_request", message: "Display labels are required.")
                    }
                    return AgentWorldResidentPlacement(agentID: try agent(row["agentID"]), ship: primary, home: secondary)
                }
                model.receiveResidentPlacements(placements)
            default: throw AgentWorldBridgeContract.Failure(code: "invalid_request", message: "The command is not supported.")
            }
            return [:]
        }
        private func sendV2Projection(force: Bool = false) {
            guard bridge.connected, !bridge.revoked, let model else { return }
            guard currentBridgeIdentity() == bridge.identity else { revoke(); return }
            let state = model.worldDisplayState(capabilities: bridge.granted)
            guard AgentWorldBridgeContract.validDisplayState(state),
                  let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), force || data != lastSnapshot else { return }
            let message = bridge.projection(state, initial: !receivedV2Snapshot || force)
            guard AgentWorldBridgeContract.validHostMessage(message) else {
                failRenderer("The world display data exceeded its supported limits.")
                return
            }
            receivedV2Snapshot = true; lastSnapshot = data; sendWire(message)
        }
        func sendVisibility(_ visible: Bool) {
            isVisible = visible
            if !visible {
                healthTask?.cancel(); healthTask = nil
                healthDeadline?.cancel(); healthDeadline = nil; healthProbeID = nil
            } else { startHealthChecks() }
            if screen.screen.version == 2 {
                guard bridge.connected else { return }
                var message = bridge.scope("visibility"); message["visible"] = visible; sendWire(message)
            } else { send(["version": 1, "type": "visibility", "visible": visible]) }
        }
        private func sendWire(_ value: [String: Any]) {
            guard !files.revoked, model?.activeScreen == screen, AgentWorldBridgeContract.validHostMessage(value) else { return }
            web?.callAsyncJavaScript("window.locusAgentWorld?.receive(message)", arguments: ["message": value], in: nil, in: .page, completionHandler: nil)
        }
        func send(_ value: [String: Any]) {
            guard ready, !files.revoked, model?.activeScreen == screen else { return }
            web?.callAsyncJavaScript("window.locusAgentWorld?.receive(message)", arguments: ["message": value], in: nil, in: .page, completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = !files.revoked && navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.request.url?.scheme == PluginScreenSchemeHandler.scheme
                && navigationAction.request.url?.host == PluginScreenSchemeHandler.host
                && navigationAction.request.url?.path == "/" + screen.screen.entrypoint
                && navigationAction.navigationType == .other
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failRenderer("The world could not load. Retry the world or continue from the resident list.")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            failRenderer("The graphics process stopped. Retry the world or continue from the resident list.")
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    }
}
