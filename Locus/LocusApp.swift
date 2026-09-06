import AppKit
import SwiftUI
import UserNotifications

func locusShouldStartAutomaticUpdater(environment: [String: String]) -> Bool {
    environment["XCTestConfigurationFilePath"] == nil
        && environment["LOCUS_UI_TESTING"] != "1"
}

private let locusEnvironment = ProcessInfo.processInfo.environment
private let locusIsUITesting = locusEnvironment["LOCUS_UI_TESTING"] == "1"
private let locusIsUnitTesting =
    locusEnvironment["XCTestConfigurationFilePath"] != nil
        && !locusIsUITesting
private let locusStartsAutomaticUpdater = locusShouldStartAutomaticUpdater(environment: locusEnvironment)

enum LocusWindowSizing {
    static let defaultSize = NSSize(width: 1_250, height: 760)
    static let normalizationKey = "Locus.didNormalizeMainWindow.1250x760"

    static func centeredFrame(in visibleFrame: NSRect) -> NSRect {
        centeredFrame(size: defaultSize, in: visibleFrame)
    }

    static func uiTestFrame(in visibleFrame: NSRect, environment: [String: String]) -> NSRect {
        let width = environment["LOCUS_UI_TESTING_WINDOW_WIDTH"].flatMap(Double.init)
            ?? defaultSize.width
        let height = environment["LOCUS_UI_TESTING_WINDOW_HEIGHT"].flatMap(Double.init)
            ?? defaultSize.height
        return centeredFrame(size: NSSize(width: width, height: height), in: visibleFrame)
    }

