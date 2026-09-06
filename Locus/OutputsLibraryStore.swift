import CryptoKit
import Foundation
import SQLite3

struct OutputOrigin: Codable, Equatable, Sendable {
    var sessionID: String
    var runID: String?
    var capturedAt: Date
}
struct OutputVersion: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var hash: String?
    var capturedAt: Date
    var sessionID: String
    var runID: String?
    var byteCount: Int64
    var label: String
    var unavailableReason: String?
    var origins: [OutputOrigin]? = nil
    func belongsTo(sessionID: String?, runID: String?) -> Bool {
        let sources = (origins ?? []) + [OutputOrigin(sessionID: self.sessionID, runID: self.runID, capturedAt: capturedAt)]
        return sources.contains { (sessionID == nil || $0.sessionID == sessionID) && (runID == nil || $0.runID == runID) }
    }
}

struct LibraryOutput: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var workspace: String
    var target: String
    var title: String
    var kind: String
    var versions: [OutputVersion]
    var updatedAt: Date
    var isWebsite: Bool { kind == "website" }
    var latest: OutputVersion? { versions.last }
}

struct OutputCapture: Sendable {
    let workspace: String
    let path: String
    let sessionID: String
    let runID: String?
    var imported = false
    var website = false
}

/// Serialized SQLite metadata and immutable, content-addressed files. A failed
/// snapshot is recorded explicitly; it never replaces the last saved version.
actor OutputsLibraryStore {
    static let defaultWorkspaceLimit: Int64 = 2_000_000_000
    static let fileLimit: Int64 = 100_000_000
    let directory: URL
    private var database: OpaquePointer?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Locus/Library", isDirectory: true)
    }
    deinit { if let database { sqlite3_close(database) } }

    private func open() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("outputs.sqlite3").path,
                              &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { throw StoreError("Could not open the Outputs library") }
        database = db
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS outputs(id TEXT PRIMARY KEY, workspace TEXT NOT NULL, payload TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS outputs_workspace ON outputs(workspace)")
        try execute("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    func list(workspace: String) throws -> [LibraryOutput] {
        try open()
        return try strings("SELECT payload FROM outputs WHERE workspace=?", [Self.canonical(workspace)])
            .compactMap { try? JSONDecoder().decode(LibraryOutput.self, from: Data($0.utf8)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func capture(_ capture: OutputCapture) throws -> LibraryOutput? {
        try open()
        let workspace = Self.canonical(capture.workspace)
        let target: String
        if capture.website {
            target = SessionOutput.normalize(capture.path)
        } else {
            guard let url = Self.containedURL(capture.path, workspace: workspace) else { return nil }
            target = String(url.path.dropFirst(workspace.count + 1))
        }
        let identity = Self.digest(Data("\(workspace)\n\(capture.website ? "website" : "file")\n\(target)".utf8))
        let existing = try strings("SELECT payload FROM outputs WHERE id=?", [identity]).first
            .flatMap { try? JSONDecoder().decode(LibraryOutput.self, from: Data($0.utf8)) }
        var output = existing ?? LibraryOutput(id: identity, workspace: workspace, target: target,
            title: capture.website ? target : (target as NSString).lastPathComponent,
            kind: capture.website ? "website" : Self.kind(target), versions: [], updatedAt: Date())
        var version = OutputVersion(id: UUID().uuidString, hash: nil, capturedAt: Date(),
            sessionID: capture.sessionID, runID: capture.runID, byteCount: 0,
            label: capture.imported ? "Imported current version" : "Version \(output.versions.count + 1)",
            unavailableReason: nil)
        if !capture.website {
            let source = URL(fileURLWithPath: workspace).appendingPathComponent(target)
            do {
                let attributes = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard attributes.isRegularFile == true else { throw StoreError("The original file is unavailable") }
                version.byteCount = Int64(attributes.fileSize ?? 0)
                guard version.byteCount <= Self.fileLimit else { throw StoreError("Not saved: this file exceeds the 100 MB snapshot limit") }
                // Own the bytes before hashing. Memory-mapped source data can
                // change underneath a capture when a generator writes in place.
                let data = try Data(contentsOf: source)
                guard data.count <= Self.fileLimit else { throw StoreError("Not saved: this file exceeds the 100 MB snapshot limit") }
                let hash = Self.digest(data)
                // Deduplicate consecutive unchanged captures, while preserving
                // meaningful history when content is restored to an older state.
                if output.latest?.hash == hash {
                    if !capture.sessionID.isEmpty, let index = output.versions.indices.last {
                        var last = output.versions[index]
                        if !last.belongsTo(sessionID: capture.sessionID, runID: capture.runID) {
                            var origins = last.origins ?? []
                            origins.append(OutputOrigin(sessionID: capture.sessionID, runID: capture.runID, capturedAt: Date()))
                            last.origins = origins
                        }
                        if last.sessionID.isEmpty { last.sessionID = capture.sessionID; last.runID = capture.runID }
                        output.versions[index] = last
                        try save(output)
                    }
                    return output
                }
                let current = try list(workspace: workspace)
                let saved = Dictionary(current.flatMap(\.versions).compactMap { v in
                    v.hash.map { ($0, v.byteCount) }
                }, uniquingKeysWith: { first, _ in first })
                let limit = try workspaceLimit(workspace)
                if saved[hash] == nil && saved.values.reduce(0, +) + Int64(data.count) > limit {
                    throw StoreError("Not saved: this workspace's snapshot storage is full. Increase its limit or remove library history.")
                }
                let snapshot = snapshotURL(hash: hash, target: target)
                try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
                let blob = snapshot.deletingLastPathComponent().appendingPathComponent("blob")
                if !FileManager.default.fileExists(atPath: blob.path) {
                    try data.write(to: blob, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: blob.path)
                }
                if !FileManager.default.fileExists(atPath: snapshot.path) {
                    // Quick Look needs a filename extension, while the quota
                    // must count identical bytes only once across file types.
                    try FileManager.default.linkItem(at: blob, to: snapshot)
                }
                version.hash = hash
                version.byteCount = Int64(data.count)
            } catch {
                if error is StoreError { version.unavailableReason = error.localizedDescription }
                else if (error as? CocoaError)?.code == .fileReadNoSuchFile {
                    version.unavailableReason = "The original file is unavailable"
                } else { version.unavailableReason = "Snapshot could not be saved: \(error.localizedDescription)" }
                if output.latest?.unavailableReason == version.unavailableReason { return output }
            }
        } else if existing != nil { return output }
        output.versions.append(version)
        output.updatedAt = version.capturedAt
        try save(output)
        return output
    }

    func snapshotURL(hash: String, target: String) -> URL {
        let ext = (target as NSString).pathExtension.lowercased()
        return directory.appendingPathComponent("Snapshots/\(hash)/content\(ext.isEmpty ? "" : "." + ext)")
    }

    func versionURL(_ output: LibraryOutput, version: OutputVersion) -> URL? {
        guard let hash = version.hash else { return nil }
        let url = snapshotURL(hash: hash, target: output.target)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func remove(_ output: LibraryOutput) throws {
        try open()
        try execute("DELETE FROM outputs WHERE id=?", [output.id])
        // A snapshot may be referenced by another workspace or output.
        let remaining = try strings("SELECT payload FROM outputs")
            .compactMap { try? JSONDecoder().decode(LibraryOutput.self, from: Data($0.utf8)) }
        let live = Set(remaining.flatMap(\.versions).compactMap(\.hash))
        for hash in Set(output.versions.compactMap(\.hash)) where !live.contains(hash) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("Snapshots/\(hash)"))
        }
    }

    func migrate(_ states: [String: SessionState]) throws {
        try open()
        guard try strings("SELECT value FROM metadata WHERE key='session-migration-v1'").isEmpty else { return }
        for (sessionID, state) in states.sorted(by: { $0.key < $1.key }) where !state.workspace.path.isEmpty {
            for file in state.files where file.kind == .create {
                _ = try capture(OutputCapture(workspace: state.workspace.path, path: file.path,
                    sessionID: sessionID, runID: nil, imported: true))
            }
            for output in state.outputs {
                _ = try capture(OutputCapture(workspace: state.workspace.path, path: output.target,
                    sessionID: sessionID, runID: nil, imported: true, website: true))
            }
        }
        try execute("INSERT OR REPLACE INTO metadata VALUES('session-migration-v1','complete')")
    }

    func workspaceLimit(_ workspace: String) throws -> Int64 {
        try open()
        return try strings("SELECT value FROM metadata WHERE key=?", ["limit:" + Self.canonical(workspace)])
            .first.flatMap(Int64.init) ?? Self.defaultWorkspaceLimit
    }

    func setWorkspaceLimit(_ bytes: Int64, workspace: String) throws {
        try open()
        try execute("INSERT OR REPLACE INTO metadata VALUES(?,?)", ["limit:" + Self.canonical(workspace), String(max(Self.fileLimit, bytes))])
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func canonical(_ workspace: String) -> String {
        URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func containedURL(_ path: String, workspace: String) -> URL? {
        let root = canonical(workspace)
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: root).appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        return url.path.hasPrefix(root + "/") ? url : nil
    }
    static func kind(_ target: String) -> String {
        let ext = (target as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg"].contains(ext) { return "image" }
        if ["csv", "tsv", "xlsx", "xls", "numbers"].contains(ext) { return "spreadsheet" }
        if ["pdf", "docx", "doc", "pages", "rtf", "pptx", "ppt"].contains(ext) { return "document" }
        if ["mp4", "mov", "mp3", "wav", "m4a"].contains(ext) { return "media" }
        return "text"
    }

    private func save(_ output: LibraryOutput) throws {
        let payload = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        try execute("INSERT OR REPLACE INTO outputs VALUES(?,?,?)", [output.id, output.workspace, payload])
    }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw StoreError("Could not read the Outputs library") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() { sqlite3_bind_text(stmt, Int32(offset + 1), value, -1, transient) }
        return stmt
    }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let stmt = try statement(sql, values)
        defer { sqlite3_finalize(stmt) }
        guard [SQLITE_DONE, SQLITE_ROW].contains(sqlite3_step(stmt)) else { throw StoreError("Could not save the Outputs library") }
    }
    private func strings(_ sql: String, _ values: [String] = []) throws -> [String] {
        let stmt = try statement(sql, values)
        defer { sqlite3_finalize(stmt) }
        var result: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = sqlite3_column_text(stmt, 0) { result.append(String(cString: value)) }
        }
        return result
    }
    struct StoreError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
