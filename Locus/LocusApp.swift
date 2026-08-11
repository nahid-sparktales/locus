import AppKit
import SwiftUI
import UserNotifications

private let locusIsUITesting = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1"
private let locusIsUnitTesting =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        && !locusIsUITesting

enum LocusWindowSizing {
    static let defaultSize = NSSize(width: 1_250, height: 760)
    static let normalizationKey = "Locus.didNormalizeMainWindow.1250x760"

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
    // XCTest injects the test bundle into the normal app host. Keep that host
    // inert so it cannot start a second backend or workspace watcher alongside
    // the models owned by unit tests. UI tests still need their seeded app.
    @StateObject private var model = AppModel(startImmediately: !locusIsUnitTesting)

    var body: some Scene {
        Window("Locus", id: "main") {
            RootView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
                .preferredColorScheme(model.effectiveAppearance.colorScheme)
                .frame(
                    // Sidebar 260 + workspace 520 + panel 280 + rail 44.
                    minWidth: locusIsUITesting ? 980 : 1_120,
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
                Button("Search All Conversations") {
                    if model.sidebarCollapsed { model.toggleSidebar() }
                    model.sidebarSearchFocusToken = UUID()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .accessibilityIdentifier("menu.searchConversations")
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
                Button("Open Terminal") { model.openTerminal() }
                    .keyboardShortcut("`", modifiers: .control)
                    .disabled(model.justChatEnabled)
                    .accessibilityIdentifier("menu.terminal")
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
                Button(model.inspectorZoomed ? "Restore Panel" : "Expand Panel") {
                    withAnimation(.easeInOut(duration: 0.18)) { model.toggleInspectorZoom() }
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
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
            SettingsView(presentationContext: .settingsWindow)
                .environmentObject(model)
                .preferredColorScheme(model.effectiveAppearance.colorScheme)
        }
    }
}

@MainActor
final class LocusApplicationDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("locus.main")
    weak var model: AppModel?
    private var terminationPending = false

    static func mainWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier == mainWindowIdentifier }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let sessionID = info["session_id"] as? String ?? ""
        let runID = info["run_id"] as? String ?? ""
        Task { @MainActor [weak self] in
            self?.model?.openNotification(sessionID: sessionID, runID: runID)
            NSApp.activate(ignoringOtherApps: true)
            completionHandler()
        }
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
        alert.messageText = "Stop running processes and quit Locus?"
        alert.informativeText = model?.terminal.hasForegroundJob == true
            ? "The terminal has a foreground job. It will be stopped; resumable agent tasks and private checkouts remain available."
            : "The active team and its private checkout will remain available to resume."
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

            // Zoomed, chat becomes the fixed column and the panel takes the
            // remainder; one frame call, because a stacked min-then-fixed
            // pair would let the inner minimum win over the outer width.
            WorkspaceView()
                .frame(
                    minWidth: model.inspectorZoomed
                        ? model.zoomedChatWidth
                        : (locusIsUITesting ? 400 : 520),
                    maxWidth: model.inspectorZoomed ? model.zoomedChatWidth : .infinity
                )

            if !model.inspectorCollapsed && !model.justChatEnabled {
                InspectorView()
                    .frame(
                        minWidth: model.inspectorZoomed
                            ? nil
                            : (locusIsUITesting ? 280 : model.inspectorWidth),
                        maxWidth: model.inspectorZoomed
                            ? .infinity
                            : (locusIsUITesting ? 280 : model.inspectorWidth)
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if !model.justChatEnabled {
                InspectorRail()
                    .environmentObject(model)
            }
        }
        // Keyed on the sidebar and the zoom flag only: including the inspector
        // would put the width change in scope too, and the panel would lag
        // behind the cursor during a resize drag. Zoom is safe — it flips on
        // toggle, never during a drag. Collapse animates at its call sites.
        .animation(.easeInOut(duration: 0.18), value: model.sidebarCollapsed)
        .animation(.easeInOut(duration: 0.18), value: model.inspectorZoomed)
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
        .sheet(isPresented: $model.reviewAndLandPresented) {
            ReviewAndLandView()
                .environmentObject(model)
        }
        .sheet(isPresented: Binding(
            get: { model.rememberConfirmationText != nil },
            set: { if !$0 { model.rememberConfirmationText = nil } }
        )) {
            if let text = model.rememberConfirmationText {
                RememberConfirmationView(initialText: text)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: $model.settingsPresented, onDismiss: {
            model.completeSettingsDismissal()
        }) {
            SettingsView(presentationContext: .sheet)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.usageDashboardPresented) {
            UsageDashboardView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.modelLibraryPresented) {
            ModelLibraryView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.shortcutsPresented) {
            ShortcutsSheet()
        }
        .sheet(item: Binding(
            get: { model.mcpInputRequest },
            set: { value in
                if value == nil, model.mcpInputRequest != nil {
                    model.answerMCPInput(action: "cancel")
                }
            }
        )) { request in
            MCPInputRequestView(request: request)
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .alert(model.automaticInspectorPrompt?.title ?? "Open request details automatically?", isPresented: Binding(
            get: { model.automaticInspectorPrompt != nil },
            set: { presented in
                if !presented, model.automaticInspectorPrompt != nil {
                    model.answerAutomaticInspectorPrompt(showEveryTime: false)
                }
            }
        )) {
            Button("Not Automatically", role: .cancel) {
                model.answerAutomaticInspectorPrompt(showEveryTime: false)
            }
            .accessibilityIdentifier("inspector.automatic.never")
            Button(model.automaticInspectorPrompt?.confirmationTitle ?? "Open Every Time") {
                model.answerAutomaticInspectorPrompt(showEveryTime: true)
            }
            .accessibilityIdentifier("inspector.automatic.always")
        } message: {
            Text(model.automaticInspectorPrompt?.message ?? "")
        }
        .alert("Clear this chat?", isPresented: $model.clearChatConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Chat") { model.clearChatConfirmed() }
                .accessibilityIdentifier("clearChat.confirm")
        } message: {
            Text("The current conversation will remain available in Sessions. Locus will start a fresh chat with the same workspace, model, mode, context, and browser home.")
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

private struct RememberConfirmationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var tags = ""
    @State private var scope = AgentMemoryScope.workspace

    init(initialText: String) {
        _title = State(initialValue: String(initialText.prefix(80)))
        _content = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remember This")
                .font(.system(size: 16, weight: .bold))
            Text("Review or edit the memory before saving. Saving is explicit approval, so it can be recalled in future chats within its scope.")
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Title", text: $title)
                .accessibilityIdentifier("remember.title")
            TextEditor(text: $content)
                .font(.system(size: 10))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 120)
                .background(LocusTheme.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(LocusTheme.line) }
                .accessibilityIdentifier("remember.content")
            Picker("Scope", selection: $scope) {
                ForEach(AgentMemoryScope.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            TextField("Tags, comma separated", text: $tags)
                .accessibilityIdentifier("remember.tags")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Memory") {
                    model.rememberWorkspaceFact(
                        title: title,
                        content: content,
                        tags: tags.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        }.filter { !$0.isEmpty },
                        scope: scope
                    )
                    model.rememberConfirmationText = nil
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("remember.save")
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(LocusTheme.panel)
    }
}

private struct MCPInputRequestView: View {
    @EnvironmentObject private var model: AppModel
    let request: MCPInputRequest
    @State private var textValues: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                request.mode == "url" ? "Complete in your browser" : "Extension input requested",
                systemImage: request.mode == "url" ? "safari" : "list.bullet.rectangle"
            )
            .font(.system(size: 14, weight: .bold))
            Text(request.message)
                .font(.system(size: 10))
                .foregroundStyle(LocusTheme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if request.mode == "url" {
                Text("Sensitive information stays on the extension's verified HTTPS page. Never paste credentials, payment details, or API keys into Locus.")
                    .font(.system(size: 9))
                    .foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Secure Page") {
                    if let value = request.url.flatMap(URL.init(string:)) {
                        NSWorkspace.shared.open(value)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
            } else {
                ForEach(formFields, id: \.name) { field in
                    if field.type == "boolean" {
                        Toggle(field.title, isOn: Binding(
                            get: { boolValues[field.name] ?? false },
                            set: { boolValues[field.name] = $0 }
                        ))
                    } else {
                        TextField(field.title, text: Binding(
                            get: { textValues[field.name] ?? "" },
                            set: { textValues[field.name] = $0 }
                        ))
                    }
                }
                Text("Only the displayed non-sensitive fields are returned to the extension.")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
            HStack {
                Button("Decline") { model.answerMCPInput(action: "decline") }
                Button("Cancel") { model.answerMCPInput(action: "cancel") }
                Spacer()
                Button(request.mode == "url" ? "I've Completed It" : "Submit") {
                    model.answerMCPInput(action: "accept", content: formContent)
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(request.mode != "url" && missingRequiredField)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private struct Field {
        let name: String
        let title: String
        let type: String
        let required: Bool
    }

    private var formFields: [Field] {
        guard case .object(let properties) = request.schema?["properties"] else { return [] }
        let required: Set<String>
        if case .array(let values) = request.schema?["required"] {
            required = Set(values.compactMap(\.string))
        } else {
            required = []
        }
        return properties.keys.sorted().map { name in
            let specification: [String: JSONValue]
            if case .object(let value) = properties[name] { specification = value }
            else { specification = [:] }
            return Field(
                name: name,
                title: specification["title"]?.string ?? name.replacingOccurrences(of: "_", with: " ").capitalized,
                type: specification["type"]?.string ?? "string",
                required: required.contains(name)
            )
        }
    }

    private var missingRequiredField: Bool {
        formFields.contains { field in
            field.required && field.type != "boolean"
                && (textValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var formContent: [String: Any] {
        var output: [String: Any] = [:]
        for field in formFields {
            if field.type == "boolean" {
                output[field.name] = boolValues[field.name] ?? false
            } else if field.type == "integer" {
                output[field.name] = Int(textValues[field.name] ?? "") ?? 0
            } else if field.type == "number" {
                output[field.name] = Double(textValues[field.name] ?? "") ?? 0
            } else {
                output[field.name] = textValues[field.name] ?? ""
            }
        }
        return output
    }
}
