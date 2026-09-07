//  The notes storage layer: the durable document, its on-disk layout, and the
//  text conventions its plain mirror has to preserve. Kept apart from the
//  inspector view so a surface that only needs to read stored notes does not
//  depend on the editor.

import AppKit
import Combine
import CryptoKit
import Foundation

extension Notification.Name {
    static let notesDocumentDidChange = Notification.Name("Locus.notesDocumentDidChange")
}

/// Baseline attributes for notes text. The plain `.txt` mirror stays the
/// canonical content the agent tools and older builds read, so every visual
/// default must be reconstructible from bare text.
enum NotesTextStyle {
    static let defaultFontSize: CGFloat = 13
    static let fontSizes: [CGFloat] = [11, 12, 13, 14, 16, 18, 21, 24]

    static var defaultFont: NSFont { .systemFont(ofSize: defaultFontSize) }

    /// Keep the archived identity used by existing notes. The editor displays
    /// this as Locus's warm body ink through temporary layout attributes;
    /// dynamic provider colors themselves cannot be securely archived.
    static var defaultColor: NSColor { .labelColor }

    static var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: defaultFont, .foregroundColor: defaultColor]
    }

    static func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: typingAttributes)
    }

    /// These fixed colors are durable identities for the built-in palette.
    /// Their displayed counterparts below adapt to the paper appearance, while
    /// existing archives and arbitrary pasted colors retain their formatting.
    static let accents: [(name: String, color: NSColor)] = [
        ("Coral", fixed(0xC9573C)),
        ("Amber", fixed(0xB07A28)),
        ("Green", fixed(0x4E9A5E)),
        ("Blue", fixed(0x5B7FE0)),
        ("Purple", fixed(0x8B6BC8)),
        ("Gray", fixed(0x8A8678)),
    ]

    /// Resolve built-in formatting only for display. Returning custom colors
    /// unchanged preserves formatting imported from other editors.
    static func displayColor(for storedColor: NSColor) -> NSColor {
        if storedColor.isEqual(defaultColor) { return NSColor(LocusTheme.inkSoft) }
        switch accents.firstIndex(where: { storedColor.isEqual($0.color) }) {
        case 0: return NSColor(LocusTheme.noteCoral)
        case 1: return NSColor(LocusTheme.noteAmber)
        case 2: return NSColor(LocusTheme.noteGreen)
        case 3: return NSColor(LocusTheme.noteBlue)
        case 4: return NSColor(LocusTheme.notePurple)
        case 5: return NSColor(LocusTheme.noteGray)
        default: return storedColor
        }
    }

    private static func fixed(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Line markers the insert menu writes. They are ordinary text so the plain
/// `.txt` mirror — the copy the agent's notes tools read — keeps its meaning.
enum NotesListKind {
    case bullet
    case numbered
    case checklist
}

enum NotesMarkers {
    static let bullet = "- "
    static let unchecked = "- [ ] "
    static let checked = "- [x] "
    static let divider = "\n———\n"

    /// Splits a line into its list marker, if any, and the rest. Checkbox
    /// markers are tested before the bullet they start with, and numbering is
    /// matched at any width so "12. " round-trips like "1. ".
    static func strippingMarker(_ line: String) -> (rest: String, kind: NotesListKind?) {
        for marker in [unchecked, checked] where line.hasPrefix(marker) {
            return (String(line.dropFirst(marker.count)), .checklist)
        }
        if line.hasPrefix(bullet) {
            return (String(line.dropFirst(bullet.count)), .bullet)
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return (String(line.dropFirst(digits.count + 2)), .numbered)
        }
        return (line, nil)
    }
}

/// Canonical identity of a notes document: the pair that decides which files
/// it owns on disk. Every (workspace, chat, scope) triple maps onto exactly one
/// of these, so keying the instance cache here makes it structurally impossible
/// for a document opened by digest and the same document opened by workspace
/// and chat to become two stores debouncing writes to one file.
struct NotesDocumentID: Hashable, Codable, Sendable {
    let directoryName: String
    let digest: String

    static let standaloneDirectoryName = "Notebook Notes"
    var isStandalone: Bool { directoryName == Self.standaloneDirectoryName }

    static func standalone(uuid: UUID = UUID()) -> NotesDocumentID {
        let digest = SHA256.hash(data: Data(("notebook\u{0}" + uuid.uuidString).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return NotesDocumentID(directoryName: standaloneDirectoryName, digest: digest)
    }

    var isValid: Bool {
        [Self.standaloneDirectoryName, "Workspace Notes", "Chat Notes", "Shared Notes"]
            .contains(directoryName) && digest.count == 64
            && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Stable string form, for SwiftUI view identity.
    var identity: String { directoryName + "\u{0}" + digest }
}

/// What a digest was named when the app still knew. SHA-256 cannot be
/// reversed, and a note outlives the workspace and chat it belongs to, so a
/// document whose owner has been deleted can only be labelled from a record
/// written while that owner still existed.
struct NotesNameRecord: Codable, Hashable {
    let directoryName: String
    let digest: String
    var scopeRaw: String
    var workspacePath: String
    var sessionID: String
    /// Snapshot of the display name. Empty when the writer did not know it —
    /// a chat title lives in the session list, not in the store — in which
    /// case a later reader that can resolve one fills it in.
    var title: String
    var updatedAt: Date

    var documentID: NotesDocumentID {
        NotesDocumentID(directoryName: directoryName, digest: digest)
    }
}

/// The durable digest → name map, kept beside the note directories.
enum NotesNameIndex {
    static func fileURL(in applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent(AppEdition.current.displayName, isDirectory: true)
            .appendingPathComponent("Notes Index.json")
    }

    static func load(in applicationSupport: URL) -> [NotesDocumentID: NotesNameRecord] {
        guard let data = try? Data(contentsOf: fileURL(in: applicationSupport)),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [:] }
        // Decoded element by element so one malformed record costs its own
        // name rather than every name in the file.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [NotesDocumentID: NotesNameRecord] = [:]
        for value in values {
            guard let encoded = try? JSONSerialization.data(withJSONObject: value),
                  let record = try? decoder.decode(NotesNameRecord.self, from: encoded)
            else { continue }
            records[record.documentID] = record
        }
        return records
    }

    /// Upsert by document. Callers know different halves of a name — the store
    /// knows the workspace and chat a document belongs to, a reader with the
    /// session list knows what to call it — so a blank title never overwrites
    /// one that is already recorded.
    @discardableResult
    static func merge(
        _ incoming: [NotesNameRecord],
        in applicationSupport: URL
    ) -> [NotesDocumentID: NotesNameRecord] {
        guard !incoming.isEmpty else { return load(in: applicationSupport) }
        var records = load(in: applicationSupport)
        var changed = false
        for var record in incoming {
            if let existing = records[record.documentID] {
                if record.title.isEmpty { record.title = existing.title }
                if record == existing { continue }
            }
            records[record.documentID] = record
            changed = true
        }
        guard changed else { return records }
        let url = fileURL(in: applicationSupport)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(
            records.values.sorted { $0.digest < $1.digest }
        ) else { return records }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Names carry workspace paths and chat titles, so this file is as
        // private as the notes it describes.
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return records
    }
}

/// One durable notes document. Workspace-scoped documents use their own
/// directory, while chat-scoped documents deliberately keep the original
/// key and `Chat Notes` location so notes created by older Locus builds remain
/// available when the user chooses the per-chat setting.
@MainActor
final class NotesStore: ObservableObject {
    static let maximumCharacters = 100_000
    static let maximumReadCharacters = 30_000

    private struct StoreKey: Hashable {
        let root: String
        let documentID: NotesDocumentID
    }
    private static var stores: [StoreKey: NotesStore] = [:]

    @Published private(set) var text = ""
    @Published private(set) var attributedText: NSAttributedString = NSAttributedString()
    /// Drives the editor's saved indicator. Saving is debounced, so without
    /// this the only feedback for an unwritten edit is the file itself.
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var lifecycle: NotebookNoteLifecycle = .active
    @Published private(set) var saveError: String?
    @Published private(set) var revision = UUID()
    var isEditable: Bool { lifecycle == .active && catalog.loadError == nil && documentID.isValid }
    let catalog: NotebookCatalog

    let scope: NotesScope
    let documentID: NotesDocumentID
    /// The workspace and chat this document belongs to, when it was opened by
    /// name. A document opened by digest has none — that is the whole reason
    /// the name index exists — and must never record over one that has.
    let origin: (workspacePath: String, sessionID: String)?
    private let applicationSupport: URL
    private var recordedName = false
    let fileURL: URL
    /// Keyed-archive sibling that carries the formatting for `fileURL`'s
    /// content. It is honored only while its string matches the plain mirror,
    /// so a `.txt` written by an older build or edited elsewhere wins.
    let styledFileURL: URL
    private var pendingSave: DispatchWorkItem?
    private var saveGeneration = UUID()
    private var catalogGeneration: UUID?
    private var catalogObservation: AnyCancellable?
    private var publishesContentChanges = true

    /// The three fixed locations. Exposed so a reader that enumerates stored
    /// documents cannot drift from where this writer puts them.
    static func directoryName(for scope: NotesScope) -> String {
        switch scope {
        case .workspace: "Workspace Notes"
        case .chat: "Chat Notes"
        case .global: "Shared Notes"
        }
    }

    static func digest(of storageKey: String) -> String {
        SHA256.hash(data: Data(storageKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func documentID(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope
    ) -> NotesDocumentID {
        let descriptor = storageDescriptor(
            workspacePath: workspacePath,
            sessionID: sessionID,
            scope: scope
        )
        return NotesDocumentID(
            directoryName: descriptor.directoryName,
            digest: digest(of: descriptor.storageKey)
        )
    }

    /// The whole-app document, named rather than derived so no caller has to
    /// pass a workspace path that `.global` deliberately ignores.
    static var globalDocumentID: NotesDocumentID {
        NotesDocumentID(
            directoryName: directoryName(for: .global),
            digest: digest(of: "global")
        )
    }

    static func shared(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope
    ) -> NotesStore {
        shared(
            documentID: documentID(
                workspacePath: workspacePath,
                sessionID: sessionID,
                scope: scope
            ),
            scope: scope,
            origin: (
                SessionSummary.canonicalWorkspacePath(workspacePath),
                sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    /// Open a document found on disk. A note can outlive the workspace or chat
    /// that named it, so identity has to come from the file rather than from
    /// inputs that may be gone. Because both entry points resolve to the same
    /// `NotesDocumentID`, a note opened here and the same note opened by the
    /// inspector are one instance, and one debounce timer.
    static func shared(
        documentID: NotesDocumentID,
        scope: NotesScope,
        origin: (workspacePath: String, sessionID: String)? = nil,
        applicationSupport: URL = applicationSupportDirectory
    ) -> NotesStore {
        let key = StoreKey(root: applicationSupport.standardizedFileURL.resolvingSymlinksInPath().path,
                           documentID: documentID)
        if let existing = stores[key] { return existing }
        let store = NotesStore(
            documentID: documentID,
            scope: scope,
            origin: origin,
            applicationSupport: applicationSupport
        )
        stores[key] = store
        return store
    }

    /// A blank document is saved explicitly; opening an ordinary contextual
    /// store still does not create a note on disk.
    static func create(
        title: String,
        attributed: NSAttributedString = NSAttributedString(string: ""),
        applicationSupport: URL = applicationSupportDirectory
    ) throws -> NotesStore {
        let title = try validatedTitle(title)
        guard attributed.string.count <= maximumCharacters else {
            throw NotebookStorageError.tooLong
        }
        let store = shared(documentID: .standalone(), scope: .global,
                           applicationSupport: applicationSupport)
        store.publishesContentChanges = false
        do {
            try store.catalog.reload()
            store.text = attributed.string
            store.attributedText = NSAttributedString(attributedString: attributed)
            store.hasUnsavedChanges = true
            try store.flush()
            try store.rename(to: title)
            store.publishesContentChanges = true
            store.postContentChange()
            return store
        } catch {
            // This UUID has never been returned to an editor. Roll back only
            // its newly created files and retire its cached writer; retrying
            // creation must not leave another anonymous copy in the Notebook.
            store.cancelPendingSave()
            store.lifecycle = .purged
            store.hasUnsavedChanges = false
            let key = StoreKey(root: applicationSupport.standardizedFileURL.resolvingSymlinksInPath().path,
                               documentID: store.documentID)
            if stores[key] === store { stores.removeValue(forKey: key) }
            var cleanupFailure: Error?
            for url in [store.fileURL, store.styledFileURL] {
                do { try NotebookFileIO.removeFileIfPresent(url) }
                catch { cleanupFailure = cleanupFailure ?? error }
            }
            if let cleanupFailure { throw cleanupFailure }
            throw error
        }
    }

    /// Normal quit/update can beat the debounce. Try every dirty canonical
    /// document in this root so one failed save does not strand the others.
    static func flushPendingChanges(applicationSupport: URL = applicationSupportDirectory) throws {
        let root = applicationSupport.standardizedFileURL.resolvingSymlinksInPath().path
        let pending = stores.filter { $0.key.root == root && $0.value.hasUnsavedChanges }.map(\.value)
        var firstFailure: Error?
        for store in pending {
            do { try store.flush() }
            catch { firstFailure = firstFailure ?? error }
        }
        if let firstFailure { throw firstFailure }
    }

    static func storageIdentity(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope
    ) -> String {
        documentID(
            workspacePath: workspacePath,
            sessionID: sessionID,
            scope: scope
        ).identity
    }

    /// A non-shared store keeps persistence tests out of the user's real
    /// Application Support folder.
    static func testingStore(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope,
        applicationSupport: URL
    ) -> NotesStore {
        NotesStore(
            documentID: documentID(
                workspacePath: workspacePath,
                sessionID: sessionID,
                scope: scope
            ),
            scope: scope,
            origin: (
                SessionSummary.canonicalWorkspacePath(workspacePath),
                sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            applicationSupport: applicationSupport
        )
    }

    static func testingStore(
        documentID: NotesDocumentID,
        scope: NotesScope,
        applicationSupport: URL
    ) -> NotesStore {
        NotesStore(
            documentID: documentID,
            scope: scope,
            origin: nil,
            applicationSupport: applicationSupport
        )
    }

    /// One temporary root per launch while UI testing. The suite drives the
    /// real editor, so without this it reads — and writes — the developer's
    /// own notes: `Workspace Notes/e9671acd…` is `SHA256("/tmp")`, left behind
    /// by the suite's own seed workspace. This is the same reasoning as
    /// `AppModel.persistenceEnabled`: a surface that will never keep its writes
    /// must not read the real ones either.
    ///
    /// Stored rather than computed because every surface has to resolve the
    /// same root within a launch.
    nonisolated static let applicationSupportDirectory: URL = {
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
            return FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "LocusUITestNotes-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }()

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
                directoryName(for: .workspace)
            )
        case .chat:
            let trimmedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalSession = trimmedSession.isEmpty ? "pending-chat" : trimmedSession
            // This is the exact pre-workspace-scope key.
            let legacyKey = canonicalWorkspace + "\u{0}" + canonicalSession
            return ("chat\u{0}" + legacyKey, legacyKey, directoryName(for: .chat))
        case .global:
            // One document for the whole app: the key deliberately ignores
            // both the workspace and the chat.
            return ("global", "global", directoryName(for: .global))
        }
    }

    /// Read one document off disk. The keyed archive carries the formatting
    /// and the `.txt` is its plain mirror, so the archive is authoritative only
    /// while the two agree — or while the mirror is absent entirely.
    ///
    /// That second case is what stops a document from being erased by being
    /// opened. Without it a note whose `.txt` was lost loads as empty, and the
    /// next keystroke archives an empty string over the only surviving copy of
    /// its text. Note that a missing mirror is deliberately not the same as an
    /// empty one: text the user really did clear must stay cleared.
    static func storedDocument(
        plain plainURL: URL,
        styled styledURL: URL
    ) -> (text: String, attributed: NSAttributedString) {
        let plain = try? String(contentsOf: plainURL, encoding: .utf8)
        let archived = (try? Data(contentsOf: styledURL)).flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NSAttributedString.self,
                from: $0
            )
        }
        if let archived, plain == nil || archived.string == plain {
            return (archived.string, archived)
        }
        let text = plain ?? ""
        return (text, NotesTextStyle.plain(text))
    }

    /// Search only needs a Sendable string, not AppKit objects. Bound archive
    /// reads independently of the editor so oversized external files do not
    /// consume unbounded memory during Notebook discovery.
    nonisolated static func storedText(plain plainURL: URL, styled styledURL: URL) -> String {
        func boundedData(_ url: URL, limit: Int) -> Data? {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { return nil }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  status.st_size <= limit else { return nil }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while data.count <= limit {
                let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit + 1 - data.count))
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { return nil }
                if count == 0 { return data }
                data.append(contentsOf: buffer.prefix(count))
            }
            return nil
        }
        if let data = boundedData(plainURL, limit: 4 * 1024 * 1024),
           let plain = String(data: data, encoding: .utf8) {
            return String(plain.prefix(100_000))
        }
        // An existing oversized mirror still wins over a stale archive.
        if FileManager.default.fileExists(atPath: plainURL.path),
           ((try? FileManager.default.attributesOfItem(atPath: plainURL.path)[.size] as? NSNumber)?.intValue ?? 0)
            > 4 * 1024 * 1024 {
            return ""
        }
        guard let data = boundedData(styledURL, limit: 16 * 1024 * 1024),
              let attributed = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
        else { return "" }
        return String(attributed.string.prefix(100_000))
    }

    private init(
        documentID: NotesDocumentID,
        scope: NotesScope,
        origin: (workspacePath: String, sessionID: String)?,
        applicationSupport: URL
    ) {
        self.scope = scope
        self.documentID = documentID
        self.origin = origin
        self.applicationSupport = applicationSupport
        self.catalog = NotebookCatalog.shared(in: applicationSupport)
        let directory = applicationSupport
            .appendingPathComponent(AppEdition.current.displayName, isDirectory: true)
            .appendingPathComponent(documentID.directoryName, isDirectory: true)
        fileURL = directory.appendingPathComponent("\(documentID.digest).txt")
        styledFileURL = directory.appendingPathComponent("\(documentID.digest).styled")
        try? catalog.reload()
        if documentID.isValid, catalog.loadError == nil {
            let metadata = try? catalog.metadata(for: documentID)
            lifecycle = metadata?.lifecycle ?? .active
            catalogGeneration = metadata?.generation
            if lifecycle != .purged {
                (text, attributedText) = Self.storedDocument(plain: fileURL, styled: styledFileURL)
            }
        } else {
            saveError = NotebookStorageError.unavailable.localizedDescription
        }
        catalogObservation = catalog.$revision.dropFirst().sink { [weak self] _ in
            self?.adoptCatalogState()
        }
    }

    /// Plain-text update path. Kept for callers that have no formatting to
    /// offer; it deliberately resets styling to the defaults.
    func update(_ value: String, expectedRevision: UUID? = nil) {
        guard isEditable, expectedRevision == nil || expectedRevision == revision,
              text != value else { return }
        text = value
        attributedText = NotesTextStyle.plain(value)
        scheduleSave()
    }

    /// Editor update path: the attributed string is the source of truth and
    /// the plain mirror is derived from it.
    func updateAttributed(_ value: NSAttributedString, expectedRevision: UUID? = nil) {
        guard isEditable, expectedRevision == nil || expectedRevision == revision,
              !attributedText.isEqual(to: value) else { return }
        let copy = NSAttributedString(attributedString: value)
        attributedText = copy
        text = copy.string
        scheduleSave()
    }

    /// Re-read the files when nothing is in flight. The instance cache never
    /// evicts, so a store opened earlier in the session holds the text it
    /// loaded then; a reader that lists documents by their modification date
    /// would otherwise show a fresh date beside stale content. Anything
    /// unsaved wins — a background reload must never discard a keystroke.
    func reloadFromDiskIfClean() {
        do { try catalog.reload() }
        catch { saveError = NotebookStorageError.unavailable.localizedDescription; return }
        guard isEditable, !hasUnsavedChanges, pendingSave == nil else { return }
        let stored = Self.storedDocument(plain: fileURL, styled: styledFileURL)
        guard !stored.attributed.isEqual(to: attributedText) else { return }
        text = stored.text
        attributedText = stored.attributed
        revision = UUID()
    }

    func exportPlainText(to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func exportRichText(to url: URL) throws {
        let data = try attributedText.data(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        try data.write(to: url, options: .atomic)
    }

    /// Execute the small native Notes tool family. The agent cannot select a
    /// path, workspace, or chat: AppModel resolves the owning store from the
    /// socket that made the request before this method is called.
    func perform(tool: String, arguments: [String: Any]) -> [String: Any] {
        guard !documentID.isStandalone else {
            return ["error": NotebookStorageError.standaloneTool.localizedDescription]
        }
        do { try catalog.reload(); try requireEditable() }
        catch { return ["error": error.localizedDescription] }
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
            let updatedAttributed: NSAttributedString
            switch action {
            case "replace":
                updated = incoming
                updatedAttributed = NotesTextStyle.plain(incoming)
            case "append":
                // Build the appended tail once and reuse it for both strings:
                // deriving it from `updated` by character count would miscount
                // when the separator merges with a trailing "\r" into a single
                // "\r\n" grapheme, silently desynchronizing the two.
                let separator = (text.isEmpty || incoming.isEmpty || text.hasSuffix("\n"))
                    ? "" : "\n"
                updated = text + separator + incoming
                // Appending keeps the user's existing formatting; only the
                // agent's new lines arrive with default styling.
                let combined = NSMutableAttributedString(attributedString: attributedText)
                combined.append(NotesTextStyle.plain(separator + incoming))
                updatedAttributed = combined
            default:
                return ["error": "Unknown notes_update action: \(action)."]
            }
            guard updated.count <= Self.maximumCharacters else {
                return [
                    "error": "Notes are limited to \(Self.maximumCharacters) characters."
                ]
            }
            text = updated
            attributedText = updatedAttributed
            hasUnsavedChanges = true
            revision = UUID()
            do { try flush() }
            catch {
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

    /// Record what this document is called while its owner is still known.
    /// Only a store opened by name has an origin to record, and only the first
    /// save needs to: a document's workspace and chat never change.
    private func recordName() {
        guard !recordedName, let origin else { return }
        recordedName = true
        let title: String
        switch scope {
        case .workspace:
            title = URL(fileURLWithPath: origin.workspacePath).lastPathComponent
        case .global:
            title = "Shared notes"
        case .chat:
            // A chat's title lives in the session list, which the store has no
            // access to. Left blank for a reader that can resolve one.
            title = ""
        }
        NotesNameIndex.merge(
            [
                NotesNameRecord(
                    directoryName: documentID.directoryName,
                    digest: documentID.digest,
                    scopeRaw: scope.rawValue,
                    workspacePath: origin.workspacePath,
                    sessionID: origin.sessionID,
                    title: title,
                    updatedAt: Date()
                )
            ],
            in: applicationSupport
        )
    }

    private static func validatedTitle(_ title: String) throws -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw NotebookStorageError.invalidTitle }
        return value
    }

    func rename(to title: String) throws {
        try reportingFailure {
            try requireEditable()
            let title = try Self.validatedTitle(title)
            try catalog.update(documentID, createdAt: creationDate) { record in
                guard record.lifecycle == .active else { throw NotebookStorageError.notEditable }
                record.title = title
            }
        }
    }

    func setPinned(_ pinned: Bool) throws {
        try reportingFailure {
            try requireEditable()
            try catalog.update(documentID, createdAt: creationDate) { record in
                guard record.lifecycle == .active else { throw NotebookStorageError.notEditable }
                record.isPinned = pinned
            }
        }
    }

    func moveToTrash() throws {
        try reportingFailure {
            try catalog.reload()
            if lifecycle == .trashed { return }
            try requireEditable()
            // Preserve the latest keystroke AND formatting before the tombstone
            // becomes durable. Failure keeps the original editor available.
            try flush()
            try catalog.update(documentID, createdAt: creationDate) { record in
                guard record.lifecycle == .active else { throw NotebookStorageError.notEditable }
                record.lifecycle = .trashed
                record.deletedAt = Date()
                record.generation = UUID()
            }
        }
    }

    func restore() throws {
        try reportingFailure {
            try catalog.reload()
            guard lifecycle == .trashed else { throw NotebookStorageError.notTrashed }
            guard FileManager.default.fileExists(atPath: fileURL.path)
                    || FileManager.default.fileExists(atPath: styledFileURL.path)
            else { throw CocoaError(.fileReadNoSuchFile) }
            try catalog.update(documentID) { record in
                guard record.lifecycle == .trashed else { throw NotebookStorageError.notTrashed }
                record.lifecycle = .active
                record.deletedAt = nil
                record.generation = UUID()
            }
        }
    }

    func deletePermanently() throws {
        try reportingFailure {
            try catalog.reload()
            guard lifecycle == .trashed || lifecycle == .purged else { throw NotebookStorageError.notTrashed }
            if lifecycle != .purged {
                // Tombstone first. If either removal fails, retrying this method
                // finishes the other file without reviving partially deleted text.
                try catalog.update(documentID) { record in
                    guard record.lifecycle == .trashed else { throw NotebookStorageError.notTrashed }
                    record.lifecycle = .purged
                    record.purgePending = true
                    record.generation = UUID()
                }
            }
            try NotebookFileIO.removeFileIfPresent(fileURL)
            try NotebookFileIO.removeFileIfPresent(styledFileURL)
            try catalog.update(documentID) { record in
                guard record.lifecycle == .purged else { throw NotebookStorageError.notTrashed }
                record.purgePending = false
                record.title = nil
                record.isPinned = false
                record.deletedAt = nil
            }
        }
    }

    /// Contextual IDs are fixed. Creating a new lifetime requires this explicit
    /// action; opening or writing through a stale reference never does it.
    func startFresh() throws {
        try reportingFailure {
            try catalog.reload()
            guard !documentID.isStandalone, lifecycle != .active else {
                throw NotebookStorageError.notEditable
            }
            if lifecycle == .trashed {
                // Keep the recoverable original as its own Recently Deleted
                // note before reusing the contextual ID.
                let metadata = try catalog.metadata(for: documentID)
                let archived = try Self.create(title: metadata?.title ?? scope.documentTitle,
                                               attributed: attributedText,
                                               applicationSupport: applicationSupport)
                try archived.moveToTrash()
            }
            cancelPendingSave()
            // Prepare both empty files while the tombstone still blocks readers.
            let empty = NotesTextStyle.plain("")
            let styled = try NSKeyedArchiver.archivedData(withRootObject: empty, requiringSecureCoding: true)
            try NotebookFileIO.write(Data(), to: fileURL)
            try NotebookFileIO.write(styled, to: styledFileURL)
            try catalog.update(documentID) { record in
                guard record.lifecycle != .active else { throw NotebookStorageError.notEditable }
                record.lifecycle = .active
                record.purgePending = false
                record.deletedAt = nil
                record.generation = UUID()
                record.createdAt = Date()
            }
        }
    }

    func flush() throws {
        try reportingFailure {
            try catalog.reload()
            try requireEditable()
            cancelPendingSave()
            try save()
        }
    }

    func retrySave() {
        do {
            try catalog.reload()
            if lifecycle == .purged { try deletePermanently() }
            else if hasUnsavedChanges { try flush() }
            else { saveError = nil }
        } catch { saveError = error.localizedDescription }
    }

    func flushForTesting() { try? flush() }

    private var creationDate: Date {
        (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }

    private func requireEditable() throws {
        guard documentID.isValid else { throw NotebookStorageError.invalidDocument }
        _ = try catalog.snapshot()
        guard lifecycle == .active else { throw NotebookStorageError.notEditable }
    }

    private func reportingFailure(_ operation: () throws -> Void) throws {
        do {
            try operation()
            // A successful rename or pin must not hide an earlier failed
            // content save while those edits are still waiting for Retry.
            if !hasUnsavedChanges { saveError = nil }
        }
        catch { saveError = error.localizedDescription; throw error }
    }

    private func adoptCatalogState() {
        guard let records = try? catalog.snapshot() else {
            cancelPendingSave()
            saveError = NotebookStorageError.unavailable.localizedDescription
            revision = UUID()
            return
        }
        let metadata = records[documentID]
        let nextLifecycle = metadata?.lifecycle ?? .active
        let changed = lifecycle != nextLifecycle ||
            (catalogGeneration != nil && catalogGeneration != metadata?.generation)
        catalogGeneration = metadata?.generation
        guard changed else {
            if saveError == NotebookStorageError.unavailable.localizedDescription { saveError = nil }
            return
        }
        cancelPendingSave()
        lifecycle = nextLifecycle
        hasUnsavedChanges = false
        if lifecycle == .purged {
            text = ""
            attributedText = NotesTextStyle.plain("")
        } else {
            (text, attributedText) = Self.storedDocument(plain: fileURL, styled: styledFileURL)
        }
        revision = UUID()
    }

    private func cancelPendingSave() {
        saveGeneration = UUID()
        pendingSave?.cancel()
        pendingSave = nil
    }

    private func scheduleSave() {
        cancelPendingSave()
        hasUnsavedChanges = true
        let generation = saveGeneration
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.saveGeneration == generation, self.isEditable else { return }
                do { try self.flush() }
                catch { self.saveError = error.localizedDescription }
            }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func save() throws {
        try requireEditable()
        let styled = try NSKeyedArchiver.archivedData(withRootObject: attributedText, requiringSecureCoding: true)
        // A formatting failure is visible and retryable; the current attributed
        // value stays in memory until both siblings are safely written.
        try NotebookFileIO.write(Data(text.utf8), to: fileURL)
        try NotebookFileIO.write(styled, to: styledFileURL)
        hasUnsavedChanges = false
        recordName()
        if publishesContentChanges { postContentChange() }
    }

    private func postContentChange() {
        NotificationCenter.default.post(name: .notesDocumentDidChange, object: self,
                                        userInfo: ["documentID": documentID,
                                                   "applicationSupport": applicationSupport])
    }
}
