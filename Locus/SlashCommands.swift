import Foundation

/// A composer slash command, mirroring the Claude Code slash-command surface
/// with actions that Locus can run locally against the bundled agent.
struct SlashCommand: Identifiable, Hashable {
    enum Action: Hashable {
        case clearChat
        case newSession
        case setMode(WorkMode)
        case selectModel
        case browseModels
        case refreshModels
        case createCheckpoint
        case manageCheckpoints
        case reviewChanges
        case openPreview
        case addContext
        case exportSession
        case chooseWorkspace
        case newWorkspace
        case openSettings
        case setPermissionMode(PermissionMode)
        case showShortcuts
        case showHelp
        case copyLastResponse
        case retryLastResponse
        case stopRun
        case compact
        case remember
        case setThinkingVisibility
    }

    let name: String
    let aliases: [String]
    let summary: String
    let argumentHint: String?
    let symbol: String
    let action: Action

    var id: String { name }

    /// Every command available from the composer, in palette order.
    static let all: [SlashCommand] = [
        SlashCommand(
            name: "clear", aliases: ["new"],
            summary: "Start a fresh chat (keeps this one in Sessions)",
            argumentHint: nil, symbol: "eraser", action: .clearChat
        ),
        SlashCommand(
            name: "model", aliases: [],
            summary: "Switch the Ollama model",
            argumentHint: "name", symbol: "bolt", action: .selectModel
        ),
        SlashCommand(
            name: "models", aliases: ["library"],
            summary: "Browse and install Hugging Face models",
            argumentHint: nil, symbol: "shippingbox", action: .browseModels
        ),
        SlashCommand(
            name: "ask", aliases: [],
            summary: "Turn on Just Chat",
            argumentHint: nil, symbol: "bubble.left", action: .setMode(.ask)
        ),
        SlashCommand(
            name: "work", aliases: [],
            summary: "Use adaptive Work mode",
            argumentHint: nil, symbol: "sparkles", action: .setMode(.work)
        ),
        SlashCommand(
            name: "plan", aliases: [],
            summary: "Switch to Plan mode",
            argumentHint: nil, symbol: "list.bullet.clipboard", action: .setMode(.plan)
        ),
        SlashCommand(
            name: "grill", aliases: ["gsd", "build"],
            summary: "Switch to Grill mode",
            argumentHint: nil, symbol: "flame", action: .setMode(.grill)
        ),
        SlashCommand(
            name: "checkpoint", aliases: ["save"],
            summary: "Create a session checkpoint",
            argumentHint: "title", symbol: "clock.arrow.circlepath", action: .createCheckpoint
        ),
        SlashCommand(
            name: "rewind", aliases: ["restore", "checkpoints"],
            summary: "Open checkpoints to restore an earlier state",
            argumentHint: nil, symbol: "arrow.counterclockwise", action: .manageCheckpoints
        ),
        SlashCommand(
            name: "changes", aliases: ["review", "diff"],
            summary: "Review file changes from this session",
            argumentHint: nil, symbol: "doc.text.magnifyingglass", action: .reviewChanges
        ),
        SlashCommand(
            name: "browser", aliases: ["preview"],
            summary: "Open the browser inspector",
            argumentHint: nil, symbol: "globe", action: .openPreview
        ),
        SlashCommand(
            name: "context", aliases: ["add"],
            summary: "Add files or folders to the context pack",
            argumentHint: nil, symbol: "doc.on.doc", action: .addContext
        ),
        SlashCommand(
            name: "export", aliases: [],
            summary: "Export the current session as Markdown",
            argumentHint: nil, symbol: "square.and.arrow.up", action: .exportSession
        ),
        SlashCommand(
            name: "workspace", aliases: ["cwd"],
            summary: "Choose a different workspace folder",
            argumentHint: nil, symbol: "folder", action: .chooseWorkspace
        ),
        SlashCommand(
            name: "newworkspace", aliases: ["mkdir"],
            summary: "Create a new folder and open it as the workspace",
            argumentHint: nil, symbol: "folder.badge.plus", action: .newWorkspace
        ),
        SlashCommand(
            name: "copy", aliases: [],
            summary: "Copy the latest response",
            argumentHint: nil, symbol: "doc.on.clipboard", action: .copyLastResponse
        ),
        SlashCommand(
            name: "retry", aliases: ["regenerate"],
            summary: "Regenerate the latest response",
            argumentHint: nil, symbol: "arrow.clockwise", action: .retryLastResponse
        ),
        SlashCommand(
            name: "stop", aliases: [],
            summary: "Stop the current run",
            argumentHint: nil, symbol: "stop.fill", action: .stopRun
        ),
        SlashCommand(
            name: "compact", aliases: [],
            summary: "Ask the agent to compact the conversation",
            argumentHint: nil, symbol: "arrow.down.right.and.arrow.up.left", action: .compact
        ),
        SlashCommand(
            name: "remember", aliases: [],
            summary: "Save an approved fact or convention to this workspace",
            argumentHint: "text", symbol: "bookmark", action: .remember
        ),
        SlashCommand(
            name: "permissions", aliases: ["perms"],
            summary: "Ask before every action (the safe default)",
            argumentHint: nil, symbol: "hand.raised", action: .setPermissionMode(.ask)
        ),
        SlashCommand(
            name: "acceptedits", aliases: ["autoedit"],
            summary: "Let file edits run without asking; commands still ask",
            argumentHint: nil, symbol: "square.and.pencil",
            action: .setPermissionMode(.acceptEdits)
        ),
        SlashCommand(
            name: "bypass", aliases: ["yolo"],
            summary: "Run every tool without asking — use with care",
            argumentHint: nil, symbol: "bolt", action: .setPermissionMode(.bypass)
        ),
        SlashCommand(
            name: "thinking", aliases: ["think"],
            summary: "Show, collapse, or hide the model's reasoning",
            argumentHint: "hidden|collapsed|expanded", symbol: "brain",
            action: .setThinkingVisibility
        ),
        SlashCommand(
            name: "settings", aliases: ["config"],
            summary: "Open Locus settings",
            argumentHint: nil, symbol: "gearshape", action: .openSettings
        ),
        SlashCommand(
            name: "shortcuts", aliases: ["keys"],
            summary: "Show keyboard shortcuts",
            argumentHint: nil, symbol: "keyboard", action: .showShortcuts
        ),
        SlashCommand(
            name: "help", aliases: ["?"],
            summary: "List available commands",
            argumentHint: nil, symbol: "questionmark.circle", action: .showHelp
        ),
    ]

