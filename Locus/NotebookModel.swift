//  Feature-owned state for the Notebook: what notes exist, what they are
//  called, and which one is open. Discovery reads the notes directories
//  rather than deriving a list from live workspaces and chats, because a note
//  outlives both.

import Combine
import Foundation
import SwiftUI

/// One stored notes document as the Notebook sees it: what is on disk, plus the
/// best name the app can currently put on it.
struct NotebookEntry: Identifiable, Hashable {
    /// What a document is called, and where it came from. Absent when nothing
    /// known to the app reproduces this digest.
    struct Origin: Hashable {
        var title: String
        var workspaceName: String
        /// Seeds the export panel. Empty when the workspace is unknown.
        var workspacePath: String
    }

    let documentID: NotesDocumentID
    let scope: NotesScope
    /// Nil for a note whose workspace or chat is gone. It stays fully readable
    /// and editable — only its name is unrecoverable.
    let origin: Origin?
    let preview: String
    let modifiedAt: Date?
    let characterCount: Int

    var id: NotesDocumentID { documentID }
    var isUnlinked: Bool { origin == nil }

    /// Two unlinked notes in one scope have to be tellable apart, and the
    /// digest prefix is the only thing left that distinguishes them.
    var title: String {
        if let origin, !origin.title.isEmpty { return origin.title }
        return scope.documentTitle
    }

    var subtitle: String {
        guard let origin else { return "Unlinked · #\(documentID.digest.prefix(8))" }
        switch scope {
        case .workspace: return origin.workspacePath.isEmpty
            ? scope.documentTitle : abbreviatedPath
        case .chat: return origin.workspaceName.isEmpty
            ? scope.documentTitle : origin.workspaceName
        case .global: return "Every chat, every workspace"
        }
    }

    /// Paths are shown tilde-abbreviated, never as the raw absolute path: in
    /// the sandboxed build the real one is a container path that means nothing
    /// to the reader, and it is not ours to put on screen either way.
    var abbreviatedPath: String {
        guard let origin, !origin.workspacePath.isEmpty else { return "" }
        return NSString(string: origin.workspacePath).abbreviatingWithTildeInPath
    }
}

struct NotebookSection: Identifiable, Hashable {
    let title: String
    let entries: [NotebookEntry]
    var id: String { title }
}

@MainActor
final class NotebookModel: ObservableObject {
    typealias StoreProvider = @MainActor (NotesDocumentID, NotesScope) -> NotesStore

    /// Bounds what is held in memory for the list. Notes cap at 100,000
    /// characters each and there can be one per chat ever opened, so the list
    /// keeps only enough of each to recognize and search it.
    static let previewCharacters = 2_000

    @Published var query = ""
    @Published private(set) var entries: [NotebookEntry] = []
    @Published private(set) var selection: NotebookEntry?
    /// Reassigned only when the selection changes, never on a keystroke: the
    /// editor observes the store directly, so typing must not republish here.
    @Published private(set) var selectedStore: NotesStore?
    /// Set when chat notes cannot be named because the session list is empty,
    /// which means the agent is offline rather than that the notes are orphans.
    @Published private(set) var namingIsIncomplete = false

    private let applicationSupport: URL
    private let storeProvider: StoreProvider

    init(
        applicationSupport: URL = NotesStore.applicationSupportDirectory,
        storeProvider: @escaping StoreProvider = { NotesStore.shared(documentID: $0, scope: $1) }
    ) {
        self.applicationSupport = applicationSupport
        self.storeProvider = storeProvider
    }

    // MARK: - Discovery

    /// Rebuild the list. Scan first and name second: deriving the list from
    /// live workspaces and chats instead would hide every note whose owner has
    /// since been deleted, which is a large share of them.
    func refresh(workspaces: [WorkspaceProfile], sessions: [SessionSummary]) {
        let scanned = Self.scan(in: applicationSupport)
        let names = resolveNames(
            for: scanned.keys,
            workspaces: workspaces,
            sessions: sessions
        )
        entries = scanned.map { documentID, found in
            NotebookEntry(
                documentID: documentID,
                scope: found.scope,
                origin: names[documentID],
                preview: found.preview,
                modifiedAt: found.modifiedAt,
                characterCount: found.characterCount
            )
        }
        .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }

