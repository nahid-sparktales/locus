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
            )
        )
    }
}

struct BrowserPanel: View {
    @ObservedObject var browser: BrowserService
    let sessionID: String
    let homeURL: URL?
    @Binding var viewportRaw: String

    @State private var draft = ""
    @State private var drawerOpen = false
    @FocusState private var addressFocused: Bool

    private var snapshot: BrowserService.TabSnapshot? {
        browser.activeSnapshot(for: sessionID)
    }

    private var sessionTabs: [BrowserService.TabSnapshot] {
        browser.snapshots(for: sessionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            if sessionTabs.count > 1 {
                tabChips
            }
            toolbar
            progressLine
            content
            if drawerOpen, let log = browser.activeLog(for: sessionID) {
                CaptureDrawer(log: log)
            }
            footer
        }
        .onChange(of: snapshot?.url) { _, updated in
            // The address bar mirrors the page unless the user is typing.
            if !addressFocused, let updated { draft = updated }
        }
        .onAppear {
            if let url = snapshot?.url, !url.isEmpty { draft = url }
        }
    }

    // MARK: - Chrome

    private var tabChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessionTabs) { tab in
                    chip(for: tab)
                }
                Button {
                    browser.userNewTab(sessionID: sessionID)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("New tab")
                .accessibilityLabel("New browser tab")
                .accessibilityIdentifier("browser.tabs.new")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) tab")
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
            if browser.windowHosted {
                InspectorPlaceholder(
                    symbol: "macwindow",
                    title: "Browsing in the Browser window",
                    message: "The page is showing in its own window. Close it to bring browsing back into this panel.",
                    identifier: "browser.detached"
                )
            } else {
                BorrowedWebView(host: host)
                    .accessibilityLabel("Web page")
            }
        } else {
            InspectorPlaceholder(
                symbol: "globe",
                title: "Browser",
                message: placeholderMessage,
                identifier: "browser.empty"
            )
        }
    }

    private var placeholderMessage: String {
        if let homeURL {
            return "Enter an address, or press Go to open \(homeURL.absoluteString).\n\nThe agent browses here too: pages it opens appear in this panel."
        }
        return "Enter an address to browse.\n\nThe agent browses here too: pages it opens appear in this panel."
    }

    private var footer: some View {
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
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .top) {
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
/// no longer owns — SwiftUI does not order a detached window's lend against
/// this view's teardown within a transaction, and an unconditional park would
/// yank the page back out of whoever borrowed it since.
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