    private static func centeredFrame(size: NSSize, in visibleFrame: NSRect) -> NSRect {
        let size = NSSize(
            width: min(size.width, visibleFrame.width),
            height: min(size.height, visibleFrame.height)
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
    @StateObject private var updates = AppUpdateController(
        startImmediately: locusStartsAutomaticUpdater
    )
    @StateObject private var lifecycle = ApplicationLifecycleCoordinator()
    @StateObject private var mainWindowPresenter = MainWindowPresenter()

    var body: some Scene {
        Window("Locus", id: "main") {
            sceneContent
                .appFeatureEnvironment(from: model)
                .environmentObject(updates)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.windowPresenter = mainWindowPresenter
                    appDelegate.lifecycle = lifecycle
                    lifecycle.connect(model: model)
                    updates.setRelaunchHandler(lifecycle)
                }
                .preferredColorScheme(model.effectiveAppearance.colorScheme)
                .accentColor(model.accentActionColor)
                .tint(model.accentActionColor)
                .environment(\.locusAccent, model.effectiveAccent)
                .frame(
                    // The full three-column layout fits comfortably at the
                    // default size. Narrow windows progressively overlay the
                    // sidebar and inspector instead of clipping the workspace.
                    minWidth: locusIsUITesting ? 680 : 720,
                    minHeight: 620
                )
                .background {
                    ZStack {
                        MainWindowMarker()
                        MainWindowPresenterInstaller(presenter: mainWindowPresenter)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(
            width: LocusWindowSizing.defaultSize.width,
            height: LocusWindowSizing.defaultSize.height
        )
        .commands {
            CommandGroup(replacing: .help) {
                Button("Getting Started…") { model.onboarding.present() }
                    .accessibilityIdentifier("menu.gettingStarted")
            }
            CommandGroup(after: .appInfo) {
                if updates.isAvailable {
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                        .accessibilityIdentifier("menu.checkForUpdates")
                }
            }

            CommandGroup(replacing: .newItem) {
                // The active destination decides whether this is a workspace
                // chat or an agent chat; the user-facing action stays the same.
                Button("New Chat") {
                    model.newChatForSidebarDestination()
                }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Chat Folder…") {
                    model.globalNewFolderName = ""
                    model.globalNewFolderPresented = true
                }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("Locus") {
                Button("Command Palette") { model.commandPalettePresented = true }
                    .keyboardShortcut("k", modifiers: .command)
                FindInConversationCommand(
                    transcriptPresentation: model.transcriptPresentation,
                    open: model.openTranscriptSearch
                )
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
                Button("Archived Sessions") {
                    model.setShowArchived(!model.showArchivedSessions)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .accessibilityIdentifier("menu.showArchived")
                Button("Browse Hugging Face Models") { model.modelLibraryPresented = true }
                    .accessibilityIdentifier("menu.modelLibrary")
                Button("Workspace Library…") { model.openLibrary() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .accessibilityIdentifier("menu.workspaceLibrary")
                Button("Review Changes") { model.selectInspectorTab(.changes) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Session Checkpoints…") { model.checkpointPresented = true }
                    .keyboardShortcut("s", modifiers: .command)
                // ⌘9 opens the Notes panel for the current chat; this is the
                // shelf behind it.
                Button("Notebook…") { model.notebookPresented = true }
                    .keyboardShortcut("9", modifiers: [.command, .shift])
                Menu("Export Session") {
                    ForEach(ChatExportFormat.allCases) { format in
                        Button("\(format.title)…") { model.exportCurrentSession(format: format) }
                    }
                }
                .accessibilityIdentifier("menu.exportSession")
                Divider()
                Button("Open Terminal") { model.openTerminal() }
                    .keyboardShortcut("`", modifiers: .control)
                    .disabled(model.justChatEnabled)
                    .accessibilityIdentifier("menu.terminal")
                // Declared once, here — a second registration in a view would
                // silently shadow these (see the ⌘⇧K note in WorkspaceView).
                ForEach(InspectorTab.allCases.filter { $0.shortcutKey != nil }) { tab in
                    Button(tab.title) {
                        if tab == .checkpoints {
                            model.checkpointPresented = true
                        } else {
                            model.selectInspectorTab(tab)
                        }
                    }
                        .keyboardShortcut(
                            KeyEquivalent(tab.shortcutKey ?? "1"),
                            modifiers: .command
                        )
                        .disabled(model.justChatEnabled && tab != .checkpoints)
                }
                Button(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    model.toggleSidebar()
                }
                .keyboardShortcut("0", modifiers: .command)
                Button(model.inspectorCollapsed ? "Show Inspector" : "Hide Inspector") {
                    withAnimation(LocusMotion.spatial) { model.toggleInspector() }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.justChatEnabled)
                Button(model.inspectorZoomed ? "Restore Panel" : "Expand Panel") {
                    withAnimation(LocusMotion.spatial) { model.toggleInspectorZoom() }
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
                Button("Grill Mode") { model.selectedMode = .grill }
                    .keyboardShortcut("g", modifiers: .option)
            }
        }

        Settings {
            SettingsView(presentationContext: .settingsWindow)
                .appFeatureEnvironment(from: model)
                .environmentObject(updates)
                .preferredColorScheme(model.effectiveAppearance.colorScheme)
                .accentColor(model.accentActionColor)
                .tint(model.accentActionColor)
                .environment(\.locusAccent, model.effectiveAccent)
        }

        MenuBarExtra {
            LocusMenuBarView(presenter: mainWindowPresenter)
                .appFeatureEnvironment(from: model)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel("Locus")
        }
        .menuBarExtraStyle(.menu)
    }

    /// Accessibility fixtures render one surface as the window root. This
    /// avoids XCTest's macOS sheet-snapshot race and audits the same production
    /// views without a dimmed, inaccessible workspace behind them.
    @ViewBuilder
    private var sceneContent: some View {
        switch locusEnvironment["LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"] {
        case "onboarding":
            OnboardingView()
        case "library":
            LibraryWorkspaceView()
                .onAppear { model.library.activate(workspace: model.workspacePath) }
        case "settings":
            SettingsView(presentationContext: .sheet)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LocusTheme.surfaceCanvas)
        case "wallet":
            SettingsView(presentationContext: .sheet)
                .onAppear { model.settingsPage = .wallet }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LocusTheme.surfaceCanvas)
        case "browser":
            BrowserPanel(
                browser: model.browser,
                sessionID: model.currentSessionID,
                homeURL: model.normalizedPreviewURL,
                isExpanded: locusEnvironment["LOCUS_UI_TESTING_BROWSER_EXPANDED"] == "1",
                onToggleExpand: {}
            )
            .onAppear {
                if model.browser.snapshots(for: model.currentSessionID).isEmpty {
                    model.browser.userNewTab(sessionID: model.currentSessionID)
                }
            }
            .frame(
                maxWidth: locusEnvironment["LOCUS_UI_TESTING_BROWSER_COMPACT"] == "1"
                    ? 440 : .infinity
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LocusTheme.surfaceCanvas)
        case "notebook":
            NotebookSheet(notebook: model.notebook)
                .onAppear {
                    // The UI-testing notes root is a fresh temporary directory,
                    // so the fixture writes the documents it means to audit
                    // instead of depending on what the host machine happens to
                    // have. Written through the real store, saved immediately
                    // because the list reads from disk.
                    for (scope, text) in [
                        (NotesScope.workspace, "Release checklist\n- [ ] tag the build"),
                        (NotesScope.chat, "Follow up on the notary job"),
                        (NotesScope.global, "Shared by every chat and workspace"),
                    ] {
                        let store = NotesStore.shared(
                            workspacePath: model.workspacePath,
                            sessionID: model.currentSessionID,
                            scope: scope
                        )
                        store.update(text)
                        store.flushForTesting()
                    }
                    model.notebook.refresh(
                        workspaces: model.workspaceProfiles,
                        sessions: model.sessions
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LocusTheme.surfaceCanvas)
        case "model-library":
            ModelLibraryView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LocusTheme.surfaceCanvas)
        case "agent-editor":
            AgentProfileEditor(
                profile: AgentProfile(
                    name: "Review Agent",
                    model: "qwen3:8b",
                    role: .reviewer,
                    instructions: AgentRole.reviewer.defaultInstructions
                ),
                onSave: { _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LocusTheme.surfaceCanvas)
        case "permission":
            Group {
                if let request = model.activePermissionRequest {
                    PermissionPromptView(request: request)
                        .frame(maxWidth: 740)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .background(LocusTheme.surfaceCanvas)
        case "plan-approval":
            PlanApprovalPromptView()
                .frame(maxWidth: 740)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .background(LocusTheme.surfaceCanvas)
        case "question-prompt":
            Group {
                if let question = model.pendingBlockingQuestion {
                    BlockingQuestionPromptView(request: question)
                        .frame(maxWidth: 740)
                } else if let question = model.pendingUserQuestion {
                    QuestionPromptView(question: question)
                        .frame(maxWidth: 740)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .background(LocusTheme.surfaceCanvas)
        default:
            RootView()
        }
    }
}

/// Observes only transcript availability for the menu item whose enabled
/// state depends on it. The app scene remains free of transcript publications.
private struct FindInConversationCommand: View {
    @ObservedObject var transcriptPresentation: TranscriptPresentationModel
    let open: () -> Void

    var body: some View {
        Button("Find in Conversation", action: open)
            .keyboardShortcut("f", modifiers: .command)
            .disabled(transcriptPresentation.snapshot.isEmpty)
    }
}

/// The one route for presenting Locus's unique main scene. Keeping the
/// environment action alive outside the Window scene lets Dock/Launch Services,
/// notifications, and the menu-bar item recreate that scene after Command-W.
@MainActor
final class MainWindowPresenter: ObservableObject {
    private var openWindow: OpenWindowAction?

    func install(_ action: OpenWindowAction) {
        openWindow = action
    }

    @discardableResult
    func present(in providedApplication: NSApplication? = nil) -> Bool {
        let application = providedApplication ?? NSApplication.shared
        if let window = LocusApplicationDelegate.mainWindow(in: application.windows) {
            reveal(window, in: application)
            return false
        }
        guard let openWindow else { return false }
        openWindow(id: "main")
        application.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak application] in
            guard let application,
                  let window = LocusApplicationDelegate.mainWindow(in: application.windows)
            else { return }
            self.reveal(window, in: application)
        }
        return true
    }

    private func reveal(_ window: NSWindow, in application: NSApplication) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class LocusApplicationDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("locus.main")
    weak var model: AppModel?
    weak var windowPresenter: MainWindowPresenter?
    weak var lifecycle: ApplicationLifecycleCoordinator?

    static func mainWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier == mainWindowIdentifier }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        TranscriptSelectionMenu.shared.start { [weak self] selection in
            self?.model?.searchWebForSelection(selection)
        }
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
            self?.windowPresenter?.present()
            completionHandler()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard let windowPresenter else {
            // During the first launch SwiftUI still owns initial scene creation.
            return true
        }
        windowPresenter.present(in: sender)
        // The presenter either revealed the existing window or explicitly
        // requested the unique SwiftUI scene, so AppKit must not do it again.
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Session overview writes are debounced; quitting must not drop the
        // last one.
        model?.sessionOverview.persistNow()
        return lifecycle?.applicationShouldTerminate(sender) ?? .terminateNow
    }

}

private struct LocusMenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var activityCenter: ActivityCenterModel
    @EnvironmentObject private var schedule: ScheduleModel
    @Environment(\.openWindow) private var openWindow
    let presenter: MainWindowPresenter

    var body: some View {
        Button("Open Locus") { revealMainWindow() }
            .keyboardShortcut("o")
        Button("Configure Agent…") {
            revealMainWindow()
            model.presentConfigureAgent(draftText: "")
        }
        Divider()
        if runningCount > 0 {
            Text("\(runningCount) \(runningCount == 1 ? "task" : "tasks") running")
        } else {
            Text("No work running")
        }
        if let next = schedule.nextScheduledTask, let date = next.nextRunDate {
            Text("Next: \(next.name) · \(date.formatted(date: .omitted, time: .shortened))")
        } else {
            Text("No upcoming schedules")
        }
        Divider()
        Button("Quit Locus") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
        EmptyView()
            .onAppear { presenter.install(openWindow) }
    }

    private var runningCount: Int {
        activityCenter.visibleActivityRuns.filter {
            ["queued", "dispatching", "running", "reviewing", "waiting_permission",
             "waiting_computer", "waiting_dispatch_approval", "paused"].contains($0.state)
        }.count
    }

    private func revealMainWindow() {
        presenter.install(openWindow)
        presenter.present()
    }
}

/// Captures `openWindow` while the main scene is alive, before the user has
/// ever opened the menu-bar menu. That makes a first Dock reopen after
/// Command-W reliable as well as subsequent menu-bar opens.
private struct MainWindowPresenterInstaller: View {
    @Environment(\.openWindow) private var openWindow
    let presenter: MainWindowPresenter

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { presenter.install(openWindow) }
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
        // SwiftUI's hidden-title-bar style still leaves a 28-point content
        // inset on macOS 15 unless AppKit is told that the content owns that
        // band. Make the contract explicit so the workspace header begins at
        // the window edge and compact layouts retain the full usable height.
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }

        // UI tests and documentation captures use the same frame customers
        // see, clamped only when the available display is smaller.
        if locusIsUITesting {
            guard !preparedUITestWindow else { return }
            preparedUITestWindow = true
            window.setFrame(
                LocusWindowSizing.uiTestFrame(in: visibleFrame, environment: locusEnvironment),
                display: true
            )
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
    @EnvironmentObject private var library: WorkspaceLibraryModel
    @EnvironmentObject private var onboarding: OnboardingModel
    @EnvironmentObject private var updates: AppUpdateController
    @EnvironmentObject private var toastCenter: ToastCenter
    @EnvironmentObject private var landingFlow: LandingFlowModel
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    @EnvironmentObject private var schedule: ScheduleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var compactSidebarPresented = false

    private let inspectorRailWidth: CGFloat = 44
    private let minimumWorkspaceWidth: CGFloat = 360

    var body: some View {
        GeometryReader { proxy in
            let inspectorOpen = !model.inspectorCollapsed && !model.justChatEnabled
            let railWidth = model.justChatEnabled ? 0 : inspectorRailWidth
            let minimumSidebarWidth = CGFloat(AppSettings.minimumSidebarWidth)
            let minimumInspectorWidth = CGFloat(AppSettings.minimumInspectorWidth)
            let inspectorReservation = inspectorOpen ? minimumInspectorWidth : 0
            let minimumThreeColumnWidth = minimumSidebarWidth
                + minimumWorkspaceWidth
                + inspectorReservation
                + railWidth
            let docksSidebar = !model.sidebarCollapsed
                && proxy.size.width >= minimumThreeColumnWidth
            // Keep the saved preference intact when the window is tight. The
            // rendered width alone contracts so dragging never crosses the
            // docking threshold and makes the sidebar vanish under the cursor.
            let availableSidebarWidth = max(
                minimumSidebarWidth,
                proxy.size.width - minimumWorkspaceWidth - inspectorReservation - railWidth
            )
            let sidebarWidth = CGFloat(AppSettings.renderedSidebarWidth(
                Double(model.sidebarWidth),
                availableWidth: Double(availableSidebarWidth)
            ))
            let overlaySidebarWidth = CGFloat(AppSettings.renderedSidebarWidth(
                Double(model.sidebarWidth),
                availableWidth: Double(proxy.size.width - railWidth)
            ))
            let widthAfterChrome = proxy.size.width
                - (docksSidebar ? sidebarWidth : 0)
                - railWidth
            let docksInspector = inspectorOpen
                && widthAfterChrome
                    >= minimumWorkspaceWidth + minimumInspectorWidth
            let availableInspectorWidth = max(
                minimumInspectorWidth,
                widthAfterChrome - minimumWorkspaceWidth
            )
            let dockedInspectorWidth = min(model.inspectorWidth, availableInspectorWidth)
            let zoomedWorkspaceWidth = min(
                model.zoomedChatWidth,
                max(minimumWorkspaceWidth, widthAfterChrome - minimumInspectorWidth)
            )

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if docksSidebar {
                        SessionSidebarView()
                            .frame(width: sidebarWidth)
                            .transition(LocusMotion.transition(
                                edge: .leading,
                                reduceMotion: reduceMotion
                            ))
                    }

                    SplitChatWorkspaceView(
                        sidebarVisible: docksSidebar,
                        showSidebar: {
                            if proxy.size.width < minimumThreeColumnWidth {
                                model.sidebarCollapsed = false
                                compactSidebarPresented = true
                            } else {
                                model.sidebarCollapsed = false
                            }
                        }
                    )
                    .frame(
                        minWidth: 0,
                        maxWidth: model.inspectorZoomed && docksInspector
                            ? zoomedWorkspaceWidth
                            : .infinity
                    )
                    .frame(
                        width: model.inspectorZoomed && docksInspector
                            ? zoomedWorkspaceWidth
                            : nil
                    )
                    .layoutPriority(1)
                    .ignoresSafeArea(.container, edges: .top)

                    if docksInspector {
                        InspectorView()
                            .frame(
                                minWidth: model.inspectorZoomed
                                    ? minimumInspectorWidth
                                    : dockedInspectorWidth,
                                maxWidth: model.inspectorZoomed
                                    ? .infinity
                                    : dockedInspectorWidth
                            )
                            .ignoresSafeArea(.container, edges: .top)
                            .transition(LocusMotion.transition(
                                edge: .trailing,
                                reduceMotion: reduceMotion
                            ))
                    }

                    if !model.justChatEnabled {
                        InspectorRail()
                            .environmentObject(model)
                            .ignoresSafeArea(.container, edges: .top)
                    }
                }

                if inspectorOpen && !docksInspector {
                    InspectorView()
                        .frame(width: min(model.inspectorWidth, proxy.size.width - railWidth))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, railWidth)
                        .shadow(color: .black.opacity(0.16), radius: 18, x: -8, y: 0)
                        .transition(LocusMotion.transition(
                            edge: .trailing,
                            reduceMotion: reduceMotion
                        ))
                        .zIndex(2)
                }

                if compactSidebarPresented && !docksSidebar && !model.sidebarCollapsed {
                    SessionSidebarView()
                        .frame(width: overlaySidebarWidth)
                        .shadow(color: .black.opacity(0.18), radius: 18, x: 8, y: 0)
                        .transition(LocusMotion.transition(
                            edge: .leading,
                            reduceMotion: reduceMotion
                        ))
                        .zIndex(3)
                }
            }
            .onChange(of: docksSidebar) { _, docked in
                if docked { compactSidebarPresented = false }
            }
            .onChange(of: model.sidebarCollapsed) { _, collapsed in
                if collapsed { compactSidebarPresented = false }
            }
        }
        // Keyed on the sidebar and the zoom flag only: including the inspector
        // would put the width change in scope too, and the panel would lag
        // behind the cursor during a resize drag. Zoom is safe — it flips on
        // toggle, never during a drag. Collapse animates at its call sites.
        .animation(LocusMotion.spatial, value: model.sidebarCollapsed)
        .animation(LocusMotion.spatial, value: model.inspectorZoomed)
        .background(LocusTheme.paper)
        .overlay(alignment: .bottomTrailing) {
            if let toast = toastCenter.toast {
                HStack(spacing: 12) {
                    Label(toast.message, systemImage: toast.systemImage)
                        .font(.locus(size: 11, weight: .semibold))
                    if let actionTitle = toast.actionTitle {
                        Button(actionTitle) { model.performToastAction() }
                            .buttonStyle(.locus())
                            .font(.locus(size: 11, weight: .bold))
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
                .transition(LocusMotion.transition(edge: .bottom, reduceMotion: reduceMotion))
            }
        }
        .animation(LocusMotion.content, value: toastCenter.toast?.id)
        // Reduced Motion is an app-wide contract. Individual components still
        // choose a gentler transition where useful, while this guard prevents
        // an overlooked state mutation from introducing spatial movement.
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Locus workspace")
        .sheet(isPresented: $library.isPresented) {
            if model.isUITesting, locusEnvironment["LOCUS_UI_TESTING_LIBRARY_CONTENT"] == "1" {
                LibraryUITestFixtureView().appFeatureEnvironment(from: model)
            } else {
                LibraryWorkspaceView().appFeatureEnvironment(from: model)
            }
        }
        .sheet(isPresented: $onboarding.isPresented, onDismiss: {
            onboarding.dismiss()
            // Wait for the setup sheet to close before presenting its sibling.
            if let run = onboarding.takeOutputRequest() {
                model.openOutputsLibrary(workspace: run.workspace, sessionID: run.sessionID, runID: run.runID)
            }
        }) {
            OnboardingView().appFeatureEnvironment(from: model)
        }
        .sheet(isPresented: $model.commandPalettePresented) {
            CommandPaletteView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.checkpointPresented) {
            CheckpointSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.notebookPresented) {
            NotebookSheet(notebook: model.notebook)
                .onAppear {
                    model.notebook.refresh(
                        workspaces: model.workspaceProfiles,
                        sessions: model.sessions
                    )
                }
        }
        .sheet(item: $model.fileViewerRequest) { request in
            WorkspaceFileViewerSheet(request: request)
                .environmentObject(model)
        }
        .sheet(isPresented: Binding(
            get: { landingFlow.reviewAndLandPresented },
            set: { landingFlow.reviewAndLandPresented = $0 }
        )) {
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
                .environmentObject(updates)
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
        .sheet(isPresented: $model.configureAgentPresented, onDismiss: {
            model.configureAgentDraftSuggestion = ""
            model.configureAgentPendingScheduleDraft = nil
        }) {
            ConfigureAgentView(
                automation: model.eventAutomations,
                schedule: schedule
            )
            .environmentObject(model)
        }
        .sheet(item: Binding(
            get: { extensionsModel.mcpInputRequest },
            set: { value in
                if value == nil, extensionsModel.mcpInputRequest != nil {
                    extensionsModel.answerMCPInput(action: "cancel")
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
        .alert("New Chat Folder", isPresented: $model.globalNewFolderPresented) {
            TextField("Folder name", text: $model.globalNewFolderName)
                .accessibilityIdentifier("chatFolder.global.name")
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                model.createChatFolder(
                    in: model.activeWorkspaceID,
                    name: model.globalNewFolderName,
                    parentID: nil
                )
            }
            .disabled(model.globalNewFolderName
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("chatFolder.global.create")
        } message: {
            Text("Folders organize chats without changing where they run.")
        }
    }
}

private struct RememberConfirmationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var knowledge: WorkspaceKnowledgeModel
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
                .font(.locus(size: 16, weight: .bold))
            Text("Review or edit the memory before saving. Saving is explicit approval, so it can be recalled in future chats within its scope.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Title", text: $title)
                .accessibilityIdentifier("remember.title")
            TextEditor(text: $content)
                .font(.locus(size: 10))
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
                    knowledge.rememberWorkspaceFact(
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
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    let request: MCPInputRequest
    @State private var textValues: [String: String] = [:]
    @State private var boolValues: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                request.mode == "url" ? "Complete in your browser" : "Extension input requested",
                systemImage: request.mode == "url" ? "safari" : "list.bullet.rectangle"
            )
            .font(.locus(size: 14, weight: .bold))
            Text(request.message)
                .font(.locus(size: 10))
                .foregroundStyle(LocusTheme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if request.mode == "url" {
                Text("Sensitive information stays on the extension's verified HTTPS page. Never paste credentials, payment details, or API keys into Locus.")
                    .font(.locus(size: 9))
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
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
            HStack {
                Button("Decline") { extensionsModel.answerMCPInput(action: "decline") }
                Button("Cancel") { extensionsModel.answerMCPInput(action: "cancel") }
                Spacer()
                Button(request.mode == "url" ? "I've Completed It" : "Submit") {
                    extensionsModel.answerMCPInput(action: "accept", content: formContent)
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
