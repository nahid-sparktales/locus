import Foundation

/// One line of console output.
struct TerminalLine: Identifiable, Hashable {
    enum Kind: Hashable {
        case command
        case output
        case status
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

/// What the console needs from the agent connection. A protocol so the panel
/// and its tests do not depend on a live socket.
@MainActor
protocol TerminalTransport: AnyObject {
    @discardableResult
    func sendTerminal(_ payload: [String: Any]) -> Bool
}

/// Console state, deliberately its own ObservableObject rather than fields on
/// AppModel: streaming output through AppModel would republish the sidebar,
/// conversation and composer on every chunk.
@MainActor
final class TerminalSession: ObservableObject {
    /// Output is capped so a runaway command cannot grow without bound.
    static let maximumLines = 5_000

    @Published private(set) var lines: [TerminalLine] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastExitCode: Int?
    @Published var draft = ""
    @Published var stdinDraft = ""

    private(set) var runID: String?
    weak var transport: TerminalTransport?
    /// True when the newest line has not been terminated by a newline yet.
    private var lastLineIsPartial = false

    var isEmpty: Bool { lines.isEmpty }

    // MARK: - Commands

    func run(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        runID = String(identifier)
        append(.command, "$ \(trimmed)")
        guard transport?.sendTerminal([
            "type": "terminal_run",
            "command": trimmed,
            "run_id": String(identifier),
        ]) == true else {
            append(.status, "Reconnect the local agent to run commands.")
            runID = nil
            return
        }
        isRunning = true
        lastExitCode = nil
        draft = ""
    }

    func cancel(force: Bool = false) {
        guard let runID else { return }
        guard transport?.sendTerminal([
            "type": "terminal_cancel",
            "run_id": runID,
            "force": force,
        ]) == true else {
            // The cancel never left the app; without this the field stays
            // disabled waiting for an exit event that cannot arrive.
            connectionLost()
            return
        }
    }

    /// Called when the agent connection drops: only a backend event could
    /// clear the running state, and that event is never coming.
    func connectionLost() {
        guard isRunning || runID != nil else { return }
        isRunning = false
        runID = nil
        append(.status, "Connection to the agent was lost — the command may still be running.")
    }

    func sendInput(_ text: String) {
        guard let runID, isRunning else { return }
        transport?.sendTerminal([
            "type": "terminal_input",
            "run_id": runID,
            "text": text,
        ])
        append(.command, "› \(text)")
        stdinDraft = ""
    }

    func clear() {
        lines = []
        lastExitCode = nil
        lastLineIsPartial = false
    }

    // MARK: - Events from the agent

    func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "terminal_started":
            runID = event["run_id"] as? String
            isRunning = true
            if (event["resumed"] as? Bool) == true {
                append(.status, "Reattached to a command already running.")
            }

        case "terminal_output":
            guard let text = event["text"] as? String, !text.isEmpty else { return }
            appendOutput(text)

        case "terminal_exit":
            isRunning = false
            let code = event["exit_code"] as? Int
            lastExitCode = code
            append(.status, Self.exitSummary(event))
            runID = nil

        case "terminal_error":
            isRunning = false
            runID = nil
            append(.status, (event["message"] as? String) ?? "The command could not run.")

        case "terminal_state":
            // A reconnect with no live run means anything we thought was
            // running has finished.
            if (event["runs"] as? [[String: Any]])?.isEmpty ?? true {
                isRunning = false
                runID = nil
            }

        default:
            break
        }
    }

    static func exitSummary(_ event: [String: Any]) -> String {
        let reason = event["reason"] as? String ?? "exited"
        if let signal = event["signal"] as? String {
            return "Stopped by \(signal)."
        }
        let code = event["exit_code"] as? Int
        switch reason {
        case "cancelled": return "Cancelled."
        case "timeout": return "Timed out and was stopped."
        default:
            guard let code else { return "Finished." }
            return code == 0 ? "Finished." : "Exited with code \(code)."
        }
    }

    // MARK: - Buffer

    private func append(_ kind: TerminalLine.Kind, _ text: String) {
        lines.append(TerminalLine(kind: kind, text: text))
        lastLineIsPartial = false
        trim()
    }

    /// Output arrives in arbitrary chunks, so a chunk may finish the previous
    /// line rather than start a new one. Whether the last line is still open
    /// has to be tracked explicitly — the text alone cannot tell you, because
    /// a completed line and a partial one both end without a newline once the
    /// trailing empty component is dropped.
    private func appendOutput(_ text: String) {
        var pieces = text.components(separatedBy: "\n")

        if lastLineIsPartial,
           let first = pieces.first,
           let last = lines.last,
           last.kind == .output
        {
            lines[lines.count - 1] = TerminalLine(kind: .output, text: last.text + first)
            pieces.removeFirst()
        }

        let endedWithNewline = pieces.last?.isEmpty == true
        if endedWithNewline { pieces.removeLast() }
        for piece in pieces {
            lines.append(TerminalLine(kind: .output, text: piece))
        }
        lastLineIsPartial = !endedWithNewline
        trim()
    }

    private func trim() {
        if lines.count > Self.maximumLines {
            lines.removeFirst(lines.count - Self.maximumLines)
        }
    }
}
