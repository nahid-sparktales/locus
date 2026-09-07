import Foundation

/// Additive presentation metadata. The message's ordinary content remains the
/// complete fallback for older clients, export, model context and recovery.
struct ResponseDocument: Codable, Hashable, Sendable {
    var version: Int
    var parts: [ResponsePart]

    var isSupported: Bool {
        version == 1 && !parts.isEmpty && parts.count <= 64
            && Set(parts.map(\.id)).count == parts.count
            && parts.allSatisfy(\.isSupported)
    }

    var sources: [ResponseSource] {
        var seen = Set<String>()
        return parts.flatMap { $0.references ?? [] }.filter { seen.insert($0.identity).inserted }
    }
}

struct ResponsePart: Codable, Hashable, Identifiable, Sendable {
    var type: String
    var id: String
    var text: String? = nil
    var title: String? = nil
    var workspace: String? = nil
    var entries: [ResponseFileEntry]? = nil
    var totalCount: Int? = nil
    var complete: Bool? = nil
    var collapsed: Bool? = nil
    var showHidden: Bool? = nil
    var variant: String? = nil
    var subject: String? = nil
    var body: String? = nil
    var path: String? = nil
    var description: String? = nil
    var references: [ResponseSource]? = nil

    enum CodingKeys: String, CodingKey {
        case type, id, text, title, workspace, entries, complete, collapsed, variant, subject, body, path, description, references
        case totalCount = "total_count"
        case showHidden = "show_hidden"
    }

    var isSupported: Bool {
        guard !id.isEmpty else { return false }
        switch type {
        case "markdown": return text != nil
        case "file_collection":
            guard let entries, let workspace, !workspace.isEmpty else { return false }
            return entries.allSatisfy { !$0.path.isEmpty } && Set(entries.map(\.path)).count == entries.count
                && (totalCount.map { $0 >= entries.count } ?? true)
        case "writing": return body != nil && ["email", "chat", "chat_message", "document", "standard", "social_post"].contains(variant ?? "standard")
        case "artifact": return !(path ?? "").isEmpty && !(workspace ?? "").isEmpty
        case "sources": return references?.allSatisfy(\.isSupported) == true
        default: return false
        }
    }

    var writingTitle: String { title?.nilIfEmpty ?? (variant == "email" ? "Email draft" : "Writing") }
    var originalWriting: String {
        [subject.map { "Subject: \($0)" }, body].compactMap { $0 }.joined(separator: "\n\n")
    }
}

struct ResponseFileEntry: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var name: String? = nil
    var kind: String? = nil
    var size: Int64? = nil
    var exists: Bool? = nil
    var description: String? = nil
    var id: String { path }
}

struct ResponseSource: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String? = nil
    var url: String? = nil
    var document: DocumentReference? = nil
    var identity: String { document?.id ?? url ?? id }
    var destination: URL? {
        if let document { return document.navigationURL }
        guard let url, let target = URL(string: url), ["https", "http"].contains(target.scheme?.lowercased() ?? "") else { return nil }
        return target
    }
    var isSupported: Bool { !id.isEmpty && destination != nil }
    var label: String {
        title?.nilIfEmpty ?? document.map { ($0.path as NSString).lastPathComponent }
            ?? destination?.host ?? "Source"
    }
    var detail: String { document?.location?.label ?? destination?.host ?? "" }
}

struct ResponseArtifactBinding: Codable, Hashable, Sendable {
    var outputID: String
    var versionID: String
    var path: String
    var unavailableReason: String?
}

/// Drafts and artifact bindings use durable provider identity, never the UUID
/// SwiftUI assigns when it reconstructs a transcript row.
enum ResponseIdentity {
    static func key(workspace: String, sessionID: String, itemID: String, partID: String) -> String {
        [OutputsLibraryStore.canonical(workspace), sessionID, itemID, partID]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}
