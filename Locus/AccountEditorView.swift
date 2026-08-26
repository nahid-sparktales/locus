import AppKit
import SwiftUI

/// Adds or edits one provider account.
///
/// The account and its key are handed back to `AppModel` on Save — nothing is
/// written while the sheet is open, so Cancel really does leave no trace.
struct AccountEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// The account being edited, or a fresh one for the chosen provider.
    let account: ProviderAccount
    let isNew: Bool

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var keyStored = false
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var contextWindow = ""
    @State private var nativeMode = true
    @State private var webSearch = false
    @State private var reasoningEffort = ""
    @State private var focusedField: FocusedField?

    private enum FocusedField: Hashable {
        case name
        case baseURL
        case apiKey
        case contextWindow
    }

    private var kind: ProviderKind { account.kind }

    private var canSave: Bool {
        if kind == .chatGPT { return true }
        // A key is required to reach a provider; an endpoint that has one
        // saved already does not need it typed again.
        let hasKey = keyStored || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = key.isEmpty && keyStored ? "saved-key" : key
        return hasKey
            && !resolvedBaseURL.isEmpty
            && RemoteEndpointTester.securityError(
                baseURL: resolvedBaseURL,
                apiKey: effectiveKey
            ) == nil
    }

    private var resolvedBaseURL: String {
        let typed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? kind.defaultBaseURL : typed
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isNew ? "Add \(kind.marketingName) Account" : "Edit \(account.displayName)")
                        .font(.locus(size: 16, weight: .bold))
                    Text(
                        kind == .chatGPT
                            ? "Use included usage from your ChatGPT plan"
                            : kind.vendorName.isEmpty
                            ? "An OpenAI-compatible endpoint"
                            : "Models served by \(kind.vendorName)"
                    )
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.locus())
                .accessibilityLabel("Close account editor")
                .accessibilityIdentifier("accountEditor.close")
            }
            .padding(17)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            Form {
                Section("Account") {
                    inputRow(
                        prompt: "Name (e.g. Work)",
                        text: $name,
                        field: .name,
                        identifier: "accountEditor.name"
                    )

                    Text("Names tell two accounts for the same provider apart in the model picker.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)

                    if kind == .chatGPT {
                        chatGPTControls
                    } else {
                        if kind.allowsBaseURLOverride {
                            inputRow(
                                prompt: "https://api.example.com/v1",
                                text: $baseURL,
                                field: .baseURL,
                                identifier: "accountEditor.baseURL"
                            )
                        }

                    inputRow(
                        prompt: keyStored && apiKey.isEmpty ? "Saved on this Mac" : kind.keyPlaceholder,
                        text: $apiKey,
                        field: .apiKey,
                        identifier: "accountEditor.apiKey",
                        secure: true
                    )

                    if !kind.keyDocsURL.isEmpty, let url = URL(string: kind.keyDocsURL) {
                        Link("Get an API key from \(kind.vendorName)", destination: url)
                            .font(.locus(size: 9))
                    }

                    // Why this key and not a subscription — read before the
                    // user tries a key that was never going to work here.
                    if let note = kind.note {
                        Text(note.text)
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("accountEditor.note")
                        if note.hasLink, let noteURL = URL(string: note.linkURL) {
                            Link(note.linkTitle, destination: noteURL)
                                .font(.locus(size: 9))
                        }
                    }

                    inputRow(
                        prompt: windowPlaceholder,
                        text: $contextWindow,
                        field: .contextWindow,
                        identifier: "accountEditor.contextWindow"
                    )

                    Text(windowHelp)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("Test Connection") { testConnection() }
                            .disabled(isTesting || resolvedBaseURL.isEmpty)
                            .accessibilityIdentifier("accountEditor.test")
                        if keyStored {
                            Button("Remove Key") {
                                model.removeProviderAccountKey(account)
                                apiKey = ""
                                keyStored = false
                                testResult = "API key removed."
                                testFailed = false
                            }
                            .accessibilityIdentifier("accountEditor.removeKey")
                        }
                        if isTesting {
                            ProgressView().controlSize(.small)
                        }
                    }

                    if let testResult {
                        Text(testResult)
                            .font(.locus(size: 9))
                            .foregroundStyle(testFailed ? LocusTheme.coral : LocusTheme.success)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("The key is written to \(CredentialStore.displayPath), readable only by your macOS user account, and passed to the local agent in memory. It is only ever sent to this provider. Anything else running as you can read that file.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("accountEditor.cancel")
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityIdentifier("accountEditor.save")
            }
            .padding(17)
            .overlay(alignment: .top) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }
        }
        .frame(width: 520, height: 480)
        .background(LocusTheme.panel)
        .onExitCommand { dismiss() }
        .onAppear {
            name = account.name
            baseURL = account.baseURLOverride ?? ""
            keyStored = account.hasKey
            contextWindow = account.contextWindow.map(String.init) ?? ""
            if kind == .chatGPT {
                nativeMode = account.codexNativeModeEnabled
                webSearch = account.codexWebSearchEnabled
                reasoningEffort = account.codexReasoningEffortValue
                Task { await model.refreshChatGPTAccount(for: account) }
            }
        }
    }

    @ViewBuilder
    private var chatGPTControls: some View {
        let status = model.chatGPTAccounts[account.id]
        VStack(alignment: .leading, spacing: 10) {
            if let status, status.status == "signed_in" {
                Label("Signed in", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(LocusTheme.success)
                if let email = status.email, !email.isEmpty {
                    Text(email).font(.locus(size: 10, weight: .semibold))
                }
                if let plan = status.planType, !plan.isEmpty {
                    Text("\(plan.replacingOccurrences(of: "_", with: " ").capitalized) plan")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                HStack {
                    Button("Refresh") {
                        Task {
                            await model.refreshChatGPTAccount(
                                for: account,
                                forceTokenRefresh: true
                            )
                        }
                    }
                    Button("Sign Out") {
                        Task { await model.signOutChatGPT(from: account) }
                    }
                }
            } else if model.chatGPTLoginIDs[account.id] != nil {
                Label("Finish signing in in your browser", systemImage: "safari")
                    .font(.locus(size: 10, weight: .semibold))
                HStack {
                    Button("Refresh Status") {
                        Task { await model.refreshChatGPTAccount(for: account) }
                    }
                    Button("Cancel Login") {
                        Task { await model.cancelChatGPTLogin(for: account) }
                    }
                }
            } else if model.chatGPTComponentMissing {
                componentDownload
            } else {
                if let message = status?.message, !message.isEmpty {
                    Text(message)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Sign in with ChatGPT") {
                    Task { await model.startChatGPTLogin(for: account) }
                }
                .disabled(status?.runtimeAvailable == false)
                .accessibilityIdentifier("accountEditor.chatGPT.signIn")
            }

            Toggle("Codex-native mode", isOn: $nativeMode)
                .accessibilityIdentifier("accountEditor.chatGPT.nativeMode")
            Text("Answers match OpenAI's Codex: native prompt and tools, no Locus memory or skills on this account's chats. Changing this restarts conversation context.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Web search", isOn: $webSearch)
                .accessibilityIdentifier("accountEditor.chatGPT.webSearch")
            Text("Lets the model use OpenAI's web search (sends search queries to OpenAI).")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Reasoning effort", selection: $reasoningEffort) {
                Text("Default").tag("")
                ForEach(reasoningEffortOptions, id: \.self) { effort in
                    Text(effort.capitalized).tag(effort)
                }
            }
            .accessibilityIdentifier("accountEditor.chatGPT.reasoningEffort")

            Text(
                "Authentication is managed by OpenAI's bundled agent runtime. "
                + "Locus never reads or stores its OAuth tokens, and this route never falls back to paid API usage."
            )
            .font(.locus(size: 9))
            .foregroundStyle(LocusTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The efforts the account's preferred model supports, from the fetched
    /// catalog; a fixed list stands in before the catalog has arrived. The
    /// stored choice is kept selectable even when the catalog drops it.
    private var reasoningEffortOptions: [String] {
        var efforts = model.accountModelCatalogs[account.id]?
            .first(where: { $0.id == account.preferredModel })?
            .supportedReasoningEfforts?
            .map(\.effort) ?? []
        if efforts.isEmpty {
            efforts = ["minimal", "low", "medium", "high", "xhigh"]
        }
        if !reasoningEffort.isEmpty, !efforts.contains(reasoningEffort) {
            efforts.append(reasoningEffort)
        }
        return efforts
    }

#if LOCUS_APP_STORE
    /// The App Store build bundles the helpers, so this state is unreachable.
    @ViewBuilder
    private var componentDownload: some View { EmptyView() }
#else
    /// Offered in place of the sign-in button when the ChatGPT-plan helpers
    /// have not been fetched yet. The prompt lives at the moment of need rather
    /// than in a downloads screen nobody would go looking for.
    @ViewBuilder
    private var componentDownload: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.codexComponent.state {
            case .idle:
                Text(
                    "Using a ChatGPT plan needs a one-time component from SparkTales. "
                    + "It is about 100 MB to download and stays on this Mac until you remove it."
                )
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                Button("Download and Continue") {
                    Task { await model.installCodexComponent(for: account) }
                }
                .accessibilityIdentifier("accountEditor.chatGPT.downloadComponent")
            case .checking:
                progressRow("Checking for the component…", fraction: nil)
            case let .downloading(received, total):
                progressRow(
                    "Downloading \(byteLabel(received)) of \(byteLabel(total))…",
                    fraction: total > 0 ? Double(received) / Double(total) : nil
                )
                Button("Cancel") { model.codexComponent.cancel() }
            case .verifying:
                progressRow("Verifying the signature…", fraction: nil)
            case .installing:
                progressRow("Installing…", fraction: nil)
            case let .installed(version):
                Label("ChatGPT plan support \(version) installed", systemImage: "checkmark.circle.fill")
                    .font(.locus(size: 10, weight: .semibold))
                    .foregroundStyle(LocusTheme.success)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    Task { await model.installCodexComponent(for: account) }
                }
                .accessibilityIdentifier("accountEditor.chatGPT.retryComponent")
            }
        }
    }

    @ViewBuilder
    private func progressRow(_ label: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func byteLabel(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB]
        return formatter.string(fromByteCount: bytes)
    }
#endif

    /// macOS `Form` treats a text field's title as a leading form label and
    /// places the actual editor in the trailing column. Keep the prompt inside
    /// one full-width editor and make the complete row focus it.
    @ViewBuilder
    private func inputRow(
        prompt: String,
        text: Binding<String>,
        field: FocusedField,
        identifier: String,
        secure: Bool = false
    ) -> some View {
        HStack(spacing: 0) {
            LeadingAccountTextField(
                text: text,
                prompt: prompt,
                secure: secure,
                isFocused: Binding(
                    get: { focusedField == field },
                    set: { wantsFocus in
                        if wantsFocus {
                            focusedField = field
                        } else if focusedField == field {
                            focusedField = nil
                        }
                    }
                ),
                identifier: identifier
            )
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .accessibilityLabel(prompt)
            .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = field }
    }

    private var windowPlaceholder: String {
        if let published = kind.publishedContextWindow(for: account.preferredModel) {
            return "Context window — \(published.formatted()) by default"
        }
        return "Context window in tokens (optional)"
    }

    private var windowHelp: String {
        if kind.publishedContextWindow(for: account.preferredModel) != nil {
            return """
            Locus uses this provider's published window for the selected model. \
            Set a value to override it — the meter and automatic compaction both \
            budget against whatever is used here.
            """
        }
        return """
        This provider advertises no window, so without a value here the meter \
        shows a plain token count and automatic compaction stays off.
        """
    }

    private func save() {
        if kind == .chatGPT {
            var updated = account
            updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if updated.preferredModel.isEmpty {
                updated.preferredModel = kind.probeModel
            }
            updated.baseURLOverride = nil
            updated.contextWindow = nil
            updated.codexNativeMode = nativeMode
            updated.codexWebSearch = webSearch
            updated.codexReasoningEffort = reasoningEffort
            if model.saveProviderAccount(updated, apiKey: nil) {
                dismiss()
            }
            return
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = trimmedKey.isEmpty && keyStored ? "saved-key" : trimmedKey
        if let error = RemoteEndpointTester.securityError(
            baseURL: resolvedBaseURL,
            apiKey: effectiveKey
        ) {
            testResult = error
            testFailed = true
            return
        }
        var updated = account
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.baseURLOverride = kind.allowsBaseURLOverride
            ? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : account.baseURLOverride
        if updated.preferredModel.isEmpty {
            updated.preferredModel = kind.probeModel
        }
        // Empty means "use the published figure"; a number overrides it.
        let typed = contextWindow.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.contextWindow = typed.isEmpty ? nil : Int(typed)
        if model.saveProviderAccount(
            updated,
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey
        ) {
            dismiss()
        }
    }

    /// Side-effect free, like the endpoint test it grew out of: it reads the
    /// typed values and never commits them.
    private func testConnection() {
        isTesting = true
        testResult = nil
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let usedSavedCredential = typedKey.isEmpty
        let key = usedSavedCredential
            ? (CredentialStore.get(account: account.credentialAccount) ?? "")
            : typedKey
        let base = resolvedBaseURL
        let probeModel = account.preferredModel.isEmpty ? kind.probeModel : account.preferredModel
        Task {
            let outcome = await RemoteEndpointTester.test(
                baseURL: base,
                model: probeModel,
                apiKey: key,
                kind: kind
            )
            var message = outcome.message
            var failed = !outcome.ok
            if outcome.ok {
                switch await model.reconnectAfterSuccessfulConnectionTest(
                    account: account,
                    usedSavedCredential: usedSavedCredential
                ) {
                case .notNeeded:
                    break
                case .saveRequired:
                    message += " Save this key to reconnect Locus."
                case .reconnected:
                    message += " Locus reconnected this account."
                case .reconnectFailed:
                    failed = true
                    message += " The provider accepted the key, but Locus could not reconnect its local agent. Try Reconnect Agent."
                }
            }
            isTesting = false
            testFailed = failed
            testResult = message
        }
    }
}

/// SwiftUI's macOS `Form` can hand its shared field editor the row's trailing
/// alignment even when the `TextField` says `.leading`. Configure the native
/// editor directly so the caret, typing, and pasted text always originate on
/// the left and advance toward the right.
private struct LeadingAccountTextField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let secure: Bool
    @Binding var isFocused: Bool
    let identifier: String

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LeadingAccountTextField

        init(parent: LeadingAccountTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            Self.configure(editor: editor)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.isFocused = false
        }

        static func configure(editor: NSTextView) {
            editor.alignment = .left
            editor.baseWritingDirection = .leftToRight
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.alignment = .left
        field.baseWritingDirection = .leftToRight
        field.userInterfaceLayoutDirection = .leftToRight
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.setAccessibilityIdentifier(identifier)
        field.alignment = .left
        field.baseWritingDirection = .leftToRight
        field.userInterfaceLayoutDirection = .leftToRight

        if field.stringValue != text {
            field.stringValue = text
        }

        if let editor = field.currentEditor() as? NSTextView {
            Coordinator.configure(editor: editor)
        } else if isFocused {
            DispatchQueue.main.async { [weak field] in
                guard let field, field.window?.makeFirstResponder(field) == true else { return }
                if let editor = field.currentEditor() as? NSTextView {
                    Coordinator.configure(editor: editor)
                }
            }
        }
    }
}
