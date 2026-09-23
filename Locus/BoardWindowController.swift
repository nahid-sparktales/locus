import AppKit
import SwiftUI

/// Each detached board keeps the store it opened with, even when the main
/// window changes projects. The inspector and agents use that same store.
@MainActor
final class BoardWindowController: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var appearances: [String: BoardWindowAppearance] = [:]

    func window(for workspacePath: String) -> NSWindow? {
        windows[BoardStore.storageIdentity(workspacePath: workspacePath)]
    }

    func open(store: BoardStore, model: AppModel, ocean: Bool = false, deck: Bool = false, island: AgentWorldQuartersIsland? = nil) {
        guard store.isAvailable else { return }
        let identity = BoardStore.storageIdentity(workspacePath: store.workspacePath)
        if let window = windows[identity] {
            appearances[identity]?.ocean = ocean
            appearances[identity]?.deck = deck
            appearances[identity]?.island = island
            window.appearance = ocean ? NSAppearance(named: .darkAqua) : nil
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Board · \(URL(fileURLWithPath: store.workspacePath).lastPathComponent)"
        window.representedURL = URL(fileURLWithPath: store.workspacePath)
        window.identifier = NSUserInterfaceItemIdentifier("locus.board." + store.workspacePath)
        window.minSize = NSSize(width: 620, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if ocean { window.appearance = NSAppearance(named: .darkAqua) }
        let appearance = BoardWindowAppearance(ocean: ocean, deck: deck, island: island)
        appearances[identity] = appearance
        window.contentView = NSHostingView(rootView: BoardWindowContent(appearance: appearance, store: store, model: model))
        windows[identity] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A card sheet owns its save/discard decisions, including unsent
        // comments and a new card draft. Do not destroy it from underneath.
        guard let sheet = sender.attachedSheet else { return true }
        sheet.makeKeyAndOrderFront(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let identity = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: identity)
        appearances.removeValue(forKey: identity)
        window.contentView = nil
    }
}

private final class BoardWindowAppearance: ObservableObject {
    @Published var ocean: Bool
    @Published var deck: Bool
    @Published var island: AgentWorldQuartersIsland?
    init(ocean: Bool, deck: Bool, island: AgentWorldQuartersIsland?) {
        self.ocean = ocean; self.deck = deck; self.island = island
    }
}

private struct BoardWindowContent: View {
    @ObservedObject var appearance: BoardWindowAppearance
    private var viewColors: LocusViewColors { .init(ocean: appearance.ocean, deck: appearance.deck, island: appearance.island) }

    @ObservedObject var store: BoardStore
    @ObservedObject var model: AppModel

    var body: some View {
        InspectorBoardTab(store: store, isDetached: true)
            .environmentObject(model)
            .appFeatureEnvironment(from: model)
            .preferredColorScheme(appearance.ocean ? .dark : model.effectiveAppearance.colorScheme)
            .tint(appearance.ocean ? viewColors.signalDeep : model.accentActionColor)
            .background(viewColors.surfaceCanvas)
            .environment(\.locusOceanTheme, appearance.ocean)
            .environment(\.locusCaptainDeckTheme, appearance.deck)
            .environment(\.locusQuartersIsland, appearance.island)
            .accessibilityIdentifier("board.window")
    }
}

extension AppModel {
    /// Detached boards may outlive the foreground project. Always allocate a
    /// new chat in the board's own workspace and prefill only its confirmed
    /// response; the existing chat's text and attachments stay with it.
    func openBoardCardInNewChat(_ card: BoardCard, store: BoardStore) async -> Bool {
        guard !pendingSessionReset,
              (!isBusy && !hasPendingPermission) || taskWorkers[currentSessionID] != nil else {
            showToast("Finish the current run or chat change before opening this card in chat")
            return false
        }
        guard let current = store.cards.first(where: { $0.id == card.id }),
              let creation = startNewChat(
                in: store.workspacePath, environment: nil,
                initialDraft: store.chatPrompt(for: current)
              ) else { return false }
        guard await creation.value else { return false }
        if let delegate = NSApp.delegate as? LocusApplicationDelegate {
            delegate.windowPresenter?.present()
        } else if let window = LocusApplicationDelegate.mainWindow(in: NSApp.windows) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
