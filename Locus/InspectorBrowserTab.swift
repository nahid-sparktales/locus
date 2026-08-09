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
                withAnimation(.easeInOut(duration: 0.18)) {
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
    @FocusState private var addressFocused: Bool

    private var snapshot: BrowserService.TabSnapshot? {
        browser.activeSnapshot(for: sessionID)
    }

    private var sessionTabs: [BrowserService.TabSnapshot] {
        browser.snapshots(for: sessionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabChips
            controlsBar
            toolbar
            progressLine
            content
            if drawerOpen, let log = browser.activeLog(for: sessionID) {
                CaptureDrawer(log: log)
            }
        }
        .onChange(of: snapshot?.url) { _, updated in
            // The address bar mirrors the page unless the user is typing.
            if !addressFocused, let updated { draft = updated }
        }
        .onAppear {
            if let url = snapshot?.url, !url.isEmpty { draft = url }
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
        }
        .buttonStyle(.plain)
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

    // MARK: - Chrome

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
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.muted)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("New tab (⌘T)")
                    .accessibilityLabel("New browser tab")
                    .accessibilityIdentifier("browser.tabs.new")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .onChange(of: snapshot?.id) { _, activeID in
                // Switching — including via ⇧⌘] — must reveal the active chip
                // at the inspector's narrowest widths.
                if let activeID {
                    withAnimation { proxy.scrollTo(activeID) }
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
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .frame(width: 12, height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            Text(title)
                .font(.system(size: 9, weight: tab.isActive ? .semibold : .regular))
                .foregroundStyle(tab.isActive ? LocusTheme.ink : LocusTheme.muted)
                .lineLimit(1)
                .frame(maxWidth: 120)
            Button {
                browser.userCloseTab(tab.id, sessionID: sessionID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(LocusTheme.muted)
            }
            .buttonStyle(.plain)
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
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                browser.userGoBack(sessionID: sessionID)
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(snapshot?.canGoBack != true)
            .foregroundStyle(snapshot?.canGoBack == true ? LocusTheme.ink : LocusTheme.muted)
            .help("Back")
            .accessibilityLabel("Back")
            .accessibilityIdentifier("browser.back")

            Button {
                browser.userGoForward(sessionID: sessionID)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(snapshot?.canGoForward != true)
            .foregroundStyle(snapshot?.canGoForward == true ? LocusTheme.ink : LocusTheme.muted)
            .help("Forward")
            .accessibilityLabel("Forward")
            .accessibilityIdentifier("browser.forward")

            if snapshot?.isLoading == true {
                Button {
                    browser.userStopLoading(sessionID: sessionID)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LocusTheme.coral)
                .help("Stop loading")
                .accessibilityLabel("Stop loading")
                .accessibilityIdentifier("browser.stop")
            } else {
                Button {
                    browser.userReload(sessionID: sessionID)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(snapshot == nil ? LocusTheme.muted : LocusTheme.ink)
                .disabled(snapshot == nil)
                .help("Reload")
                .accessibilityLabel("Reload page")
                .accessibilityIdentifier("browser.reload")
            }

            TextField("Search or enter address", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 9, design: .monospaced))
                .focused($addressFocused)
                .onSubmit(navigateToDraft)
                .accessibilityLabel("Address")
                .accessibilityIdentifier("browser.url")

            Button(action: navigateToDraft) {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
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
            .animation(.easeOut(duration: 0.2), value: snapshot.progress)
        } else {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let host = browser.activeHost(for: sessionID), snapshot?.url.isEmpty == false {
            BorrowedWebView(host: host)
                .accessibilityLabel("Web page")
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
    /// between the tab chips and the address bar, so all of the browser's
    /// chrome lives at the top and the page owns everything below it.
    private var controlsBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(BrowserViewport.allCases) { preset in
                    Button {
                        viewportRaw = preset.rawValue
                        browser.defaultViewport = preset.size
                        browser.activeHost(for: sessionID)?.setViewport(preset.size)
                    } label: {
                        if viewportRaw == preset.rawValue {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Text(preset.title)
                        }
                    }
                }
            } label: {
                Label(
                    BrowserViewport(rawValue: viewportRaw)?.title ?? "Desktop",
                    systemImage: "rectangle.ratio.3.to.4"
                )
                .font(.system(size: 8, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(LocusTheme.muted)
            .help("Emulated viewport for the agent's screenshots")
            .accessibilityIdentifier("browser.viewport")

            Spacer()

            Button {
                captureForAnnotation()
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 10))
                    .foregroundStyle(LocusTheme.muted)
            }
            .buttonStyle(.plain)
            .disabled(isCapturing || snapshot?.url.isEmpty != false)
            .help("Capture the page to annotate and attach")
            .accessibilityLabel("Capture page for chat")
            .accessibilityIdentifier("browser.capture")

            Button {
                drawerOpen.toggle()
            } label: {
                Image(systemName: drawerOpen ? "chevron.down.square.fill" : "chevron.up.square")
                    .font(.system(size: 10))
                    .foregroundStyle(drawerOpen ? LocusTheme.ink : LocusTheme.muted)
            }
            .buttonStyle(.plain)
            .help("Console and network")
            .accessibilityLabel("Toggle console and network drawer")
            .accessibilityIdentifier("browser.drawer")

            Button {
                browser.openCurrentTabExternally(sessionID: sessionID)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .foregroundStyle(snapshot == nil ? LocusTheme.muted : LocusTheme.ink)
            }
            .buttonStyle(.plain)
            .disabled(snapshot == nil)
            .help("Open in your default browser")
            .accessibilityLabel("Open in default browser")
            .accessibilityIdentifier("browser.openExternal")

            if let onToggleExpand {
                Button {
                    onToggleExpand()
                } label: {
                    Image(
                        systemName: isExpanded
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(LocusTheme.ink)
                }
                .buttonStyle(.plain)
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
struct BorrowedWebView: NSViewRepresentable {
    let host: OffscreenWebHost

    @MainActor
    final class Coordinator {
        /// Weak: a strong reference would keep an evicted tab's off-screen
        /// panel and web view alive for as long as this view exists.
        weak var lentHost: OffscreenWebHost?
        weak var container: NSView?

        func parkIfStillOwner() {
            guard let lentHost, let container,
                  lentHost.webView.superview === container
            else { return }
            lentHost.park()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if let previous = context.coordinator.lentHost, previous !== host {
            // The displayed tab changed; hand the old page home first.
            context.coordinator.parkIfStillOwner()
        }
        host.lend(to: container)
        context.coordinator.lentHost = host
        context.coordinator.container = container
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.parkIfStillOwner()
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
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
        } else {
            ForEach(log.console) { entry in
                Text("[\(entry.level)] \(entry.message)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(entry.isError ? LocusTheme.coral : LocusTheme.inkSoft)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(entry.id)
            }
            if log.droppedEntries > 0 {
                Text("\(log.droppedEntries) entries dropped while the page was noisy.")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
            }
        }
    }

    @ViewBuilder
    private var networkLines: some View {
        if log.network.isEmpty {
            Text("No requests recorded for this page.")
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
        } else {
            ForEach(log.network) { entry in
                Text(entry.summary)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(entry.ok ? LocusTheme.inkSoft : LocusTheme.coral)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(entry.id)
            }
        }
    }
}
