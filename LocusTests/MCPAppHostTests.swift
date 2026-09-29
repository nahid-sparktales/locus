import AppKit
import WebKit
import XCTest
@testable import Locus

@MainActor
final class MCPAppHostTests: XCTestCase {
    func testSandboxRejectsInjectedPoliciesAndPrivateOrigins() {
        let csp = JSONValue.object(["resourceDomains": .array([
            .string("https://cdn.example.com"), .string("https://*.static.example.com"),
            .string("http://cdn.example.com"), .string("https://127.0.0.1"),
            .string("https://app.local"), .string("https://cdn.example.com; connect-src *"),
            .string("https://user:password@example.com"), .string("https://example.com/file.js"),
        ])])
        XCTAssertEqual(MCPAppSandbox.resourceOrigins(csp), ["https://cdn.example.com", "https://*.static.example.com"])
        let policy = MCPAppSandbox.policy(csp)
        XCTAssertTrue(policy.contains("connect-src 'none'"))
        XCTAssertTrue(policy.contains("frame-src 'none'"))
        XCTAssertTrue(policy.contains("form-action 'none'"))
        XCTAssertNil(MCPAppSandbox.externalURL("javascript:alert(1)"))
        XCTAssertNil(MCPAppSandbox.externalURL("file:///etc/passwd"))
        XCTAssertNil(MCPAppSandbox.externalURL("https://user:pass@example.com"))
    }

    func testUntrustedMessagesMustBeBoundedJSONRPC() {
        XCTAssertNotNil(MCPAppSandbox.request(["jsonrpc": "2.0", "method": "ui/initialize", "id": 1]))
        XCTAssertNil(MCPAppSandbox.request(["jsonrpc": "2.0", "method": "tools/call", "id": true]))
        XCTAssertNil(MCPAppSandbox.request(["method": "tools/call", "id": 1]))
        XCTAssertNil(MCPAppSandbox.request(["jsonrpc": "2.0", "method": "tools/call", "params": ["text": String(repeating: "a", count: 300_000)]]))
    }

    func testChatGPTConnectionLinksAreRestrictedToChatGPT() throws {
        func app(_ url: String) throws -> ChatGPTDirectoryApp {
            let data = try JSONSerialization.data(withJSONObject: ["id": "fixture", "name": "Fixture", "description": "", "accessible": false, "enabled": false, "install_url": url])
            return try JSONDecoder().decode(ChatGPTDirectoryApp.self, from: data)
        }
        XCTAssertNotNil(try app("https://chatgpt.com/apps/fixture").connectionURL)
        for invalid in ["https://chatgpt.com.evil.com/apps", "https://chatgpt.com:8080/apps", "javascript:alert(1)", "http://chatgpt.com/apps"] {
            XCTAssertNil(try app(invalid).connectionURL)
        }
    }

    func testCredentialBindingIncludesLocalProgramArguments() throws {
        func server(_ args: [String]) throws -> ExtensionMCPServer {
            let data = try JSONSerialization.data(withJSONObject: ["id": "test", "name": "test", "transport": "stdio", "command": "/usr/bin/python3", "args": args])
            return try JSONDecoder().decode(ExtensionMCPServer.self, from: data)
        }
        let calendar = try server(["/app/google_workspace_mcp.py", "calendar"])
        let changed = try server(["/other/program.py", "calendar"])
        XCTAssertNotEqual(calendar.credentialBinding, changed.credentialBinding)
    }

    func testSandboxedWebViewCompletesMCPHandshakeAndGetsToolResult() async throws {
        let html = """
        <!doctype html><html><body><script>
        window.addEventListener('message', e => {
          if(e.data.id===1) parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/initialized'},'*');
          if(e.data.method==='ui/notifications/tool-result') parent.postMessage({jsonrpc:'2.0',method:'test/result',params:e.data.params},'*');
        });
        let isolated=false;try{parent.document.body}catch(e){isolated=true}
        addEventListener('securitypolicyviolation',e=>{if(e.violatedDirective==='connect-src')parent.postMessage({jsonrpc:'2.0',method:'test/isolation',params:{isolated,blocked:true}},'*')});
        fetch('https://example.com/blocked-by-csp').catch(()=>{});
        parent.postMessage({jsonrpc:'2.0',id:1,method:'ui/initialize',params:{protocolVersion:'2026-01-26',appInfo:{name:'Fixture',version:'1.0'},appCapabilities:{}}},'*');
        </script></body></html>
        """
        let document = MCPAppDocument(id: "fixture", title: "Fixture", html: html, csp: .object([:]), input: .object([:]), result: .object(["content": .array([.object(["type": .string("text"), "text": .string("hello")])])]))
        let coordinator = MCPAppHost.Coordinator(document: document, call: { _, _ in .null }, compose: { _ in })
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(coordinator.files, forURLScheme: "locus-mcp-app")
        config.userContentController.add(coordinator, name: "mcpApp")
        config.userContentController.addUserScript(WKUserScript(source: "window.testMessages=[];addEventListener('message',e=>window.testMessages.push(e.data));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        coordinator.web = web; web.navigationDelegate = coordinator
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        defer {
            web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "mcpApp")
            coordinator.active = false; window.contentView = nil
        }
        web.load(URLRequest(url: URL(string: "locus-mcp-app://view/host")!))
        var messages: [[String: Any]] = []
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(50))
            messages = (try? await web.evaluateJavaScript("window.testMessages")) as? [[String: Any]] ?? []
            if messages.contains(where: { $0["method"] as? String == "test/result" })
                && messages.contains(where: { $0["method"] as? String == "test/isolation" }) { break }
        }
        let isolation = try XCTUnwrap(messages.first { $0["method"] as? String == "test/isolation" }?["params"] as? [String: Bool])
        XCTAssertEqual(isolation, ["isolated": true, "blocked": true])
        XCTAssertTrue(coordinator.initialized, "The sandboxed iframe must negotiate with the real host bridge")
        let result = try XCTUnwrap(messages.first { $0["method"] as? String == "test/result" })
        let params = try XCTUnwrap(result["params"] as? [String: Any])
        XCTAssertEqual((params["content"] as? [[String: Any]])?.first?["text"] as? String, "hello")
    }
}
