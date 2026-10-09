import AppKit
import SwiftUI

struct IdentityVaultAPIKeysView: View {
    @Environment(\.locusViewColors) private var viewColors
    @ObservedObject var vault: IdentityVaultModel
    @ObservedObject private var store: IdentityVaultStore

    init(vault: IdentityVaultModel) {
        self.vault = vault
        self.store = vault.store
    }

    var body: some View {
        let query = vault.query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Search labels only: a guessed key must not reveal whether it is saved.
        let items = store.apiKeys.filter {
            query.isEmpty || ($0.name + " " + $0.service).localizedCaseInsensitiveContains(query)
        }
        Group {
            if items.isEmpty && !query.isEmpty {
                ContentUnavailableView {
                    Label("No matching API keys", systemImage: "magnifyingglass")
                } description: {
                    Text("Search by name or service.")
                } actions: {
                    Button("Clear search") { vault.query = "" }
                }
            } else if store.apiKeys.isEmpty {
                ContentUnavailableView {
                    Label("Your API keys, kept private", systemImage: "key.horizontal")
                } description: {
                    Text("Save a key with a name and service so it is easy to find. Keys stay encrypted on this Mac and are not included in agent context.")
                } actions: {
                    Button("Add API Key", systemImage: "plus") { vault.apiKeyEditor = .init() }
                }
            } else {
                List(items) { record in
                    HStack(spacing: 14) {
                        Image(systemName: "key.horizontal").font(.title2)
                            .frame(width: 40, height: 40)
                            .background(viewColors.surfaceCard, in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.name).font(.headline)
                            if !record.service.isEmpty {
                                Text(record.service).font(.subheadline).foregroundStyle(viewColors.textSecondary)
                            }
                            Text("••••••••••••").font(.system(.body, design: .monospaced))
                                .foregroundStyle(viewColors.textSecondary)
                                .accessibilityLabel("API key hidden")
                            Text("Updated \(record.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(viewColors.textTertiary)
                        }
                        Spacer()
                        Button("Copy key", systemImage: "doc.on.doc") { vault.copyAPIKey(id: record.id) }
                            .accessibilityLabel("Copy key for \(record.name)")
                        Button("Edit") { vault.apiKeyEditor = record }
                            .accessibilityLabel("Edit \(record.name)")
                    }.padding(.vertical, 10)
                }.scrollContentBackground(.hidden)
            }
        }
    }
}

struct IdentityVaultAPIKeyEditor: View {
    @Environment(\.locusViewColors) private var viewColors
    @Environment(\.dismiss) private var dismiss
    @State var record: IdentityVaultAPIKey
    let isNew: Bool
    let save: (IdentityVaultAPIKey) throws -> Void
    let onDelete: () throws -> Void
    @State private var revealed = false
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(isNew ? "Add API Key" : "Edit API Key", systemImage: "key.horizontal")
                .font(.title2.bold())
            Text("Only you can reveal or copy this key here. Saving it does not connect a provider or share it with agents.")
                .font(.subheadline).foregroundStyle(viewColors.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.headline)
                TextField("For example, Development key", text: $record.name)
                    .accessibilityIdentifier("identity.apiKey.name")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Service (optional)").font(.headline)
                TextField("Provider or service name", text: $record.service)
                    .accessibilityIdentifier("identity.apiKey.service")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("API key").font(.headline)
                HStack {
                    Group {
                        if revealed { TextField("Paste your API key", text: $record.secret) }
                        else { SecureField("Paste your API key", text: $record.secret) }
                    }
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("identity.apiKey.secret")
                    Button { revealed.toggle() } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(revealed ? "Hide API key" : "Show API key")
                    .help(revealed ? "Hide API key" : "Show API key")
                    .accessibilityIdentifier("identity.apiKey.reveal")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes (optional)").font(.headline)
                TextField("Purpose or usage notes", text: $record.notes, axis: .vertical)
                    .lineLimit(3...5)
                    .accessibilityIdentifier("identity.apiKey.notes")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(viewColors.dangerForeground)
            }
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if !isNew {
                    Button("Delete API Key", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Save API Key") {
                    do { try save(record) } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).tint(viewColors.ink)
                .disabled(record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || record.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("identity.apiKey.save")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24).frame(width: 590)
        .background(viewColors.paper).foregroundStyle(viewColors.ink)
        .modifier(IdentityPrivateSurface())
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            revealed = false
        }
        .onDisappear { revealed = false; record.secret = "" }
        .alert("Delete this API key?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                do { try onDelete() } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("This removes the saved key from your vault. To revoke it, use the service that issued it.")
        }
    }
}
