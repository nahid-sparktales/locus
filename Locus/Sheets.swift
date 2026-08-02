import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var commands: [CommandAction] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return CommandAction.allCases }
        return CommandAction.allCases.filter {
            "\($0.title) \($0.rawValue)".lowercased().contains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(LocusTheme.muted)
                TextField("Run a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .accessibilityIdentifier("palette.search")
                    .onKeyPress(.upArrow) {
                        selection = max(selection - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        selection = min(selection + 1, max(commands.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.return) {
                        runSelected()
                        return .handled
                    }
                Button("esc") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(LocusTheme.paperDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityLabel("Close command palette")
                    .accessibilityIdentifier("palette.close")
            }
            .padding(.horizontal, 15)
            .frame(height: 53)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            if commands.isEmpty {
                Text("No commands match that search.")
                    .font(.system(size: 10))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ScrollViewReader { proxy in
                        LazyVStack(spacing: 3) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                Button {
                                    model.runCommand(command)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: command.symbol)
                                            .font(.system(size: 13))
                                            .foregroundStyle(LocusTheme.muted)
                                            .frame(width: 30, height: 30)
                                            .background(LocusTheme.panel)
                                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .stroke(LocusTheme.line, lineWidth: 1)
                                            }
                                        Text(command.title)
                                            .font(.system(size: 10, weight: .medium))
                                        Spacer()
                                        if index == selection {
                                            Text("↵")
                                                .font(.system(size: 8, design: .monospaced))
                                                .foregroundStyle(LocusTheme.muted)
                                        }
                                        if !command.shortcut.isEmpty {
                                            Text(command.shortcut)
                                                .font(.system(size: 8, design: .monospaced))
                                                .foregroundStyle(LocusTheme.muted)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 44)
                                    .background(index == selection ? LocusTheme.paperDeep.opacity(0.8) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { hovering in
                                    if hovering { selection = index }
                                }
                                .id(index)
                                .accessibilityIdentifier("palette.command.\(command.rawValue)")
                            }
                        }
                        .padding(7)
                        .onChange(of: selection) {
                            proxy.scrollTo(selection)
                        }
                    }
                }
            }

            HStack(spacing: 15) {
                Text("↑↓ Navigate")
                Text("↵ Select")
                Spacer()
                Text("⌘K Close")
            }
            .font(.system(size: 7))
            .foregroundStyle(LocusTheme.muted)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(LocusTheme.paperDeep.opacity(0.7))
            .overlay(alignment: .top) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }
        }
        .frame(width: 520, height: 430)
        .background(LocusTheme.white)
        .onAppear { focused = true }
        .onChange(of: query) {
            selection = 0
        }
        .onExitCommand { dismiss() }
        .background {
            // ⌘K closes the palette, matching the footer hint and the
            // shortcut that opened it.
            Button("") { dismiss() }
                .keyboardShortcut("k", modifiers: .command)
                .buttonStyle(.plain)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func runSelected() {
        let available = commands
        guard !available.isEmpty else { return }
        model.runCommand(available[min(selection, available.count - 1)])
    }
}