    /// Parses a draft into a slash query when the caret text is a command
    /// invocation ("/", "/mo", "/model qwen"). Returns nil for ordinary prose.
    static func query(from draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let firstLine = draft.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard firstLine == draft[...] || !draft.contains("\n") else { return nil }
        return String(firstLine.dropFirst())
    }

    /// Commands matching a query typed after "/" — prefix matches on the name
    /// or an alias rank first, then substring matches on the summary.
    static func matches(for query: String) -> [SlashCommand] {
        let term = query
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .lowercased()
        guard !term.isEmpty else { return all }
        let prefixed = all.filter { command in
            command.name.hasPrefix(term) || command.aliases.contains { $0.hasPrefix(term) }
        }
        let described = all.filter { command in
            !prefixed.contains(command) && command.summary.lowercased().contains(term)
        }
        return prefixed + described
    }

    /// The argument portion of an invocation ("/model qwen3" → "qwen3").
    static func argument(in draft: String) -> String {
        guard let query = query(from: draft) else { return "" }
        let parts = query.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
    }

    /// True when the draft names this command exactly ("/plan", "/model x").
    func isInvoked(by draft: String) -> Bool {
        guard let query = Self.query(from: draft) else { return false }
        let term = query
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .lowercased()
        return term == name || aliases.contains(term)
    }

    static func command(invokedBy draft: String) -> SlashCommand? {
        all.first { $0.isInvoked(by: draft) }
    }

    var helpLine: String {
        let hint = argumentHint.map { " <\($0)>" } ?? ""
        return "/\(name)\(hint) — \(summary)"
    }
}
