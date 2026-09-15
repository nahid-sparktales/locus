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

    static func minimumContentSize(isUITesting: Bool) -> NSSize {
        // Fixture dimensions describe the whole NSWindow frame, not its
        // content. A 620-point content minimum forces a 652-point frame on
        // macOS 26 after native titlebar chrome is added. Let the fixture's
        // explicitly applied frame determine its usable content height;
        // compact layout assertions must see the actual requested geometry.
        NSSize(width: isUITesting ? 680 : 720, height: isUITesting ? 0 : 620)
    }

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

#if !LOCUS_WALLET_FUZZ_HOST
@main
#endif
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
        Window(AppEdition.current.displayName, id: "main") {
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
                #if LOCUS_WALLET
                .onOpenURL { url in
                    Task { _ = await model.walletGateway.beginWalletConnectPairing(deepLink: url) }
                }
                #endif
                .preferredColorScheme(model.effectiveAppearance.colorScheme)
                .accentColor(model.accentActionColor)
                .foregroundStyle(LocusTheme.textPrimary)
                .tint(model.accentActionColor)
                .environment(\.locusAccent, model.effectiveAccent)
                .frame(
                    // The full three-column layout fits comfortably at the
                    // default size. Narrow windows progressively overlay the
                    // sidebar and inspector instead of clipping the workspace.
                    minWidth: LocusWindowSizing.minimumContentSize(isUITesting: locusIsUITesting).width,
                    minHeight: LocusWindowSizing.minimumContentSize(isUITesting: locusIsUITesting).height
                )
                .background {
                    ZStack {
                        MainWindowMarker(
                            coordinator: model.workspaceLayout.liveResizeCoordinator
                        )
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
            AgentWorldCommands(model: model.agentWorld)
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
                // The active destination chooses New Chat or New Agent.
                NotebookNewNoteCommand(newItemTitle: model.sidebarDestination == .agents ? "New Agent" : "New Chat") {
                    model.newChatForSidebarDestination()
                }
                Button("New Chat Folder…") {
                    model.globalNewFolderName = ""
                    model.globalNewFolderPresented = true
                }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("Locus") {
                Button("Task Capsules…") { model.taskCapsules.open() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                    .accessibilityIdentifier("menu.taskCapsules")
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
                    model.toggleInspectorZoom()
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
                .foregroundStyle(LocusTheme.textPrimary)
                .tint(model.accentActionColor)
                .environment(\.locusAccent, model.effectiveAccent)
        }

        MenuBarExtra {
            LocusMenuBarView(presenter: mainWindowPresenter)
                .appFeatureEnvironment(from: model)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel(AppEdition.current.displayName)
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
        case "identity-vault" where model.isUITesting:
            IdentityVaultUITestFixtureView()
        case "settings":
            GeometryReader { proxy in
                SettingsView(presentationContext: .sheet, availableSize: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LocusTheme.surfaceCanvas)
            }
        #if LOCUS_WALLET
        case "wallet":
            GeometryReader { proxy in
                SettingsView(presentationContext: .sheet, availableSize: proxy.size)
                    .onAppear { model.settingsPage = .wallet }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LocusTheme.surfaceCanvas)
            }
        #endif
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
            GeometryReader { proxy in
                NotebookSheet(notebook: model.notebook, availableSize: proxy.size)
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
            }
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
        Button("Open \(AppEdition.current.displayName)") { revealMainWindow() }
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
    let coordinator: LiveResizeCoordinator

    func makeNSView(context: Context) -> MainWindowMarkerView {
        MainWindowMarkerView(coordinator: coordinator)
    }

    func updateNSView(_ nsView: MainWindowMarkerView, context: Context) {
        nsView.markWindow()
    }
}

private final class MainWindowMarkerView: NSView {
    private var preparedUITestWindow = false
    private var normalizedLaunchWindow = false
    private let coordinator: LiveResizeCoordinator
    private weak var observedWindow: NSWindow?
    private var resizeObservers: [NSObjectProtocol] = []

    init(coordinator: LiveResizeCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        resizeObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeLiveResize(of: window)
        markWindow()
    }

    private func observeLiveResize(of window: NSWindow?) {
        guard observedWindow !== window else { return }
        resizeObservers.forEach(NotificationCenter.default.removeObserver)
        resizeObservers.removeAll(keepingCapacity: true)
        observedWindow = window
        guard let window else { return }
        let center = NotificationCenter.default
        resizeObservers.append(center.addObserver(
            forName: NSWindow.willStartLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.coordinator.beginLiveResize()
                self?.coordinator.update(width: window?.frame.width ?? 0)
            }
        })
        resizeObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard window?.inLiveResize == true else { return }
                self?.coordinator.update(width: window?.frame.width ?? 0)
            }
        })
        resizeObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.coordinator.endLiveResize(finalWidth: window?.frame.width ?? 0)
            }
        })
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

