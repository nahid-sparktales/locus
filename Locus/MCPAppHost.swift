import AppKit
import SwiftUI
import WebKit

struct MCPAppReference: Identifiable {
    let serverID: String
    let tool: String
    let callID: String
    var id: String { serverID + ":" + tool + ":" + callID }
}

struct MCPAppDocument: Decodable {
    let id: String
    let title: String
    let html: String
    let csp: JSONValue
    let input: JSONValue
    let result: JSONValue
}

/// External resources are limited to declared HTTPS origins. Network calls,
/// child frames, forms, navigation and device permissions remain unavailable.
enum MCPAppSandbox {
    static func resourceOrigins(_ csp: JSONValue) -> [String] {
        guard case .object(let fields) = csp, case .array(let values) = fields["resourceDomains"] else { return [] }
        return values.prefix(40).compactMap { value in
            guard case .string(let raw) = value, raw.count < 300,
                  !raw.contains(where: { $0.isWhitespace || "'\";\\".contains($0) }),
                  let url = URLComponents(string: raw.replacingOccurrences(of: "https://*.", with: "https://")),
                  url.scheme == "https", let host = url.host, host.contains("."),
                  host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
                  !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/", url.port == nil || url.port == 443 else { return nil }
            return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        }
    }

    static func policy(_ csp: JSONValue) -> String {
        let origins = resourceOrigins(csp).joined(separator: " ")
        return "default-src 'none'; script-src 'unsafe-inline' \(origins); style-src 'unsafe-inline' \(origins); img-src data: blob: \(origins); font-src data: \(origins); media-src data: blob: \(origins); connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
    }

    static func externalURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, text.count <= 4096 else { return nil }
        return url
    }

    static func request(_ value: Any) -> [String: Any]? {
        guard let object = value as? [String: Any], object["jsonrpc"] as? String == "2.0",
              let method = object["method"] as? String, method.count < 100,
              JSONSerialization.isValidJSONObject(object),
              let bytes = try? JSONSerialization.data(withJSONObject: object), bytes.count <= 256 * 1024 else { return nil }
        if let id = object["id"] {
            if let number = id as? NSNumber {
                guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            } else if let string = id as? String {
                guard string.count <= 200 else { return nil }
            } else { return nil }
        }
        return object
    }
}

/// Appears with the text result, keeping the conversation visible alongside the app.
struct MCPAppResultView: View {
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    let callID: String
    var body: some View {
        if let reference = extensionsModel.mcpApps[callID] {
            MCPAppLauncher(reference: reference)
        }
    }
}

