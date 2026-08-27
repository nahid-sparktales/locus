import SwiftUI
import WebKit

/// The Browser tab: the same live web views the agent drives, with human
/// controls. The person and the agent share the session's tabs on purpose —
/// watching the agent work and stepping in are the same surface.
struct InspectorBrowserTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Observed here rather than through AppModel so tab-strip churn and
        // progress ticks redraw only this panel.
        BrowserPanel(
            browser: model.browser,
            sessionID: model.currentSessionID,
            homeURL: model.normalizedPreviewURL,
            viewportRaw: Binding(
                get: { model.settings.browserViewportRaw },
                set: { model.settings.browserViewportRaw = $0 }
            ),
            onAttachToChat: { [weak model] data in
                model?.addPastedImages(
                    [(data: data, mimeType: "image/png")],
                    nameStem: "Browser screenshot"
                ) ?? false
            },
            isExpanded: model.inspectorZoomed,
            onToggleExpand: { [weak model] in
                withAnimation(LocusMotion.spatial) {
                    model?.toggleInspectorZoom()
                }
            }
        )
    }
}

struct BrowserPanel: View {
    @ObservedObject var browser: BrowserService
    let sessionID: String
    let homeURL: URL?
    @Binding var viewportRaw: String
    /// Receives the flattened, annotated capture and reports whether the
    /// composer accepted it. A closure rather than an AppModel dependency, so
    /// the panel stays previewable and its redraws stay scoped to the
    /// browser service.
    var onAttachToChat: ((Data) -> Bool)? = nil
    /// Zoom state and toggle, injected the same closure-shaped way. Full
    /// size is the zoomed panel — there is no separate browser window.
    var isExpanded = false
    var onToggleExpand: (() -> Void)? = nil

    @State private var draft = ""
    @State private var drawerOpen = false
    @State private var screenshotDraft: BrowserScreenshotDraft?
    @State private var isCapturing = false
    @State private var findOpen = false
    @State private var findQuery = ""
    /// nil until a search has run, so the field does not accuse the user of
    /// finding nothing before they have typed anything.
    @State private var findMatched: Bool?
    @State private var colorScheme = BrowserPageAppearance.automatic.rawValue
    @State private var canvasFits = true
    @State private var canvasScale: CGFloat = 1
    @State private var historyOpen = false
    @State private var downloadsOpen = false
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool

    /// The menu's own label: the preset name, plus a marker when the tab is
    /// also pretending to be a phone.
    private var viewportLabel: String {
        let name = BrowserViewport(rawValue: viewportRaw)?.title ?? "Desktop"
        return snapshot?.emulatesDevice == true ? "\(name) · device" : name
    }

    private var snapshot: BrowserService.TabSnapshot? {
        browser.activeSnapshot(for: sessionID)
    }