        namingIsIncomplete = sessions.isEmpty && entries.contains {
            $0.scope == .chat && $0.isUnlinked
        }
        // A selection made before a refresh must keep pointing at its document
        // rather than a stale copy of the row.
        if let current = selection {
            selection = entries.first { $0.documentID == current.documentID }
        }
    }

    private struct Found {
        let scope: NotesScope
        let preview: String
        let modifiedAt: Date?
        let characterCount: Int
    }

    /// Enumerate exactly the three directories `NotesStore` writes. An older,
    /// abandoned notes format also left a `Locus/Notes` folder behind; it has
    /// no reader anywhere in the app and is deliberately not listed here.
    private static func scan(in applicationSupport: URL) -> [NotesDocumentID: Found] {
        var found: [NotesDocumentID: Found] = [:]
        for scope in NotesScope.allCases {
            let directoryName = NotesStore.directoryName(for: scope)
            let directory = applicationSupport
                .appendingPathComponent("Locus", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
            let names = (try? FileManager.default
                .contentsOfDirectory(atPath: directory.path)) ?? []

            // Grouped by digest rather than by file, so a document whose plain
            // mirror was lost is one row rather than none.
            var digests: Set<String> = []
            for name in names {
                let candidate = URL(fileURLWithPath: name)
                guard ["txt", "styled"].contains(candidate.pathExtension) else { continue }
                let stem = candidate.deletingPathExtension().lastPathComponent.lowercased()
                guard stem.count == 64, stem.allSatisfy(\.isHexDigit) else { continue }
                digests.insert(stem)
            }

            for digest in digests {
                let plainURL = directory.appendingPathComponent("\(digest).txt")
                let styledURL = directory.appendingPathComponent("\(digest).styled")
                // Read through the store's own rule so a row and the editor
                // never disagree about what a document contains.
                let text = NotesStore.storedDocument(plain: plainURL, styled: styledURL).text
                let modified = [plainURL, styledURL].compactMap {
                    try? FileManager.default
                        .attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
                }.compactMap { $0 }.max()
                found[NotesDocumentID(directoryName: directoryName, digest: digest)] = Found(
                    scope: scope,
                    preview: Self.preview(from: text),
                    modifiedAt: modified,
                    characterCount: text.count
                )
            }
        }
        return found
    }

    /// The note's own opening words. List markers are stripped so a checklist
    /// does not preview as a column of dashes.
    static func preview(from text: String) -> String {
        let body = text.prefix(previewCharacters)
            .components(separatedBy: .newlines)
            .lazy
            .map {
                NotesMarkers.strippingMarker($0).rest
                    .trimmingCharacters(in: .whitespaces)
            }
            .first { !$0.isEmpty } ?? ""
        return String(body.prefix(140))
    }

    // MARK: - Naming

    /// Name each digest from the durable index first, then backfill by
    /// recomputing digests from what the app currently knows — recording every
    /// fresh hit, so a name resolved once survives deleting the chat that
    /// produced it.
    ///
    /// Recomputation is lossy by construction: `canonicalWorkspacePath`
    /// resolves symlinks only for a path that still exists, so the digest
    /// written while a workspace was mounted may be unreachable afterwards.
    /// That is why the index exists, and why a digest is never "repaired" by
    /// rewriting its note under a corrected one — that would fork the document.
    private func resolveNames(
        for documentIDs: some Collection<NotesDocumentID>,
        workspaces: [WorkspaceProfile],
        sessions: [SessionSummary]
    ) -> [NotesDocumentID: NotebookEntry.Origin] {
        let known = Set(documentIDs)
        var discovered: [NotesDocumentID: NotesNameRecord] = [:]
        let now = Date()

        func record(
            _ documentID: NotesDocumentID,
            _ scope: NotesScope,
            workspacePath: String,
            sessionID: String,
            title: String
        ) {
            guard known.contains(documentID), discovered[documentID] == nil else { return }
            discovered[documentID] = NotesNameRecord(
                directoryName: documentID.directoryName,
                digest: documentID.digest,
                scopeRaw: scope.rawValue,
                workspacePath: workspacePath,
                sessionID: sessionID,
                title: title,
                updatedAt: now
            )
        }

        record(
            NotesStore.globalDocumentID, .global,
            workspacePath: "", sessionID: "", title: NotesScope.global.documentTitle
        )

        var workspaceNames: [String: String] = [:]
        for path in workspaces.map(\.path) + sessions.flatMap({ [$0.cwd, $0.workspaceRoot] })
            .compactMap({ $0 })
        {
            let canonical = SessionSummary.canonicalWorkspacePath(path)
            guard !canonical.isEmpty, workspaceNames[canonical] == nil else { continue }
            workspaceNames[canonical] = URL(fileURLWithPath: canonical).lastPathComponent
        }

        for (path, name) in workspaceNames {
            record(
                NotesStore.documentID(workspacePath: path, sessionID: "", scope: .workspace),
                .workspace, workspacePath: path, sessionID: "", title: name
            )
            // A note written before its chat had an id keeps the sentinel key,
            // so name it for its workspace rather than orphaning it.
            record(
                NotesStore.documentID(workspacePath: path, sessionID: "", scope: .chat),
                .chat, workspacePath: path, sessionID: "", title: "Unsaved chat"
            )
        }

        // A chat note is keyed by whichever workspace was open when it was
        // written, which is usually but not always the session's own, so each
        // session is tried against every known workspace. The session's own
        // workspace is registered first so a cross-product hit cannot displace
        // it.
        for session in sessions {
            let own = session.cwd.map(SessionSummary.canonicalWorkspacePath)
            for path in [own].compactMap({ $0 }) + workspaceNames.keys.filter({ $0 != own }) {
                record(
                    NotesStore.documentID(
                        workspacePath: path, sessionID: session.id, scope: .chat
                    ),
                    .chat,
                    workspacePath: path,
                    sessionID: session.id,
                    title: session.displayTitle
                )
            }
        }

        let merged = NotesNameIndex.merge(Array(discovered.values), in: applicationSupport)
        return merged.compactMapValues { record in
            let path = record.workspacePath
            return NotebookEntry.Origin(
                title: record.title,
                workspaceName: path.isEmpty
                    ? "" : URL(fileURLWithPath: path).lastPathComponent,
                workspacePath: path
            )
        }
        .filter { !$0.value.title.isEmpty || !$0.value.workspacePath.isEmpty }
    }

    // MARK: - Presentation

    var sections: [NotebookSection] {
        let matches = filteredEntries
        let groups: [(String, (NotebookEntry) -> Bool)] = [
            ("Shared", { $0.scope == .global && !$0.isUnlinked }),
            ("Workspaces", { $0.scope == .workspace && !$0.isUnlinked }),
            ("Chats", { $0.scope == .chat && !$0.isUnlinked }),
            ("Unlinked", \.isUnlinked),
        ]
        return groups.compactMap { title, belongs in
            let entries = matches.filter(belongs)
            return entries.isEmpty ? nil : NotebookSection(title: title, entries: entries)
        }
    }

    var filteredEntries: [NotebookEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            [$0.title, $0.subtitle, $0.preview]
                .contains { $0.lowercased().contains(needle) }
        }
    }

    func select(_ entry: NotebookEntry) {
        selection = entry
        let store = storeProvider(entry.documentID, entry.scope)
        // The instance cache never evicts, so a store opened earlier in the
        // session may hold text older than the file it points at.
        store.reloadFromDiskIfClean()
        selectedStore = store
    }
}
