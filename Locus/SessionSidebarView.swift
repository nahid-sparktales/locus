import SwiftUI

struct SessionSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sessionToRename: SessionSummary?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            primaryNavigation
            controls

            ScrollView {
                LazyVStack(spacing: 4) {
                    if model.filteredSessions.isEmpty {
                        emptyState
                    } else {
                        SectionLabel(model.showArchivedSessions ? "All sessions" : "Recent")
                        ForEach(model.filteredSessions) { session in
                            SessionRow(
                                session: session,
                                isActive: session.id == model.currentSessionID
                            ) {
                                model.resume(session)
                            }
                            .contextMenu {
                                Button("Rename…") {
                                    renameText = session.displayTitle
                                    sessionToRename = session
                                }
                                .accessibilityIdentifier("session.\(session.id).rename")
                                Button(session.isPinned ? "Unpin" : "Pin") {
                                    model.togglePin(session)
                                }
                                .accessibilityIdentifier("session.\(session.id).pin")
                                Divider()
                                Button("Export Markdown…") {
                                    model.exportSession(session)
                                }
                                .accessibilityIdentifier("session.\(session.id).export")
                                Button(session.isArchived ? "Restore from Archive" : "Archive") {
                                    model.archive(session)
                                }
                                .disabled(session.id == model.currentSessionID)
                                .accessibilityIdentifier("session.\(session.id).archive")
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(maxHeight: .infinity)
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .trailing) {
            Rectangle().fill(LocusTheme.line).frame(width: 1)
        }
        .alert("Rename Session", isPresented: Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )) {
            TextField("Session name", text: $renameText)
                .accessibilityIdentifier("session.rename.input")
            Button("Cancel", role: .cancel) { sessionToRename = nil }
            Button("Save") {
                if let session = sessionToRename {
                    model.renameSession(session, title: renameText)
                }
                sessionToRename = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("session.rename.save")
        } message: {
            Text("Give this conversation a name that is easy to find later.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            BrandMark(compact: true)

            Text("Locus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(LocusTheme.ink)
                .accessibilityIdentifier("sidebar.brand")

            Spacer(minLength: 4)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.sidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Hide sidebar")
            .accessibilityLabel("Hide sidebar")
            .accessibilityIdentifier("sidebar.collapse")
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
    }

    private var primaryNavigation: some View {
        VStack(spacing: 6) {
            JustChatControl(isChatSelected: model.justChatEnabled) { enabled in
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.setJustChatEnabled(enabled)
                }
            }

            Button {
                model.settingsPage = .extensions
                model.settingsPresented = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 12)
                    Text("Plugins & MCP")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 4)
                }
                .foregroundStyle(LocusTheme.inkSoft)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Manage plugins, MCP servers, and skills")
            .accessibilityLabel("Plugins, MCP servers, and skills")
            .accessibilityIdentifier("sidebar.extensions")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            Button {
                model.newSession()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("New chat")
                    Spacer(minLength: 4)
                    Text("⌘N")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LocusTheme.paper)
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(LocusTheme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.newSession")

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LocusTheme.muted)
                TextField("Search sessions", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityLabel("Clear session search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 35)
            .background(LocusTheme.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
            .accessibilityIdentifier("sidebar.search")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "bubble.left")
                .font(.system(size: 18))
                .foregroundStyle(LocusTheme.muted)
            Text(model.searchQuery.isEmpty ? "No saved sessions yet" : "No matching sessions")
                .font(.system(size: 10, weight: .semibold))
            if model.searchQuery.isEmpty {
                Text("Start a conversation and it will appear here.")
                    .font(.system(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 18)
    }

    // MARK: - Footer

    /// Two quiet rows: the workspace selector, then status with everything
    /// else tucked into an overflow menu — the rest of the sidebar stays about
    /// the conversation list.
    private var footer: some View {
        VStack(spacing: 8) {
            workspaceMenu

            HStack(spacing: 8) {
                status
                Spacer(minLength: 4)
                moreMenu
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Settings…") { model.settingsPresented = true }
                .accessibilityIdentifier("sidebar.settings")
            Button("Session Checkpoints…") { model.checkpointPresented = true }
                .accessibilityIdentifier("sidebar.checkpoints")
            Divider()
            Toggle("Show Archived Sessions", isOn: Binding(
                get: { model.showArchivedSessions },
                set: { model.setShowArchived($0) }
            ))
            .accessibilityIdentifier("sidebar.showArchived")
            Button(model.isClearingSessions ? "Clearing Saved Sessions…" : "Clear Saved Sessions…") {
                model.requestClearSavedSessions()
            }
            .disabled(model.isClearingSessions)
            .accessibilityIdentifier("sidebar.clearSessions")
            Divider()
            Button("Reconnect Agent") {
                Task { await model.bootstrap() }
            }
            .accessibilityIdentifier("sidebar.reconnect")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("More sidebar actions")
        .accessibilityLabel("More sidebar actions")
        .accessibilityIdentifier("sidebar.more")
    }

    private var workspaceMenu: some View {
        Menu {
            Button("Choose Workspace…") { model.chooseWorkspace() }
            Button("New Workspace…") { model.createWorkspace() }
                .accessibilityIdentifier("workspace.new")
            Button("Reveal in Finder") { model.openWorkspaceInFinder() }
            if !model.recentWorkspaceProfiles.isEmpty {
                Divider()
                Section("Recent Workspaces") {
                    ForEach(model.recentWorkspaceProfiles) { profile in
                        Button {
                            model.switchWorkspace(to: profile.path)
                        } label: {
                            Label(
                                profile.displayName,
                                systemImage: profile.isAvailable ? "folder" : "exclamationmark.triangle"
                            )
                        }
                        .disabled(!profile.isAvailable)
                        .accessibilityIdentifier("workspace.profile.\(profile.path)")
                    }
                }
                if model.recentWorkspaceProfiles.contains(where: { !$0.isAvailable }) {
                    Button("Remove Missing Entries") {
                        for profile in model.recentWorkspaceProfiles where !profile.isAvailable {
                            model.removeWorkspaceProfile(profile.path)
                        }
                    }
                    .accessibilityIdentifier("workspace.removeMissingProfiles")
                }
            }
            Divider()
            Button("Settings…") { model.settingsPresented = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: model.workspacePath).lastPathComponent)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                    Text("Workspace")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(LocusTheme.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Workspace menu")
        .accessibilityIdentifier("sidebar.workspaceMenu")
    }

    private var status: some View {
        HStack(spacing: 9) {
            statusPill(
                label: backendStatusText,
                color: backendStatusColor,
                identifier: "sidebar.backendStatus"
            )
            statusPill(
                label: model.providerLabel,
                color: model.ollamaOnline ? LocusTheme.success : LocusTheme.coral,
                identifier: "sidebar.ollamaStatus"
            )
        }
        .font(.system(size: 8))
        .foregroundStyle(LocusTheme.muted)
        .frame(height: 22)
    }

    private func statusPill(label: String, color: Color, identifier: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var backendStatusColor: Color {
        switch model.connectionPhase {
        case .starting: LocusTheme.warning
        case .connected: LocusTheme.success
        case .disconnected: LocusTheme.coral
        }
    }

    private var backendStatusText: String {
        switch model.connectionPhase {
        case .starting: "Agent starting"
        case .connected: "Agent ready"
        case .disconnected: "Agent offline"
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(LocusTheme.muted.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 5)
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isActive ? "sparkles" : "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? LocusTheme.ink : LocusTheme.muted)
                    .frame(width: 27, height: 27)
                    .background(isActive ? LocusTheme.signal : LocusTheme.line.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                    Text(session.date, style: .relative)
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer(minLength: 4)
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                if session.isArchived {
                    Image(systemName: "archivebox.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                if isActive {
                    Circle()
                        .fill(LocusTheme.success)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 49)
            .background(isActive ? LocusTheme.panel : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isActive ? LocusTheme.line : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(session.displayTitle)")
        .accessibilityIdentifier("session.\(session.id)")
    }
}
