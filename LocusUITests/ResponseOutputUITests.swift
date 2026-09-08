import AppKit
import XCTest

/// Exercises the production transcript with real disposable files and notes.
/// No provider runs, user directories, or persistent output libraries are used.
final class ResponseOutputUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_RESPONSE_OUTPUT"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "1180"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "900"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    }

    override func tearDownWithError() throws { app?.terminate() }

    func testTenFileCollectionShowsOneCountAndBrowsesAllTypes() {
        launch(focus: "files")
        let collection = element("message.fileCollection")
        XCTAssertTrue(collection.waitForExistence(timeout: 10))
        let headings = collection.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "File collection, 10 files,"))
        XCTAssertEqual(headings.count, 1)
        XCTAssertEqual(headings.firstMatch.label, "File collection, 10 files, collapse")
        for category in ["Documents", "Scripts", "Tests", "Setup"] {
            XCTAssertTrue(collection.staticTexts[category].exists, category)
        }
        clickInTranscript(element("message.fileCollection.showFiles"))
        let search = element("files.search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let count = element("files.count")
        // SwiftUI Text is exposed through AXValue on macOS 15. Match the
        // complete visible count on either supported accessibility surface.
        XCTAssertTrue(waitUntil {
            count.label == "10 items in workspace root"
                || count.value as? String == "10 items in workspace root"
        })
        for filename in ["AGENTS.md", "audit_findings_report.pdf", "code_audit_report.pdf", "storyboobible-influencer-intro-email.pdf", "reddit_latest.py"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "files.row.", filename)).firstMatch.exists, filename)
        }
        capture("Response files and all-type workspace browser")
        search.click()
        search.typeText("audit_findings_report.pdf")
        let result = element("files.row.0")
        XCTAssertTrue(waitUntil { result.label == "audit_findings_report.pdf" })
        result.click()
        XCTAssertTrue(element("library.pdf.page").waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["This file is not readable as UTF-8 text."].exists)
        capture("Response PDF opens in document preview")
    }

    func testWritingDraftEditsSaveAndOriginalRemainsAvailable() {
        launch(focus: "writing")
        let edit = element("message.writing.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertTrue(edit.isEnabled)
        clickInTranscript(edit)
        let editor = element("message.writing.draft.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Edited collaboration draft from the response UI test.")
        clickInTranscript(edit)
        XCTAssertTrue(waitUntil { edit.label == "Edit" })
        clickInTranscript(element("message.writing.copy"))
        XCTAssertTrue(waitUntil { NSPasteboard.general.string(forType: .string) == "Edited collaboration draft from the response UI test." })
        capture("Response writing edited and saved")
        let actions = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Writing actions")).firstMatch
        clickInTranscript(actions)
        let original = app.menuItems["View original"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.click()
        clickInTranscript(element("message.writing.copy"))
        XCTAssertTrue(waitUntil {
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            return copied.contains("Hi Morgan,") && copied.contains("An invitation to collaborate")
                && !copied.contains("Edited collaboration draft")
        })
        capture("Response writing original remains intact")
    }

    func testTableCopyIncludesCollapsedRowsAndSavedArtifactOpens() {
        launch(focus: "table")
        let collapse = element("message.table.collapse")
        XCTAssertTrue(collapse.waitForExistence(timeout: 10))
        clickInTranscript(collapse)
        XCTAssertTrue(waitUntil { collapse.label.contains("Expand") })
        clickInTranscript(element("message.table.copy"))
        XCTAssertTrue(waitUntil {
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            return copied.hasPrefix("File\tStatus\tSize") && copied.contains("Example 24\tReviewed\t240 KB")
        })
        let lines = (NSPasteboard.general.string(forType: .string) ?? "").split(separator: "\n")
        XCTAssertEqual(lines.count, 25)
        capture("Response collapsed table copies all rows")
        app.terminate()
        launch(focus: "artifact")
        XCTAssertTrue(element("message.responseSources").waitForExistence(timeout: 10))
        let artifact = element("message.deliveredArtifact")
        XCTAssertTrue(artifact.waitForExistence(timeout: 10))
        let saved = artifact.buttons["Open saved version"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { saved.isEnabled })
        clickInTranscript(saved)
        XCTAssertTrue(app.textFields["Search outputs"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(element("library.output.versions").waitForExistence(timeout: 10))
        capture("Response artifact opens its saved version")
    }

    func testLightDarkAndNarrowControlsRemainLabeledAndReachable() {
        for appearance in ["light", "dark"] {
            app.launchEnvironment["LOCUS_UI_TESTING_APPEARANCE"] = appearance
            app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = appearance == "dark" ? "760" : "1180"
            app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "800"
            launch(focus: "writing")
            for id in ["message.writing.edit", "message.writing.copy"] {
                let control = element(id)
                XCTAssertTrue(control.waitForExistence(timeout: 10), id)
                scrollIntoView(control)
                XCTAssertFalse(control.label.isEmpty, id)
                XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -2, dy: -2).contains(control.frame), id)
            }
            clickInTranscript(element("message.writing.edit"))
            let editor = element("message.writing.draft.editor")
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Keyboard editing works in " + appearance + ".")
            XCTAssertTrue(waitUntil { (editor.value as? String ?? "").contains("Keyboard editing works") })
            app.typeKey("z", modifierFlags: .command)
            capture("Response output \(appearance) \(appearance == "dark" ? "narrow" : "wide") keyboard and accessibility")
            app.terminate()
        }
    }

    private func launch(focus: String) {
        app.launchEnvironment["LOCUS_UI_TESTING_RESPONSE_FOCUS"] = focus
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(element("message.structuredResponse").waitForExistence(timeout: 15))
    }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10) == .completed
    }
    private func scrollIntoView(_ target: XCUIElement) {
        let transcript = element("conversation.scroll")
        guard transcript.exists else { return }
        for _ in 0..<18 {
            let viewport = transcript.frame, frame = target.frame
            let below = frame.maxY - (viewport.maxY - 24), above = (viewport.minY + 24) - frame.minY
            let delta = below > 0 ? below : (above > 0 ? -above : 0)
            if abs(delta) < 1 { return }
            transcript.scroll(byDeltaX: 0, deltaY: -max(-400, min(400, delta)))
        }
    }
    private func clickInTranscript(_ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        scrollIntoView(target)
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
    private func capture(_ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
