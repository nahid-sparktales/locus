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
        guard screen.isSupported, let value = body as? [String: Any],
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
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        model.visibilityChanged = { [weak coordinator = context.coordinator] visible in
            coordinator?.send(["version": 1, "type": "visibility", "visible": visible])
        }
        let rules = "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}},{\"trigger\":{\"url-filter\":\"^wss?://\"},\"action\":{\"type\":\"block\"}}]"
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "LocusPluginScreenLocalOnlyV1", encodedContentRuleList: rules) { [weak coordinator = context.coordinator] rules, error in
            Task { @MainActor in
                guard let coordinator, !coordinator.files.revoked else { return }
                guard let rules, error == nil else { coordinator.model?.graphicsError = "The local screen could not be secured. Use the resident list to continue."; return }
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
        init(model: AgentWorldModel, screen: AgentWorldModel.AvailableScreen) {
            self.model = model; self.screen = screen
            files = PluginScreenSchemeHandler(root: URL(fileURLWithPath: screen.root))
        }
        func revoke() {
            files.revoked = true; ready = false
            web?.stopLoading()
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "locusScreen")
            web?.navigationDelegate = nil; web?.uiDelegate = nil
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !files.revoked, model?.activeScreen == screen, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.scheme == PluginScreenSchemeHandler.scheme,
                  message.frameInfo.request.url?.host == PluginScreenSchemeHandler.host,
                  let action = PluginScreenMessage.decode(message.body, screen: screen.screen) else { return }
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
            guard let model, model.activeScreen == screen,
                  let data = try? JSONSerialization.data(withJSONObject: model.snapshot, options: [.sortedKeys]), data != lastSnapshot else { return }
            guard ready else { return }
            lastSnapshot = data; send(model.snapshot)
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
            model?.graphicsError = "The world could not load. Use the resident list to continue."
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            model?.graphicsError = "The graphics process stopped. Close and reopen Agent World, or continue from the resident list."
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    }
}
