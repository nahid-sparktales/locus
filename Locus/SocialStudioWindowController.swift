import AppKit
import SwiftUI

/// Native plugin screens share Agent World's catalog, trust review, Work menu,
/// and revocation lifecycle, without exposing credentials to plugin JavaScript.
@MainActor
final class SocialStudioWindowController: NSObject, NSWindowDelegate {
    private struct Entry {
        let window: NSWindow
        let store: SocialStudioStore
        let screen: AgentWorldModel.AvailableScreen
    }
    private var entries: [String: Entry] = [:]

    func open(screen: AgentWorldModel.AvailableScreen, workspace: String, appModel: AppModel) {
        guard screen.screen.isSocialStudio else { return }
        let key = SessionSummary.canonicalWorkspacePath(workspace)
        if let entry = entries[key], entry.screen == screen {
            if entry.window.isMiniaturized { entry.window.deminiaturize(nil) }
            entry.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        if let old = entries[key] { old.store.revoke(); old.window.close() }
        let support = appModel.persistenceEnabled ? NotesStore.applicationSupportDirectory
            : FileManager.default.temporaryDirectory.appendingPathComponent("LocusSocialStudio-\(UUID().uuidString)")
        let store = SocialStudioStore(workspace: key, applicationSupport: support,
            credentials: appModel.persistenceEnabled ? ConnectorCredentialStore.shared : InMemoryConnectorCredentialStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Social Studio · \(URL(fileURLWithPath: key).lastPathComponent)"
        window.identifier = NSUserInterfaceItemIdentifier("locus.socialStudio." + key)
        window.minSize = NSSize(width: 1040, height: 780)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: SocialStudioView(store: store, appModel: appModel))
        entries[key] = .init(window: window, store: store, screen: screen)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func refresh(catalog: ExtensionsResponse) {
        for (key, entry) in Array(entries) {
            let enabled = catalog.capabilities.pluginScreens == true && catalog.plugins.contains {
                $0.id == entry.screen.pluginID && $0.error == nil && $0.root == entry.screen.root && $0.digest == entry.screen.digest
                    && AgentWorldModel.enabled($0, workspace: entry.store.workspace) && ($0.screens ?? []).contains(entry.screen.screen)
            }
            if !enabled {
                entry.store.revoke()
                // Close sheets as well; disabling a plugin revokes its actions immediately.
                if let sheet = entry.window.attachedSheet { entry.window.endSheet(sheet) }
                entry.window.close(); entries.removeValue(forKey: key)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let sheet = sender.attachedSheet { sheet.makeKeyAndOrderFront(nil); return false }
        return !(entries.values.first { $0.window === sender }?.store.busy ?? false)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let key = entries.first(where: { $0.value.window === window })?.key else { return }
        entries.removeValue(forKey: key); window.contentView = nil
    }
}
