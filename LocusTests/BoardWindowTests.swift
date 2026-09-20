import AppKit
import XCTest
@testable import Locus

@MainActor
final class BoardWindowTests: XCTestCase {
    private func fixture() throws -> (AppModel, BoardStore, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BoardWindowTests-\(UUID())")
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoardChatURLProtocol.self]
        let backend = BackendService(baseURL: URL(string: "http://127.0.0.1:9")!,
                                     session: URLSession(configuration: configuration))
        let model = AppModel(startImmediately: false, backendOverride: backend)
        let store = BoardStore.shared(workspacePath: workspace.path,
                                      applicationSupport: root.appendingPathComponent("Support"))
        BoardChatURLProtocol.reset()
        return (model, store, root)
    }

    private func sessionInfo(_ id: String, workspace: String) -> SessionInfo {
        SessionInfo(model: "fixture", host: "http://127.0.0.1:9", cwd: workspace,
                    session: id, sessionID: id, messages: 0, approxTokens: 0,
                    promptTokens: 0, completionTokens: 0, maxIterations: 30,
                    hasProjectContext: false, permissions: .init(skipAll: false, allowed: []))
    }

    private func installOriginalChat(_ model: AppModel, workspace: String) {
        model.installTranscriptSession("original", blocks: [])
        model.sessionInfo = sessionInfo("original", workspace: workspace)
        model.draftText = "Keep this earlier draft"
        model.settings.newGitChatsUseWorktree = false
    }

    func testWindowsReuseCanonicalWorkspaceAndRemainBoundToTheirSharedStores() throws {
        let (model, store, root) = try fixture()
        defer { model.boardWindows.window(for: store.workspacePath)?.close() }
        model.boardWindows.open(store: store, model: model)
        let first = try XCTUnwrap(model.boardWindows.window(for: store.workspacePath))
        XCTAssertEqual(first.contentLayoutRect.size, NSSize(width: 1280, height: 780))
        XCTAssertEqual(first.title, "Board · project")
        model.boardWindows.open(store: BoardStore.shared(
            workspacePath: store.workspacePath + "/", applicationSupport: root.appendingPathComponent("Support")
        ), model: model)
        XCTAssertTrue(model.boardWindows.window(for: store.workspacePath + "/") === first)

        let otherPath = root.appendingPathComponent("other-project").path
        let other = BoardStore.shared(workspacePath: otherPath,
                                      applicationSupport: root.appendingPathComponent("Support"))
        model.boardWindows.open(store: other, model: model)
        defer { model.boardWindows.window(for: otherPath)?.close() }
        let second = try XCTUnwrap(model.boardWindows.window(for: otherPath))
        XCTAssertFalse(first === second)
        model.initialWorkspacePath = otherPath
        XCTAssertEqual(first.representedURL?.path, store.workspacePath)
        XCTAssertEqual(second.representedURL?.path, other.workspacePath)
        let card = try store.createCard(title: "Visible in both surfaces")
        let shared = BoardStore.shared(workspacePath: store.workspacePath,
                                       applicationSupport: root.appendingPathComponent("Support"))
        XCTAssertTrue(shared === store)
        XCTAssertEqual(shared.cards.first?.id, card.id)
        XCTAssertTrue(other.cards.isEmpty)
        first.close()
        XCTAssertNil(model.boardWindows.window(for: store.workspacePath))
        XCTAssertTrue(model.boardWindows.window(for: otherPath) === second)
        XCTAssertEqual(shared.cards.first?.id, card.id)
    }

    func testClosingBoardWaitsForTheCardSheetToFinish() throws {
        let (model, store, _) = try fixture()
        model.boardWindows.open(store: store, model: model)
        let window = try XCTUnwrap(model.boardWindows.window(for: store.workspacePath))
        defer { window.close() }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        XCTAssertFalse(model.boardWindows.windowShouldClose(window))
        window.endSheet(sheet)
        XCTAssertTrue(model.boardWindows.windowShouldClose(window))
    }

    func testDetachedCardPrefillsOnlyAfterCreationAndPreservesEarlierDraftAndAttachments() async throws {
        let (model, store, root) = try fixture()
        installOriginalChat(model, workspace: root.path)
        let attachment = ChatAttachment(url: root.appendingPathComponent("notes.txt"), kind: .text,
                                        textContent: "Earlier attachment")
        model.chatAttachments = [attachment]
        let card = try store.createCard(title: "Fix checkout", details: "Keep the user's selection")
        let gate = BoardChatURLProtocol.holdCreation()
        let opening = Task { await model.openBoardCardInNewChat(card, store: store) }
        await fulfillment(of: [gate.requested], timeout: 5)
        XCTAssertEqual(model.currentSessionID, "original")
        XCTAssertEqual(model.draftText, "Keep this earlier draft")
        model.draftText = "Latest original draft"
        let body = try XCTUnwrap(gate.requestBody)
        XCTAssertEqual(body["cwd"] as? String, store.workspacePath)
        XCTAssertEqual(body["reason"] as? String, "workspace_chat")
        try gate.respond(NewSessionResponse(ok: true, reason: "workspace_chat",
                                           sessionInfo: sessionInfo("board-chat", workspace: store.workspacePath)))
        let opened = await opening.value
        XCTAssertTrue(opened)
        XCTAssertEqual(model.currentSessionID, "board-chat")
        XCTAssertEqual(model.draftText, store.chatPrompt(for: card))
        XCTAssertEqual(model.paneDraft(for: "original"), "Latest original draft")
        XCTAssertEqual(model.splitPaneAttachments["original"], [attachment])
        XCTAssertTrue(model.chatAttachments.isEmpty)
        XCTAssertTrue(model.blocks.isEmpty, "The card is an editable draft, never an automatic send")
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(BoardChatURLProtocol.paths.filter { $0 == "/api/sessions/new" }.count, 1)
        XCTAssertFalse(BoardChatURLProtocol.paths.contains { $0.contains("/chat") || $0.contains("/send") })
    }

    func testFailedCardChatCreationLeavesOriginalDraftAndSelection() async throws {
        let (model, store, root) = try fixture()
        installOriginalChat(model, workspace: root.path)
        let card = try store.createCard(title: "Failure remains editable")
        let gate = BoardChatURLProtocol.holdCreation()
        let opening = Task { await model.openBoardCardInNewChat(card, store: store) }
        await fulfillment(of: [gate.requested], timeout: 5)
        try gate.respond(["error": "Temporarily unavailable"], status: 500)
        let opened = await opening.value
        XCTAssertFalse(opened)
        XCTAssertEqual(model.currentSessionID, "original")
        XCTAssertEqual(model.draftText, "Keep this earlier draft")
        XCTAssertFalse(model.pendingSessionReset)
    }

    func testLateCreationResponseCannotOverwriteAChatSelectedWhileItWasLoading() async throws {
        let (model, store, root) = try fixture()
        installOriginalChat(model, workspace: root.path)
        let card = try store.createCard(title: "Stale handoff")
        let gate = BoardChatURLProtocol.holdCreation()
        let opening = Task { await model.openBoardCardInNewChat(card, store: store) }
        await fulfillment(of: [gate.requested], timeout: 5)
        let newer = model.beginTranscriptSessionLoad("later-selection")
        XCTAssertTrue(model.completeTranscriptSessionLoad(newer, sessionID: "later-selection", blocks: []))
        model.draftText = "A different chat's draft"
        try gate.respond(NewSessionResponse(ok: true, reason: "workspace_chat",
                                           sessionInfo: sessionInfo("board-chat", workspace: store.workspacePath)))
        let opened = await opening.value
        XCTAssertFalse(opened)
        XCTAssertEqual(model.currentSessionID, "later-selection")
        XCTAssertEqual(model.draftText, "A different chat's draft")
    }
}

