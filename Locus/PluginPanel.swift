import AppKit
import Foundation
import SwiftUI
import WebKit

/// Messages a plugin panel may send. Each is gated by a capability the panel
/// declared and the user saw in the install review; everything is scoped to
/// the panel's own plugin.
enum PluginPanelMessage: Equatable {
    case ready
    case getSettings(requestID: String)
    case saveSettings(requestID: String, values: Data, revision: String)
    case callTool(requestID: String, tool: String, arguments: Data)
    case composeChat(String)
    case listAgents(requestID: String)
    case confirmRun(requestID: String, runID: String, title: String, steps: [RunStep])
    case dispatchJob(requestID: String, job: Handoff)
    case openAgentChat(runID: String, agentID: UUID)

    /// One step of a run as the panel describes it for the native confirmation.
    struct RunStep: Equatable { let title: String; let agentID: UUID; let edits: Bool }
    /// One job for one saved agent. Locus frames and sends the text itself.
    struct Handoff: Equatable {
        let runID: String; let agentID: UUID; let operationID: String
        let title: String; let text: String; let edits: Bool
    }

    static let maxSettingsBytes = 64 * 1024
    static let maxRunSteps = 40
    static let maxArgumentBytes = 256 * 1024
    static let maxDraftCharacters = 16_000

    static func decode(_ body: Any, panel: ExtensionPluginPanel) -> PluginPanelMessage? {
        guard panel.isSupported, let value = body as? [String: Any],
              let version = value["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let type = value["type"] as? String else { return nil }
        let keys = Set(value.keys)
        let requestID = (value["requestID"] as? String).flatMap(Self.requestID)
        switch type {
        case "ready":
            guard keys == ["version", "type"] else { return nil }
            return .ready
        case "getSettings":
            guard keys == ["version", "type", "requestID"], panel.capabilities.contains("plugin.settings"),
                  let requestID else { return nil }
            return .getSettings(requestID: requestID)
        case "saveSettings":
            guard keys == ["version", "type", "requestID", "values", "revision"],
                  panel.capabilities.contains("plugin.settings"), let requestID,
                  let values = value["values"] as? [String: Any],
                  let data = json(values, limit: maxSettingsBytes),
                  let revision = value["revision"] as? String, revision.count <= 128 else { return nil }
            return .saveSettings(requestID: requestID, values: data, revision: revision)
        case "callTool":
            guard keys == ["version", "type", "requestID", "tool", "arguments"],
                  panel.capabilities.contains("plugin.tools"), let requestID,
                  let tool = value["tool"] as? String, isToolName(tool),
                  let arguments = value["arguments"] as? [String: Any],
                  let data = json(arguments, limit: maxArgumentBytes) else { return nil }
            return .callTool(requestID: requestID, tool: tool, arguments: data)
        case "composeChat":
            guard keys == ["version", "type", "text"], panel.capabilities.contains("chat.compose"),
                  let text = value["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= maxDraftCharacters else { return nil }
            return .composeChat(text)
        case "listAgents":
            guard keys == ["version", "type", "requestID"], panel.capabilities.contains("agents.read"),
                  let requestID else { return nil }
            return .listAgents(requestID: requestID)
        case "confirmRun":
            guard keys == ["version", "type", "requestID", "runID", "title", "steps"],
                  panel.capabilities.contains("agents.dispatch"), let requestID,
                  let runID = (value["runID"] as? String).flatMap(Self.reference),
                  let title = (value["title"] as? String).flatMap({ Self.line($0, limit: 200) }),
                  let raw = value["steps"] as? [[String: Any]], (1...maxRunSteps).contains(raw.count) else { return nil }
            var steps: [RunStep] = []
            for step in raw {
                guard Set(step.keys) == ["title", "agentID", "access"],
                      let title = (step["title"] as? String).flatMap({ Self.line($0, limit: 200) }),
                      let agentID = (step["agentID"] as? String).flatMap(UUID.init(uuidString:)),
                      let access = step["access"] as? String, ["read", "write"].contains(access) else { return nil }
                steps.append(RunStep(title: title, agentID: agentID, edits: access == "write"))
            }
            return .confirmRun(requestID: requestID, runID: runID, title: title, steps: steps)
        case "dispatchJob":
            guard keys == ["version", "type", "requestID", "runID", "agentID", "operationID", "title", "text", "access"],
                  panel.capabilities.contains("agents.dispatch"), let requestID,
                  let runID = (value["runID"] as? String).flatMap(Self.reference),
                  let agentID = (value["agentID"] as? String).flatMap(UUID.init(uuidString:)),
                  let operationID = (value["operationID"] as? String).flatMap(Self.reference),
                  let title = (value["title"] as? String).flatMap({ Self.line($0, limit: 200) }),
                  let text = value["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maxDraftCharacters,
                  let access = value["access"] as? String, ["read", "write"].contains(access) else { return nil }
            return .dispatchJob(requestID: requestID, job: Handoff(
                runID: runID, agentID: agentID, operationID: operationID, title: title, text: text, edits: access == "write"))
        case "openAgentChat":
            guard keys == ["version", "type", "runID", "agentID"], panel.capabilities.contains("agents.dispatch"),
                  let runID = (value["runID"] as? String).flatMap(Self.reference),
                  let agentID = (value["agentID"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            return .openAgentChat(runID: runID, agentID: agentID)
        default:
            return nil
        }
    }

    /// Plugin-chosen identifiers (run and operation ids): bounded, printable, no spaces.
    private static func reference(_ value: String) -> String? {
        (1...200).contains(value.count) && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_.:/-".unicodeScalars.contains($0)
        } ? value : nil
    }

    private static func line(_ value: String, limit: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= limit
            && !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? trimmed : nil
    }

    private static func requestID(_ value: String) -> String? {
        (1...64).contains(value.count) && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        } ? value : nil
    }

    private static func isToolName(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)
        }
    }

    private static func json(_ value: [String: Any], limit: Int) -> Data? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              data.count <= limit else { return nil }
        return data
    }
}

