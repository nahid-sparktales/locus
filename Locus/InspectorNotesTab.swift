import Combine
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class ChatNotesStore: ObservableObject {
    private static var stores: [String: ChatNotesStore] = [:]

    @Published private(set) var text = ""

    private let fileURL: URL
    private var pendingSave: DispatchWorkItem?

    static func shared(workspacePath: String, sessionID: String) -> ChatNotesStore {
        let canonicalWorkspace = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        let canonicalSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = canonicalWorkspace + "\u{0}" + (canonicalSession.isEmpty ? "pending-chat" : canonicalSession)
        if let existing = stores[key] { return existing }
        let store = ChatNotesStore(key: key)
        stores[key] = store
        return store
    }

    private init(key: String) {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        fileURL = applicationSupport
            .appendingPathComponent("Locus", isDirectory: true)
            .appendingPathComponent("Chat Notes", isDirectory: true)
            .appendingPathComponent("\(digest).txt")
        text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func update(_ value: String) {
        guard text != value else { return }
        text = value
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.save() }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func save() {
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
        } catch {
            // Keep the current text in memory; the next edit retries the save.
        }
    }
}

struct InspectorNotesTab: View {
    @StateObject private var store: ChatNotesStore

    init(workspacePath: String, sessionID: String) {
        _store = StateObject(wrappedValue: ChatNotesStore.shared(
            workspacePath: workspacePath,
            sessionID: sessionID
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
        .accessibilityLabel("Notes for this chat")
        .accessibilityIdentifier("notes.editor")
    }
}
