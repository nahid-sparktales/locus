import Combine
import CryptoKit
import Foundation
import SwiftUI

/// One durable notes document. Workspace-scoped documents use their own
/// directory, while chat-scoped documents deliberately keep the original
/// key and `Chat Notes` location so notes created by older Locus builds remain
/// available when the user chooses the per-chat setting.
@MainActor
final class NotesStore: ObservableObject {
    static let maximumCharacters = 100_000
    static let maximumReadCharacters = 30_000

    private static var stores: [String: NotesStore] = [:]

    @Published private(set) var text = ""

    let scope: NotesScope
    let fileURL: URL
    private var pendingSave: DispatchWorkItem?

    static func shared(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope
    ) -> NotesStore {
        let descriptor = storageDescriptor(
            workspacePath: workspacePath,
            sessionID: sessionID,
            scope: scope
        )
        if let existing = stores[descriptor.cacheKey] { return existing }
        let store = NotesStore(
            storageKey: descriptor.storageKey,
            directoryName: descriptor.directoryName,
            scope: scope,
            applicationSupport: applicationSupportDirectory
        )
        stores[descriptor.cacheKey] = store
        return store
    }

    static func storageIdentity(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope
    ) -> String {
        storageDescriptor(
            workspacePath: workspacePath,
            sessionID: sessionID,
            scope: scope
        ).cacheKey
    }

    /// A non-shared store keeps persistence tests out of the user's real
    /// Application Support folder.
    static func testingStore(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope,
        applicationSupport: URL
    ) -> NotesStore {
        let descriptor = storageDescriptor(
            workspacePath: workspacePath,
            sessionID: sessionID,
            scope: scope
        )
        return NotesStore(
            storageKey: descriptor.storageKey,
            directoryName: descriptor.directoryName,
            scope: scope,
            applicationSupport: applicationSupport
        )
    }

    private static var applicationSupportDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private static func storageDescriptor(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope
    ) -> (cacheKey: String, storageKey: String, directoryName: String) {
        let canonicalWorkspace = SessionSummary.canonicalWorkspacePath(workspacePath)
        switch scope {
        case .workspace:
            return (
                "workspace\u{0}" + canonicalWorkspace,
                canonicalWorkspace,
                "Workspace Notes"
            )
        case .chat:
            let trimmedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalSession = trimmedSession.isEmpty ? "pending-chat" : trimmedSession
            // This is the exact pre-workspace-scope key.
            let legacyKey = canonicalWorkspace + "\u{0}" + canonicalSession
            return ("chat\u{0}" + legacyKey, legacyKey, "Chat Notes")
        }
    }

    private init(
        storageKey: String,
        directoryName: String,
        scope: NotesScope,
        applicationSupport: URL
    ) {
        self.scope = scope
        let digest = SHA256.hash(data: Data(storageKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        fileURL = applicationSupport
            .appendingPathComponent("Locus", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(digest).txt")
        text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func update(_ value: String) {
        guard text != value else { return }
        text = value
        scheduleSave()
    }

    /// Execute the small native Notes tool family. The agent cannot select a
    /// path, workspace, or chat: AppModel resolves the owning store from the
    /// socket that made the request before this method is called.
    func perform(tool: String, arguments: [String: Any]) -> [String: Any] {
        switch tool {
        case "notes_read":
            let requestedLimit = arguments["max_chars"] as? Int ?? Self.maximumReadCharacters
            let limit = min(max(requestedLimit, 1), Self.maximumReadCharacters)
            let truncated = text.count > limit
            let visible = String(text.prefix(limit))
            let content = visible.isEmpty ? "Notes are empty." : visible
            let suffix = truncated ? "\n\n[Notes truncated at \(limit) characters.]" : ""
            return [
                "text": content + suffix,
                "scope": scope.rawValue,
                "truncated": truncated,
            ]

        case "notes_update":
            guard let incoming = arguments["text"] as? String else {
                return ["error": "notes_update requires text."]
            }
            let action = (arguments["action"] as? String) ?? "replace"
            let updated: String
            switch action {
            case "replace":
                updated = incoming
            case "append":
                if text.isEmpty || incoming.isEmpty {
                    updated = text + incoming
                } else {
                    updated = text + (text.hasSuffix("\n") ? "" : "\n") + incoming
                }
            default:
                return ["error": "Unknown notes_update action: \(action)."]
            }
            guard updated.count <= Self.maximumCharacters else {
                return [
                    "error": "Notes are limited to \(Self.maximumCharacters) characters."
                ]
            }
            text = updated
            pendingSave?.cancel()
            pendingSave = nil
            if let error = save() {
                return ["error": "Could not save notes: \(error.localizedDescription)"]
            }
            return [
                "text": action == "append" ? "Appended to notes." : "Replaced notes.",
                "scope": scope.rawValue,
                "character_count": updated.count,
            ]

        default:
            return ["error": "Unknown Notes tool: \(tool)."]
        }
    }

    func flushForTesting() {
        pendingSave?.cancel()
        pendingSave = nil
        _ = save()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in _ = self?.save() }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    @discardableResult
    private func save() -> Error? {
        pendingSave = nil
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            return nil
        } catch {
            // UI edits retain the latest text in memory and retry next time.
            return error
        }
    }
}

struct InspectorNotesTab: View {
    @StateObject private var store: NotesStore

    init(workspacePath: String, sessionID: String, scope: NotesScope) {
        _store = StateObject(wrappedValue: NotesStore.shared(
            workspacePath: workspacePath,
            sessionID: sessionID,
            scope: scope
        ))
    }

    var body: some View {
        TextEditor(text: Binding(
            get: { store.text },
            set: { store.update($0) }
        ))
        .font(.locus(size: 13))
        .scrollContentBackground(.hidden)
        .padding(10)
        .background(LocusTheme.paper)
        .accessibilityLabel(store.scope.accessibilityLabel)
        .accessibilityIdentifier("notes.editor")
    }
}
