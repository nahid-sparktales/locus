import AppKit
import XCTest
@testable import Locus

@MainActor
private final class NotebookUndoTextView: NSTextView {
    let noteUndoManager = UndoManager()
    override var undoManager: UndoManager? { noteUndoManager }
}

@MainActor
final class NotebookEditorTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testReadOnlyFormattingAndInsertionCannotChangePreview() {
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(NotesTextStyle.plain("Keep this note"))
        textView.isEditable = false
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        let proxy = NotesEditorProxy()
        proxy.textView = textView
        let original = NSAttributedString(attributedString: textView.textStorage!)

        proxy.insert("Overwrite")
        proxy.toggleBold()
        proxy.toggleUnderline()
        proxy.toggleList(.bullet)
        proxy.toggleChecklist()
        proxy.clearFormatting()

        XCTAssertTrue(textView.textStorage!.isEqual(to: original))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 4))
    }

    func testEditorRejectsStaleCallbacksAfterTrashAndRestore() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore.create(title: "Original", attributed: NotesTextStyle.plain("Saved content"), applicationSupport: root)
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(store.attributedText)
        let proxy = NotesEditorProxy()
        proxy.textView = textView
        let coordinator = RichNotesEditor.Coordinator(store: store, proxy: proxy)
        coordinator.textView = textView
        XCTAssertTrue(coordinator.canEdit)

        try store.moveToTrash()
        XCTAssertFalse(coordinator.canEdit)
        try store.restore()
        // The old editor must reconcile its revision and undo history before
        // it can deliver an edit, even if deletion and restore happened in one turn.
        XCTAssertFalse(coordinator.canEdit)
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "Stale"))
        textView.string = "Stale editor text"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertEqual(store.text, "Saved content")
        await settleReconciliation()
        XCTAssertTrue(coordinator.canEdit)
        XCTAssertEqual(textView.string, "Saved content")
    }

    func testReconciliationPreservesSelectionAndUndoWhenContentDidNotChange() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore.create(title: "Same content", attributed: NotesTextStyle.plain("Keep selection"), applicationSupport: root)
        let textView = NotebookUndoTextView()
        textView.allowsUndo = true
        textView.textStorage?.setAttributedString(store.attributedText)
        textView.setSelectedRange(NSRange(location: 5, length: 9))
        textView.noteUndoManager.registerUndo(withTarget: textView) { _ in }
        let proxy = NotesEditorProxy()
        proxy.textView = textView
        let coordinator = RichNotesEditor.Coordinator(store: store, proxy: proxy)
        coordinator.textView = textView

        try store.rename(to: "Renamed")
        try store.setPinned(true)
        coordinator.scheduleExternalReconciliation()
        await settleReconciliation()

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 9))
        XCTAssertEqual(textView.string, "Keep selection")
        XCTAssertTrue(coordinator.canEdit)
        XCTAssertTrue(textView.noteUndoManager.canUndo, "Metadata changes must preserve document undo")
    }

    func testReadOnlyCoordinatorRejectsEditingEvenForAnActiveStore() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore.create(title: "Preview", applicationSupport: root)
        let textView = NSTextView()
        let coordinator = RichNotesEditor.Coordinator(store: store, proxy: NotesEditorProxy(), readOnly: true)
        XCTAssertFalse(coordinator.canEdit)
        XCTAssertFalse(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "Edit"))
    }

    private func settleReconciliation() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
