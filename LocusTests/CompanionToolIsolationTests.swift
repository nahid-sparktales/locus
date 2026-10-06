import AppKit
import SwiftUI
import XCTest
@testable import Locus

@MainActor
final class CompanionToolIsolationTests: XCTestCase {
    func testSideToolMediaDoesNotUseCenterTransportWhileNormalTranscriptStillLoads() async throws {
        CompanionToolImageProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompanionToolImageProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!,
                                     session: URLSession(configuration: configuration))
        let app = AppModel(startImmediately: false, backendOverride: backend)
        app.installTranscriptSession("central-task", blocks: [])
        app.draftText = "Private central draft"
        let media = ToolMediaReference(id: String(repeating: "a", count: 32), name: "Tool image",
                                       mimeType: "image/png", size: 1, width: 1, height: 1)
        let tool = ToolPayload(toolID: "fixture-call", tool: "fixture_tool", summary: "Returned an image",
                               detail: "", status: .done, media: [media])
        let block = ChatBlock(kind: .tool, tool: tool)
        let row = MessageBlockView(block: block, thinkingVisibility: .collapsed,
            accent: app.effectiveAccent, workspacePath: "/tmp/companion", actionsDisabled: false,
            canRewind: false, canRegenerate: false, showsAssistantMarker: false,
            showsAssistantActions: false, accessibilityIdentifier: "fixture.tool",
            selectionStore: TranscriptSelectionStore(), selectionRowID: "fixture.tool",
            onCopy: { _ in }, onUseAsDraft: {}, onMakeReusableCheck: {}, onRewind: {}, onRegenerate: {},
            onOpenWorkspaceReference: { _ in }, showsConversationActions: false)
        var context = ResponseOutputContext()
        context.allowsForegroundToolResults = false
        var routed = false
        context.openFullConversation = { routed = true }
        let host = NSHostingView(rootView: AnyView(row
            .environmentObject(app).environmentObject(app.extensionsModel)
            .environment(\.responseOutputContext, context)))
        let window = mount(host)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(CompanionToolImageProtocol.paths().isEmpty,
                      "Mounting a side tool image must not request any center-session media")
        XCTAssertFalse(routed, "Rendering a notice cannot navigate automatically")
        XCTAssertEqual(app.draftText, "Private central draft")

        // Positive control: the same real row under the normal context mounts
        // the established image loader. The transport is an in-process fixture.
        host.rootView = AnyView(row.environmentObject(app).environmentObject(app.extensionsModel)
            .environment(\.responseOutputContext, ResponseOutputContext()))
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if !CompanionToolImageProtocol.paths().isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(CompanionToolImageProtocol.paths(), ["/api/sessions/central-task/media/\(media.id)"])
        XCTAssertEqual(app.draftText, "Private central draft")
    }

    func testSideInteractiveResultMountsWithoutForegroundAppController() async throws {
        let extensions = ExtensionsModel()
        extensions.ingest("mcp_app_available", ["call_id": "fixture", "server_id": "fixture", "tool": "fixture"])
        var context = ResponseOutputContext()
        context.allowsForegroundToolResults = false
        var opened = false
        context.openFullConversation = { opened = true }
        // Deliberately provide no AppModel: the foreground MCP launcher needs
        // that controller, while the side notice must never mount it.
        let host = NSHostingView(rootView: MCPAppResultView(callID: "fixture")
            .environmentObject(extensions).environment(\.responseOutputContext, context))
        let window = mount(host)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertFalse(opened)
        XCTAssertEqual(extensions.mcpApps["fixture"]?.tool, "fixture")
    }

    private func mount(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 420, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }
}

private final class CompanionToolImageProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [String] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; requests = [] }
    static func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request.url!.path)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"detail\":\"Fixture image unavailable\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
