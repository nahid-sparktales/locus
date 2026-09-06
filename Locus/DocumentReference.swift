import Foundation

/// A source location travels with the content hash it refers to. It cannot
/// silently become a citation into a later revision of the same path.
struct DocumentLocation: Codable, Hashable, Sendable {
    var kind: String
    var page: Int?
    var pageIndex: Int?
    var lineStart: Int?
    var lineEnd: Int?
    var heading: String?
    var paragraphStart: Int?
    var paragraphEnd: Int?
    var sheet: String?
    var cellRange: String?
    var bounds: Bounds?
    struct Bounds: Codable, Hashable, Sendable { let x: Double; let y: Double; let width: Double; let height: Double }
    enum CodingKeys: String, CodingKey {
        case kind, page, heading, sheet, bounds
        case pageIndex = "page_index", lineStart = "line_start", lineEnd = "line_end"
        case paragraphStart = "paragraph_start", paragraphEnd = "paragraph_end", cellRange = "cell_range"
    }
    var label: String {
        switch kind {
        case "pdf": return "Page \(page ?? ((pageIndex ?? 0) + 1))"
        case "paragraph": return heading ?? "Paragraph \(paragraphStart ?? 1)"
        case "sheet": return [sheet, cellRange].compactMap { $0 }.joined(separator: " · ")
        default: return "Line \(lineStart ?? 1)"
        }
    }
}

struct DocumentReference: Codable, Hashable, Identifiable, Sendable {
    var workspace: String
    var path: String
    var contentHash: String?
    var location: DocumentLocation?
    var id: String { "\(workspace)|\(path)|\(contentHash ?? "")|\(location?.label ?? "")" }
    var navigationURL: URL? {
        var components = URLComponents()
        components.scheme = "locus-workspace"
        components.host = "open"
        components.path = "/" + path
        var items = [URLQueryItem(name: "workspace", value: workspace)]
        if let contentHash { items.append(.init(name: "content_hash", value: contentHash)) }
        if let location, let data = try? JSONEncoder().encode(location) {
            items.append(.init(name: "locator", value: String(decoding: data, as: UTF8.self)))
        }
        components.queryItems = items
        return components.url
    }
    static func fromNavigationURL(_ url: URL, workspace: String) -> DocumentReference? {
        guard url.scheme == "locus-workspace", url.host == "open" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard value("locator") != nil || value("content_hash") != nil || value("hash") != nil else { return nil }
        if let namedWorkspace = value("workspace"), OutputsLibraryStore.canonical(namedWorkspace) != OutputsLibraryStore.canonical(workspace) { return nil }
        let location = value("locator").flatMap { try? JSONDecoder().decode(DocumentLocation.self, from: Data($0.utf8)) }
        return DocumentReference(workspace: workspace, path: String(url.path.dropFirst()), contentHash: value("content_hash") ?? value("hash"), location: location)
    }
}

struct LibraryDocument: Decodable, Identifiable, Hashable {
    let id: String
    let path: String
    let title: String
    let format: String
    let contentHash: String?
    let status: String
    let jobID: String?
    let error: String?
    let warnings: [String]
    let truncated: Bool
    let excluded: Bool
    let segmentCount: Int
    let updatedAt: Double
    let size: Int64
    enum CodingKeys: String, CodingKey {
        case id, path, title, format, status, error, warnings, truncated, excluded, size
        case contentHash = "content_hash", jobID = "job_id", segmentCount = "segment_count", updatedAt = "updated_at"
    }
    var stateLabel: String { status == "running" ? "Processing" : status.capitalized }
}
struct DocumentExtractionJob: Decodable, Identifiable {
    let id: String
    let documentID: String?
    let workspace: String
    let path: String
    let format: String
    let persistent: Bool
    let contentHash: String?
    let state: String
    let progress: Int
    let total: Int
    let error: String?
    let resultAvailable: Bool
    enum CodingKeys: String, CodingKey {
        case id, workspace, path, format, persistent, state, progress, total, error
        case documentID = "document_id", contentHash = "content_hash", resultAvailable = "result_available"
    }
    var isActive: Bool { state == "queued" || state == "running" || state == "processing" }
}
struct DocumentSegment: Decodable, Identifiable {
    let text: String
    let locator: DocumentLocation
    let method: String
    var id: String { locator.label + "|" + String(text.prefix(100)) }
}
struct DocumentExtractionResult: Decodable {
    let job: DocumentExtractionJob
    let segments: [DocumentSegment]
    let contentHash: String
    let format: String
    let truncated: Bool
    let warnings: [String]
    enum CodingKeys: String, CodingKey { case job, segments, format, truncated, warnings; case contentHash = "content_hash" }
}
struct DocumentSearchHit: Decodable, Identifiable {
    let sourceID: String?
    let path: String
    let text: String?
    let snippet: String?
    let contentHash: String?
    let locator: DocumentLocation?
    let lineStart: Int?
    let lineEnd: Int?
    var id: String { sourceID ?? (path + "|" + (locator?.label ?? String(lineStart ?? 0))) }
    enum CodingKeys: String, CodingKey {
        case path, text, snippet, locator
        case contentHash = "content_hash", lineStart = "line_start", lineEnd = "line_end"
        case sourceID = "id"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)
        // Knowledge search can also return memory records. They are decoded
        // safely and filtered out of the document-only results by the model.
        path = try values.decodeIfPresent(String.self, forKey: .path) ?? ""
        text = try values.decodeIfPresent(String.self, forKey: .text)
        snippet = try values.decodeIfPresent(String.self, forKey: .snippet)
        contentHash = try values.decodeIfPresent(String.self, forKey: .contentHash)
        locator = try values.decodeIfPresent(DocumentLocation.self, forKey: .locator)
        lineStart = try values.decodeIfPresent(Int.self, forKey: .lineStart)
        lineEnd = try values.decodeIfPresent(Int.self, forKey: .lineEnd)
    }
}

struct DocumentPreviewRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var reference: DocumentReference?
    var result: DocumentExtractionResult?
    var warning: String?
}
