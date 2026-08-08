import AppKit
import SwiftUI

private let locusIsUITesting = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1"

enum LocusWindowSizing {
    static let defaultSize = NSSize(width: 1_200, height: 760)
    static let normalizationKey = "Locus.didNormalizeMainWindow.1200x760"

    static func centeredFrame(in visibleFrame: NSRect) -> NSRect {
        let size = NSSize(
            width: min(defaultSize.width, visibleFrame.width),
            height: min(defaultSize.height, visibleFrame.height)
        )
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

@main
struct LocusApp: App {
    @NSApplicationDelegateAdaptor(LocusApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Locus", id: "main") {
            RootView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
                .preferredColorScheme(.light)
                .frame(
                    minWidth: locusIsUITesting ? 920 : 1_080,
                    minHeight: locusIsUITesting ? 620 : 700
                )
                .background {
                    MainWindowMarker()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(
            width: LocusWindowSizing.defaultSize.width,
            height: LocusWindowSizing.defaultSize.height
        )
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
                Button("Adaptive Work") { model.selectedMode = .work }
                    .keyboardShortcut("w", modifiers: .option)
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
    weak var model: AppModel?
    private var terminationPending = false

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        guard model?.hasRunningWorkForQuit == true else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Stop running work and quit Locus?"
        alert.informativeText = "The active team and its private checkout will remain available to resume."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }
        terminationPending = true
        model?.stopRunningWorkForQuit { [weak self, weak sender] in
            self?.terminationPending = false
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
    private var preparedUITestWindow = false
    private var normalizedLaunchWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        markWindow()
    }

    func markWindow() {
        guard let window else { return }
        window.identifier = LocusApplicationDelegate.mainWindowIdentifier

        guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }

        // UI tests and documentation captures use the same frame customers
        // see, clamped only when the available display is smaller.
        if locusIsUITesting {
            guard !preparedUITestWindow else { return }
            preparedUITestWindow = true
            window.setFrame(LocusWindowSizing.centeredFrame(in: visibleFrame), display: true)
            return
        }

        // SwiftUI restores the previous window frame before applying the
        // scene's default. Normalize that saved oversized frame once for this
        // release, then leave every resize the customer makes alone.
        let defaults = UserDefaults.standard
        guard !normalizedLaunchWindow,
              !defaults.bool(forKey: LocusWindowSizing.normalizationKey) else {
            return
        }
        normalizedLaunchWindow = true
        window.setFrame(LocusWindowSizing.centeredFrame(in: visibleFrame), display: true)
        defaults.set(true, forKey: LocusWindowSizing.normalizationKey)
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if !model.sidebarCollapsed {
                SessionSidebarView()
                    .frame(width: locusIsUITesting ? 240 : 260)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            WorkspaceView()
                .frame(minWidth: locusIsUITesting ? 400 : 520)

            if !model.inspectorCollapsed && !model.justChatEnabled {
                InspectorView()
                    .frame(width: locusIsUITesting ? 280 : model.inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Keyed on the sidebar only: including the inspector would put the
        // width change in scope too, and the panel would lag behind the cursor
        // during a resize drag. Collapse animates at its call sites instead.
        .animation(.easeInOut(duration: 0.18), value: model.sidebarCollapsed)
        .background(LocusTheme.paper)
        .overlay(alignment: .bottomTrailing) {
            if let toast = model.toast {
                HStack(spacing: 12) {
                    Label(toast.message, systemImage: toast.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                    if let actionTitle = toast.actionTitle {
                        Button(actionTitle) { model.performToastAction() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LocusTheme.signal)
                            .accessibilityIdentifier("toast.action")
                    }
                }
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
        .animation(.easeOut(duration: 0.18), value: model.toast?.id)
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