private final class BoardChatURLProtocol: URLProtocol, @unchecked Sendable {
    final class Gate: @unchecked Sendable {
        let requested = XCTestExpectation(description: "New board chat requested")
        private let lock = NSLock()
        private var pending: BoardChatURLProtocol?
        var requestBody: [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            guard let request = pending?.request else { return nil }
            let data: Data
            if let body = request.httpBody { data = body }
            else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var collected = Data()
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count > 0 else { break }
                    collected.append(contentsOf: bytes.prefix(count))
                }
                data = collected
            } else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        func attach(_ value: BoardChatURLProtocol) {
            lock.lock(); pending = value; lock.unlock()
            requested.fulfill()
        }
        func respond<Value: Encodable>(_ value: Value, status: Int = 200) throws {
            let data = try JSONEncoder().encode(value)
            lock.lock(); let active = pending; pending = nil; lock.unlock()
            try XCTUnwrap(active).finish(status: status, data: data)
        }
    }

    private static let lock = NSLock()
    private static var gate: Gate?
    private static var recordedPaths: [String] = []
    static var paths: [String] {
        lock.lock(); defer { lock.unlock() }; return recordedPaths
    }
    static func reset() { lock.lock(); gate = nil; recordedPaths = []; lock.unlock() }
    static func holdCreation() -> Gate {
        let value = Gate()
        lock.lock(); gate = value; lock.unlock()
        return value
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        Self.recordedPaths.append(path)
        let gate = path == "/api/sessions/new" ? Self.gate : nil
        if gate != nil { Self.gate = nil }
        Self.lock.unlock()
        if let gate { gate.attach(self) }
        else { finish(status: 404, data: Data("{}".utf8)) }
    }
    private func finish(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
