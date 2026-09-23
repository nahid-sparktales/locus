import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SocialStudioStore: ObservableObject {
    @Published private(set) var document = SocialStudioDocument()
    @Published private(set) var accounts: [OpenPostAccount] = []
    @Published private(set) var publications: [OpenPostPublication] = []
    @Published private(set) var busy = false
    @Published private(set) var lastSynced: Date?
    @Published var error: String?
    @Published var notice: String?
    private(set) var revoked = false
    private var loadFailed = false
    let workspace: String
    let fileURL: URL
    private let credentials: any ConnectorCredentialStoring
    private let session: URLSession?

    init(workspace: String, applicationSupport: URL = NotesStore.applicationSupportDirectory,
         credentials: any ConnectorCredentialStoring = ConnectorCredentialStore.shared, session: URLSession? = nil) {
        self.workspace = SessionSummary.canonicalWorkspacePath(workspace)
        self.credentials = credentials; self.session = session
        let hash = SHA256.hash(data: Data(self.workspace.utf8)).map { String(format: "%02x", $0) }.joined()
        fileURL = applicationSupport.appendingPathComponent(AppEdition.current.displayName, isDirectory: true)
            .appendingPathComponent("Social Studio", isDirectory: true).appendingPathComponent(hash + ".json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                guard data.count <= 16 * 1024 * 1024 else { throw SocialStudioError.message("The Social Studio file is too large to open.") }
                let saved = try JSONDecoder().decode(SocialStudioDocument.self, from: data)
                guard saved.version == 1 else { throw SocialStudioError.message("This Social Studio file needs a newer Locus version.") }
                document = saved
            } catch {
                loadFailed = true
                self.error = "Couldn't read your Social Studio data. The original file has been preserved. \(error.localizedDescription)"
            }
        }
    }

    private func commit(_ next: SocialStudioDocument) throws {
        guard !revoked, !loadFailed else { throw SocialStudioError.message("Social Studio is unavailable. Reopen the plugin or restore its data file.") }
        let data = try JSONEncoder().encode(next)
        guard next.drafts.count <= 2_000, data.count <= 16 * 1024 * 1024 else {
            throw SocialStudioError.message("Social Studio is full. Export and remove some local drafts before adding more.")
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        document = next
    }

    @discardableResult
    func save(_ draft: SocialDraft) -> Bool {
        do {
            guard !busy else { throw SocialStudioError.message("Wait for the OpenPost request to finish before changing this draft.") }
            guard draft.title.count <= 200, draft.text.count <= 50_000,
                  draft.variants.values.allSatisfy({ $0.count <= 50_000 }) else {
                throw SocialStudioError.message("Keep titles under 200 characters and each post under 50,000 characters.")
            }
            var next = document; var value = draft; value.updatedAt = Date()
            if let index = next.drafts.firstIndex(where: { $0.id == draft.id }) {
                guard next.drafts[index].handoff == nil else { throw SocialStudioError.message("This draft has been handed to OpenPost. Duplicate it to make a new version.") }
                next.drafts[index] = value
            } else { next.drafts.insert(value, at: 0) }
            try commit(next); error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func saveBrand(_ brand: SocialBrand) -> Bool {
        do {
            var next = document; next.brand = brand
            try commit(next); return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func remove(_ id: UUID) {
        guard !busy else { return }
        do {
            var next = document; next.drafts.removeAll { $0.id == id }
            try commit(next)
        } catch { self.error = error.localizedDescription }
    }

    func connect(origin: String, token: String, workspace: OpenPostWorkspace) throws {
        guard !busy, !revoked, !loadFailed else { throw SocialStudioError.message("Social Studio is unavailable or still finishing a request.") }
        let origin = try OpenPostClient.validatedOrigin(origin).absoluteString
        let old = document.connection
        let id = "social-studio." + UUID().uuidString
        try credentials.save(["token": token], for: id)
        do {
            var next = document
            next.connection = .init(origin: origin, workspaceID: workspace.id, workspaceName: workspace.name, credentialID: id)
            try commit(next)
        } catch { try? credentials.delete(for: id); throw error }
        if let old { try? credentials.delete(for: old.credentialID) }
        accounts = []; publications = []; lastSynced = nil
    }

    func disconnect() {
        guard !busy, !revoked, !loadFailed, let connection = document.connection else { return }
        do {
            try credentials.delete(for: connection.credentialID)
            var next = document; next.connection = nil; try commit(next)
            accounts = []; publications = []; lastSynced = nil
        } catch { self.error = error.localizedDescription }
    }

    private func client() throws -> (OpenPostClient, SocialConnection) {
        guard !revoked, let connection = document.connection,
              let token = try credentials.load(for: connection.credentialID)?["token"] else {
            throw SocialStudioError.message("Connect OpenPost in Accounts first.")
        }
        return (try OpenPostClient(origin: connection.origin, token: token, session: session), connection)
    }

    func refresh() async {
        guard !busy, !revoked, document.connection != nil else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let (client, connection) = try client()
            async let fetchedAccounts = client.accounts(workspaceID: connection.workspaceID)
            async let fetchedPosts = client.publications(workspaceID: connection.workspaceID)
            let result = try await (fetchedAccounts, fetchedPosts)
            guard !revoked, document.connection == connection else { return }
            accounts = result.0; publications = result.1; lastSynced = Date()
        } catch { self.error = error.localizedDescription }
    }

    func sendDraft(_ id: UUID, accountIDs: Set<String>) async {
        guard !busy, !revoked else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            let (client, connection) = try client()
            guard let index = document.drafts.firstIndex(where: { $0.id == id }) else { return }
            var draft = document.drafts[index]
            if draft.handoff == nil {
                let selected = accounts.filter { accountIDs.contains($0.id) && $0.isActive }
                guard selected.count == accountIDs.count else { throw SocialStudioError.message("An account is unavailable. Refresh Accounts and choose again.") }
                let body = try OpenPostClient.publicationBody(draft: draft, workspaceID: connection.workspaceID, accounts: selected)
                draft.handoff = .init(origin: connection.origin, workspaceID: connection.workspaceID,
                                      key: "locus-draft-" + UUID().uuidString, body: body)
                var next = document; next.drafts[index] = draft; try commit(next)
            }
            guard let handoff = draft.handoff, handoff.origin == connection.origin, handoff.workspaceID == connection.workspaceID else {
                throw SocialStudioError.message("This draft belongs to another OpenPost workspace. Reconnect that workspace or duplicate the draft.")
            }
            guard handoff.publicationID == nil else { notice = "This draft is already in OpenPost. Find it in Activity."; return }
            let publication: OpenPostPublication = try await client.request(["publications"], method: "POST", body: handoff.body, key: handoff.key)
            guard !revoked else { return }
            var next = document
            next.drafts[index].handoff?.publicationID = publication.id
            try commit(next)
            publications.removeAll { $0.id == publication.id }; publications.insert(publication, at: 0)
            notice = "Draft sent to OpenPost. Review it in Activity to schedule or publish."
        } catch { self.error = error.localizedDescription }
    }

    /// The native confirmation presents the exact loaded revision. Never fetch
    /// a newer revision and implicitly authorize changed content for publication.
    func perform(_ action: String, publication: OpenPostPublication) async {
        guard !busy, !revoked, ["schedule", "publish-now", "cancel"].contains(action) else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            let (client, connection) = try client()
            guard publication.workspaceId == connection.workspaceID else { throw SocialStudioError.message("This publication belongs to another workspace.") }
            if action == "schedule" {
                guard let date = publication.scheduledDate, date > Date() else {
                    throw SocialStudioError.message("Choose a future schedule in OpenPost, then refresh Activity.")
                }
            }
            if action != "cancel" {
                let validation: OpenPostValidation = try await client.request(["publications", publication.id, "validate"], method: "POST", body: Data("{}".utf8))
                guard validation.valid else {
                    throw SocialStudioError.message("OpenPost validation: " + (validation.issues ?? []).map(\.message).joined(separator: " · "))
                }
            }
            guard !revoked else { return }
            let body = try JSONSerialization.data(withJSONObject: ["expected_revision": publication.revision])
            let result: OpenPostActionResult = try await client.request(["publications", publication.id, action], method: "POST", body: body,
                key: "locus-\(publication.id)-\(publication.revision)-\(action)")
            guard !revoked else { return }
            notice = action == "cancel" ? "Cancellation accepted. Refresh to check the latest status." : "OpenPost accepted the request. Refresh to check each destination's result."
            if let job = result.jobId { notice = (notice ?? "") + " Job: \(job)" }
            let updated: OpenPostPublication = try await client.request(["publications", publication.id])
            guard !revoked else { return }
            publications.removeAll { $0.id == updated.id }; publications.insert(updated, at: 0)
        } catch { self.error = error.localizedDescription }
    }

    func revoke() { revoked = true }

    func exportDrafts() {
        guard !revoked, !loadFailed else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Social Studio drafts.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Export content only, never saved connection identifiers or retry envelopes.
            var content = document; content.connection = nil
            content.drafts = content.drafts.map { var copy = $0; copy.handoff = nil; return copy }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(content).write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}
