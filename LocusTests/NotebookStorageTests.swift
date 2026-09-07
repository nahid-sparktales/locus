import AppKit
import XCTest
@testable import Locus

@MainActor
final class NotebookStorageTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NotebookStorageTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func contextual(in root: URL) -> NotesStore {
        NotesStore.shared(documentID: NotesStore.globalDocumentID, scope: .global, applicationSupport: root)
    }

    func testBlankCreationPersistsDistinctIdentitiesAndStaysOutsideNativeTools() async throws {
        let root = try root()
        let first = try NotesStore.create(title: "First", applicationSupport: root)
        let second = try NotesStore.create(title: "Second", applicationSupport: root)
        XCTAssertNotEqual(first.documentID, second.documentID)
        XCTAssertTrue(first.documentID.isStandalone)
        XCTAssertEqual(first.fileURL.deletingLastPathComponent().lastPathComponent, "Notebook Notes")
        XCTAssertEqual(try String(contentsOf: first.fileURL, encoding: .utf8), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.styledFileURL.path))
        XCTAssertNotNil(first.perform(tool: "notes_read", arguments: [:])["error"])
        XCTAssertNotNil(first.perform(tool: "notes_update", arguments: ["text": "Agent write"])["error"])
        let reopened = NotesStore.testingStore(documentID: first.documentID, scope: .global, applicationSupport: root)
        XCTAssertEqual(reopened.text, "")
        XCTAssertEqual(try reopened.catalog.metadata(for: first.documentID)?.title, "First")
    }

    func testFailedCreateRollsBackOnlyNewFilesAndRetryCreatesOneCopy() async throws {
        let root = try root()
        var failWrites = false
        let catalog = NotebookCatalog.testingShared(in: root) { data, url in
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            try NotebookFileIO.write(data, to: url)
        }
        let original = try NotesStore.create(title: "Original", attributed: NotesTextStyle.plain("Keep my original"),
                                            applicationSupport: root)
        let originalBytes = try Data(contentsOf: original.fileURL)
        let originalStyled = try Data(contentsOf: original.styledFileURL)
        var savedNotifications = 0
        let observation = NotificationCenter.default.addObserver(forName: .notesDocumentDidChange, object: nil, queue: nil) { notification in
            if (notification.userInfo?["applicationSupport"] as? URL) == root { savedNotifications += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        failWrites = true
        XCTAssertThrowsError(try NotesStore.create(title: "Copy", attributed: original.attributedText, applicationSupport: root))
        XCTAssertEqual(savedNotifications, 0, "An uncommitted create must not enter the Notebook's live list")
        XCTAssertEqual(try catalog.snapshot().count, 1)
        let directory = original.fileURL.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".txt") }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".styled") }.count, 1)
        XCTAssertEqual(try Data(contentsOf: original.fileURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: original.styledFileURL), originalStyled)
        failWrites = false
        let retry = try NotesStore.create(title: "Copy", attributed: original.attributedText, applicationSupport: root)
        XCTAssertEqual(retry.text, original.text)
        XCTAssertEqual(savedNotifications, 1)
        XCTAssertEqual(try catalog.snapshot().count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".txt") }.count, 2)
    }

    func testFlushPendingChangesImmediatelyWritesOnlyRequestedRoot() async throws {
        let root = try root()
        let otherRoot = try self.root()
        let first = try NotesStore.create(title: "First", applicationSupport: root)
        let second = contextual(in: root)
        let outside = contextual(in: otherRoot)
        first.update("Last typed first value")
        second.update("Last typed second value")
        outside.update("Wait for my own root")
        try NotesStore.flushPendingChanges(applicationSupport: root)
        XCTAssertEqual(try String(contentsOf: first.fileURL, encoding: .utf8), "Last typed first value")
        XCTAssertEqual(try String(contentsOf: second.fileURL, encoding: .utf8), "Last typed second value")
        XCTAssertFalse(first.hasUnsavedChanges)
        XCTAssertFalse(second.hasUnsavedChanges)
        XCTAssertTrue(outside.hasUnsavedChanges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.fileURL.path))
        try NotesStore.flushPendingChanges(applicationSupport: otherRoot)
    }

    func testFlushPendingChangesAttemptsOtherNotesAndRetainsFailedEdits() async throws {
        let root = try root()
        let failing = try NotesStore.create(title: "Needs retry", applicationSupport: root)
        let succeeding = contextual(in: root)
        try FileManager.default.removeItem(at: failing.styledFileURL)
        try FileManager.default.createDirectory(at: failing.styledFileURL, withIntermediateDirectories: false)
        failing.update("Still needs to be saved")
        succeeding.update("This one must finish")
        XCTAssertThrowsError(try NotesStore.flushPendingChanges(applicationSupport: root))
        XCTAssertTrue(failing.hasUnsavedChanges)
        XCTAssertNotNil(failing.saveError)
        XCTAssertEqual(failing.text, "Still needs to be saved")
        XCTAssertFalse(succeeding.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: succeeding.fileURL, encoding: .utf8), "This one must finish")
        try FileManager.default.removeItem(at: failing.styledFileURL)
        try NotesStore.flushPendingChanges(applicationSupport: root)
        XCTAssertFalse(failing.hasUnsavedChanges)
        XCTAssertNil(failing.saveError)
    }

    func testRenamePinAndSortPreserveContentIdentityAndEditorRevision() async throws {
        let root = try root()
        let store = contextual(in: root)
        store.update("Working text")
        try store.flush()
        let revision = store.revision
        let id = store.documentID
        try store.rename(to: "My chosen title")
        try store.setPinned(true)
        try store.catalog.setSortOrder(.titleAscending)
        NotesNameIndex.merge([NotesNameRecord(directoryName: id.directoryName, digest: id.digest,
                                              scopeRaw: "global", workspacePath: "", sessionID: "",
                                              title: "Inferred title", updatedAt: Date())], in: root)
        try store.catalog.reload()
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.documentID, id)
        XCTAssertEqual(store.text, "Working text")
        let metadata = try XCTUnwrap(store.catalog.metadata(for: id))
        XCTAssertEqual(metadata.title, "My chosen title")
        XCTAssertTrue(metadata.isPinned)
        XCTAssertEqual(store.catalog.sortOrder, .titleAscending)
        let catalogRevision = store.catalog.revision
        try store.catalog.reload()
        XCTAssertEqual(store.catalog.revision, catalogRevision, "Reloading our own dates must not publish changes")
    }

    func testTrashFlushesPendingRichEditsAndRestoreRejectsOldEditorCallbacks() async throws {
        let root = try root()
        let store = contextual(in: root)
        let rich = NSAttributedString(string: "Unsaved formatted note", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.systemRed
        ])
        store.updateAttributed(rich)
        let oldRevision = store.revision
        try store.moveToTrash()
        XCTAssertEqual(store.lifecycle, .trashed)
        XCTAssertFalse(store.isEditable)
        XCTAssertFalse(store.hasUnsavedChanges)
        store.update("Stale edit")
        XCTAssertNotNil(store.perform(tool: "notes_update", arguments: ["text": "Stale tool"])["error"])
        XCTAssertNotNil(store.perform(tool: "notes_read", arguments: [:])["error"])
        try store.restore()
        XCTAssertTrue(store.isEditable)
        XCTAssertTrue(store.attributedText.isEqual(to: rich))
        store.updateAttributed(NotesTextStyle.plain("Old callback"), expectedRevision: oldRevision)
        XCTAssertEqual(store.text, rich.string)
        XCTAssertNotEqual(store.revision, oldRevision)
    }

    func testPurgeCannotBeUndoneByDelayedAutosaveOrStaleReferences() async throws {
        let root = try root()
        let store = contextual(in: root)
        store.update("Typing immediately before deletion")
        try store.moveToTrash()
        try store.deletePermanently()
        store.update("A late editor notification")
        store.flushForTesting()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(store.lifecycle, .purged)
        XCTAssertEqual(store.text, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.styledFileURL.path))
        let reopened = NotesStore.testingStore(documentID: store.documentID, scope: .global, applicationSupport: root)
        XCTAssertEqual(reopened.lifecycle, .purged)
        XCTAssertFalse(reopened.isEditable)
        XCTAssertFalse(try XCTUnwrap(reopened.catalog.metadata(for: store.documentID)).purgePending)
    }

    func testMissingCatalogAfterRelaunchFailsClosedButUntouchedLegacyRootOpens() async throws {
        let root = try root()
        let store = contextual(in: root)
        store.update("Recoverable deleted content")
        try store.moveToTrash()
        XCTAssertTrue(FileManager.default.fileExists(atPath: NotebookCatalog.initializationMarkerURL(in: root).path))
        try FileManager.default.removeItem(at: NotebookCatalog.fileURL(in: root))
        let relaunched = NotebookCatalog(applicationSupport: root)
        XCTAssertNotNil(relaunched.loadError)
        XCTAssertThrowsError(try relaunched.snapshot())
        let legacyRoot = try self.root()
        let legacy = NotebookCatalog(applicationSupport: legacyRoot)
        XCTAssertTrue(try legacy.snapshot().isEmpty)
        XCTAssertNil(legacy.loadError)
    }

    func testPurgeFailureKeepsDurablePendingCleanupAndRetryFinishesBothFiles() async throws {
        let root = try root()
        let store = contextual(in: root)
        store.update("Delete me")
        try store.rename(to: "Private custom title")
        try store.setPinned(true)
        try store.moveToTrash()
        try FileManager.default.removeItem(at: store.styledFileURL)
        try FileManager.default.createDirectory(at: store.styledFileURL, withIntermediateDirectories: false)
        try Data("obstruction".utf8).write(to: store.styledFileURL.appendingPathComponent("child"))
        XCTAssertThrowsError(try store.deletePermanently())
        XCTAssertEqual(store.lifecycle, .purged)
        XCTAssertNotNil(store.saveError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let onDisk = NotebookCatalog(applicationSupport: root)
        XCTAssertTrue(try XCTUnwrap(onDisk.metadata(for: store.documentID)).purgePending)
        XCTAssertThrowsError(try store.restore())
        let reopened = NotesStore.testingStore(documentID: store.documentID, scope: .global, applicationSupport: root)
        try FileManager.default.removeItem(at: store.styledFileURL)
        reopened.retrySave()
        XCTAssertNil(reopened.saveError)
        XCTAssertFalse(try XCTUnwrap(reopened.catalog.metadata(for: store.documentID)).purgePending)
        let marker = try XCTUnwrap(reopened.catalog.metadata(for: store.documentID))
        XCTAssertNil(marker.title)
        XCTAssertNil(marker.deletedAt)
        XCTAssertFalse(marker.isPinned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.styledFileURL.path))
    }

    func testFormattingSaveFailureRetainsEditsAndRetryAfterRename() async throws {
        let root = try root()
        let store = contextual(in: root)
        store.update("Original")
        try store.flush()
        try FileManager.default.removeItem(at: store.styledFileURL)
        try FileManager.default.createDirectory(at: store.styledFileURL, withIntermediateDirectories: false)
        let rich = NSAttributedString(string: "Latest", attributes: [.font: NSFont.boldSystemFont(ofSize: 21)])
        store.updateAttributed(rich)
        XCTAssertThrowsError(try store.flush())
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertNotNil(store.saveError)
        try store.rename(to: "Renamed while unsaved")
        XCTAssertNotNil(store.saveError, "Metadata success must not hide a content save error")
        try FileManager.default.removeItem(at: store.styledFileURL)
        store.retrySave()
        XCTAssertNil(store.saveError)
        XCTAssertFalse(store.hasUnsavedChanges)
        let reopened = NotesStore.testingStore(documentID: store.documentID, scope: .global, applicationSupport: root)
        XCTAssertTrue(reopened.attributedText.isEqual(to: rich))
    }

    func testCorruptMetadataFailsClosedAndCanBeRetriedWithoutLosingTypedText() async throws {
        let root = try root()
        let store = contextual(in: root)
        try store.rename(to: "Named")
        store.update("Still in memory")
        let url = NotebookCatalog.fileURL(in: root)
        let goodData = try Data(contentsOf: url)
        try Data("broken catalog".utf8).write(to: url)
        XCTAssertThrowsError(try store.flush())
        XCTAssertFalse(store.isEditable)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertNotNil(store.perform(tool: "notes_read", arguments: [:])["error"])
        store.update("Must not replace the pending text")
        XCTAssertEqual(store.text, "Still in memory")
        try goodData.write(to: url, options: .atomic)
        store.retrySave()
        XCTAssertTrue(store.isEditable)
        XCTAssertNil(store.saveError)
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "Still in memory")
    }

    func testFailedCatalogWriteDoesNotPublishOrReplaceCommittedMetadata() async throws {
        let root = try root()
        let original = NotebookCatalog(applicationSupport: root)
        let id = NotesDocumentID.standalone()
        try original.update(id) { $0.title = "Committed" }
        let url = NotebookCatalog.fileURL(in: root)
        let data = try Data(contentsOf: url)
        let failing = NotebookCatalog(applicationSupport: root, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let revision = failing.revision
        XCTAssertThrowsError(try failing.update(id) { $0.title = "Unwritten" })
        XCTAssertEqual(try failing.metadata(for: id)?.title, "Committed")
        XCTAssertEqual(failing.revision, revision)
        XCTAssertEqual(try Data(contentsOf: url), data)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try original.reload(), "A formerly existing catalog must not become an empty catalog")
        XCTAssertThrowsError(try original.snapshot())
    }

    func testStartFreshPreservesRecoverableOriginalAndInvalidatesItsRevision() async throws {
        let root = try root()
        let store = contextual(in: root)
        store.update("Original contextual note")
        try store.moveToTrash()
        let oldRevision = store.revision
        try store.startFresh()
        XCTAssertEqual(store.lifecycle, .active)
        XCTAssertEqual(store.text, "")
        XCTAssertNotEqual(store.revision, oldRevision)
        store.update("Old lifetime", expectedRevision: oldRevision)
        XCTAssertEqual(store.text, "")
        let archived = try XCTUnwrap(store.catalog.snapshot().values.first {
            $0.documentID.isStandalone && $0.lifecycle == .trashed
        })
        let original = NotesStore.shared(documentID: archived.documentID, scope: .global, applicationSupport: root)
        XCTAssertEqual(original.text, "Original contextual note")
        try original.restore()
        XCTAssertEqual(original.text, "Original contextual note")
    }

    func testSharedStoresAreCanonicalWithinOneSupportRootOnly() async throws {
        let firstRoot = try root()
        let secondRoot = try root()
        let first = contextual(in: firstRoot)
        XCTAssertTrue(first === contextual(in: firstRoot))
        let second = contextual(in: secondRoot)
        XCTAssertFalse(first === second)
        first.update("First root")
        try first.moveToTrash()
        XCTAssertEqual(second.lifecycle, .active)
        XCTAssertEqual(second.text, "")
    }

    func testSearchReaderHonorsEmptyMirrorStyledFallbackAndBounds() async throws {
        let root = try root()
        let store = contextual(in: root)
        store.update("Archive fallback")
        try store.flush()
        try FileManager.default.removeItem(at: store.fileURL)
        XCTAssertEqual(NotesStore.storedText(plain: store.fileURL, styled: store.styledFileURL), "Archive fallback")
        try Data().write(to: store.fileURL)
        XCTAssertEqual(NotesStore.storedText(plain: store.fileURL, styled: store.styledFileURL), "")
        try Data(repeating: 65, count: 100_100).write(to: store.fileURL)
        XCTAssertEqual(NotesStore.storedText(plain: store.fileURL, styled: store.styledFileURL).count, 100_000)
        try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: store.fileURL)
        XCTAssertEqual(NotesStore.storedText(plain: store.fileURL, styled: store.styledFileURL), "")
    }
}
