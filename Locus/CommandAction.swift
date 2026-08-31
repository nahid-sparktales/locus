import Foundation

enum CommandAction: String, CaseIterable, Identifiable {
    case newSession
    case clearChat
    case clearSessions
    case reviewChanges
    case createCheckpoint
    case askMode
    case workMode
    case planMode
    case grillMode
    case chooseWorkspace
    case newWorkspace
    case browseModels
    case refreshModels
    case exportSession
    case permissions
    case searchConversations
    case showUsage
    case showShortcuts
    case showNotebook
    case openSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newSession: "Start a new session"
        case .clearChat: "Clear chat"
        case .clearSessions: "Clear saved sessions"
        case .reviewChanges: "Review file changes"
        case .createCheckpoint: "Create a session checkpoint"
        case .askMode: "Turn on Just Chat"
        case .workMode: "Use adaptive Work mode"
        case .planMode: "Switch to Plan mode"
        case .grillMode: "Switch to Grill mode"
        case .chooseWorkspace: "Choose a workspace"
        case .newWorkspace: "Create a new workspace folder"
        case .browseModels: "Browse Hugging Face models"
        case .refreshModels: "Refresh installed models"
        case .exportSession: "Export current session as Markdown"
        case .permissions: "Change what the agent may do without asking"
        case .searchConversations: "Search all conversations"
        case .showUsage: "Show usage and costs"
        case .showShortcuts: "Show keyboard shortcuts"
        case .showNotebook: "Open the notebook"
        case .openSettings: "Open Settings"
        }
    }

    var symbol: String {
        switch self {
        case .newSession: "plus"
        case .clearChat: "eraser"
        case .clearSessions: "trash"
        case .reviewChanges: "doc.text.magnifyingglass"
        case .createCheckpoint: "clock.arrow.circlepath"
        case .askMode: "bubble.left"
        case .workMode: "sparkles"
        case .planMode: "list.bullet.clipboard"
        case .grillMode: "flame"
        case .chooseWorkspace: "folder"
        case .newWorkspace: "folder.badge.plus"
        case .browseModels: "shippingbox.and.arrow.backward"
        case .refreshModels: "arrow.clockwise"
        case .exportSession: "square.and.arrow.up"
        case .permissions: "shield.lefthalf.filled"
        case .searchConversations: "text.magnifyingglass"
        case .showUsage: "dollarsign.circle"
        case .showShortcuts: "keyboard"
        case .showNotebook: "text.book.closed"
        case .openSettings: "gearshape"
        }
    }

    var shortcut: String {
        switch self {
        case .newSession: "⌘N"
        case .clearChat: "⌘⇧K"
        case .clearSessions: ""
        case .reviewChanges: "⌘R"
        case .createCheckpoint: "⌘S"
        case .askMode: "⌥A"
        case .workMode: "⌥W"
        case .planMode: "⌥P"
        case .grillMode: "⌥G"
        case .showShortcuts: "⌘/"
        case .showNotebook: "⇧⌘9"
        case .searchConversations: "⇧⌘F"
        case .chooseWorkspace, .newWorkspace, .browseModels, .refreshModels,
             .exportSession, .permissions, .showUsage, .openSettings: ""
        }
    }
}
