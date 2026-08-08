import Foundation
import WebKit

struct BrowserConsoleEntry: Identifiable, Equatable {
    let id = UUID()
    let level: String
    let message: String
    let url: String
    let at: Date

    var isError: Bool { level == "error" }
}

struct BrowserNetworkEntry: Identifiable, Equatable {
    /// The id the page-world script minted, so `browser_network` can ask for
    /// one response by name.
    let id: String
    let method: String
    let url: String
    /// Absent for resource-timing entries: the browser fetched those itself and
    /// no status code is observable from JavaScript.
    let status: Int?
    let ok: Bool
    let durationMS: Int
    let contentType: String
    let source: String
    let size: Int
    let at: Date
    var body: String

    var summary: String {
        let code = status.map(String.init) ?? "—"
        var line = "\(method) \(url) → \(code) in \(durationMS)ms"
        if source == "resource" { line += " [sub-resource: timing only]" }
        if size > 0 { line += " \(size)B" }
        return line
    }
}

/// Bounded console and network history for one tab.
///
/// Caps matter more than they look: a page can produce these faster than
/// anything can read them, and every entry arrives on the main actor.
@MainActor
final class BrowserCaptureLog {
    static let consoleLimit = 500
    static let networkLimit = 200
    /// Bodies are the expensive part, so only the newest entries keep theirs.
    static let bodyLimit = 25

    private(set) var console: [BrowserConsoleEntry] = []
    private(set) var network: [BrowserNetworkEntry] = []
    private(set) var droppedEntries = 0

    func clear() {
        console.removeAll()
        network.removeAll()
        droppedEntries = 0
    }

    func note(dropped: Int) {
        guard dropped > 0 else { return }
        droppedEntries += dropped
    }

    func append(console entry: BrowserConsoleEntry) {
        console.append(entry)
        if console.count > Self.consoleLimit {
            console.removeFirst(console.count - Self.consoleLimit)
        }
    }

    func append(network entry: BrowserNetworkEntry) {
        network.append(entry)
        if network.count > Self.networkLimit {
            network.removeFirst(network.count - Self.networkLimit)
        }
        // Trim bodies outside the newest window rather than dropping the
        // entries: the model usually wants the request list, and only
        // occasionally one response.
        let keepFrom = max(0, network.count - Self.bodyLimit)
        for index in network.indices where index < keepFrom && !network[index].body.isEmpty {
            network[index].body = ""
        }
    }

    func body(forRequest id: String) -> String? {
        network.first { $0.id == id }?.body.nilIfBlank
    }
}

/// `WKUserContentController` retains its handlers strongly, so registering the
/// service directly is the classic WebKit retain cycle — here it would mean
/// every closed tab keeping its buffers for the life of the app.
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(controller, didReceive: message)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