struct CheckpointSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Session checkpoints")
                        .font(.system(size: 15, weight: .bold))
                    Text("Save and restore the conversation, tasks, workspace, model, and context pack.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close checkpoints")
                .accessibilityIdentifier("checkpoints.close")
            }
            .padding(16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            HStack(spacing: 8) {
                TextField("Checkpoint name (optional)", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("checkpoints.title")
                Button("Create Checkpoint") {
                    model.createCheckpoint(title: title)
                    title = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .accessibilityIdentifier("checkpoints.create")
            }
            .padding(14)

            if model.checkpoints.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 25))
                        .foregroundStyle(LocusTheme.muted)
                    Text("No checkpoints yet")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Create one before a risky or exploratory turn.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.checkpoints) { checkpoint in
                            HStack(spacing: 11) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(LocusTheme.signal)
                                    .frame(width: 34, height: 34)
                                    .background(LocusTheme.ink)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(checkpoint.title)
                                        .font(.system(size: 10, weight: .bold))
                                        .lineLimit(1)
                                    Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 8))
                                        .foregroundStyle(LocusTheme.muted)
                                }
                                Spacer()
                                Button("Restore") {
                                    model.restore(checkpoint)
                                }
                                .accessibilityIdentifier("checkpoints.restore.\(checkpoint.id)")
                                Button {
                                    model.delete(checkpoint)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(LocusTheme.coral)
                                .help("Delete checkpoint")
                                .accessibilityLabel("Delete \(checkpoint.title)")
                            }
                            .padding(10)
                            .locusCard(radius: 9)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
        .frame(width: 560, height: 500)
        .background(LocusTheme.panel)
        .onExitCommand { dismiss() }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppSettings()
    @State private var localWindow = ""
    @State private var addingAccount: ProviderAccount?
    @State private var editingAccount: ProviderAccount?
    @State private var accountPendingRemoval: ProviderAccount?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Locus Settings")
                        .font(.system(size: 16, weight: .bold))
                    Text("Local agent and preview configuration")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                    model.settingsPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")
                .accessibilityIdentifier("settings.close")
            }
            .padding(17)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            Form {
                Section("Model providers") {
                    Label(
                        "Local Ollama — models installed on this Mac appear in the picker automatically.",
                        systemImage: "bolt.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(LocusTheme.muted)

                    TextField("Local context window in tokens (optional)", text: $localWindow)
                        .accessibilityIdentifier("settings.localContextWindow")

                    Text("Leave empty to use the window Ollama is really running the model in, measured once it is loaded. Set a value to pin one — it is requested as num_ctx and is what compaction budgets against.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(model.providerAccounts) { account in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(
                                    model.accountStatus[account.id]?.isHealthy ?? account.hasKey
                                        ? LocusTheme.success
                                        : LocusTheme.coral
                                )
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(accountDetail(account))
                                    .font(.system(size: 9))
                                    .foregroundStyle(LocusTheme.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Edit") { editingAccount = account }
                                .accessibilityIdentifier("settings.accounts.edit")
                            Button("Remove") { accountPendingRemoval = account }
                                .accessibilityIdentifier("settings.accounts.remove")
                        }
                        .accessibilityIdentifier("settings.accounts.row")
                    }

                    Menu("Add Account…") {
                        ForEach(ProviderKind.allCases) { kind in
                            Button(kind.title) {
                                addingAccount = ProviderAccount(kind: kind)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.accounts.add")

                    Text("Each account keeps its API key in your login keychain. Keys are passed to the local agent in memory, never written to a config file, and only ever sent to their own provider.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Permissions") {
                    Picker("The agent may", selection: Binding(
                        get: { model.permissionMode },
                        set: { model.setPermissionMode($0) }
                    )) {
                        ForEach(PermissionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("settings.permissionMode")

                    Text(model.permissionMode.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(
                            model.permissionMode.isRisky ? LocusTheme.coral : LocusTheme.muted
                        )
                        .fixedSize(horizontal: false, vertical: true)

                    if !model.allowedTools.isEmpty {
                        LabeledContent("Always allowed") {
                            Text(model.allowedTools.joined(separator: ", "))
                                .font(.system(size: 9))
                                .foregroundStyle(LocusTheme.muted)
                        }
                    }

                    Button("Reset session allowances") { model.resetPermissions() }
                        .disabled(model.allowedTools.isEmpty && model.permissionMode == .ask)
                        .accessibilityIdentifier("settings.resetPermissions")

                    Text("Reading, searching and listing inside the workspace never ask. Anything outside it always does, in every mode.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Local agent") {
                    Text("The app includes its own local-agent runtime. These settings are used for custom or development backends.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                    TextField("Backend URL", text: $draft.backendURL)
                        .accessibilityIdentifier("settings.backendURL")
                    TextField("Fallback backend folder", text: $draft.backendRoot)
                        .accessibilityIdentifier("settings.backendRoot")
                    Toggle("Start the local agent automatically", isOn: $draft.launchBackendAutomatically)
                        .accessibilityIdentifier("settings.autoLaunch")
                    HStack {
                        Button("Choose Folder…") { chooseBackendFolder() }
                            .accessibilityIdentifier("settings.chooseBackend")
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: draft.backendRoot))
                        }
                        .accessibilityIdentifier("settings.revealBackend")
                    }
                }

                Section("Preview") {
                    TextField("Preview URL", text: $draft.previewURL)
                        .accessibilityIdentifier("settings.previewURL")
                }

                Section("Notifications") {
                    Toggle(
                        "Notify when a run finishes while Locus is in the background",
                        isOn: $draft.notifyOnCompletion
                    )
                    .accessibilityIdentifier("settings.notifyOnCompletion")
                }

                Section("Status") {
                    LabeledContent("Agent") {
                        Text(connectionLabel)
                            .foregroundStyle(connectionColor)
                    }
                    LabeledContent("Ollama") {
                        Text(model.ollamaOnline ? "Online" : "Unavailable")
                            .foregroundStyle(model.ollamaOnline ? LocusTheme.success : LocusTheme.coral)
                    }
                    // The reason, not just the state: Ollama's own error (a
                    // model too large to load, a dead server) used to be
                    // captured and then shown nowhere.
                    if !model.ollamaOnline,
                       let reason = model.ollamaErrorMessage,
                       !reason.isEmpty
                    {
                        Text(reason)
                            .font(.system(size: 9))
                            .foregroundStyle(LocusTheme.coral)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.ollamaError")
                    }
                    if !model.backendLogHint.isEmpty {
                        Text(model.backendLogHint)
                            .font(.system(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                    model.settingsPresented = false
                }
                .accessibilityIdentifier("settings.cancel")
                Spacer()
                Button("Save") {
                    var saved = draft
                    let typed = localWindow.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.localContextWindow = typed.isEmpty ? nil : Int(typed)
                    model.applySettings(saved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .accessibilityIdentifier("settings.save")
            }
            .padding(15)
            .overlay(alignment: .top) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }
        }
        .frame(width: 560, height: 560)
        .background(LocusTheme.panel)
        .onAppear { draft = model.settings }
        .onExitCommand {
            dismiss()
            model.settingsPresented = false
        }
        // Accounts are saved as they are edited rather than with the rest of
        // the draft: they write the keychain, and Cancel cannot un-write it.
        .sheet(item: $addingAccount) { account in
            AccountEditorView(account: account, isNew: true)
                .environmentObject(model)
        }
        .sheet(item: $editingAccount) { account in
            AccountEditorView(account: account, isNew: false)
                .environmentObject(model)
        }
        .alert(item: $accountPendingRemoval) { account in
            Alert(
                title: Text("Remove \(account.displayName)?"),
                message: Text(
                    account.id.uuidString == model.settings.activeAccountID
                        ? "The API key is deleted from your keychain and Locus switches back to local Ollama. Saved transcripts are kept."
                        : "The API key is deleted from your keychain. Saved transcripts are kept."
                ),
                primaryButton: .destructive(Text("Remove")) {
                    model.removeProviderAccount(account)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func accountDetail(_ account: ProviderAccount) -> String {
        let status = model.accountStatus[account.id]
            ?? (account.hasKey ? .keySaved : .noKey)
        let host = URL(string: RemoteEndpointTester.normalizeBaseURL(account.resolvedBaseURL))?.host
        return [host, status.summary].compactMap { $0 }.joined(separator: " · ")
    }

    private var connectionLabel: String {
        switch model.connectionPhase {
        case .starting: "Starting"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        }
    }

    private var connectionColor: Color {
        switch model.connectionPhase {
        case .starting: LocusTheme.warning
        case .connected: LocusTheme.success
        case .disconnected: LocusTheme.coral
        }
    }

    private func chooseBackendFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the ollama-code backend folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draft.backendRoot)
        if panel.runModal() == .OK, let url = panel.url {
            draft.backendRoot = url.path
        }
    }
}