private struct RootViewUpdateProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        locusPerformanceSignposter.emitEvent("Root View Update")
    }
}

/// A compact sidebar overlaps native transcript views. A SwiftUI z-index
/// orders their drawing, but does not give its virtual accessibility children
/// a separate native hit-test boundary on every supported macOS release.
/// Keep this non-modal panel in a native hosting subtree: its visible bounds
/// then own both pointer and accessibility hits, without hiding the workspace.
private struct CompactSidebarHost: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: AppUpdateController

    func makeNSView(context: Context) -> CompactSidebarHostingView {
        let view = CompactSidebarHostingView(rootView: content(environment: context.environment))
        view.sizingOptions = []
        view.safeAreaRegions = []
        view.clipsToBounds = true
        return view
    }

    func updateNSView(_ view: CompactSidebarHostingView, context: Context) {
        view.rootView = content(environment: context.environment)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: CompactSidebarHostingView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ view: CompactSidebarHostingView, coordinator: ()) {
        view.restorePreviousFocusIfOwned()
    }

    private func content(environment: EnvironmentValues) -> AnyView {
        // A new native hosting root owns its accessibility, focus and scroll
        // bridges. Copy only the public presentation inputs and app models;
        // replacing its whole environment also carries the outer host's
        // private bridge state into this independent view hierarchy.
        AnyView(
            SessionSidebarView()
                .appFeatureEnvironment(from: model)
                .environmentObject(updates)
                .environment(\.colorScheme, environment.colorScheme)
                .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
                .environment(\.layoutDirection, environment.layoutDirection)
                .environment(\.locale, environment.locale)
                .environment(\.calendar, environment.calendar)
                .environment(\.timeZone, environment.timeZone)
                .environment(\.isEnabled, environment.isEnabled)
                .environment(\.locusAccent, environment.locusAccent)
                .environment(\.locusWorkspaceGeometry, environment.locusWorkspaceGeometry)
                .environment(\.locusIsLiveResizing, environment.locusIsLiveResizing)
                .tint(model.accentActionColor)
                .accentColor(model.accentActionColor)
                .foregroundStyle(LocusTheme.textPrimary)
        )
    }
}

final class CompactSidebarHostingView: NSHostingView<AnyView> {
    private weak var previousResponder: NSResponder?
    private weak var previousWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let responder = window.firstResponder, !owns(responder) else { return }
        // A field editor is shared by the window. Remember its owning control
        // before editing in the sidebar can replace the editor's delegate.
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            previousResponder = editor.delegate as? NSResponder
        } else {
            previousResponder = responder
        }
        previousWindow = window
    }

    func restorePreviousFocusIfOwned() {
        guard let window, window === previousWindow,
              let responder = window.firstResponder, owns(responder),
              let previous = previousResponder else { return }
        if let view = previous as? NSView, view.window !== window { return }
        window.makeFirstResponder(previous)
        previousResponder = nil
        previousWindow = nil
    }

    private func owns(_ responder: NSResponder) -> Bool {
        if let view = responder as? NSView,
           view === self || view.isDescendant(of: self) { return true }
        // AppKit's shared field editor belongs to the window, not the field's
        // subtree. Its delegate identifies the actual editing control.
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSView {
            return field === self || field.isDescendant(of: self)
        }
        return false
    }
}