struct MCPAppLauncher: View {
    @Environment(\.locusViewColors) private var colors
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    @EnvironmentObject private var model: AppModel
    let reference: MCPAppReference
    @State private var document: MCPAppDocument?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    if document != nil { document = nil } else { open() }
                } label: {
                    Label(document == nil ? "Open interactive result" : "Close interactive result", systemImage: "rectangle.on.rectangle")
                }.buttonStyle(.locus()).disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let error { Text(error).font(.locus(size: 9)).foregroundStyle(colors.coral) }
            if let document {
                Text("\(document.title) · Actions ask for permission")
                    .font(.locus(size: 9)).foregroundStyle(colors.muted)
                MCPAppHost(document: document, call: { name, arguments in
                    try await extensionsModel.callMCPApp(document.id, tool: name, arguments: arguments)
                }, compose: { text in
                    model.draftText += (model.draftText.isEmpty ? "" : "\n\n") + text
                })
                .id(document.id)
                .frame(minHeight: 300, idealHeight: 420, maxHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
    }

    private func open() {
        loading = true; error = nil
        Task {
            defer { loading = false }
            do { document = try await extensionsModel.openMCPApp(reference) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct MCPAppHost: NSViewRepresentable {
    let document: MCPAppDocument
    let call: (String, [String: Any]) async throws -> JSONValue
    let compose: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(document: document, call: call, compose: compose) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator.files, forURLScheme: "locus-mcp-app")
        configuration.userContentController.add(context.coordinator, name: "mcpApp")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        web.load(URLRequest(url: URL(string: "locus-mcp-app://view/host")!))
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {}
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "mcpApp")
        web.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let document: MCPAppDocument
        let files: MCPAppFiles
        let call: (String, [String: Any]) async throws -> JSONValue
        let compose: (String) -> Void
        weak var web: WKWebView?
        var active = true
        var initialized = false
        var busy = false
        var negotiated = false

        init(document: MCPAppDocument, call: @escaping (String, [String: Any]) async throws -> JSONValue,
             compose: @escaping (String) -> Void) {
            self.document = document; files = MCPAppFiles(document: document)
            self.call = call; self.compose = compose
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            let expected = action.targetFrame?.isMainFrame == true ? "/host" : "/app"
            decisionHandler(url?.scheme == "locus-mcp-app" && url?.host == "view" && url?.path == expected
                && action.navigationType == .other ? .allow : .cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, message.frameInfo.isMainFrame, message.webView === web,
                  let request = MCPAppSandbox.request(message.body), let method = request["method"] as? String else { return }
            let params = request["params"] as? [String: Any] ?? [:]
            if method == "ui/initialize" {
                negotiated = true
                reply(request, result: [
                    "protocolVersion": "2026-01-26", "hostInfo": ["name": "Locus", "version": "1.0"],
                    "hostCapabilities": ["serverTools": ["listChanged": false], "message": ["text": [:]],
                                         "openLinks": [:], "sandbox": ["permissions": [:], "csp": ["resourceDomains": MCPAppSandbox.resourceOrigins(document.csp)]]],
                    "hostContext": ["theme": "light", "displayMode": "inline", "availableDisplayModes": ["inline"],
                                    "locale": Locale.current.identifier, "timeZone": TimeZone.current.identifier, "platform": "desktop"],
                ])
                return
            }
            if method == "ui/notifications/initialized", negotiated, !initialized {
                initialized = true
                deliver(["jsonrpc": "2.0", "method": "ui/notifications/tool-input", "params": ["arguments": PluginPanelBridge.foundation(document.input)]])
                deliver(["jsonrpc": "2.0", "method": "ui/notifications/tool-result", "params": PluginPanelBridge.foundation(document.result)])
                return
            }
            guard initialized else { reply(request, error: "Initialize the app first."); return }
            switch method {
            case "ping": reply(request, result: [:])
            case "ui/notifications/size-changed", "notifications/message": break
            case "tools/call", "ui/message", "ui/open-link":
                guard !busy else { reply(request, error: "An action is already awaiting a decision."); return }
                busy = true
                Task { [weak self] in
                    guard let self else { return }
                    defer { busy = false }
                    do {
                        if method == "tools/call" {
                            guard let name = params["name"] as? String, name.count <= 200,
                                  let arguments = params["arguments"] as? [String: Any] else {
                                reply(request, error: "Invalid tool request."); return
                            }
                            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted, .sortedKeys])
                            guard await confirm("Allow \(document.title) to run \(name)?", detail: String(decoding: data, as: UTF8.self)) else {
                                reply(request, error: "Action declined."); return
                            }
                            guard active else { return }
                            let result = try await call(name, arguments)
                            reply(request, result: PluginPanelBridge.foundation(result))
                        } else if method == "ui/message" {
                            guard let content = params["content"] as? [[String: Any]], !content.isEmpty,
                                  content.allSatisfy({ $0["type"] as? String == "text" && $0["text"] is String }) else {
                                reply(request, error: "Only text drafts are supported."); return
                            }
                            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                            guard text.count <= 16_000, await confirm("Add this to your chat draft?", detail: text), active else {
                                reply(request, error: "Draft declined."); return
                            }
                            compose(text); reply(request, result: [:])
                        } else {
                            guard let text = params["url"] as? String, let url = MCPAppSandbox.externalURL(text),
                                  await confirm("Open this link in your browser?", detail: text), active else {
                                reply(request, error: "Link declined or unsupported."); return
                            }
                            NSWorkspace.shared.open(url); reply(request, result: [:])
                        }
                    } catch { reply(request, error: error.localizedDescription) }
                }
            default:
                if request["id"] != nil { reply(request, error: "This host does not support \(method).", code: -32601) }
            }
        }

        private func confirm(_ title: String, detail: String) async -> Bool {
            guard active, let window = web?.window else { return false }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = "Review the full request below. This grants permission for this action only."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.string = detail
            scroll.documentView = text
            alert.accessoryView = scroll
            alert.addButton(withTitle: "Allow once"); alert.addButton(withTitle: "Cancel")
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        private func reply(_ request: [String: Any], result: Any = [String: Any](), error: String? = nil, code: Int = -32000) {
            guard let id = request["id"] else { return }
            var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
            if let error { response["error"] = ["code": code, "message": error] } else { response["result"] = result }
            deliver(response)
        }
        private func deliver(_ message: [String: Any]) {
            guard active, let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
                  data.count <= 3 * 1024 * 1024 else { return }
            // JSON is passed as a base64 string, never interpolated as executable script.
            web?.evaluateJavaScript("window.deliverMCP(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(data.base64EncodedString())'),c=>c.charCodeAt(0)))));")
        }
    }
}

final class MCPAppFiles: NSObject, WKURLSchemeHandler {
    let document: MCPAppDocument
    init(document: MCPAppDocument) { self.document = document }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "view", ["/host", "/app"].contains(url.path) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let isHost = url.path == "/host"
        let policy = isHost ? "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-src locus-mcp-app:; base-uri 'none'; form-action 'none'" : MCPAppSandbox.policy(document.csp)
        let body = isHost ? """
        <!doctype html><html><head><meta charset="utf-8"><style>html,body,iframe{margin:0;border:0;width:100%;height:100%;overflow:hidden}body{background:#fff}</style></head><body>
        <iframe id="app" title="Interactive tool result" sandbox="allow-scripts" referrerpolicy="no-referrer" src="locus-mcp-app://view/app"></iframe>
        <script>const f=document.getElementById('app'); window.addEventListener('message',e=>{if(e.source===f.contentWindow&&e.data&&typeof e.data==='object')window.webkit.messageHandlers.mcpApp.postMessage(e.data)});window.deliverMCP=m=>f.contentWindow.postMessage(m,'*');</script></body></html>
        """ : document.html
        // A response header cannot be removed or weakened by untrusted HTML.
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": policy,
            "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
            "Permissions-Policy": "camera=(), microphone=(), geolocation=(), clipboard-read=(), clipboard-write=()",
        ]) else { task.didFailWithError(URLError(.badServerResponse)); return }
        task.didReceive(response); task.didReceive(Data(body.utf8)); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
