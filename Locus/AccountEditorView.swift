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

    private var kind: ProviderKind { account.kind }

    private var canSave: Bool {
        // A key is required to reach a provider; an endpoint that has one
        // saved already does not need it typed again.
        let hasKey = keyStored || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        return hasKey && !resolvedBaseURL.isEmpty
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
                        .font(.system(size: 16, weight: .bold))
                    Text(
                        kind.vendorName.isEmpty
                            ? "An OpenAI-compatible endpoint"
                            : "Models served by \(kind.vendorName)"
                    )
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
                .accessibilityLabel("Close account editor")
                .accessibilityIdentifier("accountEditor.close")
            }
            .padding(17)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            Form {
                Section("Account") {
                    TextField("Name (e.g. Work)", text: $name)
                        .accessibilityIdentifier("accountEditor.name")

                    Text("Names tell two accounts for the same provider apart in the model picker.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)

                    if kind.allowsBaseURLOverride {
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .accessibilityIdentifier("accountEditor.baseURL")
                    }

                    SecureField(
                        keyStored && apiKey.isEmpty ? "Saved in your keychain" : kind.keyPlaceholder,
                        text: $apiKey
                    )
                    .accessibilityIdentifier("accountEditor.apiKey")

                    if !kind.keyDocsURL.isEmpty, let url = URL(string: kind.keyDocsURL) {
                        Link("Get an API key from \(kind.vendorName)", destination: url)
                            .font(.system(size: 9))
                    }

                    // Why this key and not a subscription — read before the
                    // user tries a key that was never going to work here.
                    if let note = kind.note {
                        Text(note.text)
                            .font(.system(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("accountEditor.note")
                        if note.hasLink, let noteURL = URL(string: note.linkURL) {
                            Link(note.linkTitle, destination: noteURL)
                                .font(.system(size: 9))
                        }
                    }

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
                            .font(.system(size: 9))
                            .foregroundStyle(testFailed ? LocusTheme.coral : LocusTheme.success)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("The key is kept in your login keychain and passed to the local agent in memory. It is never written to a config file, and it is only ever sent to this provider.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
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
        }
    }

    private func save() {
        var updated = account
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.baseURLOverride = kind.allowsBaseURLOverride
            ? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : account.baseURLOverride
        if updated.preferredModel.isEmpty {
            updated.preferredModel = kind.probeModel
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveProviderAccount(updated, apiKey: trimmedKey.isEmpty ? nil : trimmedKey)
        dismiss()
    }

    /// Side-effect free, like the endpoint test it grew out of: it reads the
    /// typed values and never commits them.
    private func testConnection() {
        isTesting = true
        testResult = nil
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Keychain.get(account: account.keychainAccount) ?? "")
            : apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = resolvedBaseURL
        let probeModel = account.preferredModel.isEmpty ? kind.probeModel : account.preferredModel
        Task {
            let outcome = await RemoteEndpointTester.test(
                baseURL: base,
                model: probeModel,
                apiKey: key,
                kind: kind
            )
            isTesting = false
            testFailed = !outcome.ok
            testResult = outcome.message
        }
    }
}