    private var sessionTabs: [BrowserService.TabSnapshot] {
        browser.snapshots(for: sessionID)
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 480 && !isExpanded
            VStack(spacing: 0) {
                if compact {
                    compactControlsBar
                } else {
                    controlsBar
                    tabChips
                }
                toolbar
                if addressFocused, !addressSuggestions.isEmpty { addressSuggestionBar }
                if findOpen { findBar }
                progressLine
                canvasControls
                if let prompt = browser.autofillPrompt,
                   prompt.sessionID == sessionID
                {
                    autofillSuggestions(prompt)
                }
                if let prompt = browser.pendingPasswordSave,
                   prompt.sessionID == sessionID
                {
                    passwordSaveBanner(prompt)
                }
                content
                if drawerOpen, let log = browser.activeLog(for: sessionID) {
                    CaptureDrawer(log: log)
                }
            }
        }
        .onChange(of: snapshot?.url) { _, updated in
            // The address bar mirrors the page unless the user is typing.
            if !addressFocused { draft = updated ?? "" }
        }
        .onAppear {
            if let url = snapshot?.url, !url.isEmpty { draft = url }
            colorScheme = browser.pageAppearance.rawValue
            // Opening the panel is the clearest signal a navigation is coming;
            // warm WebKit's processes before the user finishes typing the URL.
            browser.prewarm()
        }
        .background(shortcutHost)
        .sheet(item: $screenshotDraft) { draft in
            BrowserScreenshotSheet(draft: draft) { data in
                onAttachToChat?(data) ?? false
            }
        }
    }

    /// Capture the visible viewport for the annotation sheet. No consent gate
    /// and no size cap: those guard the *agent* shipping pixels autonomously,
    /// while this is the user capturing, seeing, editing, and explicitly
    /// attaching — the composer's own attachment caps still apply.
    private func captureForAnnotation() {
        guard let host = browser.activeHost(for: sessionID), !isCapturing else { return }
        isCapturing = true
        let title = snapshot?.title ?? ""
        Task {
            defer { isCapturing = false }
            guard let data = try? await host.snapshotPNG(),
                  let image = NSBitmapImageRep(data: data)?.cgImage
            else {
                NSSound.beep()
                return
            }
            screenshotDraft = BrowserScreenshotDraft(image: image, pageTitle: title)
        }
    }

    /// Browser keyboard shortcuts, active exactly while this panel sits in the
    /// key window's hierarchy — the inspector removes it structurally on tab
    /// switch. ⌘W is deliberately shadowed here the way ⌘⇧K is in the
    /// workspace: while staring at the browser it means "close tab" (and in
    /// the main window, un-shadowed ⌘W would quit the app); everywhere else
    /// it keeps meaning Close Window.
    private var shortcutHost: some View {
        Group {
            Button("") { newTabFocusingAddress() }
                .keyboardShortcut("t", modifiers: .command)
            Button("") { closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(snapshot == nil)
            Button("") { browser.userCycleTab(sessionID: sessionID, forward: true) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(sessionTabs.count < 2)
            Button("") { browser.userCycleTab(sessionID: sessionID, forward: false) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(sessionTabs.count < 2)
            Button("") { openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(snapshot?.url.isEmpty != false)
            Button("") { stepZoom(by: 0.1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("") { stepZoom(by: -0.1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { browser.userSetPageZoom(1, sessionID: sessionID) }
                .keyboardShortcut("0", modifiers: .command)
        }
        .buttonStyle(.locus())
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func newTabFocusingAddress() {
        browser.userNewTab(sessionID: sessionID)
        draft = ""
        addressFocused = true
    }

    private func closeActiveTab() {
        guard let active = snapshot else { return }
        browser.userCloseTab(active.id, sessionID: sessionID)
    }

    private func openFind() {
        guard snapshot?.url.isEmpty == false else { return }
        findOpen = true
        findFocused = true
    }

    private func closeFind() {
        findOpen = false
        findQuery = ""
        findMatched = nil
        browser.userClearFind(sessionID: sessionID)
    }

    private func runFind(forward: Bool) {
        let query = findQuery
        guard !query.isEmpty else {
            findMatched = nil
            return
        }
        Task {
            findMatched = await browser.userFind(query, sessionID: sessionID, forward: forward)
        }
    }

    private func stepZoom(by delta: CGFloat) {
        let current = snapshot?.pageZoom ?? 1
        browser.userSetPageZoom(current + delta, sessionID: sessionID)
    }

    // MARK: - Chrome

    /// ⌘F, in the panel rather than the window: WebKit owns the highlight, and
    /// the person searching a page is looking at this pane, not the transcript.
    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)

            TextField("Find on page", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.locus(size: 9))
                .focused($findFocused)
                .onSubmit { runFind(forward: true) }
                .onChange(of: findQuery) { _, _ in runFind(forward: true) }
                .accessibilityLabel("Find on page")
                .accessibilityIdentifier("browser.find.query")

            // WebKit's find API reports only whether something matched, so this
            // says exactly that rather than inventing "1 of 12".
            if findMatched == false, !findQuery.isEmpty {
                Text("Not found")
                    .font(.locus(size: 8, weight: .semibold))
                    .foregroundStyle(LocusTheme.coral)
                    .accessibilityIdentifier("browser.find.empty")
            }

            Button { runFind(forward: false) } label: {
                Image(systemName: "chevron.up").font(.locus(size: 9, weight: .semibold))
            }
            .buttonStyle(.locus())
            .disabled(findQuery.isEmpty)
            .help("Previous match (⇧↩)")
            .accessibilityLabel("Previous match")

            Button { runFind(forward: true) } label: {
                Image(systemName: "chevron.down").font(.locus(size: 9, weight: .semibold))
            }
            .buttonStyle(.locus())
            .disabled(findQuery.isEmpty)
            .help("Next match (↩)")
            .accessibilityLabel("Next match")

            Button(action: closeFind) {
                Image(systemName: "xmark").font(.locus(size: 8, weight: .bold))
            }
            .buttonStyle(.locus())
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close find bar")
            .accessibilityLabel("Close find bar")
        }
        .foregroundStyle(LocusTheme.muted)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .accessibilityIdentifier("browser.find")
    }

    private var tabChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(sessionTabs) { tab in
                        chip(for: tab)
                            .id(tab.id)
                    }
                    Button {
                        newTabFocusingAddress()
                    } label: {
                        Image(systemName: "plus")
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.muted)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.locus())
                    .help("New tab (⌘T)")
                    .accessibilityLabel("New browser tab")
                    .accessibilityIdentifier("browser.tabs.new")
                    Button {
                        browser.userReopenClosedTab(sessionID: sessionID)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.muted)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.locus())
                    .disabled(!browser.canReopenClosedTab(sessionID: sessionID))
                    .help("Reopen recently closed tab")
                    .accessibilityLabel("Reopen recently closed browser tab")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .onChange(of: snapshot?.id) { _, activeID in
                // Switching — including via ⇧⌘] — must reveal the active chip
                // at the inspector's narrowest widths.
                if let activeID {
                    withAnimation(LocusMotion.scroll) { proxy.scrollTo(activeID) }
                }
            }
        }
        .accessibilityIdentifier("browser.tabs")
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private func chip(for tab: BrowserService.TabSnapshot) -> some View {
        let title = tab.title.isEmpty
            ? (URL(string: tab.url)?.host ?? "New Tab")
            : tab.title
        return HStack(spacing: 4) {
            Group {
                if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else if let icon = browser.favicon(forPageURL: URL(string: tab.url)) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.medium)
                } else {
                    Image(systemName: "globe")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .frame(width: 12, height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            Text(title)
                .font(.locus(size: 9, weight: tab.isActive ? .semibold : .regular))
                .foregroundStyle(tab.isActive ? LocusTheme.ink : LocusTheme.muted)
                .lineLimit(1)
                .frame(maxWidth: 120)
            Button {
                browser.userCloseTab(tab.id, sessionID: sessionID)
            } label: {
                Image(systemName: "xmark")
                    .font(.locus(size: 7, weight: .bold))
                    .foregroundStyle(LocusTheme.muted)
            }
            .buttonStyle(.locus())
            .help("Close tab")
            .accessibilityLabel("Close \(title)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tab.isActive ? LocusTheme.white : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            if tab.isActive {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            browser.userSelectTab(tab.id, sessionID: sessionID)
        }
        .contextMenu {
            Button("Duplicate Tab") {
                browser.userDuplicateTab(tab.id, sessionID: sessionID)
            }
            .disabled(tab.url.isEmpty)
            Button("Close Tab") {
                browser.userCloseTab(tab.id, sessionID: sessionID)
            }
            Button("Close Other Tabs") {
                browser.userCloseOtherTabs(keeping: tab.id, sessionID: sessionID)
            }
            .disabled(sessionTabs.count < 2)
            Divider()
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url, forType: .string)
            }
            .disabled(tab.url.isEmpty)
            Button("Open in Default Browser") {
                browser.userOpenTabExternally(tab.id, sessionID: sessionID)
            }
            .disabled(tab.url.isEmpty)
        }
        .help(tab.url.isEmpty ? "New Tab" : tab.url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) tab")
        .accessibilityIdentifier("browser.tab.\(tab.id)")
        .accessibilityAddTraits(tab.isActive ? [.isSelected] : [])
        .draggable(tab.id)
        .dropDestination(for: String.self) { dragged, _ in
            guard let source = dragged.first else { return false }
            browser.userMoveTab(source, before: tab.id, sessionID: sessionID)
            return true
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                browser.userGoBack(sessionID: sessionID)
            } label: {
                Image(systemName: "chevron.left").font(.locus(size: 10, weight: .semibold))
            }
            .buttonStyle(.locus())
            .disabled(snapshot?.canGoBack != true)
            .foregroundStyle(snapshot?.canGoBack == true ? LocusTheme.ink : LocusTheme.muted)
            .help("Back")
            .accessibilityLabel("Back")
            .accessibilityIdentifier("browser.back")

            Button {
                browser.userGoForward(sessionID: sessionID)
            } label: {
                Image(systemName: "chevron.right").font(.locus(size: 10, weight: .semibold))
            }
            .buttonStyle(.locus())
            .disabled(snapshot?.canGoForward != true)
            .foregroundStyle(snapshot?.canGoForward == true ? LocusTheme.ink : LocusTheme.muted)
            .help("Forward")
            .accessibilityLabel("Forward")
            .accessibilityIdentifier("browser.forward")

            if snapshot?.isLoading == true {
                Button {
                    browser.userStopLoading(sessionID: sessionID)
                } label: {
                    Image(systemName: "xmark").font(.locus(size: 9, weight: .semibold))
                }
                .buttonStyle(.locus())
                .foregroundStyle(LocusTheme.coral)
                .help("Stop loading")
                .accessibilityLabel("Stop loading")
                .accessibilityIdentifier("browser.stop")
            } else {
                Button {
                    browser.userReload(sessionID: sessionID)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.locus(size: 9, weight: .semibold))
                }
                .buttonStyle(.locus())
                .foregroundStyle(snapshot == nil ? LocusTheme.muted : LocusTheme.ink)
                .disabled(snapshot == nil)
                .help("Reload")
                .accessibilityLabel("Reload page")
                .accessibilityIdentifier("browser.reload")
            }

            TextField("Search or enter address", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.locus(size: 9, design: .monospaced))
                .focused($addressFocused)
                .onSubmit(navigateToDraft)
                .accessibilityLabel("Address")
                .accessibilityIdentifier("browser.url")

            Button(action: navigateToDraft) {
                Image(systemName: "return").font(.locus(size: 10, weight: .semibold))
            }
            .buttonStyle(.locus())
            .foregroundStyle(draft.isEmpty ? LocusTheme.muted : LocusTheme.ink)
            .disabled(draft.isEmpty)
            .help("Go")
            .accessibilityLabel("Go")
            .accessibilityIdentifier("browser.go")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    @ViewBuilder
    private var progressLine: some View {
        if let snapshot, snapshot.isLoading {
            GeometryReader { proxy in
                Rectangle()
                    .fill(LocusTheme.signalDeep)
                    .frame(width: proxy.size.width * max(0.05, snapshot.progress))
            }
            .frame(height: 2)
            .animation(LocusMotion.content, value: snapshot.progress)
        } else {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let host = browser.activeHost(for: sessionID), snapshot?.url.isEmpty == false {
            BorrowedWebView(host: host, fit: canvasFits, scale: canvasScale)
                .accessibilityLabel("Web page")
                .background(Color(nsColor: .windowBackgroundColor))
        } else {
            InspectorPlaceholder(
                symbol: "globe",
                title: placeholderTitle,
                message: placeholderMessage,
                identifier: "browser.empty"
            )
        }
    }

    private var placeholderTitle: String {
        snapshot != nil && snapshot?.url.isEmpty == true ? "New Tab" : "Browser"
    }

    private var placeholderMessage: String {
        if snapshot != nil, snapshot?.url.isEmpty == true {
            if let homeURL {
                return "Type an address above, or press ↵ to open \(homeURL.absoluteString)."
            }
            return "Type an address above to browse."
        }
        if let homeURL {
            return "Enter an address, or press Go to open \(homeURL.absoluteString).\n\nThe agent browses here too: pages it opens appear in this panel."
        }
        return "Enter an address to browse.\n\nThe agent browses here too: pages it opens appear in this panel."
    }

    /// Viewport, capture, drawer, open-external and expand — one compact bar
    /// at the very top, above the tab chips, so the chips sit directly on the
    /// address bar they steer and the page owns everything below.
    private var controlsBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(BrowserViewport.allCases) { preset in
                    Button {
                        viewportRaw = preset.rawValue
                        browser.defaultViewport = preset.size
                        browser.userSetViewport(preset.size, sessionID: sessionID)
                    } label: {
                        let size = preset.size
                        let label = "\(preset.title)  \(Int(size.width))×\(Int(size.height))"
                        if viewportRaw == preset.rawValue {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }

                Divider()

                // The agent can turn this on by itself through browser_resize;
                // showing it here is what stops a spoofed user agent from being
                // an invisible difference between what the page serves the
                // person and what it serves the screenshot.
                Toggle(
                    "Emulate mobile device",
                    isOn: Binding(
                        get: { snapshot?.emulatesDevice ?? false },
                        set: { browser.userSetDeviceEmulation($0, sessionID: sessionID) }
                    )
                )
                .accessibilityIdentifier("browser.device")

                Divider()

                Picker(
                    "Appearance",
                    selection: Binding(
                        get: { colorScheme },
                        set: { scheme in
                            colorScheme = scheme
                            browser.userSetColorScheme(scheme, sessionID: sessionID)
                        }
                    )
                ) {
                    Text("Automatic").tag(BrowserPageAppearance.automatic.rawValue)
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("browser.colorScheme")
            } label: {
                Label(viewportLabel, systemImage: "rectangle.ratio.3.to.4")
                    .font(.locus(size: 8, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(LocusTheme.muted)
            .help("Emulated viewport and device for the agent's screenshots")
            .accessibilityIdentifier("browser.viewport")

            if let zoom = snapshot?.pageZoom, abs(zoom - 1) > 0.001 {
                Button {
                    browser.userSetPageZoom(1, sessionID: sessionID)
                } label: {
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .buttonStyle(.locus())
                .help("Page zoom — click to reset (⌘0)")
                .accessibilityLabel("Page zoom \(Int((zoom * 100).rounded())) percent")
                .accessibilityIdentifier("browser.zoom")
            }

            Spacer()

            siteMenu
            browserActivityButtons
            pageActionsMenu

            if let onToggleExpand {
                Button {
                    onToggleExpand()
                } label: {
                    Image(
                        systemName: isExpanded
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.locus(size: 10))
                    .foregroundStyle(LocusTheme.ink)
                }
                .buttonStyle(.locus())
                .help(isExpanded ? "Restore panel size" : "Expand in window")
                .accessibilityLabel(isExpanded ? "Restore panel size" : "Expand in window")
                .accessibilityIdentifier("browser.expand")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private var compactControlsBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(sessionTabs) { tab in
                    Button {
                        browser.userSelectTab(tab.id, sessionID: sessionID)
                    } label: {
                        if tab.isActive {
                            Label(tabDisplayTitle(tab), systemImage: "checkmark")
                        } else {
                            Text(tabDisplayTitle(tab))
                        }
                    }
                }
                Divider()
                Button("New Tab", systemImage: "plus") { newTabFocusingAddress() }
                Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") {
                    browser.userReopenClosedTab(sessionID: sessionID)
                }
                .disabled(!browser.canReopenClosedTab(sessionID: sessionID))
            } label: {
                Label(tabDisplayTitle(snapshot), systemImage: "rectangle.stack")
                    .font(.locus(size: 9, weight: .semibold))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 180, alignment: .leading)
            .accessibilityLabel("Browser tabs")

            Spacer(minLength: 0)
            siteMenu
            browserActivityButtons
            pageActionsMenu
            expandButton
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private func tabDisplayTitle(_ tab: BrowserService.TabSnapshot?) -> String {
        guard let tab else { return "New Tab" }
        if !tab.title.isEmpty { return tab.title }
        return URL(string: tab.url)?.host ?? "New Tab"
    }

    private var siteMenu: some View {
        Menu {
            if let url = snapshot?.url, let pageURL = URL(string: url) {
                Text(pageURL.host ?? pageURL.absoluteString)
                Text(pageURL.scheme == "https" ? "Secure connection" : "Connection is not secure")
                Divider()
                Menu("Permissions for This Site") {
                    ForEach(BrowserPermissionKind.allCases) { kind in
                        Menu(kind.title) {
                            ForEach(BrowserPermissionDecision.allCases) { decision in
                                Button {
                                    browser.permissionStore.set(
                                        decision,
                                        kind: kind,
                                        origin: BrowserPermissionStore.normalizedOrigin(pageURL)
                                    )
                                } label: {
                                    if browser.permissionStore.decision(for: kind, url: pageURL) == decision {
                                        Label(decision.title, systemImage: "checkmark")
                                    } else {
                                        Text(decision.title)
                                    }
                                }
                            }
                        }
                    }
                }
                Button("Clear Stored Data for This Site…", role: .destructive) {
                    Task { await browser.removeWebsiteData(named: pageURL.host ?? "") }
                }
            } else {
                Text("No site open")
            }
        } label: {
            Image(systemName: snapshot?.url.hasPrefix("https://") == true ? "lock.fill" : "info.circle")
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(snapshot?.url.hasPrefix("https://") == true ? LocusTheme.signalDeep : LocusTheme.muted)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .help("Connection, permissions, and stored site data")
        .accessibilityLabel(snapshot?.url.hasPrefix("https://") == true ? "Secure site information" : "Site information")
        .accessibilityIdentifier("browser.siteInfo")
    }

    private var browserActivityButtons: some View {
        HStack(spacing: 4) {
            Button { historyOpen.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath").frame(width: 24, height: 24)
            }
            .buttonStyle(.locus())
            .popover(isPresented: $historyOpen, arrowEdge: .bottom) {
                BrowserQuickHistory(
                    store: browser.activityStore,
                    open: { url in
                        draft = url
                        navigateToDraft()
                        historyOpen = false
                    }
                )
            }
            .help("Browsing history")
            .accessibilityLabel("Browsing history")

            Button { downloadsOpen.toggle() } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.down.circle").frame(width: 24, height: 24)
                    if browser.activityStore.downloads.contains(where: { $0.state == .running }) {
                        Circle().fill(LocusTheme.signalDeep).frame(width: 6, height: 6)
                    }
                }
            }
            .buttonStyle(.locus())
            .popover(isPresented: $downloadsOpen, arrowEdge: .bottom) {
                BrowserQuickDownloads(browser: browser, store: browser.activityStore)
            }
            .help("Downloads")
            .accessibilityLabel("Downloads")

            BrowserVaultStatusButton(vault: browser.autofillVault)
        }
        .font(.locus(size: 10))
        .foregroundStyle(LocusTheme.muted)
    }

    private var pageActionsMenu: some View {
        Menu {
            Button("Find on Page…", systemImage: "magnifyingglass") { openFind() }
                .disabled(snapshot?.url.isEmpty != false)
            Button("Capture and Attach…", systemImage: "camera") { captureForAnnotation() }
                .disabled(isCapturing || snapshot?.url.isEmpty != false)
            Button(drawerOpen ? "Hide Console and Network" : "Show Console and Network", systemImage: "terminal") {
                drawerOpen.toggle()
            }
            Divider()
            Button("Open in Default Browser", systemImage: "arrow.up.right.square") {
                browser.openCurrentTabExternally(sessionID: sessionID)
            }
            .disabled(snapshot == nil)
            Button(browser.webInspectorEnabled ? "Disable Web Inspector" : "Allow Web Inspector", systemImage: "hammer") {
                browser.webInspectorEnabled.toggle()
                browser.activeHost(for: sessionID)?.webView.isInspectable = browser.webInspectorEnabled
            }
            Divider()
            Menu("Viewport and Device") {
                ForEach(BrowserViewport.allCases) { preset in
                    Button("\(preset.title)  \(Int(preset.size.width))×\(Int(preset.size.height))") {
                        viewportRaw = preset.rawValue
                        browser.defaultViewport = preset.size
                        browser.userSetViewport(preset.size, sessionID: sessionID)
                    }
                }
                Toggle("Emulate Mobile Device", isOn: Binding(
                    get: { snapshot?.emulatesDevice ?? false },
                    set: { browser.userSetDeviceEmulation($0, sessionID: sessionID) }
                ))
            }
        } label: {
            Label("Page", systemImage: "ellipsis.circle")
                .font(.locus(size: 9, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .help("Page actions and developer tools")
        .accessibilityIdentifier("browser.pageActions")
    }

    @ViewBuilder
    private var expandButton: some View {
        if let onToggleExpand {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .font(.locus(size: 10, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.locus())
            .help(isExpanded ? "Restore panel size" : "Expand browser")
            .accessibilityLabel(isExpanded ? "Restore panel size" : "Expand browser")
            .accessibilityIdentifier("browser.expand.compact")
        }
    }

    private var canvasControls: some View {
        HStack(spacing: 7) {
            Button("Fit") { canvasFits = true }
                .buttonStyle(.locus())
                .foregroundStyle(canvasFits ? LocusTheme.ink : LocusTheme.muted)
            Button("100%") { canvasFits = false; canvasScale = 1 }
                .buttonStyle(.locus())
            Button { canvasFits = false; canvasScale = max(0.25, canvasScale - 0.1) } label: {
                Image(systemName: "minus.magnifyingglass")
            }.buttonStyle(.locus()).accessibilityLabel("Zoom canvas out")
            Text(canvasFits ? "Fit" : "\(Int((canvasScale * 100).rounded()))%")
                .font(.locus(size: 8, weight: .semibold, design: .monospaced))
                .frame(width: 36)
            Button { canvasFits = false; canvasScale = min(2, canvasScale + 0.1) } label: {
                Image(systemName: "plus.magnifyingglass")
            }.buttonStyle(.locus()).accessibilityLabel("Zoom canvas in")
            Spacer()
            if let host = browser.activeHost(for: sessionID) {
                Text("\(Int(host.viewport.width))×\(Int(host.viewport.height))")
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
            }
            expandButton
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(LocusTheme.paperDeep.opacity(0.86))
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
        .accessibilityIdentifier("browser.canvasControls")
    }

    private var addressSuggestions: [BrowserHistoryEntry] {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Array(browser.activityStore.searchHistory(query: draft, limit: 5).prefix(5))
    }

    private var addressSuggestionBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(addressSuggestions) { entry in
                Button {
                    draft = entry.url
                    navigateToDraft()
                } label: {
                    HStack {
                        Image(systemName: "clock").frame(width: 18)
                        Text(entry.title.isEmpty ? entry.host : entry.title).lineLimit(1)
                        Spacer()
                        Text(entry.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
        .accessibilityIdentifier("browser.omnibox.suggestions")
    }

    private func autofillSuggestions(_ prompt: BrowserAutofillPrompt) -> some View {
        BrowserAutofillSuggestionBar(browser: browser, prompt: prompt)
    }

    private func passwordSaveBanner(_ prompt: BrowserPasswordSavePrompt) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(LocusTheme.signalDeep)
            VStack(alignment: .leading, spacing: 1) {
                Text("Save password for \(URL(string: prompt.origin)?.host ?? prompt.origin)?")
                    .font(.locus(size: 10, weight: .semibold))
                if !prompt.username.isEmpty {
                    Text(prompt.username).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Not Now") { browser.dismissPasswordSavePrompt() }
            Button("Save") { Task { _ = await browser.acceptPasswordSavePrompt() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
        .accessibilityIdentifier("browser.passwordSave")
    }

    private func navigateToDraft() {
        let target = draft.isEmpty ? (homeURL?.absoluteString ?? "") : draft
        guard !target.isEmpty else { return }
        if browser.userNavigate(target, sessionID: sessionID) {
            addressFocused = false
        }
    }
}

// MARK: - Borrowing the live web view

/// Shows the service-owned `WKWebView` without ever creating one. `lend` steals
/// safely, so the only rule that matters is: never park a view this container
/// no longer owns — SwiftUI does not order a successor's lend against this
/// view's teardown within a transaction, and an unconditional park would yank
/// the page back out of whoever borrowed it since.
private final class BrowserCanvasClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if documentView.frame.width < result.width {
            result.origin.x = (documentView.frame.width - result.width) / 2
        }
        if documentView.frame.height < result.height {
            result.origin.y = (documentView.frame.height - result.height) / 2
        }
        return result
    }
}

@MainActor
final class BrowserCanvasContainer: NSView {
    private let scrollView = NSScrollView()
    fileprivate let canvas = NSView()
    weak var host: OffscreenWebHost?
    var fits = true
    var requestedScale: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let clip = BrowserCanvasClipView()
        clip.drawsBackground = true
        clip.backgroundColor = .windowBackgroundColor
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 2
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        applyScale()
    }

    func display(_ newHost: OffscreenWebHost, fits: Bool, scale: CGFloat) {
        if let host, host !== newHost { parkIfStillOwner() }
        host = newHost
        self.fits = fits
        requestedScale = min(2, max(0.25, scale))
        canvas.frame = NSRect(origin: .zero, size: newHost.viewport)
        newHost.lend(to: canvas, preservingViewport: true)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func parkIfStillOwner() {
        guard let host, host.webView.superview === canvas else { return }
        host.park()
        self.host = nil
    }

    private func applyScale() {
        guard let host, bounds.width > 0, bounds.height > 0 else { return }
        let available = CGSize(
            width: max(1, bounds.width - 4),
            height: max(1, bounds.height - 4)
        )
        let fitScale = min(
            available.width / host.viewport.width,
            available.height / host.viewport.height
        )
        let target = min(2, max(0.25, fits ? fitScale : requestedScale))
        guard abs(scrollView.magnification - target) > 0.001 else { return }
        scrollView.setMagnification(
            target,
            centeredAt: CGPoint(x: host.viewport.width / 2, y: host.viewport.height / 2)
        )
    }
}

struct BorrowedWebView: NSViewRepresentable {
    let host: OffscreenWebHost
    var fit = true
    var scale: CGFloat = 1

    func makeNSView(context: Context) -> BrowserCanvasContainer {
        BrowserCanvasContainer()
    }

    func updateNSView(_ container: BrowserCanvasContainer, context: Context) {
        container.display(host, fits: fit, scale: scale)
    }

    static func dismantleNSView(_ container: BrowserCanvasContainer, coordinator: ()) {
        container.parkIfStillOwner()
    }
}

private struct BrowserVaultStatusButton: View {
    @ObservedObject var vault: BrowserAutofillVault

    var body: some View {
        Button {
            if vault.isUnlocked { vault.lock() }
            else { Task { await vault.unlock(reason: "Unlock Locus Autofill") } }
        } label: {
            Image(systemName: vault.isUnlocked ? "lock.open.fill" : "lock.fill")
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.locus())
        .help(vault.isUnlocked ? "Autofill unlocked — click to lock" : "Unlock Autofill")
        .accessibilityLabel(vault.isUnlocked ? "Lock Autofill" : "Unlock Autofill")
        .accessibilityIdentifier("browser.vault")
    }
}

private struct BrowserQuickHistory: View {
    @ObservedObject var store: BrowserActivityStore
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent History").font(.headline).padding(12)
            Divider()
            if store.history.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock")
                    .frame(width: 360, height: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.history.prefix(20)) { entry in
                            Button { open(entry.url) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(entry.title.isEmpty ? entry.host : entry.title).lineLimit(1)
                                        Text(entry.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(entry.visitedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                }.padding(.horizontal, 12).frame(height: 46)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 380, height: 300)
            }
        }
    }
}

private struct BrowserQuickDownloads: View {
    @ObservedObject var browser: BrowserService
    @ObservedObject var store: BrowserActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Downloads").font(.headline).padding(12)
            Divider()
            if store.downloads.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
                    .frame(width: 360, height: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.downloads.prefix(20)) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(item.fileName).lineLimit(1); Spacer(); Text(item.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }
                                if item.state == .running { ProgressView(value: item.progress) }
                                HStack {
                                    if item.state == .running { Button("Pause") { browser.pauseDownload(item.id) }; Button("Cancel") { browser.cancelDownload(item.id) } }
                                    if item.state == .paused { Button("Resume") { browser.resumeDownload(item.id) } }
                                    if item.state == .failed { Button("Retry") { browser.retryDownload(item.id) } }
                                    if item.state == .completed { Button("Open") { browser.openDownload(item.id) }; Button("Finder") { browser.revealDownload(item.id) } }
                                }.buttonStyle(.borderless)
                            }.padding(.horizontal, 12)
                        }
                    }.padding(.vertical, 8)
                }.frame(width: 380, height: 300)
            }
        }
    }
}

private struct BrowserAutofillSuggestionBar: View {
    @ObservedObject var browser: BrowserService
    @ObservedObject private var vault: BrowserAutofillVault
    let prompt: BrowserAutofillPrompt

    init(browser: BrowserService, prompt: BrowserAutofillPrompt) {
        self.browser = browser
        self.prompt = prompt
        _vault = ObservedObject(wrappedValue: browser.autofillVault)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(LocusTheme.signalDeep)
            Text(title).font(.locus(size: 9, weight: .semibold))
            if !vault.isUnlocked {
                Button("Unlock Autofill") { Task { await vault.unlock(reason: "Show Autofill suggestions") } }
                    .buttonStyle(.borderedProminent)
            } else {
                suggestions
            }
            Spacer(minLength: 0)
            Button { browser.dismissAutofillPrompt() } label: { Image(systemName: "xmark") }
                .buttonStyle(.locus()).accessibilityLabel("Dismiss Autofill suggestions")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
        .accessibilityIdentifier("browser.autofill.suggestions")
    }

    private var symbol: String {
        switch prompt.category { case .password: "key.fill"; case .contact: "person.text.rectangle"; case .paymentCard: "creditcard.fill" }
    }

    private var title: String {
        switch prompt.category { case .password: "Passwords"; case .contact: "Contact info"; case .paymentCard: "Payment cards" }
    }

    @ViewBuilder private var suggestions: some View {
        switch prompt.category {
        case .password:
            ForEach(vault.passwordSuggestions(for: prompt.origin).prefix(3)) { item in
                Button(item.username.isEmpty ? item.displayOrigin : item.username) {
                    Task { _ = await browser.fillPassword(item.id, sessionID: prompt.sessionID) }
                }
            }
        case .contact:
            ForEach(vault.contactSuggestions().prefix(3)) { item in
                Button(item.fullName.isEmpty ? item.label : item.fullName) {
                    Task { _ = await browser.fillContact(item.id, sessionID: prompt.sessionID) }
                }
            }
        case .paymentCard:
            ForEach(vault.cardSuggestions().prefix(3)) { item in
                Button("\(item.nickname) \(item.maskedNumber)") {
                    Task { _ = await browser.fillCard(item.id, sessionID: prompt.sessionID) }
                }
            }
        }
    }
}

// MARK: - Console / network drawer

struct CaptureDrawer: View {
    @ObservedObject var log: BrowserCaptureLog
    @State private var pane = Pane.console

    enum Pane: String, CaseIterable, Identifiable {
        case console
        case network

        var id: String { rawValue }
        var title: String { rawValue == "console" ? "Console" : "Network" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        switch pane {
                        case .console: consoleLines
                        case .network: networkLines
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .onChange(of: log.console.count) {
                    if pane == .console, let last = log.console.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: log.network.count) {
                    if pane == .network, let last = log.network.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 150)
        .background(LocusTheme.white.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .accessibilityIdentifier("browser.drawer.content")
    }

    @ViewBuilder
    private var consoleLines: some View {
        if log.console.isEmpty {
            Text("The console is empty.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
        } else {
            ForEach(log.console) { entry in
                Text("[\(entry.level)] \(entry.message)")
                    .font(.locus(size: 9, design: .monospaced))
                    .foregroundStyle(entry.isError ? LocusTheme.coral : LocusTheme.inkSoft)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(entry.id)
            }
            if log.droppedEntries > 0 {
                Text("\(log.droppedEntries) entries dropped while the page was noisy.")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
        }
    }

    @ViewBuilder
    private var networkLines: some View {
        if log.network.isEmpty {
            Text("No requests recorded for this page.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
        } else {
            ForEach(log.network) { entry in
                Text(entry.summary)
                    .font(.locus(size: 9, design: .monospaced))
                    .foregroundStyle(entry.ok ? LocusTheme.inkSoft : LocusTheme.coral)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(entry.id)
            }
        }
    }
}
