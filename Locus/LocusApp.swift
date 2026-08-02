import AppKit
import SwiftUI

@main
struct LocusApp: App {
    @NSApplicationDelegateAdaptor(LocusApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Locus", id: "main") {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .frame(minWidth: 1_080, minHeight: 700)
                .background {
                    MainWindowMarker()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1_420, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }

            CommandMenu("Locus") {
                Button("Command Palette") { model.commandPalettePresented = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Find in Conversation") { model.openTranscriptSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.blocks.isEmpty)
                Button("Keyboard Shortcuts") { model.shortcutsPresented = true }
                    .keyboardShortcut("/", modifiers: .command)
                    .accessibilityIdentifier("menu.shortcuts")
                Button("Clear Chat") { model.requestClearChat() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.hasPendingPermission)
                    .accessibilityIdentifier("menu.clearChat")
                Button("Clear Saved Sessions…") { model.requestClearSavedSessions() }
                    .disabled(model.isClearingSessions)
                    .accessibilityIdentifier("menu.clearSessions")
                Button("Browse Hugging Face Models") { model.modelLibraryPresented = true }
                    .accessibilityIdentifier("menu.modelLibrary")
                Button("Review Changes") { model.selectInspectorTab(.changes) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Create Checkpoint") { model.checkpointPresented = true }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Export Session…") { model.exportCurrentSession() }
                    .accessibilityIdentifier("menu.exportSession")
                Divider()
                // Declared once, here — a second registration in a view would
                // silently shadow these (see the ⌘⇧K note in WorkspaceView).
                ForEach(InspectorTab.allCases) { tab in
                    Button(tab.title) { model.selectInspectorTab(tab) }
                        .keyboardShortcut(KeyEquivalent(tab.shortcutKey), modifiers: .command)
                        .disabled(model.justChatEnabled)
                }
                Button(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    model.toggleSidebar()
                }
                .keyboardShortcut("0", modifiers: .command)
                Button(model.inspectorCollapsed ? "Show Inspector" : "Hide Inspector") {
                    withAnimation(.easeInOut(duration: 0.18)) { model.toggleInspector() }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.justChatEnabled)
                Divider()
                Button("Just Chat") { model.selectedMode = .ask }
                    .keyboardShortcut("a", modifiers: .option)
                Button("Plan Mode") { model.selectedMode = .plan }
                    .keyboardShortcut("p", modifiers: .option)
                Button("Build Mode") { model.selectedMode = .build }
                    .keyboardShortcut("b", modifiers: .option)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class LocusApplicationDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("locus.main")

    static func mainWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier == mainWindowIdentifier }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard let window = Self.mainWindow(in: sender.windows) else {
            // If reopening races initial scene creation, allow SwiftUI to
            // finish presenting the unique Window scene normally.
            return true
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        // The existing main window handled the reopen. Returning false keeps
        // AppKit from asking SwiftUI to create or restore another scene.
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == Self.mainWindowIdentifier else {
            return
        }
        NSApp.terminate(nil)
    }
}

private struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowMarkerView {
        MainWindowMarkerView()
    }

    func updateNSView(_ nsView: MainWindowMarkerView, context: Context) {
        nsView.markWindow()
    }
}

private final class MainWindowMarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        markWindow()
    }

    func markWindow() {
        window?.identifier = LocusApplicationDelegate.mainWindowIdentifier
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if !model.sidebarCollapsed {
                SessionSidebarView()
                    .frame(width: 260)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            WorkspaceView()
                .frame(minWidth: 520)

            if !model.inspectorCollapsed && !model.justChatEnabled {
                InspectorView()
                    .frame(width: model.inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Keyed on the sidebar only: including the inspector would put the
        // width change in scope too, and the panel would lag behind the cursor
        // during a resize drag. Collapse animates at its call sites instead.
        .animation(.easeInOut(duration: 0.18), value: model.sidebarCollapsed)
        .background(LocusTheme.paper)
        .overlay(alignment: .bottomTrailing) {
            if let toast = model.toastMessage {
                Label(toast, systemImage: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LocusTheme.paper)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(LocusTheme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .padding(18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toastMessage)
        .sheet(isPresented: $model.commandPalettePresented) {
            CommandPaletteView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.checkpointPresented) {
            CheckpointSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.settingsPresented) {
            SettingsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.modelLibraryPresented) {
            ModelLibraryView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.shortcutsPresented) {
            ShortcutsSheet()
        }
        .sheet(isPresented: $model.graphStudioPresented) {
            GraphStudioView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.workflowRunPresented) {
            WorkflowRunSheet()
                .environmentObject(model)
        }
        .alert("Clear this chat?", isPresented: $model.clearChatConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Chat") { model.clearChatConfirmed() }
                .accessibilityIdentifier("clearChat.confirm")
        } message: {
            Text("The current conversation will remain available in Sessions. Locus will start a fresh chat with the same workspace, model, mode, context, and preview.")
        }
        .alert("Clear saved sessions?", isPresented: $model.clearSessionsConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Saved Sessions", role: .destructive) {
                model.clearSavedSessionsConfirmed()
            }
            .accessibilityIdentifier("clearSessions.confirm")
        } message: {
            Text("Previous sessions will move to a recovery folder. The active session, current chat, connection, and any running job will remain untouched.")
        }
    }
}