/// Observe the transcript policy in this small modifier, keeping content
/// commits out of RootView's layout calculations. Large chats take one exact
/// layout step; short chats retain the panel motion across every entry point.
private struct WorkspacePanelMotion: ViewModifier {
    @EnvironmentObject private var transcriptPresentation: TranscriptPresentationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sidebarCollapsed: Bool
    let inspectorCollapsed: Bool
    let inspectorZoomed: Bool
    let inspectorTab: InspectorTab

    func body(content: Content) -> some View {
        let immediate = reduceMotion || transcriptPresentation.snapshot.prefersImmediatePanelLayout
        content
            .animation(immediate ? nil : LocusMotion.spatial, value: sidebarCollapsed)
            .animation(immediate ? nil : LocusMotion.spatial, value: inspectorCollapsed)
            .animation(immediate ? nil : LocusMotion.spatial, value: inspectorZoomed)
            .animation(immediate ? nil : LocusMotion.spatial, value: inspectorTab)
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var library: WorkspaceLibraryModel
    @EnvironmentObject private var onboarding: OnboardingModel

    @EnvironmentObject private var workspaceLayout: WorkspaceLayoutModel
    @EnvironmentObject private var updates: AppUpdateController
    @EnvironmentObject private var toastCenter: ToastCenter
    @EnvironmentObject private var landingFlow: LandingFlowModel
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    @EnvironmentObject private var schedule: ScheduleModel
    @EnvironmentObject private var agentInspector: AgentInspectorModel
    @EnvironmentObject private var activityCenter: ActivityCenterModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var compactSidebarPresented = false

    private let inspectorRailWidth: CGFloat = InspectorRail.width
    private let minimumWorkspaceWidth: CGFloat = 360

    var body: some View {
        GeometryReader { proxy in
            let duplicateAgentOverview = model.savedAgentOverviewProfile != nil
                && model.inspectorTab == .agent && agentInspector.context == .fleet
            let inspectorOpen = !model.inspectorCollapsed && !model.justChatEnabled && !duplicateAgentOverview
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
                Double(workspaceLayout.sidebarWidth),
                availableWidth: Double(availableSidebarWidth)
            ))
            let overlaySidebarWidth = CGFloat(AppSettings.renderedSidebarWidth(
                Double(workspaceLayout.sidebarWidth),
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
            let dockedInspectorWidth = min(workspaceLayout.inspectorWidth, availableInspectorWidth)
            let zoomedWorkspaceWidth = min(
                workspaceLayout.zoomedChatWidth,
                max(minimumWorkspaceWidth, widthAfterChrome - minimumInspectorWidth)
            )
            let workspaceWidth = model.inspectorZoomed && docksInspector
                ? zoomedWorkspaceWidth
                : max(widthAfterChrome - (docksInspector ? dockedInspectorWidth : 0), 0)
            let geometrySnapshot = WorkspaceGeometrySnapshot(
                windowSize: proxy.size,
                sidebarWidth: docksSidebar ? sidebarWidth : 0,
                workspaceWidth: workspaceWidth,
                workspaceHeight: WorkspaceLayoutMetrics.contentHeight(
                    forWindowHeight: proxy.size.height
                ),
                inspectorWidth: docksInspector ? dockedInspectorWidth : 0,
                composerWidth: min(max(workspaceWidth - 48, 0), 740),
                docksSidebar: docksSidebar,
                docksInspector: docksInspector,
                requestOverview: RequestOverviewLayout.resolve(
                    workspaceWidth: workspaceWidth,
                    visible: model.requestOverviewVisible,
                    expanded: model.overviewPresented,
                    splitView: model.splitViewActive
                )
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
                    // The root has already resolved every column's width.
                    // Re-negotiating flexible widths with a long native-text
                    // transcript can keep the HStack's layout graph cycling
                    // when an expanded inspector is restored.
                    .frame(width: workspaceWidth)
                    .layoutPriority(1)
                    .ignoresSafeArea(.container, edges: .top)

                    if docksInspector {
                        InspectorView(resizeWidth: model.inspectorZoomed
                            ? zoomedWorkspaceWidth : dockedInspectorWidth)
                            .frame(width: widthAfterChrome - workspaceWidth)
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

                ZStack(alignment: .topTrailing) {
                    if model.requestOverviewVisible {
                        // The anchor stays beside the rail. When the layout
                        // docks, the chat column gives up this card's width.
                        RequestOverviewActivity(session: model.sessionOverview)
                            .frame(width: geometrySnapshot.requestOverview.panelWidth, alignment: .trailing)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(.trailing, railWidth + 8)
                            .padding(.top, max(0, WorkspaceLayoutMetrics.toolbarHeight - proxy.safeAreaInsets.top) + 8)
                            .transition(LocusMotion.transition(edge: .trailing, reduceMotion: reduceMotion))
                    }
                }
                // Scoped to the card: a send presents it in the same update
                // that appends the user's row and clears the composer, and
                // those must not spring. The column follows in WorkspaceView.
                .animation(reduceMotion ? nil : LocusMotion.spatial, value: model.requestOverviewVisible)
                .animation(reduceMotion ? nil : LocusMotion.spatial, value: model.overviewPresented)
                .zIndex(1)

                if inspectorOpen && !docksInspector {
                    InspectorView(resizeWidth: min(workspaceLayout.inspectorWidth, proxy.size.width - railWidth))
                        .frame(width: min(workspaceLayout.inspectorWidth, proxy.size.width - railWidth))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, railWidth)
                        .shadow(
                            color: workspaceLayout.isLiveResizing ? .clear : .black.opacity(0.16),
                            radius: workspaceLayout.isLiveResizing ? 0 : 18,
                            x: -8,
                            y: 0
                        )
                        .transition(LocusMotion.transition(
                            edge: .trailing,
                            reduceMotion: reduceMotion
                        ))
                        .zIndex(2)
                }

                if compactSidebarPresented && !docksSidebar && !model.sidebarCollapsed {
                    CompactSidebarHost()
                        .frame(width: overlaySidebarWidth, height: proxy.size.height)
                        .shadow(
                            color: workspaceLayout.isLiveResizing ? .clear : .black.opacity(0.18),
                            radius: workspaceLayout.isLiveResizing ? 0 : 18,
                            x: 8,
                            y: 0
                        )
                        .transition(LocusMotion.transition(
                            edge: .leading,
                            reduceMotion: reduceMotion
                        ))
                        .zIndex(3)
                }
            }
            .environment(\.locusWorkspaceGeometry, geometrySnapshot)
            .onAppear {
                workspaceLayout.updateGeometry(geometrySnapshot)
            }
            .onChange(of: geometrySnapshot) { _, snapshot in
                // Retain the latest exact geometry for commands and
                // diagnostics without publishing a second width-driven pass.
                workspaceLayout.updateGeometry(snapshot)
            }
            .onChange(of: docksSidebar) { _, docked in
                if docked { compactSidebarPresented = false }
            }
            .onChange(of: model.sidebarCollapsed) { _, collapsed in
                if collapsed { compactSidebarPresented = false }
            }
            .onChange(of: activityCenter.activityCenterPresented) { _, presented in
                if presented { compactSidebarPresented = false }
            }
            .onChange(of: sessionCatalog.sessionReveal?.id) {
                guard sessionCatalog.sessionReveal != nil else { return }
                // Activity links bring the output forward. A compact sidebar
                // would cover it, so only reveal the sidebar when it docks.
                compactSidebarPresented = false
                if proxy.size.width >= minimumThreeColumnWidth { model.sidebarCollapsed = false }
            }
            .onChange(of: model.activityResultReveal?.id) {
                guard let request = model.activityResultReveal,
                      request.sessionID == model.currentSessionID else { return }
                // Keep the selected run available, but let its result own the
                // foreground when the inspector would cover the conversation.
                if !docksInspector { model.inspectorCollapsed = true }
            }
        }
        .environment(\.locusIsLiveResizing, workspaceLayout.isLiveResizing)
        .background(RootViewUpdateProbe().frame(width: 0, height: 0))
        .transaction { transaction in
            if workspaceLayout.isLiveResizing {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .modifier(WorkspacePanelMotion(
            sidebarCollapsed: model.sidebarCollapsed,
            inspectorCollapsed: model.inspectorCollapsed,
            inspectorZoomed: model.inspectorZoomed,
            inspectorTab: model.inspectorTab
        ))
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
        .accessibilityLabel("\(AppEdition.current.displayName) workspace")
        .modifier(LocusSharedPresentations(surface: .main, updates: updates))
        .onAppear { model.appUpdates = updates }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === LocusApplicationDelegate.mainWindow(in: NSApp.windows) else { return }
            model.agentWorldOwnsPresentations = false
        }
        .task { onboarding.presentOnLaunchIfNeeded() }
    }
}

struct RememberConfirmationView: View {
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
                .foregroundStyle(LocusTheme.inkSoft)
                .tint(LocusTheme.accentAction)
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

struct MCPInputRequestView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    let request: MCPInputRequest
    @State private var draft = MCPFormDraft()

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(formFields, id: \.name) { field in
                            VStack(alignment: .leading, spacing: 4) {
                                formControl(field)
                                if let description = field.specification["description"]?.string {
                                    Text(description).font(.locus(size: 9)).foregroundStyle(LocusTheme.textSecondary)
                                }
                                if let error = validation.errors[field.name] {
                                    Text(error).font(.locus(size: 9)).foregroundStyle(LocusTheme.coral)
                                        .accessibilityIdentifier("mcpInput.error.\(field.name)")
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 430)
                Text("Only the displayed non-sensitive fields are returned to the extension.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
            HStack {
                Button("Decline") { extensionsModel.answerMCPInput(action: "decline") }
                Button("Cancel") { extensionsModel.answerMCPInput(action: "cancel") }
                Spacer()
                Button(request.mode == "url" ? "I've Completed It" : "Submit") {
                    extensionsModel.answerMCPInput(action: "accept", content: validation.content)
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(request.mode != "url" && !validation.errors.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 500)
        .task(id: request.id) { draft = MCPFormDraft(fields: formFields) }
    }

    private var formFields: [MCPFormField] { MCPFormField.fields(request.schema ?? [:]) }
    private var validation: MCPFormValidation { draft.validate(formFields) }

    @ViewBuilder
    private func formControl(_ field: MCPFormField) -> some View {
        if field.type == "array" {
            Text(field.title).font(.locus(size: 11, weight: .semibold))
            ForEach(Array(field.choices.enumerated()), id: \.offset) { _, choice in
                Toggle(choice.title, isOn: Binding(
                    get: { draft.arrays[field.name, default: []].contains(choice.value) },
                    set: { selected in
                        if selected { draft.arrays[field.name, default: []].insert(choice.value) }
                        else { draft.arrays[field.name, default: []].remove(choice.value) }
                    }
                ))
            }
        } else if !field.choices.isEmpty {
            Picker(field.title, selection: Binding(
                get: { field.choices.firstIndex { $0.value == draft.selections[field.name] } ?? -1 },
                set: { index in
                    if field.choices.indices.contains(index) { draft.selections[field.name] = field.choices[index].value }
                    else { draft.selections.removeValue(forKey: field.name) }
                }
            )) {
                Text(field.required ? "Choose…" : "Not set").tag(-1)
                ForEach(Array(field.choices.enumerated()), id: \.offset) { index, choice in Text(choice.title).tag(index) }
            }
        } else if field.type == "boolean" {
            if field.required {
                Toggle(field.title, isOn: Binding(
                    get: { draft.booleans[field.name] ?? false },
                    set: { draft.booleans[field.name] = $0 }
                ))
            } else {
                Picker(field.title, selection: Binding(
                    get: { draft.booleans[field.name] }, set: { draft.booleans[field.name] = $0 }
                )) {
                    Text("Not set").tag(Optional<Bool>.none)
                    Text("Yes").tag(Optional(true))
                    Text("No").tag(Optional(false))
                }
            }
        } else {
            TextField(field.title, text: Binding(
                get: { draft.text[field.name] ?? "" }, set: { draft.text[field.name] = $0 }
            ))
            .accessibilityIdentifier("mcpInput.field.\(field.name)")
        }
    }
}

struct MCPFormChoice {
    let value: JSONValue
    let title: String
}

struct MCPFormField {
    let name: String
    let specification: [String: JSONValue]
    let required: Bool
    var title: String { (specification["title"]?.string ?? name.replacingOccurrences(of: "_", with: " ").capitalized) + (required ? " *" : "") }
    var type: String { specification["type"]?.string ?? "string" }
    var choices: [MCPFormChoice] {
        let source: [String: JSONValue]
        if type == "array", case .object(let items) = specification["items"] { source = items }
        else { source = specification }
        if case .array(let values) = source["enum"] {
            let labels: [JSONValue]
            if case .array(let names) = source["enumNames"] { labels = names } else { labels = [] }
            return values.enumerated().map { index, value in
                MCPFormChoice(value: value, title: labels.indices.contains(index) ? labels[index].string ?? "Choice" : value.string ?? "Choice")
            }
        }
        if case .array(let values) = source["oneOf"] ?? source["anyOf"] {
            return values.compactMap { value in
                guard case .object(let option) = value, let constant = option["const"] else { return nil }
                return MCPFormChoice(value: constant, title: option["title"]?.string ?? constant.string ?? "Choice")
            }
        }
        return []
    }

    static func fields(_ schema: [String: JSONValue]) -> [MCPFormField] {
        guard case .object(let properties) = schema["properties"] else { return [] }
        let required: Set<String>
        if case .array(let values) = schema["required"] { required = Set(values.compactMap(\.string)) }
        else { required = [] }
        return properties.keys.sorted().map { name in
            let specification: [String: JSONValue]
            if case .object(let value) = properties[name] { specification = value } else { specification = [:] }
            return MCPFormField(name: name, specification: specification, required: required.contains(name))
        }
    }
}

struct MCPFormValidation {
    var content: [String: Any] = [:]
    var errors: [String: String] = [:]
}

struct MCPFormDraft {
    var text: [String: String] = [:]
    var booleans: [String: Bool] = [:]
    var selections: [String: JSONValue] = [:]
    var arrays: [String: Set<JSONValue>] = [:]

    init(fields: [MCPFormField] = []) {
        for field in fields {
            if let value = field.specification["default"] {
                if field.type == "array", case .array(let values) = value { arrays[field.name] = Set(values) }
                else if !field.choices.isEmpty { selections[field.name] = value }
                else if case .bool(let value) = value { booleans[field.name] = value }
                else if case .number(let value) = value { text[field.name] = value.rounded() == value && value >= Double(Int.min) && value < Double(Int.max) ? String(Int(value)) : String(value) }
                else if case .string(let value) = value { text[field.name] = value }
            } else if field.required && field.type == "boolean" { booleans[field.name] = false }
        }
    }

    func validate(_ fields: [MCPFormField]) -> MCPFormValidation {
        var result = MCPFormValidation()
        for field in fields {
            let name = field.name
            func number(_ key: String) -> Double? {
                if case .number(let value) = field.specification[key] { return value }
                return nil
            }
            var value: Any?
            if field.type == "array" {
                let selected = arrays[name] ?? []
                if field.choices.isEmpty { result.errors[name] = "This field needs an unsupported form control."; continue }
                if !selected.isSubset(of: Set(field.choices.map(\.value))) { result.errors[name] = "Choose only the listed values."; continue }
                if !selected.isEmpty || field.required {
                    value = field.choices.filter { selected.contains($0.value) }.map { Self.scalar($0.value) }
                    if let minimum = number("minItems"), Double(selected.count) < minimum { result.errors[name] = "Choose at least \(minimum.formatted()) values." }
                    if let maximum = number("maxItems"), Double(selected.count) > maximum { result.errors[name] = "Choose at most \(maximum.formatted()) values." }
                }
            } else if !field.choices.isEmpty {
                if let selected = selections[name] {
                    if field.choices.contains(where: { $0.value == selected }) { value = Self.scalar(selected) }
                    else { result.errors[name] = "Choose one of the listed values." }
                }
            } else if field.type == "boolean" { value = booleans[name] }
            else if ["string", "integer", "number"].contains(field.type) {
                if let raw = text[name], field.required || !raw.isEmpty {
                    if field.type == "string" {
                        value = raw
                        if let minimum = number("minLength"), Double(raw.count) < minimum { result.errors[name] = "Enter at least \(minimum.formatted()) characters." }
                        if let maximum = number("maxLength"), Double(raw.count) > maximum { result.errors[name] = "Enter at most \(maximum.formatted()) characters." }
                        if let pattern = field.specification["pattern"]?.string,
                           raw.range(of: pattern, options: .regularExpression) == nil { result.errors[name] = "This value does not match the requested format." }
                        if let format = field.specification["format"]?.string, !Self.matchesFormat(raw, format: format) {
                            result.errors[name] = "Enter a valid \(format.replacingOccurrences(of: "-", with: " "))."
                        }
                    } else {
                        let parsed = Double(raw)
                        if let parsed, parsed.isFinite, field.type != "integer" || Int(raw) != nil {
                            value = field.type == "integer" ? Int(raw)! as Any : parsed as Any
                            if let minimum = number("minimum"), parsed < minimum { result.errors[name] = "Enter \(minimum.formatted()) or greater." }
                            if let maximum = number("maximum"), parsed > maximum { result.errors[name] = "Enter \(maximum.formatted()) or less." }
                            if let minimum = number("exclusiveMinimum"), parsed <= minimum { result.errors[name] = "Enter more than \(minimum.formatted())." }
                            if let maximum = number("exclusiveMaximum"), parsed >= maximum { result.errors[name] = "Enter less than \(maximum.formatted())." }
                            if let multiple = number("multipleOf"), multiple > 0 {
                                let quotient = parsed / multiple
                                if !quotient.isFinite || abs(quotient - quotient.rounded()) > 1e-9 * max(1, abs(quotient)) {
                                    result.errors[name] = "Enter a multiple of \(multiple.formatted())."
                                }
                            }
                        } else { result.errors[name] = field.type == "integer" ? "Enter a whole number." : "Enter a valid number." }
                    }
                }
            } else { result.errors[name] = "This field needs an unsupported form control." }
            if let value { result.content[name] = value }
            else if field.required && result.errors[name] == nil { result.errors[name] = "This field is required." }
        }
        return result
    }

    private static func scalar(_ value: JSONValue) -> Any {
        switch value {
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        default: NSNull()
        }
    }

    private static func matchesFormat(_ value: String, format: String) -> Bool {
        switch format {
        case "email": return value.contains("@")
        case "uri": return URLComponents(string: value)?.scheme != nil
        case "date":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: value) else { return false }
            return formatter.string(from: date) == value
        case "date-time":
            let formatter = ISO8601DateFormatter()
            if formatter.date(from: value) != nil { return true }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: value) != nil
        default: return true
        }
    }
}
