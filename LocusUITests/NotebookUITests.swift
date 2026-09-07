import AppKit
import XCTest

/// The standalone surface uses the app's isolated, temporary UI-test notes root.
final class NotebookUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"] = "notebook"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    }

    override func tearDownWithError() throws { app.terminate() }

    func testCreateDuplicatePinTrashPreviewAndRestore() {
        launchNotebook()
        createNote(named: "Notebook lifecycle original")
        let editor = element("notebook.document.editor")
        editor.click()
        editor.typeText("Remember this notebook sentence.")
        XCTAssertTrue(waitUntil { self.editorText.contains("Remember this notebook sentence.") })

        chooseAction("duplicate", title: "Duplicate")
        XCTAssertTrue(waitUntil { self.element("notebook.title").value as? String == "Notebook lifecycle original copy" })
        // Duplication focuses the title just as creation does.
        replaceFocusedTitle(with: "Notebook lifecycle duplicate")
        XCTAssertTrue(editorText.contains("Remember this notebook sentence."))
        chooseAction("pin", title: "Pin")
        element("notebook.noteActions").click()
        XCTAssertTrue(menuItem("notebook.action.pin", title: "Unpin").waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        chooseAction("trash", title: "Move to Recently Deleted")
        element("notebook.recentlyDeleted").click()
        let deleted = row(named: "Notebook lifecycle duplicate")
        XCTAssertTrue(deleted.waitForExistence(timeout: 5))
        deleted.click()
        XCTAssertTrue(element("notebook.deletedTitle").waitForExistence(timeout: 5))
        let savedText = editorText
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        app.typeText("A deleted note stays read only")
        XCTAssertEqual(editorText, savedText)
        XCTAssertTrue(element("notebook.restore").exists)
        element("notebook.restore").click()
        XCTAssertTrue(waitUntil { !self.row(named: "Notebook lifecycle duplicate").exists })
        element("notebook.allNotes").click()
        let restored = row(named: "Notebook lifecycle duplicate")
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        restored.click()
        XCTAssertEqual(editorText, savedText)
        capture("Notebook restored note")
    }

    func testDeleteKeyStaysInEditorAndListDeletionRequiresPurgeConfirmation() {
        launchNotebook()
        createNote(named: "Notebook keyboard deletion")
        let editor = element("notebook.document.editor")
        editor.click()
        editor.typeText("Keep this word")
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil { self.editorText.contains("Keep this wor") && !self.editorText.contains("Keep this word") })
        XCTAssertTrue(row(named: "Notebook keyboard deletion").exists)
        XCTAssertEqual(element("notebook.recentlyDeleted").value as? String, "0 notes")

        row(named: "Notebook keyboard deletion").click()
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil { !self.row(named: "Notebook keyboard deletion").exists })
        element("notebook.recentlyDeleted").click()
        let deleted = row(named: "Notebook keyboard deletion")
        XCTAssertTrue(deleted.waitForExistence(timeout: 5))
        deleted.click()
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil { self.confirmation.exists })
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(deleted.exists)
        chooseAction("deletePermanently", title: "Delete Permanently…")
        XCTAssertTrue(waitUntil { self.confirmation.exists })
        confirmButton("notebook.confirmPermanentDelete", title: "Delete Permanently").click()
        XCTAssertTrue(waitUntil { !self.row(named: "Notebook keyboard deletion").exists })
        XCTAssertTrue(element("notebook.trashEmpty").exists)
        XCTAssertFalse(element("notebook.restore").exists)
    }

    func testNarrowNotebookSupportsCommandNAndEmptyTrashConfirmation() {
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "760"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "600"
        launchNotebook()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(element("notebook.title").waitForExistence(timeout: 5))
        replaceFocusedTitle(with: "Narrow notebook note")
        for id in ["notebook.newNote", "notebook.close", "notebook.search", "notebook.title", "notebook.noteActions"] {
            let control = element(id)
            XCTAssertTrue(control.isHittable, id)
            XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(control.frame), id)
        }
        chooseAction("trash", title: "Move to Recently Deleted")
        element("notebook.recentlyDeleted").click()
        XCTAssertTrue(row(named: "Narrow notebook note").waitForExistence(timeout: 5))
        element("notebook.emptyTrash").click()
        XCTAssertTrue(waitUntil { self.confirmation.exists })
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(row(named: "Narrow notebook note").exists)
        element("notebook.emptyTrash").click()
        confirmButton("notebook.confirmEmptyTrash", title: "Delete All Permanently").click()
        XCTAssertTrue(element("notebook.trashEmpty").waitForExistence(timeout: 5))
        XCTAssertEqual(element("notebook.recentlyDeleted").value as? String, "0 notes")
        capture("Notebook narrow Recently Deleted")
    }

    func testInvalidTitleSurvivesNewNoteButtonAndKeyboardShortcut() {
        launchNotebook()
        createNote(named: "Notebook title validation")
        let title = element("notebook.title")
        title.click()
        app.typeKey("a", modifierFlags: .command)
        let draft = String(repeating: "A", count: 201)
        app.typeText(draft)
        element("notebook.newNote").click()
        XCTAssertTrue(element("notebook.error").waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, draft)
        XCTAssertTrue(row(named: "Notebook title validation").exists)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertEqual(title.value as? String, draft)
        XCTAssertFalse(row(named: "Untitled Note").exists)

        title.click()
        replaceFocusedTitle(with: "Notebook corrected title")
        XCTAssertTrue(row(named: "Notebook corrected title").waitForExistence(timeout: 5))
        title.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Notebook latest title")
        row(named: "Notebook corrected title").click()
        XCTAssertTrue(waitUntil { self.element("notebook.title").value as? String == "Notebook latest title" })
        XCTAssertTrue(row(named: "Notebook latest title").exists)
        element("notebook.newNote").click()
        XCTAssertTrue(waitUntil { self.element("notebook.title").value as? String == "Untitled Note" })
        XCTAssertFalse(element("notebook.error").exists)
    }

    private func launchNotebook() {
        app.launch()
        XCTAssertTrue(element("notebook.newNote").waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "notebook.entry.")).firstMatch.waitForExistence(timeout: 10))
    }

    private func createNote(named title: String) {
        element("notebook.newNote").click()
        XCTAssertTrue(element("notebook.title").waitForExistence(timeout: 5))
        replaceFocusedTitle(with: title)
        XCTAssertTrue(element("notebook.document.editor").waitForExistence(timeout: 5))
    }

    private func replaceFocusedTitle(with title: String) {
        app.typeKey("a", modifierFlags: .command)
        app.typeText(title)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { self.element("notebook.title").value as? String == title })
    }

    private var editorText: String { element("notebook.document.editor").value as? String ?? "" }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func row(named title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "notebook.entry.", title + ",")).firstMatch
    }

    private func chooseAction(_ action: String, title: String) {
        element("notebook.noteActions").click()
        let item = menuItem("notebook.action." + action, title: title)
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    private func menuItem(_ id: String, title: String) -> XCUIElement {
        let identified = app.menuItems[id].firstMatch
        return identified.exists ? identified : app.menuItems[title].firstMatch
    }

    private func confirmButton(_ id: String, title: String) -> XCUIElement {
        XCTAssertTrue(waitUntil { self.confirmation.exists })
        let identified = confirmation.buttons[id].firstMatch
        return identified.exists ? identified : confirmation.buttons[title].firstMatch
    }

    private var confirmation: XCUIElement {
        let alert = app.alerts.firstMatch
        // macOS 15 exposes SwiftUI alerts as sheets with the alert label.
        return alert.exists ? alert : app.sheets.matching(NSPredicate(format: "label == %@", "alert")).firstMatch
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: timeout) == .completed
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