/// The native services a panel reaches. Built by the window controller so the
/// web view never holds the backend or the app model.
struct PluginPanelBridge {
    let settings: () async throws -> Any
    let saveSettings: (_ values: [String: Any], _ revision: String) async throws -> Any
    let callTool: (_ tool: String, _ arguments: [String: Any]) async throws -> Any
    let compose: (_ text: String) -> Void
    var listAgents: () -> Any = { [String: Any]() }
    var confirmRun: (_ runID: String, _ title: String, _ steps: [PluginPanelMessage.RunStep]) async throws -> Any = { _, _, _ in
        ["confirmed": false]
    }
    var dispatch: (_ job: PluginPanelMessage.Handoff) async throws -> Any = { _ in
        throw PluginPanelHandoffs.Refusal.notConfirmed
    }
    var openChat: (_ runID: String, _ agentID: UUID) -> Void = { _, _ in }

    static func foundation(_ value: JSONValue) -> Any {
        switch value {
        case .string(let text): text
        case .number(let number): number
        case .bool(let flag): flag
        case .object(let object): object.mapValues(foundation)
        case .array(let array): array.map(foundation)
        case .null: NSNull()
        }
    }
}

struct PluginPanelHost: NSViewRepresentable {
    let target: PluginPanelWindowController.Target
    let project: String
    let bridge: PluginPanelBridge

    func makeCoordinator() -> Coordinator { Coordinator(target: target, project: project, bridge: bridge) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(context.coordinator.files, forURLScheme: PluginScreenSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: "locusPanel")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        // Same local-only guarantees as plugin screens: no http(s) or ws(s).
        let rules = "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}},{\"trigger\":{\"url-filter\":\"^wss?://\"},\"action\":{\"type\":\"block\"}}]"
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "LocusPluginScreenLocalOnlyV1", encodedContentRuleList: rules) { [weak coordinator = context.coordinator] rules, error in
            Task { @MainActor in
                guard let coordinator, !coordinator.files.revoked, let rules, error == nil,
                      let url = URL(string: "locus-screen://plugin/" + target.panel.entrypoint) else { return }
                web.configuration.userContentController.add(rules)
                web.load(URLRequest(url: url))
            }
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { coordinator.revoke() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        let target: PluginPanelWindowController.Target
        let project: String
        let bridge: PluginPanelBridge
        let files: PluginScreenSchemeHandler
        private var ready = false

        init(target: PluginPanelWindowController.Target, project: String, bridge: PluginPanelBridge) {
            self.target = target; self.project = project; self.bridge = bridge
            files = PluginScreenSchemeHandler(root: URL(fileURLWithPath: target.root))
        }

        func revoke() {
            files.revoked = true; ready = false
            web?.stopLoading()
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "locusPanel")
            web?.navigationDelegate = nil; web?.uiDelegate = nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !files.revoked, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.scheme == PluginScreenSchemeHandler.scheme,
                  message.frameInfo.request.url?.host == PluginScreenSchemeHandler.host,
                  let action = PluginPanelMessage.decode(message.body, panel: target.panel) else { return }
            switch action {
            case .ready:
                ready = true
                send(["version": 1, "type": "hello", "project": project, "panel": target.panel.id,
                      "capabilities": target.panel.capabilities])
            case .getSettings(let id):
                answer(id) { try await self.bridge.settings() }
            case .saveSettings(let id, let values, let revision):
                answer(id) { try await self.bridge.saveSettings(Self.object(values), revision) }
            case .callTool(let id, let tool, let arguments):
                answer(id) { try await self.bridge.callTool(tool, Self.object(arguments)) }
            case .composeChat(let text):
                bridge.compose(text)
            case .listAgents(let id):
                answer(id) { self.bridge.listAgents() }
            case .confirmRun(let id, let runID, let title, let steps):
                answer(id) { try await self.bridge.confirmRun(runID, title, steps) }
            case .dispatchJob(let id, let job):
                answer(id) { try await self.bridge.dispatch(job) }
            case .openAgentChat(let runID, let agentID):
                bridge.openChat(runID, agentID)
            }
        }

        private static func object(_ data: Data) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        private func answer(_ requestID: String, _ work: @escaping () async throws -> Any) {
            Task { @MainActor in
                do {
                    let result = try await work()
                    send(["version": 1, "type": "response", "requestID": requestID, "ok": true, "result": result])
                } catch {
                    send(["version": 1, "type": "response", "requestID": requestID, "ok": false,
                          "error": error.localizedDescription])
                }
            }
        }

        func send(_ value: [String: Any]) {
            guard ready, !files.revoked else { return }
            web?.callAsyncJavaScript("window.locusPanel?.receive(message)", arguments: ["message": value],
                                     in: nil, in: .page, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let allowed = !files.revoked && navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.request.url?.scheme == PluginScreenSchemeHandler.scheme
                && navigationAction.request.url?.host == PluginScreenSchemeHandler.host
                && navigationAction.request.url?.path == "/" + target.panel.entrypoint
                && navigationAction.navigationType == .other
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    }
}

/// One window per project and panel, closed as soon as the plugin is
/// disabled, removed or changed (same rule as Social Studio windows).
@MainActor
final class PluginPanelWindowController: NSObject, NSWindowDelegate {
    struct Target: Identifiable, Equatable {
        let pluginID: String
        let pluginName: String
        let digest: String?
        let root: String
        let panel: ExtensionPluginPanel
        var id: String { pluginID + ":" + panel.id }
    }

    private struct Entry { let window: NSWindow; let target: Target; let workspace: String; let handoffs: PluginPanelHandoffs }
    private var entries: [String: Entry] = [:]

    private func key(_ target: Target, _ workspace: String) -> String { workspace + "\n" + target.id }

    func open(_ target: Target, workspace rawWorkspace: String, appModel: AppModel) {
        let workspace = SessionSummary.canonicalWorkspacePath(rawWorkspace)
        let key = key(target, workspace)
        if let entry = entries[key], entry.target == target {
            entry.window.deminiaturize(nil); entry.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        entries[key]?.window.close()
        let project = URL(fileURLWithPath: workspace).lastPathComponent
        let handoffs = PluginPanelHandoffs()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = project.isEmpty ? target.panel.title : "\(target.panel.title) · \(project)"
        window.identifier = NSUserInterfaceItemIdentifier("locus.pluginPanel." + key)
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: PluginPanelHost(
            target: target, project: project,
            bridge: Self.bridge(target, workspace: workspace, appModel: appModel, handoffs: handoffs, window: window)
        ))
        entries[key] = Entry(window: window, target: target, workspace: workspace, handoffs: handoffs)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func refresh(catalog: ExtensionsResponse) {
        for (key, entry) in entries {
            let enabled = catalog.capabilities.pluginPanels == true && catalog.plugins.contains {
                $0.id == entry.target.pluginID && $0.error == nil && $0.root == entry.target.root
                    && $0.digest == entry.target.digest && AgentWorldModel.enabled($0, workspace: entry.workspace)
                    && ($0.panels ?? []).contains(entry.target.panel)
            }
            if !enabled {
                entry.window.close()
                entries.removeValue(forKey: key)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = entries.first(where: { $0.value.window === window })?.key else { return }
        entries.removeValue(forKey: key)
        window.contentView = nil  // dismantles the web view and revokes the bridge
    }

    private static func bridge(_ target: Target, workspace: String, appModel: AppModel,
                               handoffs: PluginPanelHandoffs, window: NSWindow) -> PluginPanelBridge {
        let backend = appModel.backend
        let pluginID = target.pluginID
        let pluginName = target.pluginName
        var bridge = PluginPanelBridge(
            settings: {
                PluginPanelBridge.foundation(try await backend.get(
                    "/api/extensions/plugins/settings", query: [URLQueryItem(name: "plugin_id", value: pluginID)],
                    as: JSONValue.self))
            },
            saveSettings: { values, revision in
                PluginPanelBridge.foundation(try await backend.post(
                    "/api/extensions/plugins/settings",
                    body: ["plugin_id": pluginID, "values": values, "revision": revision], as: JSONValue.self))
            },
            callTool: { tool, arguments in
                PluginPanelBridge.foundation(try await backend.post(
                    "/api/extensions/plugins/panel-tool",
                    body: ["plugin_id": pluginID, "tool": tool, "arguments": arguments],
                    timeout: 120, as: JSONValue.self))
            },
            compose: { [weak appModel] text in
                // Drafts only: the user reviews and sends the message.
                guard let appModel, let task = appModel.startNewChat(
                    in: workspace, environment: .local, initialDraft: text) else { return }
                Task { @MainActor in
                    guard await task.value else { return }
                    LocusApplicationDelegate.mainWindow(in: NSApp.windows)?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        )
        bridge.listAgents = { [weak appModel] in
            ["agents": appModel.map { model in model.agentProfiles.map { PluginPanelHandoffs.summary($0, appModel: model) } } ?? []]
        }
        bridge.confirmRun = { [weak appModel, weak window] runID, title, steps in
            guard let appModel, let window else { return ["confirmed": false] }
            let profiles = Dictionary(appModel.agentProfiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard steps.allSatisfy({ profiles[$0.agentID] != nil }) else {
                throw PluginPanelHandoffs.Refusal.unknownAgent
            }
            let alert = NSAlert()
            alert.messageText = "Let \(pluginName) hand steps of “\(title)” to these agents?"
            alert.informativeText = PluginPanelHandoffs.confirmationText(steps, profiles: profiles, appModel: appModel)
                + "\n\nEach step is sent to that agent's own chat in this project and follows your Locus permissions. "
                + "This lasts while the window stays open."
            alert.addButton(withTitle: "Allow for This Run")
            alert.addButton(withTitle: "Don't Allow")
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard response == .alertFirstButtonReturn else { return ["confirmed": false] }
            handoffs.allow(runID, agents: Set(steps.map(\.agentID)))
            return ["confirmed": true]
        }
        bridge.dispatch = { [weak appModel] job in
            guard let appModel else { throw PluginPanelHandoffs.Refusal.unavailable }
            try handoffs.check(job)
            guard let profile = appModel.agentProfiles.first(where: { $0.id == job.agentID }) else {
                throw PluginPanelHandoffs.Refusal.unknownAgent
            }
            var sessionID = handoffs.session(run: job.runID, agent: job.agentID)
            if let existing = sessionID, appModel.sessionCatalog.snapshot.sessionsByID[existing] == nil { sessionID = nil }
            if sessionID == nil {
                sessionID = try await appModel.createSavedAgentConversation(profile, workspace: workspace).id
                handoffs.bind(run: job.runID, agent: job.agentID, session: sessionID!)
            }
            guard let sessionID else { throw PluginPanelHandoffs.Refusal.unavailable }
            if appModel.agentWorldConversationState(sessionID).busy { throw PluginPanelHandoffs.Refusal.busy }
            let framed = "From the \(pluginName) plugin, run \(job.runID), step “\(job.title)”:\n\n\(job.text)"
            try await appModel.sendAgentWorldTurn(sessionID: sessionID, workspace: workspace,
                                                  profileID: profile.id, text: framed, mode: .work)
            return ["sessionID": sessionID]
        }
        bridge.openChat = { [weak appModel] runID, agentID in
            guard let appModel, let sessionID = handoffs.session(run: runID, agent: agentID),
                  let session = appModel.sessionCatalog.snapshot.sessionsByID[sessionID] else { return }
            appModel.resume(session)
            LocusApplicationDelegate.mainWindow(in: NSApp.windows)?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return bridge
    }
}

/// What the user allowed for runs in one panel window: which saved agents may
/// receive steps of which run, and each agent's chat for that run. Lives only
/// as long as the window, so nothing is sent after it closes.
@MainActor
final class PluginPanelHandoffs {
    enum Refusal: LocalizedError {
        case notConfirmed, unknownAgent, busy, unavailable
        var errorDescription: String? {
            switch self {
            case .notConfirmed: "not_confirmed: allow hand-offs for this run first"
            case .unknownAgent: "That agent isn't one of your saved agents in Locus."
            case .busy: "busy: the agent is still working on its previous step"
            case .unavailable: "Locus can't reach that agent right now."
            }
        }
    }

    private var allowed: [String: Set<UUID>] = [:]
    private var sessions: [String: String] = [:]

    func allow(_ runID: String, agents: Set<UUID>) { allowed[runID, default: []].formUnion(agents) }

    func check(_ job: PluginPanelMessage.Handoff) throws {
        guard allowed[job.runID]?.contains(job.agentID) == true else { throw Refusal.notConfirmed }
    }

    func session(run: String, agent: UUID) -> String? { sessions[run + "\n" + agent.uuidString] }
    func bind(run: String, agent: UUID, session: String) { sessions[run + "\n" + agent.uuidString] = session }

    /// What a panel may know about a saved agent: never instructions, accounts or keys.
    static func summary(_ profile: AgentProfile, appModel: AppModel) -> [String: Any] {
        let account = AppModel.capsuleAccount(profile: profile, accounts: appModel.providerAccounts)
        let provider: String
        if case .localOllama = profile.route { provider = "Local" } else { provider = account?.kind.marketingName ?? "Missing account" }
        return ["id": profile.id.uuidString, "name": profile.name, "role": profile.role.rawValue,
                "provider": provider, "model": profile.model, "access": profile.accessCeiling.rawValue,
                "available": (try? appModel.agentProfileProvider(profile)) != nil]
    }

    static func confirmationText(_ steps: [PluginPanelMessage.RunStep], profiles: [UUID: AgentProfile],
                                 appModel: AppModel) -> String {
        var lines: [String] = []
        for agentID in steps.map(\.agentID).uniqued() {
            guard let profile = profiles[agentID] else { continue }
            let info = summary(profile, appModel: appModel)
            let mine = steps.filter { $0.agentID == agentID }
            let titles = mine.map { $0.edits ? "\($0.title) (edits files)" : $0.title }.joined(separator: ", ")
            var line = "• \(profile.name) — \(info["provider"] as? String ?? "")\(profile.model.isEmpty ? "" : " · \(profile.model)"): \(titles)"
            if mine.contains(where: \.edits), profile.accessCeiling == .readOnly {
                line += " — can only read, so its editing steps will fail"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
