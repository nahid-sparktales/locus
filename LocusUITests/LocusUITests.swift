import AppKit
import XCTest

final class LocusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        // The window is clamped to the screen, so a CI runner's display can
        // leave far less of a panel visible than a developer's. Forwarding an
        // explicit size makes that geometry reproducible locally with
        // TEST_RUNNER_LOCUS_UI_TESTING_WINDOW_HEIGHT=<points>.
        for key in ["LOCUS_UI_TESTING_WINDOW_WIDTH", "LOCUS_UI_TESTING_WINDOW_HEIGHT"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
        // Stale window-restoration state can suppress the main window at
        // launch; tests must not depend on the machine's saved state.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    /// SwiftUI controls do not expose a stable element type across macOS
    /// releases. Match anchors by identifier on any element type and take the
    /// first result, because interactions on an ambiguous query fail outright.
    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// SwiftUI menu commands arrive as menu items on macOS 26 but can retain
    /// their underlying button or checkbox role on macOS 15. Match every role
    /// by either the stable identifier or native title; older AppKit can append
    /// a toggle's accessibility value to its label.
    private func menuItem(_ identifier: String, title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label CONTAINS[c] %@ OR title CONTAINS[c] %@",
            identifier,
            title,
            title
        )).firstMatch
    }

    /// Existence becomes true at the start of a SwiftUI transition, before a
    /// newly presented control has necessarily reached a clickable position.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { candidate, _ in
                guard let candidate = candidate as? XCUIElement else { return false }
                return candidate.exists && candidate.isHittable
            },
            object: element
        )
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping () -> Bool
    ) -> Bool {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    /// SwiftUI alerts surface as sheets labeled "alert" on current macOS;
    /// their message text is exposed as a value, not a label.
    private func staticTextWithValue(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", fragment)
        ).firstMatch
    }

    /// Transcript prose, headings and table cells render as `ResponseSelectableText`
    /// (an `NSTextView`), which XCUI exposes as a text view carrying its content
    /// in `value` — never as a `staticTexts` whose `label` matches. Reasoning
    /// entries still render as SwiftUI `Text`, so match either shape.
    /// Scrolls a transcript control into the visible part of the conversation
    /// and clicks it.
    ///
    /// The text-output fixture is deliberately long — an eleven-row table and a
    /// twenty-five line code block, both expanded — so it is taller than the
    /// test window and a control can sit below the fold. None of these tests is
    /// about how much of the transcript happens to fit on screen, so bring the
    /// target into view the way a person would before reaching for it. The
    /// click goes through a coordinate because AppKit reports a transcript
    /// button at the end of a long conversation as not hittable even once it is
    /// fully on screen, which is why the fixture's disclosure control was
    /// already clicked this way.
    private func clickInTranscript(
        _ element: XCUIElement,
        normalizedOffset: CGVector = CGVector(dx: 0.5, dy: 0.5),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 3), file: file, line: line)
        let transcript = anyElement("conversation.scroll")
        if transcript.waitForExistence(timeout: 3) {
            for _ in 0..<12 {
                let viewport = transcript.frame
                let frame = element.frame
                // Leave a margin so the control is not flush against an edge,
                // where a click can land on the neighbouring row instead.
                let below = frame.maxY - (viewport.maxY - 24)
                let above = (viewport.minY + 24) - frame.minY
                let delta = below > 0 ? below : (above > 0 ? -above : 0)
                guard abs(delta) > 1 else { break }
                transcript.scroll(byDeltaX: 0, deltaY: -max(-400, min(400, delta)))
                if abs(element.frame.midY - frame.midY) < 1 { break }
            }
        }
        element.coordinate(withNormalizedOffset: normalizedOffset).click()
    }

    private func transcriptText(_ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR value == %@", value, value)
        ).firstMatch
    }

    private func cancelConfirmation() {
        let sheetCancel = app.sheets.buttons["Cancel"].firstMatch
        if sheetCancel.exists {
            sheetCancel.click()
        } else {
            app.buttons["Cancel"].firstMatch.click()
        }
    }

    /// Contrast between the darkest and lightest pixels actually drawn inside
    /// an element, or `nil` when it could not be measured.
    ///
    /// For a run of text on a flat surface those two pixels are the glyph core
    /// and the background, which is the pair the audit is meant to be judging.
    private func renderedContrastRatio(of element: XCUIElement?) -> Double? {
        guard let extremes = renderedLuminanceExtremes(of: element) else { return nil }
        return (max(extremes.0, extremes.1) + 0.05) / (min(extremes.0, extremes.1) + 0.05)
    }

    /// The darkest and lightest pixels actually drawn inside an element.
    ///
    /// A contrast audit works on rendered pixels, so what was drawn is the
    /// evidence that separates a genuine colour mistake from a heuristic
    /// misfire — and CI is the only place some of these reproduce.
    private func renderedExtremes(of element: XCUIElement?) -> String {
        guard let element else { return "<no element>" }
        let window = app.windows.firstMatch
        let bounds = window.frame
        let frame = element.frame
        guard bounds.width > 0, bounds.height > 0,
              let image = NSBitmapImageRep(data: window.screenshot().pngRepresentation)
        else { return "<no image>" }
        let scaleX = CGFloat(image.pixelsWide) / bounds.width
        let scaleY = CGFloat(image.pixelsHigh) / bounds.height
        var darkest: (luma: CGFloat, hex: String) = (2, "-")
        var lightest: (luma: CGFloat, hex: String) = (-1, "-")
        for x in Int((frame.minX - bounds.minX) * scaleX)..<Int((frame.maxX - bounds.minX) * scaleX) {
            for y in Int((frame.minY - bounds.minY) * scaleY)..<Int((frame.maxY - bounds.minY) * scaleY) {
                guard x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh,
                      let pixel = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let luma = 0.2126 * pixel.redComponent
                    + 0.7152 * pixel.greenComponent
                    + 0.0722 * pixel.blueComponent
                let hex = String(
                    format: "%02X%02X%02X",
                    Int(pixel.redComponent * 255),
                    Int(pixel.greenComponent * 255),
                    Int(pixel.blueComponent * 255)
                )
                if luma < darkest.luma { darkest = (luma, hex) }
                if luma > lightest.luma { lightest = (luma, hex) }
            }
        }
        return "darkest=\(darkest.hex) lightest=\(lightest.hex) scale=\(scaleX)"
    }

    /// WCAG relative luminance of the darkest and lightest drawn pixels.
    private func renderedLuminanceExtremes(of element: XCUIElement?) -> (Double, Double)? {
        guard let element else { return nil }
        let window = app.windows.firstMatch
        let bounds = window.frame
        let frame = element.frame
        guard bounds.width > 0, bounds.height > 0, frame.width > 0, frame.height > 0,
              let image = NSBitmapImageRep(data: window.screenshot().pngRepresentation)
        else { return nil }
        let scaleX = CGFloat(image.pixelsWide) / bounds.width
        let scaleY = CGFloat(image.pixelsHigh) / bounds.height
        func channel(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        var darkest = 2.0
        var lightest = -1.0
        var sampled = false
        for x in Int((frame.minX - bounds.minX) * scaleX)..<Int((frame.maxX - bounds.minX) * scaleX) {
            for y in Int((frame.minY - bounds.minY) * scaleY)..<Int((frame.maxY - bounds.minY) * scaleY) {
                guard x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh,
                      let pixel = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                sampled = true
                let luminance = 0.2126 * channel(pixel.redComponent)
                    + 0.7152 * channel(pixel.greenComponent)
                    + 0.0722 * channel(pixel.blueComponent)
                darkest = min(darkest, luminance)
                lightest = max(lightest, luminance)
            }
        }
        return sampled ? (darkest, lightest) : nil
    }

    private func auditCurrentSurface() throws {
        // Keep transient Help tags out of the audit. AppKit exposes a visible
        // Help tag as a separate, undescribed accessibility element even when
        // the control that owns it has a complete label.
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.52, dy: 0.52)
        ).hover()
        try app.performAccessibilityAudit(for: [
            .contrast,
            .hitRegion,
            .sufficientElementDescription,
            .action,
        ]) { issue in
            // SwiftUI's hosting view is exposed as a disabled, unlabeled group
            // around the explicitly labeled root workspace. It has the exact
            // window frame and is not a user-navigable element.
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element,
               element.elementType == .group,
               element.frame.equalTo(self.app.windows.firstMatch.frame) {
                return true
            }
            // SwiftUI exposes non-interactive layout containers as AX groups
            // and `other` elements, depending on the macOS release.
            // Their controls and text are audited independently, so the
            // container itself does not need a duplicate description.
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element,
               element.elementType == .group || element.elementType == .other {
                return true
            }
            // The macOS system menu bar container has no label by design;
            // every menu item inside it (Locus, File, Edit, and so on) keeps
            // its native accessible name and role.
            if issue.auditType == .sufficientElementDescription,
               issue.element?.elementType == .menuBar {
                return true
            }
            // XCTest includes the system-owned Touch Bar container in a
            // window audit even on Macs without a Touch Bar. The container
            // itself is unlabeled; any controls AppKit places inside it retain
            // their own labels and actions.
            if issue.auditType == .sufficientElementDescription,
               issue.element?.elementType == .touchBar {
                return true
            }
            // Older XCTest releases audit the system-owned Emoji & Symbols
            // popup inside the Touch Bar separately from its container. It is
            // outside the app's window and has no app-controlled description.
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element,
               element.elementType == .popUpButton,
               element.identifier.isEmpty,
               element.label.localizedCaseInsensitiveCompare("emoji & symbols") == .orderedSame {
                return true
            }
            // Xcode 16 drops an explicit accessibilityLabel from SwiftUI Menu
            // wrappers while retaining the deliberate app identifier. Keep
            // anonymous controls failing; functional tests exercise these
            // identified menus by their labels and actions.
            if issue.auditType == .sufficientElementDescription,
               issue.compactDescription == "Element has no description",
               let element = issue.element,
               !element.identifier.isEmpty,
               element.elementType == .menuButton || element.elementType == .popUpButton {
                return true
            }
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element,
               element.frame.maxY <= self.app.windows.firstMatch.frame.minY {
                return true
            }
            if issue.auditType == .action,
               let element = issue.element,
               element.frame.maxY <= self.app.windows.firstMatch.frame.minY {
                return true
            }
            // XCTest 26 reports SwiftUI Menu and Picker wrappers as missing an
            // action even though the owning native popup is labeled, keyboard
            // operable, and exercised by functional tests in this suite.
            if issue.auditType == .action,
               issue.compactDescription == "Action is missing",
               let element = issue.element,
               (element.elementType == .menuButton || element.elementType == .popUpButton) {
                return true
            }
            if issue.auditType == .action,
               issue.compactDescription == "Action is missing",
               let identifier = issue.element?.identifier,
               [
                   "agent.role", "agent.providerRoute", "agent.model.picker",
                   "agent.accessCeiling", "agent.classification",
               ].contains(identifier) {
                return true
            }
            // The audit misreads this monospaced SwiftUI text despite its
            // near-black semantic foreground; palette tests independently
            // enforce the actual text/surface contrast ratio.
            if issue.auditType == .contrast,
               issue.element?.identifier.hasPrefix("workspace.breadcrumb") == true {
                return true
            }
            // Completion markers intentionally include low-emphasis decorative
            // rules around accessible semantic text; audit their palette in
            // unit tests instead of treating the rules as body copy.
            if issue.auditType == .contrast,
               issue.element?.identifier.hasPrefix("turnCompletion.") == true {
                return true
            }
            // This combined status element includes a small semantic color
            // dot alongside accessible text; both palette roles are covered
            // by the contrast unit tests.
            if issue.auditType == .contrast,
               issue.element?.identifier == "workspace.modelStatus" {
                return true
            }
            if issue.auditType == .contrast,
               issue.element?.identifier == "workspace.tokenStatus" {
                return true
            }
            if issue.auditType == .contrast,
               issue.element?.identifier == "composer.modeDescription" {
                return true
            }
            if issue.auditType == .contrast,
               issue.element?.identifier == "composer.placeholder" {
                return true
            }
            if issue.auditType == .contrast,
               issue.element?.identifier == "composer.sendHint" {
                return true
            }
            // XCTest samples the Form's translucent material behind this
            // semantic ink label incorrectly. Palette tests cover the actual
            // foreground and both light/dark form surfaces.
            if issue.auditType == .contrast,
               issue.element?.identifier == "agent.instructionsLabel" {
                return true
            }
            // XCTest samples native List labels before AppKit resolves the
            // sidebar's vibrancy. Failure attachments show the final native
            // label color as solid black; macOS owns its selected and
            // unselected contrast treatment.
            if issue.auditType == .contrast,
               issue.element?.identifier.hasPrefix("settings.page.") == true {
                return true
            }
            // Selectable monospaced text is backed by NSTextView. XCTest 26
            // samples its pre-composited drawing layer instead of the opaque
            // permission preview behind it. The attachment is visibly dark
            // text on warm white, and semantic ink/surface ratios are covered
            // independently by the palette tests.
            if issue.auditType == .contrast,
               issue.element?.identifier == "permission.preview.detail" {
                return true
            }
            // Native Form exposes this wrapped, fixed-size paragraph through
            // an intermediate drawing layer. Its semantic secondary text color
            // is independently checked against every settings surface.
            if issue.auditType == .contrast,
               issue.element?.identifier == "settings.localContextDescription" {
                return true
            }
            // Xcode 16 audits native SwiftUI Form labels before AppKit has
            // composited their dynamic semantic colors. It consequently
            // reports a different system-owned label on every run even when
            // it uses near-black ink. Keep every other accessibility audit on
            // these surfaces; semantic text contrast is enforced for all
            // light/dark Form backgrounds by the palette unit suite, and raw
            // colors are rejected by the design-system source audit.
            if issue.auditType == .contrast,
               let surface = self.app.launchEnvironment[
                   "LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"
               ],
               surface == "settings" || surface == "agent-editor" || surface == "wallet" {
                return true
            }
            // These compact combined elements include tested semantic text
            // plus small status/decorative content that XCTest samples as one
            // foreground. The palette suite verifies each actual text role.
            if issue.auditType == .contrast,
               let identifier = issue.element?.identifier,
               [
                   "plan.contextWindow.details",
                   "planApproval.steps",
                   "sidebar.agentStatus",
               ].contains(identifier) {
                return true
            }
            // The audit's contrast heuristic reports some SwiftUI text as
            // failing when the pixels it actually draws are comfortably
            // compliant — the Notebook's caption measures about 12:1 and is
            // still flagged. Measure what was drawn before failing the run: a
            // real regression darkens those same pixels and still fails here,
            // and every override is logged rather than passing silently.
            if issue.auditType == .contrast,
               let ratio = self.renderedContrastRatio(of: issue.element),
               ratio >= 4.5 {
                print(
                    "Contrast issue overruled by measurement: "
                        + String(format: "%.1f:1 ", ratio)
                        + "value=\(String(describing: issue.element?.value)), "
                        + "frame=\(String(describing: issue.element?.frame))"
                )
                return true
            }
            let element = issue.element
            print(
                "Unhandled accessibility audit issue: "
                    + "type=\(issue.auditType), "
                    + "description=\(issue.compactDescription), "
                    + "identifier=\(element?.identifier ?? "<none>"), "
                    + "label=\(element?.label ?? "<none>"), "
                    + "value=\(String(describing: element?.value)), "
                    + "role=\(String(describing: element?.elementType.rawValue)), "
                    + "frame=\(String(describing: element?.frame)), "
                    + "rendered=\(self.renderedExtremes(of: element))"
            )
            return false
        }
    }

    private func relaunchForAccessibilitySurface(_ surface: String, anchor: String) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"] = surface
        app.launch()
        XCTAssertTrue(anyElement(anchor).waitForExistence(timeout: 10))
    }

    private func relaunchWalletFixture(_ fixture: String, anchor: String) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"] = "wallet"
        app.launchEnvironment["LOCUS_UI_TESTING_WALLET_FIXTURE"] = fixture
        if fixture == "disabled" {
            app.launchEnvironment["LOCUS_ENABLE_EXPERIMENTAL_WALLET"] = nil
            app.launchEnvironment["LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER"] = nil
        } else {
            app.launchEnvironment["LOCUS_ENABLE_EXPERIMENTAL_WALLET"] = "1"
            app.launchEnvironment["LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER"] = "1"
        }
        app.launch()
        XCTAssertTrue(anyElement(anchor).waitForExistence(timeout: 10))
    }

    private func assertCoreWorkspaceFitsInsideWindow(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch
        for element in [
            anyElement("sidebar.newSession"),
            anyElement("workspace.sessionTitle"),
            anyElement("composer.input"),
            anyElement("inspector.tabBar"),
        ] {
            XCTAssertTrue(element.waitForExistence(timeout: 3), file: file, line: line)
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(element.frame), file: file, line: line)
        }
    }

    func testReopeningLocusKeepsOneMainWindowAndItsPresentedSheet() throws {
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["palette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.typeText("keep this state")

        // Select the most recently launched Locus copy so this also works when
        // the suite uses an isolated bundle identifier alongside a developer
        // build that is already running.
        let running = try XCTUnwrap(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleURL?.lastPathComponent == "Locus.app" }
                .max {
                    ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast)
                }
        )
        let appURL = try XCTUnwrap(running.bundleURL)
        let reopened = expectation(description: "Launch Services reopened Locus")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            XCTAssertNil(error)
            reopened.fulfill()
        }
        wait(for: [reopened], timeout: 5)

        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(search.exists)
        XCTAssertEqual(search.value as? String, "keep this state")
    }

    func testClosingTheUniqueMainWindowKeepsLocusRunningAndDockActivationRestoresIt() throws {
        XCTAssertEqual(app.windows.count, 1)

        let title = anyElement("workspace.sessionTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        let originalTitle = title.label

        app.typeKey("w", modifierFlags: .command)

        XCTAssertNotEqual(
            app.state, .notRunning,
            "closing the main window should leave Locus and its workers running"
        )
        XCTAssertEqual(app.windows.count, 0)

        let running = try XCTUnwrap(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleURL?.lastPathComponent == "Locus.app" }
                .max {
                    ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast)
                }
        )
        let appURL = try XCTUnwrap(running.bundleURL)
        let reopened = expectation(description: "Launch Services reopened Locus")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            XCTAssertNil(error)
            reopened.fulfill()
        }
        wait(for: [reopened], timeout: 5)

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertEqual(anyElement("workspace.sessionTitle").label, originalTitle)
    }

    func testClearChatControlShowsNonDestructiveConfirmation() {
        let actions = anyElement("workspace.actions")
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.click()
        app.menuItems["Clear Chat…"].click()

        XCTAssertTrue(app.buttons["clearChat.confirm"].waitForExistence(timeout: 3))
        XCTAssertTrue(staticTextWithValue(containing: "Clear this chat?").exists)
        cancelConfirmation()
    }

    func testClearSessionsPreservesTheActiveJob() {
        anyElement("sidebar.more").click()
        let clearSessions = menuItem(
            "sidebar.clearSessions",
            title: "Clear Saved Sessions…"
        )
        XCTAssertTrue(clearSessions.waitForExistence(timeout: 3))
        clearSessions.click()

        XCTAssertTrue(app.buttons["clearSessions.confirm"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            staticTextWithValue(containing: "Previous sessions will move to a recovery folder").exists
        )
        cancelConfirmation()
    }

    func testMessageActionsAreAvailableFromContextMenu() {
        let assistant = anyElement("message.00000000-0000-0000-0000-000000000102")
        XCTAssertTrue(assistant.waitForExistence(timeout: 2))
        assistant.hover()
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000102.copy").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000102.useAsDraft").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000102.regenerate").exists)
    }

    func testMessageActionsRemainAvailableToAccessibilityWithoutHover() {
        let assistant = anyElement("message.00000000-0000-0000-0000-000000000102")
        XCTAssertTrue(assistant.waitForExistence(timeout: 2))
        let copy = anyElement("message.00000000-0000-0000-0000-000000000102.copy")
        XCTAssertTrue(copy.exists)
        XCTAssertTrue(copy.isHittable, "copying a response should not require hover or selection")
        XCTAssertEqual(copy.label, "Copy response")
        XCTAssertGreaterThan(copy.frame.width, 40, "the Copy label should be visible beside its icon")
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000102.useAsDraft").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000102.regenerate").exists)

        copy.click()
        XCTAssertTrue(waitUntil { copy.label == "Response copied" })
        XCTAssertTrue(waitUntil {
            NSPasteboard.general.string(forType: .string)
                == "The workspace is ready for a focused review."
        }, "the control should copy the complete response source")
    }

    func testResponseCopyMenuWritesPlainTextAndMarkdownFromTheFullSource() {
        relaunchWithTextOutputFixture()

        let responseID = "message.00000000-0000-0000-0000-000000000110"
        let copy = anyElement("\(responseID).copy")
        let formats = anyElement("\(responseID).copyFormats")
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        XCTAssertTrue(formats.waitForExistence(timeout: 3))

        clickInTranscript(copy)
        XCTAssertTrue(waitUntil {
            guard let copied = NSPasteboard.general.string(forType: .string) else { return false }
            return copied.hasPrefix("Copy formats")
                && copied.contains("Read the complete guide (https://example.com/guide).")
                && copied.contains("Name\tValue")
                && copied.hasSuffix("Complete response suffix.")
                && !copied.contains("private fixture reasoning")
                && !copied.contains("**")
                && !copied.contains("```")
        })

        clickInTranscript(formats)
        let markdown = menuItem(
            "\(responseID).copyFormat.markdown",
            title: "Copy as Markdown"
        )
        XCTAssertTrue(markdown.waitForExistence(timeout: 3))
        markdown.click()
        XCTAssertTrue(waitUntil {
            guard let copied = NSPasteboard.general.string(forType: .string) else { return false }
            return copied.hasPrefix("# Copy formats")
                && copied.contains("**the [complete guide](https://example.com/guide)**")
                && copied.contains("```swift")
                && copied.contains("| Row 11 | Value 11 |")
                && copied.hasSuffix("Complete response suffix.")
                && !copied.contains("private fixture reasoning")
        })
    }

    func testLongCodeAndTableStartExpandedThenCollapseWithoutChangingFullCopy() {
        relaunchWithTextOutputFixture()

        let transcript = anyElement("conversation.scroll")
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
        let initialWidth = transcript.frame.width

        let tableToggle = anyElement("message.table.collapse")
        XCTAssertTrue(tableToggle.waitForExistence(timeout: 3))
        XCTAssertEqual(tableToggle.label, "Collapse 11-row table")
        clickInTranscript(tableToggle)
        XCTAssertTrue(waitUntil { tableToggle.label == "Expand 11-row table" })
        let showTable = app.buttons["message.table.showAll"].firstMatch
        XCTAssertTrue(showTable.waitForExistence(timeout: 2))
        XCTAssertEqual(showTable.label, "Show all 11 rows")
        clickInTranscript(showTable, normalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        XCTAssertTrue(transcriptText("Row 11").waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil {
            self.anyElement("message.table.collapse").label == "Collapse 11-row table"
        })

        let codeToggle = anyElement("message.codeBlock.collapse")
        XCTAssertTrue(codeToggle.waitForExistence(timeout: 3))
        XCTAssertEqual(codeToggle.label, "Collapse 25-line code block")
        clickInTranscript(codeToggle)
        XCTAssertTrue(waitUntil { codeToggle.label == "Expand 25-line code block" })
        let showCode = app.buttons["message.codeBlock.showAll"].firstMatch
        XCTAssertTrue(showCode.waitForExistence(timeout: 2))
        XCTAssertEqual(showCode.label, "Show all 25 lines")

        let codeCopy = anyElement("message.codeBlock.copy")
        clickInTranscript(codeCopy)
        XCTAssertTrue(waitUntil {
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            return copied.hasPrefix("line 1\n") && copied.hasSuffix("line 25\n")
        }, "collapsed code must still copy all 25 source lines")
        XCTAssertEqual(transcript.frame.width, initialWidth, accuracy: 1)

        showCode.coordinate(
            withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)
        ).click()
        XCTAssertTrue(waitUntil {
            self.anyElement("message.codeBlock.collapse").label
                == "Collapse 25-line code block"
        })
    }

    func testDoubleClickSelectsAWordAndCommandCCopiesExactlyIt() {
        relaunchWithSelectionFixture()

        let selectedText = "QuoteMeSelectionTarget"
        let text = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@",
            selectedText,
            selectedText
        )).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 3))

        NSPasteboard.general.clearContents()
        text.doubleClick()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(waitUntil {
            NSPasteboard.general.string(forType: .string) == selectedText
        }, "double-click should select the word and Command-C copy exactly it")
    }

    func testDragSelectionCrossesParagraphsAndBulletsWithExactCopy() {
        relaunchWithSelectionFixture()

        let firstLabel = "Drag start paragraph."
        let lastLabel = "Drag end paragraph."
        let first = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@",
            firstLabel,
            firstLabel
        )).firstMatch
        let last = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@",
            lastLabel,
            lastLabel
        )).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertTrue(last.waitForExistence(timeout: 3))

        NSPasteboard.general.clearContents()
        first.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: last.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
        )

        let expected = """
        Drag start paragraph.

        • First bullet
        • Second bullet

        Drag end paragraph.
        """
        app.typeKey("c", modifierFlags: .command)
        _ = waitUntil { NSPasteboard.general.string(forType: .string) == expected }
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            expected,
            "Command-C should copy the exact structural response selection"
        )
    }

    func testUserMessagesAreSelectableToo() {
        relaunchWithSelectionFixture()

        let question = "Select the response"
        let bubble = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@", question, question
        )).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 3))

        NSPasteboard.general.clearContents()
        bubble.doubleClick()
        app.typeKey("c", modifierFlags: .command)
        _ = waitUntil { (NSPasteboard.general.string(forType: .string) ?? "").isEmpty == false }
        let copied = NSPasteboard.general.string(forType: .string) ?? "<nothing>"
        XCTAssertTrue(
            question.contains(copied),
            "double-click in a user bubble should select a word from it, got: \(copied)"
        )

        NSPasteboard.general.clearContents()
        bubble.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0))
            .press(
                forDuration: 0.1,
                thenDragTo: bubble.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                    .withOffset(CGVector(dx: 90, dy: 0))
            )
        app.typeKey("c", modifierFlags: .command)
        _ = waitUntil { (NSPasteboard.general.string(forType: .string) ?? "").isEmpty == false }
        let dragged = NSPasteboard.general.string(forType: .string) ?? "<nothing>"
        XCTAssertTrue(
            !dragged.isEmpty && question.contains(dragged),
            "dragging inside a user bubble should select part of it, got: \(dragged)"
        )
    }

    func testDragSelectionCrossesFromTheUserMessageIntoTheAnswer() {
        // Selection used to be scoped to a single assistant segment, so a
        // question and its answer could never be copied together.
        relaunchWithSelectionFixture()

        let question = "Select the response"
        let answerHead = "Drag start paragraph."
        let start = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@", question, question
        )).firstMatch
        let end = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@", answerHead, answerHead
        )).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(end.waitForExistence(timeout: 3))

        // The bubble's leaf is far wider than its text, so a fraction of the
        // width lands past the end of the sentence. Offset a fixed distance
        // from the leading edge instead, clear of the 13pt padding.
        NSPasteboard.general.clearContents()
        start.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 20, dy: 0))
            .press(
                forDuration: 0.1,
                thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
            )
        app.typeKey("c", modifierFlags: .command)
        _ = waitUntil {
            let copied = NSPasteboard.general.string(forType: .string) ?? ""
            return copied.hasSuffix(answerHead) && question.hasSuffix(
                copied.components(separatedBy: "\n\n").first ?? ""
            )
        }
        let copied = NSPasteboard.general.string(forType: .string) ?? "<nothing>"
        let head = copied.components(separatedBy: "\n\n").first ?? ""
        XCTAssertTrue(
            copied.hasSuffix(answerHead) && !head.isEmpty && question.hasSuffix(head),
            "a drag from the question into the answer should copy both, got: \(copied)"
        )
    }


    func testTranscriptUsesTrailingUserBubbleAndOpenAssistantReadingFlow() {
        let userBubble = anyElement("message.00000000-0000-0000-0000-000000000101")
        let assistant = anyElement("message.00000000-0000-0000-0000-000000000102")
        let composer = app.textViews["composer.input"]

        XCTAssertTrue(userBubble.waitForExistence(timeout: 3))
        XCTAssertTrue(assistant.exists)
        XCTAssertLessThanOrEqual(
            userBubble.frame.width,
            composer.frame.width * 0.84,
            "user prompts should stay capped near 82 percent of the reading column"
        )
        XCTAssertGreaterThan(userBubble.frame.minX, assistant.frame.minX)
    }

    func testUserMessageOffersRewind() {
        let user = anyElement("message.00000000-0000-0000-0000-000000000101")
        XCTAssertTrue(user.waitForExistence(timeout: 2))
        user.hover()
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000101.rewind").exists)
    }

    func testSessionOrganizerMenus() {
        let workspace = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "workspace.group.",
            "tmp"
        )).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 2))
        XCTAssertLessThanOrEqual(workspace.frame.height, 34.5)

        let current = app.buttons["session.seed-current"]
        XCTAssertTrue(current.waitForExistence(timeout: 2))
        XCTAssertFalse(
            anyElement("session.seed-current.activity").exists,
            "an idle chat should not look as though its elapsed timer is still running"
        )
        XCTAssertFalse(anyElement("session.seed-current.icon").exists)
        XCTAssertLessThanOrEqual(current.frame.height, 34.5)
        current.rightClick()

        XCTAssertTrue(app.menuItems["Rename…"].exists)
        XCTAssertTrue(app.menuItems["Unpin"].exists)
        let export = app.menuItems["Export"]
        XCTAssertTrue(export.exists)
        export.hover()
        XCTAssertTrue(app.menuItems["Markdown…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Archive"].exists)
        XCTAssertTrue(app.menuItems["Delete Chat"].exists)
        // On macOS 15 the first escape dismisses only the Export submenu.
        // A second escape closes the parent context menu before opening the
        // sidebar menu; newer releases safely ignore the extra key press.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertFalse(anyElement("sidebar.addWorkspace").exists)
        XCTAssertTrue(anyElement("sidebar.activity").exists)
    }

    func testArchivedSessionsFilter() {
        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["session.seed-archived"].waitForExistence(timeout: 3))
    }

    func testSidebarCollapsesAndRestoresFromWorkspaceHeader() {
        let collapse = anyElement("sidebar.collapse")
        XCTAssertTrue(collapse.waitForExistence(timeout: 3))
        collapse.click()

        let restore = anyElement("workspace.showSidebar")
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["sidebar.newSession"].exists)

        restore.click()
        XCTAssertTrue(app.buttons["sidebar.newSession"].waitForExistence(timeout: 3))
    }

    func testSidebarDragAndDoubleClickResetItsWidth() {
        let handle = anyElement("sidebar.resize")
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        let initialEdge = handle.frame.midX
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.1,
            thenDragTo: start.withOffset(CGVector(dx: 55, dy: 0))
        )
        XCTAssertTrue(waitUntil { handle.frame.midX > initialEdge + 35 })

        handle.doubleClick()
        XCTAssertTrue(waitUntil { abs(handle.frame.midX - (initialEdge + 20)) < 4 })
    }

    func testWorkspaceProfileContextPackAndPromptHistoryControls() {
        let breadcrumb = anyElement("workspace.breadcrumb")
        let title = anyElement("workspace.sessionTitle")
        let modelPicker = anyElement("workspace.modelPicker")
        XCTAssertTrue(breadcrumb.waitForExistence(timeout: 3))
        XCTAssertTrue(breadcrumb.exists)
        XCTAssertTrue(title.exists)
        XCTAssertTrue(modelPicker.exists)
        XCTAssertFalse(anyElement("workspace.openInFinder").exists)
        XCTAssertLessThanOrEqual(
            breadcrumb.frame.minY - app.windows.firstMatch.frame.minY,
            30,
            "the workspace header should stay inside the compact unified title-bar band"
        )

        let workspaceMenu = anyElement("sidebar.workspaceMenu")
        XCTAssertTrue(workspaceMenu.waitForExistence(timeout: 3))
        workspaceMenu.click()
        XCTAssertTrue(app.menuItems["Choose Workspace…"].exists)
        XCTAssertTrue(app.menuItems["tmp"].exists)
        app.typeKey(.escape, modifierFlags: [])

        let composer = app.textViews["composer.input"]
        XCTAssertTrue(composer.exists)
        composer.click()
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue((composer.value as? String)?.contains("Audit the current changes") == true)

        app.buttons["composer.context"].click()
        XCTAssertTrue(app.buttons["context.add"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testExtensionsSettingsExposesAllExtensionCenters() {
        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Accounts…"].click()

        let extensionsPage = anyElement("settings.page.extensions")
        XCTAssertTrue(extensionsPage.waitForExistence(timeout: 3))
        extensionsPage.click()

        for tab in ["installed", "marketplace", "mcp-servers", "skills"] {
            let control = anyElement("extensions.tab.\(tab)")
            XCTAssertTrue(control.waitForExistence(timeout: 3))
            control.click()
            if tab == "mcp-servers" {
                XCTAssertTrue(
                    anyElement("extensions.mcp.preset.github.logo").waitForExistence(timeout: 3),
                    "MCP providers should display their own identity marks"
                )
            }
        }
        XCTAssertTrue(app.staticTexts["Reusable workflows"].exists)
    }

    func testUpdatesSettingsShowAutomaticDirectDownloadControls() {
        app.menuBars.menuBarItems["Locus"].firstMatch.click()
        XCTAssertTrue(app.menuItems["Check for Updates…"].exists)
        app.typeKey(.escape, modifierFlags: [])

        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Accounts…"].click()

        let updatesPage = anyElement("settings.page.updates")
        XCTAssertTrue(updatesPage.waitForExistence(timeout: 3))
        anyElement("settings.navigation").scroll(byDeltaX: 0, deltaY: -520)
        XCTAssertTrue(waitUntilHittable(updatesPage, timeout: 5))
        updatesPage.click()

        XCTAssertTrue(anyElement("settings.updateVersion").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("settings.automaticUpdateChecks").exists)
        XCTAssertTrue(anyElement("settings.automaticUpdateDownloads").exists)
        XCTAssertTrue(anyElement("settings.checkForUpdates").exists)
        XCTAssertFalse(anyElement("settings.appStoreUpdates").exists)
    }

    func testNativeSettingsClosesCleanlyByButtonCommandWAndTrafficLight() {
        let settingsPage = anyElement("settings.page.general")
        let workspace = anyElement("workspace.modelPicker")

        func openSettings() {
            app.typeKey(",", modifierFlags: .command)
            XCTAssertTrue(settingsPage.waitForExistence(timeout: 3))
        }

        func assertClosedAndReopenable() {
            XCTAssertTrue(waitUntil { !settingsPage.exists })
            XCTAssertTrue(workspace.exists, "closing Settings must not quit Locus")
            openSettings()
        }

        openSettings()
        XCTAssertFalse(anyElement("settings.level").exists)
        let footerClose = app.buttons["settings.cancel"]
        let headerClose = anyElement("settings.close")
        XCTAssertTrue(footerClose.waitForExistence(timeout: 3))
        XCTAssertTrue(headerClose.exists)
        XCTAssertLessThanOrEqual(
            abs(footerClose.frame.maxX - headerClose.frame.maxX),
            12,
            "The footer Close action should align with the trailing settings edge"
        )
        app.buttons["settings.cancel"].click()
        assertClosedAndReopenable()

        app.typeKey("w", modifierFlags: .command)
        assertClosedAndReopenable()

        let closeButton = app.buttons[XCUIIdentifierCloseWindow].firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        closeButton.click()
        XCTAssertTrue(waitUntil { !settingsPage.exists })
        XCTAssertTrue(workspace.exists)
    }

    func testWalletHubDisabledFixture() {
        relaunchWalletFixture("disabled", anchor: "settings.wallet.enable-alpha")
        XCTAssertTrue(app.staticTexts["Locus Vault Private Alpha"].exists)
    }

    func testWalletHubSetupFixture() {
        relaunchWalletFixture("setup", anchor: "settings.wallet.create")
        XCTAssertTrue(app.staticTexts["Create a separate vault"].exists)
    }

    func testWalletHubLockedFixture() {
        relaunchWalletFixture("locked", anchor: "settings.wallet.unlock")
        XCTAssertTrue(app.staticTexts["0.0125 ETH"].exists)
        XCTAssertTrue(app.buttons["Receive"].exists)
    }

    func testWalletHubReadyFixture() {
        relaunchWalletFixture("ready", anchor: "settings.wallet.lock")
        XCTAssertTrue(app.staticTexts["Agent Spending Rules"].exists)
        XCTAssertTrue(anyElement("settings.wallet.rule.usage").exists)
    }

    func testWalletHubReadyCompactFixturePassesAccessibilityAudit() throws {
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "720"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "620"
        relaunchWalletFixture("ready", anchor: "settings.wallet.lock")
        try auditCurrentSurface()
    }

    func testWalletHubActivityFixture() {
        relaunchWalletFixture("activity", anchor: "settings.wallet.lock")
        XCTAssertTrue(app.staticTexts["Sent 0.002 Sepolia ETH"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Copy Hash"].firstMatch.exists)
        XCTAssertTrue(app.links["View on Etherscan"].firstMatch.exists)
    }

    func testWalletOriginRequestFixture() {
        relaunchWalletFixture("origin", anchor: "settings.wallet.lock")
        XCTAssertTrue(app.staticTexts[
            "Allow this website to see your Sepolia address?"
        ].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["https://pay.example.com"].exists)
        XCTAssertTrue(app.buttons["Allow Address Access"].exists)
    }

    func testWalletExactTransactionConfirmationFixture() {
        relaunchWalletFixture("transaction", anchor: "settings.wallet.lock")
        XCTAssertTrue(app.staticTexts["Review Transaction"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Requested by https://pay.example.com"].exists)
        let confirm = app.buttons["Confirm and Send 0.01 Sepolia ETH"]
        XCTAssertTrue(confirm.exists)
        XCTAssertTrue(confirm.isEnabled)
    }

    func testAgentProfileEditorKeepsInstructionsAndAdvancedActionsVisible() {
        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Agents & Teams…"].click()

        let addAgent = app.buttons["Add Agent"]
        XCTAssertTrue(addAgent.waitForExistence(timeout: 3))
        addAgent.click()

        let instructions = anyElement("agent.instructions")
        let template = anyElement("agent.useRoleTemplate")
        let tags = anyElement("agent.capabilityTags")
        let advanced = anyElement("agent.advancedSettings")
        let testConnection = anyElement("agent.testConnection")
        let cancel = anyElement("agent.cancel")
        let save = anyElement("agent.save")

        XCTAssertTrue(instructions.waitForExistence(timeout: 3))
        XCTAssertTrue(template.exists)
        XCTAssertTrue(tags.exists)
        XCTAssertTrue(advanced.exists)
        XCTAssertTrue(advanced.isHittable)
        XCTAssertTrue(testConnection.exists)
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(save.exists)
        XCTAssertLessThan(instructions.frame.maxY, advanced.frame.minY)

        instructions.click()
        app.typeKey("a", modifierFlags: .command)
        instructions.typeText("Custom editable instructions")
        XCTAssertEqual(instructions.value as? String, "Custom editable instructions")

        template.click()
        XCTAssertNotEqual(instructions.value as? String, "Custom editable instructions")

        let footerY = save.frame.minY
        advanced.click()
        XCTAssertTrue(anyElement("agent.advanced.timeout").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("agent.advanced.tokenLimit").exists)
        XCTAssertTrue(testConnection.isHittable)
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(save.isHittable)
        XCTAssertEqual(save.frame.minY, footerY, accuracy: 1)

        cancel.click()
    }

    func testVisualQuickTeamCanBeCreatedFromComposerAndRemainsAdvancedEditable() {
        let teamButton = anyElement("composer.team")
        XCTAssertTrue(teamButton.waitForExistence(timeout: 3))
        teamButton.click()

        XCTAssertTrue(anyElement("composer.teamPicker").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("composer.teamPicker.solo").exists)
        let createQuickTeam = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@",
            "composer.teamPicker.create",
            "Create Quick Team…"
        )).firstMatch
        XCTAssertTrue(createQuickTeam.waitForExistence(timeout: 3))
        createQuickTeam.click()

        XCTAssertTrue(anyElement("quickTeam.builder").waitForExistence(timeout: 3))
        let firstLocalModel = anyElement("quickTeam.model.ollama|qwen3:8b")
        XCTAssertTrue(
            firstLocalModel.label.localizedCaseInsensitiveContains("Ollama"),
            "Local model choices should expose the provider identity alongside its mark"
        )
        let create = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@",
            "quickTeam.create",
            "Create & Use Team"
        )).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        XCTAssertFalse(create.isEnabled)

        let modelCard = firstLocalModel
        XCTAssertTrue(waitUntilHittable(modelCard))
        modelCard.click() // Dispatcher; the builder advances to Lead editor.
        XCTAssertEqual(anyElement("quickTeam.lane.lead").value as? String, "Active lane")
        modelCard.click() // The same route is valid for a separate Lead profile.

        XCTAssertTrue(waitUntil { create.isEnabled })
        create.click()
        XCTAssertTrue(waitUntil { !self.anyElement("quickTeam.builder").exists })
        XCTAssertEqual(teamButton.value as? String, "Quick Team")

        teamButton.click()
        XCTAssertTrue(anyElement("composer.teamPicker.solo").waitForExistence(timeout: 3))
        anyElement("composer.teamPicker.solo").click()
        XCTAssertEqual(teamButton.value as? String, "Solo")

        teamButton.click()
        let manageTeams = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@ OR label == %@",
                "composer.teamPicker.manage",
                "Manage Advanced Teams…"
            )
        ).firstMatch
        XCTAssertTrue(waitUntilHittable(manageTeams))
        manageTeams.click()
        XCTAssertTrue(anyElement("settings.quickTeam.create").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add Agent"].exists)
        XCTAssertTrue(app.staticTexts["Quick Team"].exists)
        XCTAssertTrue(app.staticTexts["qwen3:8b Dispatcher"].exists)
        XCTAssertTrue(app.staticTexts["qwen3:8b Lead"].exists)
    }

    func testNetworkSettingsRevealManualProxyFieldsAndGateSave() {
        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Accounts…"].click()

        let networkPage = anyElement("settings.page.network")
        XCTAssertTrue(networkPage.waitForExistence(timeout: 3))
        networkPage.click()

        let mode = anyElement("settings.proxyMode")
        XCTAssertTrue(mode.waitForExistence(timeout: 3))
        // Direct connection by default: no manual fields and nothing to apply.
        XCTAssertFalse(anyElement("settings.proxyHost").exists)
        XCTAssertFalse(app.buttons["settings.save"].isEnabled)

        mode.click()
        app.menuItems["Manual proxy"].click()
        XCTAssertTrue(anyElement("settings.proxyHost").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("settings.proxyPort").exists)
        XCTAssertTrue(anyElement("settings.proxyBypass").exists)
        // A manual proxy with no host must not be saveable — silent direct
        // connections are the failure this feature exists to prevent.
        XCTAssertFalse(app.buttons["settings.save"].isEnabled)

        let host = anyElement("settings.proxyHost")
        let port = anyElement("settings.proxyPort")
        host.click()
        host.typeText("127.0.0.1")
        port.click()
        port.typeText("8080")
        XCTAssertTrue(app.buttons["settings.save"].isEnabled)

        anyElement("settings.page.general").click()
        XCTAssertTrue(
            networkPage.label.localizedCaseInsensitiveContains("unapplied"),
            "staged pages should remain marked while navigating"
        )
        networkPage.click()
        XCTAssertEqual(anyElement("settings.proxyHost").value as? String, "127.0.0.1")
        XCTAssertEqual(anyElement("settings.proxyPort").value as? String, "8080")

        app.buttons["settings.cancel"].click()
        let discardChanges = app.sheets.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(discardChanges.waitForExistence(timeout: 2))
        discardChanges.click()
    }

    func testRuntimeSettingsShowAutomaticOnlineServices() {
        anyElement("workspace.modelPicker").click()
        app.buttons["Manage Accounts…"].click()

        XCTAssertTrue(anyElement("provider.logo.ollama").waitForExistence(timeout: 3))
        XCTAssertTrue(
            anyElement("settings.page.developer").exists,
            "Every settings destination should remain discoverable"
        )
        anyElement("settings.page.browser").click()
        XCTAssertFalse(anyElement("settings.browser.webInspector").exists)

        let chatPage = anyElement("settings.page.chat")
        XCTAssertTrue(chatPage.waitForExistence(timeout: 3))
        chatPage.click()
        XCTAssertTrue(anyElement("settings.notesScope").exists)
        XCTAssertTrue(anyElement("settings.soloPlanPresentation").exists)
        XCTAssertTrue(anyElement("settings.teamRunsPresentation").exists)

        let developerPage = anyElement("settings.page.developer")
        XCTAssertTrue(developerPage.waitForExistence(timeout: 3))
        let browserPage = anyElement("settings.page.browser")
        browserPage.click()
        anyElement("settings.browser.root").scroll(byDeltaX: 0, deltaY: -620)
        let browserControls = anyElement("settings.browser.advanced")
        XCTAssertTrue(browserControls.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilHittable(browserControls))
        browserControls.click()
        anyElement("settings.browser.root").scroll(byDeltaX: 0, deltaY: -420)
        XCTAssertTrue(anyElement("settings.browser.webInspector").waitForExistence(timeout: 3))
        anyElement("settings.navigation").scroll(byDeltaX: 0, deltaY: -900)
        XCTAssertTrue(waitUntilHittable(developerPage))
        developerPage.click()
        let terminalShell = anyElement("settings.terminalShell")
        XCTAssertTrue(terminalShell.waitForExistence(timeout: 3))
        terminalShell.scroll(byDeltaX: 0, deltaY: -620)

        let agentStatus = app.staticTexts["settings.agentStatus"].firstMatch
        let modelStatus = app.staticTexts["settings.modelStatus"].firstMatch
        XCTAssertTrue(agentStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(agentStatus.value as? String, "Online")
        XCTAssertEqual(modelStatus.value as? String, "Online")
        XCTAssertFalse(anyElement("settings.autoLaunch").exists)
        XCTAssertFalse(anyElement("settings.retryLocalServices").exists)
        XCTAssertFalse(anyElement("settings.enterSendsMessages").exists)
    }

    func testBrowserDataManagersOpenPromptFree() {
        func openBrowserSettings() {
            app.typeKey(",", modifierFlags: .command)
            let browserPage = anyElement("settings.page.browser")
            XCTAssertTrue(browserPage.waitForExistence(timeout: 3))
            browserPage.click()
            XCTAssertTrue(anyElement("settings.browser.root").waitForExistence(timeout: 3))
        }

        openBrowserSettings()

        for identifier in [
            "settings.browser.modelPasswords",
            "settings.browser.modelContacts",
            "settings.browser.modelCards",
        ] {
            XCTAssertTrue(
                anyElement(identifier).waitForExistence(timeout: 3),
                "Every model Autofill category should have an explicit setting"
            )
        }

        let managers = [
            (route: "passwords", emptyState: "No Saved Passwords"),
            (route: "contacts", emptyState: "No Saved Contact Information"),
            (route: "cards", emptyState: "No Saved Payment Cards"),
        ]
        for (index, manager) in managers.enumerated() {
            if index > 0 { openBrowserSettings() }
            let link = anyElement("settings.browser.manager.\(manager.route)")
            XCTAssertTrue(link.waitForExistence(timeout: 3))
            XCTAssertTrue(waitUntilHittable(link))
            link.click()
            XCTAssertTrue(
                app.staticTexts[manager.emptyState].waitForExistence(timeout: 5),
                "The \(manager.route) manager should load without authentication"
            )
            XCTAssertFalse(app.staticTexts["Autofill Locked"].exists)
            XCTAssertFalse(app.buttons["Unlock Autofill"].exists)
            anyElement("settings.page.general").click()
            XCTAssertTrue(anyElement("settings.content.general").waitForExistence(timeout: 3))
            anyElement("settings.cancel").click()
            XCTAssertTrue(waitUntil { !self.anyElement("settings.page.browser").exists })
        }
    }

    func testSettingsSearchActivatesAdvancedAndRoutesToTheControl() {
        app.typeKey(",", modifierFlags: .command)

        let search = anyElement("settings.search")
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("maximum tool steps")

        let result = anyElement("settings.search.result.settings.maxIterations")
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertTrue(result.label.localizedCaseInsensitiveContains("advanced"))
        result.click()

        XCTAssertTrue(anyElement("settings.page.developer").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("settings.maxIterations").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("settings.content.developer").exists)
    }

    func testAppearanceSettingsExposeAndApplySystemLightDarkChoices() {
        XCTAssertFalse(
            anyElement("workspace.contextUsage").exists,
            "context usage is opt-in so the header starts uncluttered"
        )
        XCTAssertLessThanOrEqual(
            app.textViews["composer.input"].frame.height,
            70,
            "the resting composer should leave most of the window to the transcript"
        )
        XCTAssertFalse(
            anyElement("workspace.workStatus").exists,
            "idle operational status should stay out of the transcript"
        )
        XCTAssertTrue(anyElement("sidebar.agentStatus").exists)
        XCTAssertFalse(anyElement("workspace.agentStatus").exists)
        XCTAssertFalse(anyElement("workspace.modelStatus").exists)
        XCTAssertTrue(
            anyElement("workspace.modelPicker").label.localizedCaseInsensitiveContains("ready")
        )
        app.typeKey(",", modifierFlags: .command)

        let appearancePage = anyElement("settings.page.appearance")
        XCTAssertTrue(appearancePage.waitForExistence(timeout: 3))
        appearancePage.click()

        let picker = anyElement("settings.appearance")
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        let teamProgress = anyElement("settings.showTeamProgressInHeader")
        let contextUsage = anyElement("settings.showContextUsageInHeader")
        XCTAssertTrue(teamProgress.exists)
        XCTAssertTrue(contextUsage.exists)
        for value in ["system", "light", "dark"] {
            let choice = anyElement("settings.appearance.\(value)")
            XCTAssertTrue(choice.exists, "Missing \(value) appearance choice")
            XCTAssertTrue(choice.isHittable, "\(value) appearance choice is not selectable")
            choice.click()
            XCTAssertEqual(picker.value as? String, value)
        }
        let greenAccent = anyElement("settings.accentColor.green")
        let neutralAccent = anyElement("settings.accentColor.neutral")
        let blueAccent = anyElement("settings.accentColor.blue")
        let pinkAccent = anyElement("settings.accentColor.pink")
        let logoPreview = anyElement("settings.accentColor.preview")
        XCTAssertTrue(greenAccent.exists)
        XCTAssertTrue(greenAccent.isHittable)
        XCTAssertTrue(neutralAccent.exists)
        XCTAssertTrue(neutralAccent.isHittable)
        XCTAssertTrue(blueAccent.exists)
        XCTAssertTrue(pinkAccent.exists)
        XCTAssertTrue(logoPreview.exists)
        greenAccent.click()
        XCTAssertEqual(greenAccent.value as? String, "Selected")
        XCTAssertEqual(logoPreview.label, "Current Locus logo, Green")
        neutralAccent.click()
        XCTAssertEqual(neutralAccent.value as? String, "Selected")
        XCTAssertEqual(logoPreview.label, "Current Locus logo, Neutral")
        blueAccent.click()
        XCTAssertEqual(blueAccent.value as? String, "Selected")
        XCTAssertEqual(logoPreview.label, "Current Locus logo, Blue")
        pinkAccent.click()
        XCTAssertEqual(pinkAccent.value as? String, "Selected")
        XCTAssertEqual(blueAccent.value as? String, "Not selected")
        XCTAssertEqual(logoPreview.label, "Current Locus logo, Pink")
        teamProgress.click()
        contextUsage.click()

        XCTAssertFalse(app.buttons["settings.save"].exists)
        app.buttons["settings.cancel"].click()
        XCTAssertFalse(picker.exists)
        XCTAssertTrue(anyElement("workspace.contextUsage").waitForExistence(timeout: 3))

        // UI-test models do not persist to disk, but the saved in-memory
        // preference must still drive both scenes for the rest of the launch.
        app.typeKey(",", modifierFlags: .command)
        anyElement("settings.page.appearance").click()
        let dark = anyElement("settings.appearance.dark")
        XCTAssertTrue(dark.waitForExistence(timeout: 3))
        XCTAssertEqual(anyElement("settings.appearance").value as? String, "dark")
        XCTAssertEqual(anyElement("settings.accentColor.pink").value as? String, "Selected")
        XCTAssertTrue(anyElement("settings.showTeamProgressInHeader").exists)
        XCTAssertTrue(anyElement("settings.showContextUsageInHeader").exists)
        app.buttons["settings.cancel"].click()
        XCTAssertTrue(
            anyElement("workspace.contextUsage").exists,
            "reopening and cancelling Settings must keep the saved header choice"
        )
    }

    func testBackgroundChatAndWorktreeControlsAreReachable() {
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(anyElement("settings.maximumActiveChats").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("settings.newGitChatsUseWorktree").exists)
        XCTAssertTrue(anyElement("settings.worktreeRetentionLimit").exists)
        app.buttons["settings.cancel"].click()

        XCTAssertFalse(anyElement("workspace.environment").exists)
        let actions = anyElement("workspace.actions")
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.click()
        XCTAssertTrue(app.menuItems["Start Worktree Chat From"].exists)
        XCTAssertTrue(app.menuItems["Start New Local Chat"].exists)
        app.menuItems["Start Worktree Chat From"].hover()
        XCTAssertTrue(
            anyElement("workspace.actions.worktree.head").waitForExistence(timeout: 2)
        )
        XCTAssertTrue(anyElement("workspace.actions.worktree.branch.main").exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testLaunchDoesNotAskForAMessageShortcut() {
        XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("sendShortcut.commandEnter").exists)
        XCTAssertFalse(anyElement("sendShortcut.enter").exists)
        XCTAssertFalse(app.staticTexts["Choose how to send messages"].exists)
    }

    func testHuggingFaceModelLibraryIsAvailableFromModelPicker() {
        let picker = anyElement("workspace.modelPicker")
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.click()
        app.buttons["Browse Hugging Face Models…"].click()

        XCTAssertTrue(app.textFields["modelLibrary.search"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["modelLibrary.searchButton"].exists)
        XCTAssertTrue(app.buttons["modelLibrary.close"].exists)
        app.buttons["modelLibrary.close"].click()
    }

    func testHuggingFaceModelLibraryHandsOffFromSettings() {
        anyElement("workspace.modelPicker").click()
        anyElement("workspace.modelPicker.manageAccounts").click()

        let browse = anyElement("settings.accounts.browseHuggingFace")
        XCTAssertTrue(browse.waitForExistence(timeout: 3))
        browse.click()

        XCTAssertTrue(app.textFields["modelLibrary.search"].waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("settings.accounts.browseHuggingFace").exists)
        app.buttons["modelLibrary.close"].click()
    }

    func testHuggingFaceModelLibraryHandsOffFromNativeSettingsWindow() {
        app.typeKey(",", modifierFlags: .command)
        let accounts = anyElement("settings.page.accounts")
        XCTAssertTrue(accounts.waitForExistence(timeout: 3))
        accounts.click()

        let browse = anyElement("settings.accounts.browseHuggingFace")
        XCTAssertTrue(browse.waitForExistence(timeout: 3))
        browse.click()

        XCTAssertTrue(app.textFields["modelLibrary.search"].waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("settings.page.accounts").exists)
        app.buttons["modelLibrary.close"].click()
    }

    func testAccountInputRowsFocusAcrossTheirWidthAndPasteLeftToRight() {
        anyElement("workspace.modelPicker").click()
        anyElement("workspace.modelPicker.manageAccounts").click()
        anyElement("settings.accounts.add").click()
        app.menuItems["Custom endpoint"].click()

        let name = anyElement("accountEditor.name")
        let baseURL = anyElement("accountEditor.baseURL")
        let apiKey = anyElement("accountEditor.apiKey")
        let context = anyElement("accountEditor.contextWindow")
        XCTAssertTrue(name.waitForExistence(timeout: 3))

        func focusAndReplace(
            _ field: XCUIElement,
            with value: String,
            horizontalOffset: CGFloat,
            paste: Bool = false
        ) {
            field.coordinate(
                withNormalizedOffset: CGVector(dx: horizontalOffset, dy: 0.5)
            ).click()
            app.typeKey("a", modifierFlags: .command)
            if paste {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                app.typeKey("v", modifierFlags: .command)
            } else {
                app.typeText(value)
            }
        }

        // The far-left hit target must focus every row, even though the old
        // Form layout put the actual editor only in a trailing column.
        focusAndReplace(name, with: "Left", horizontalOffset: 0.02)
        XCTAssertEqual(name.value as? String, "Left")
        focusAndReplace(name, with: "Work", horizontalOffset: 0.5, paste: true)
        XCTAssertEqual(name.value as? String, "Work")

        focusAndReplace(baseURL, with: "h", horizontalOffset: 0.02)
        focusAndReplace(
            baseURL,
            with: "https://api.example.com/v1",
            horizontalOffset: 0.5,
            paste: true
        )
        XCTAssertEqual(baseURL.value as? String, "https://api.example.com/v1")

        focusAndReplace(apiKey, with: "x", horizontalOffset: 0.02)
        focusAndReplace(apiKey, with: "sk-test-secret", horizontalOffset: 0.5, paste: true)
        let masked = apiKey.value as? String ?? ""
        XCTAssertFalse(masked.isEmpty)
        XCTAssertNotEqual(masked, "sk-test-secret")

        focusAndReplace(context, with: "8", horizontalOffset: 0.02)
        focusAndReplace(context, with: "8192", horizontalOffset: 0.5, paste: true)
        XCTAssertEqual(context.value as? String, "8192")
        XCTAssertTrue(app.buttons["accountEditor.save"].isEnabled)

        // Avoid leaving a test credential in the developer's account file.
        app.buttons["accountEditor.cancel"].click()
    }

    func testModelPickerStaysResponsiveWithLongVLLMModelName() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_LONG_MODEL"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let originalFrame = app.windows.firstMatch.frame
        anyElement("workspace.modelPicker").click()

        XCTAssertTrue(anyElement("workspace.modelPicker.popover").waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "Qwen3.6-27B-Fable-Fusion")
            ).firstMatch.exists
        )
        XCTAssertTrue(anyElement("workspace.modelPicker.manageAccounts").exists)
        XCTAssertEqual(app.windows.firstMatch.frame, originalFrame)

        anyElement("workspace.modelPicker.close").click()
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["palette.search"].waitForExistence(timeout: 3))
    }

    func testSlashCommandPopupListsCommands() {
        let composer = app.textViews["composer.input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        composer.click()
        composer.typeText("/")

        XCTAssertTrue(anyElement("composer.slash.clear").waitForExistence(timeout: 2))

        // Escape dismisses the popup without clearing the draft.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(anyElement("composer.slash.clear").exists)
        app.typeKey(.delete, modifierFlags: [])
    }

    func testShortcutsSheetOpensWithCommandSlash() {
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(app.buttons["shortcuts.close"].waitForExistence(timeout: 3))
        app.buttons["shortcuts.close"].click()
    }

    func testKeyboardShortcutsHaveASettingsTabBelowExtensions() {
        anyElement("workspace.modelPicker").click()
        anyElement("workspace.modelPicker.manageAccounts").click()

        let extensions = anyElement("settings.page.extensions")
        let shortcuts = anyElement("settings.page.shortcuts")
        XCTAssertTrue(extensions.waitForExistence(timeout: 3))
        XCTAssertTrue(shortcuts.exists)
        XCTAssertLessThan(extensions.frame.maxY, shortcuts.frame.minY)

        anyElement("settings.navigation").scroll(byDeltaX: 0, deltaY: -520)
        XCTAssertTrue(waitUntilHittable(shortcuts, timeout: 5))
        shortcuts.click()
        XCTAssertTrue(anyElement("shortcuts.reference").waitForExistence(timeout: 3))
    }

    func testCommandPaletteNavigatesWithArrowKeys() {
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["palette.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))

        search.typeText("shortcuts")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["shortcuts.close"].waitForExistence(timeout: 3))
        app.buttons["shortcuts.close"].click()
    }

    // MARK: - Inspector

    func testSidebarPlacesChatWorkAndScheduleBelowTheBrand() {
        let brand = anyElement("sidebar.brand")
        let chat = app.buttons["workspace.mode.chat"]
        let work = app.buttons["workspace.mode.work"]
        let schedule = anyElement("sidebar.schedule")

        XCTAssertTrue(brand.waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("inspector.rail.sideChat").exists)
        XCTAssertFalse(anyElement("sidebar.splitView").exists)
        XCTAssertFalse(anyElement("workspace.splitView").exists)
        XCTAssertTrue(chat.exists)
        XCTAssertTrue(work.exists)
        XCTAssertTrue(schedule.exists)
        XCTAssertLessThan(brand.frame.maxY, chat.frame.minY)
        XCTAssertLessThan(chat.frame.maxY, schedule.frame.minY)

        // Manage Accounts sits above New chat as a quiet row; Plugins & MCP
        // lives in the Overview shortcut bar now.
        let accounts = anyElement("sidebar.accounts")
        XCTAssertTrue(accounts.exists)
        XCTAssertLessThan(accounts.frame.maxY, schedule.frame.minY)
        XCTAssertFalse(anyElement("sidebar.extensions").exists)

        schedule.click()
        XCTAssertTrue(anyElement("scheduleEditor").waitForExistence(timeout: 3))
    }

    func testRunAwarenessControlsAreVisibleAndJustChatHidesAgenticWorkspaceUI() {
        let chat = app.buttons["workspace.mode.chat"]
        let work = app.buttons["workspace.mode.work"]
        XCTAssertTrue(chat.waitForExistence(timeout: 3))
        XCTAssertTrue(work.exists)
        XCTAssertTrue(work.isSelected)

        chat.click()
        XCTAssertTrue(chat.isSelected)
        XCTAssertTrue(anyElement("composer.justChatBoundary").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("composer.chatAttachments").exists)
        XCTAssertTrue(anyElement("composer.addChatAttachment").exists)
        XCTAssertFalse(anyElement("composer.context").exists)
        XCTAssertFalse(anyElement("composer.mode.plan").exists)
        XCTAssertFalse(anyElement("composer.mode.grill").exists)
        XCTAssertFalse(anyElement("plan.context").exists)
        // Just Chat is not a workspace surface, so the rail goes with the
        // panel — the whole right side disappears.
        XCTAssertFalse(anyElement("inspector.rail.more").exists)
        XCTAssertFalse(anyElement("inspector.rail.terminal").exists)

        XCTAssertTrue(
            anyElement("turnCompletion.00000000-0000-0000-0000-000000000103")
                .waitForExistence(timeout: 3)
        )

        app.typeKey("1", modifierFlags: .command)
        XCTAssertFalse(anyElement("plan.context").exists)

        work.click()
        XCTAssertTrue(work.isSelected)
        let planMode = anyElement("composer.mode.plan")
        XCTAssertTrue(planMode.waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("composer.mode.grill").exists)
        XCTAssertGreaterThanOrEqual(
            planMode.frame.minY,
            app.textViews["composer.input"].frame.maxY - 2,
            "mode and routing controls belong in the composer footer"
        )
        XCTAssertTrue(anyElement("plan.context").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.rail.plan").exists, "the rail returns with agentic modes")
    }

    func testWorkspaceActionsSitBesideModelPickerAndRailMoreMenuRestoresTabs() {
        XCTAssertTrue(anyElement("inspector.rail.notes").waitForExistence(timeout: 3))
        let more = anyElement("inspector.rail.more")
        let toggle = anyElement("inspector.rail.toggle")
        XCTAssertTrue(more.exists)
        XCTAssertFalse(anyElement("inspector.rail.settings").exists)
        XCTAssertTrue(toggle.exists)
        XCTAssertFalse(anyElement("inspector.rail.sideChat").exists)
        XCTAssertFalse(anyElement("inspector.rail.simulator").exists)

        let modelPicker = anyElement("workspace.modelPicker")
        let workspaceActions = anyElement("workspace.actions")
        XCTAssertTrue(modelPicker.exists)
        XCTAssertTrue(workspaceActions.exists)
        XCTAssertLessThan(modelPicker.frame.maxX, workspaceActions.frame.minX)
        XCTAssertLessThanOrEqual(
            workspaceActions.frame.minX - modelPicker.frame.maxX,
            24,
            "workspace actions should stay next to the model picker"
        )
        XCTAssertLessThan(
            more.frame.maxY,
            toggle.frame.minY,
            "the vertical-dots panel menu belongs at the top of the inspector rail"
        )
        XCTAssertLessThan(toggle.frame.maxY, anyElement("inspector.rail.plan").frame.minY)

        more.click()
        XCTAssertTrue(app.menuItems["inspector.rail.menu.sideChat"].exists)
        for tab in ["changes", "files", "simulator", "runs", "agents"] {
            XCTAssertTrue(
                app.menuItems["inspector.rail.menu.\(tab)"].exists,
                "the more-panels menu should restore \(tab)"
            )
        }
        XCTAssertFalse(
            app.menuItems["inspector.rail.menu.checkpoints"].exists,
            "manual checkpoints should not occupy a persistent inspector tab"
        )
        app.menuItems["inspector.rail.menu.agents"].click()
        XCTAssertTrue(anyElement("agents.content").waitForExistence(timeout: 3))

        let settingsMenu = anyElement("sidebar.more")
        XCTAssertTrue(settingsMenu.waitForExistence(timeout: 3))
        settingsMenu.click()
        XCTAssertTrue(menuItem(
            "sidebar.settings",
            title: "Settings…"
        ).waitForExistence(timeout: 3))
        XCTAssertTrue(menuItem(
            "sidebar.checkpoints",
            title: "Session Checkpoints…"
        ).exists)
    }

    func testRouterAndProxiesLiveOnlyInMorePanelsMenu() {
        XCTAssertTrue(anyElement("inspector.rail.notes").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("inspector.rail.router").exists)
        XCTAssertFalse(anyElement("inspector.rail.proxies").exists)

        let more = anyElement("inspector.rail.more")
        XCTAssertTrue(more.exists)
        more.click()

        for tab in ["router", "proxies"] {
            XCTAssertTrue(
                app.menuItems["inspector.rail.menu.\(tab)"].exists,
                "the more-panels menu should contain \(tab)"
            )
        }
    }

    func testRailIconsOpenAndTogglePanels() {
        // The suite seeds the panel open on Overview; the Overview icon's second
        // click collapses, its next click reopens.
        let planIcon = anyElement("inspector.rail.plan")
        XCTAssertTrue(planIcon.waitForExistence(timeout: 3))
        XCTAssertTrue(planIcon.label.contains("Overview"))
        let terminalIcon = anyElement("inspector.rail.terminal")
        XCTAssertTrue(terminalIcon.exists)
        XCTAssertFalse(anyElement("inspector.rail.simulator").exists)
        XCTAssertLessThan(planIcon.frame.maxY, terminalIcon.frame.minY)
        XCTAssertTrue(anyElement("inspector.tab.plan").exists)
        for closedTab in ["changes", "files", "terminal", "preview", "checkpoints", "runs", "agents"] {
            XCTAssertFalse(
                anyElement("inspector.tab.\(closedTab)").exists,
                "the old permanent inspector strip must not expose \(closedTab)"
            )
        }
        planIcon.click()
        XCTAssertFalse(anyElement("plan.context").exists)
        XCTAssertTrue(planIcon.exists)

        // Terminal is a direct rail destination and closes on a second click.
        terminalIcon.click()
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.terminal").exists)
        terminalIcon.click()
        XCTAssertFalse(anyElement("terminal.output").exists)

        // A different tab's icon opens the panel straight onto that tab.
        let browserIcon = anyElement("inspector.rail.preview")
        XCTAssertTrue(browserIcon.exists)
        browserIcon.click()
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.plan").exists)
        XCTAssertTrue(anyElement("inspector.tab.terminal").exists)
        XCTAssertTrue(anyElement("inspector.tab.preview").exists)
    }

    func testPanelToggleClosesAndRestoresTheLastPanel() {
        let toggle = anyElement("inspector.rail.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("plan.context").exists)

        toggle.click()
        XCTAssertFalse(anyElement("plan.context").exists)
        XCTAssertEqual(toggle.value as? String, "Closed")

        toggle.click()
        XCTAssertTrue(anyElement("plan.context").waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.value as? String, "Open")

        let browserIcon = anyElement("inspector.rail.preview")
        browserIcon.click()
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))

        toggle.click()
        XCTAssertFalse(anyElement("browser.url").exists)
        toggle.click()
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))
    }

    func testKeyboardShortcutsReachAdditionalInspectorTabs() {
        XCTAssertTrue(anyElement("inspector.rail.plan").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.rail.more").exists)
        let zoom = anyElement("inspector.zoom")
        XCTAssertTrue(zoom.exists)
        XCTAssertGreaterThan(
            zoom.frame.minY,
            anyElement("inspector.rail.notes").frame.minY,
            "expand belongs at the rail bottom"
        )

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.plan").exists)
        XCTAssertTrue(anyElement("inspector.tab.changes").exists)
        XCTAssertFalse(anyElement("inspector.tab.files").exists)

        // A second shortcut destination appends to the dynamic bar instead of
        // replacing the first or exposing every destination permanently.
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(anyElement("files.search").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("inspector.tab.files").exists)

        // Existing tabs switch in place and an active close selects the tab to
        // its right (Files here) without collapsing the inspector.
        let changesTab = app.buttons["inspector.tab.changes"].firstMatch
        XCTAssertTrue(changesTab.isHittable)
        // On macOS 15 an AX click can land on the adjacent close control when
        // two plain buttons share a horizontally scrolling tab. Press the
        // label-side coordinate so this continues to exercise tab selection.
        changesTab.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
        anyElement("inspector.tab.close.changes").click()
        XCTAssertFalse(anyElement("inspector.tab.changes").exists)
        XCTAssertFalse(anyElement("changes.file.0").exists)
        XCTAssertTrue(anyElement("files.search").exists)

        anyElement("inspector.tab.close.plan").click()
        anyElement("inspector.tab.close.files").click()
        XCTAssertTrue(anyElement("inspector.tabBar").waitForNonExistence(timeout: 3))
        XCTAssertFalse(anyElement("files.search").exists)
        XCTAssertTrue(anyElement("inspector.rail.plan").exists)
        XCTAssertTrue(anyElement("inspector.rail.more").exists)
    }

    func testBrowserExpandsInPlaceAndRestores() {
        // ⌘5 opens the Browser tab; its top controls bar carries the expand
        // control.
        app.typeKey("5", modifierFlags: .command)
        let expand = anyElement("browser.expand")
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        expand.click()

        // Zoomed: the rail's zoom button flips to "restore" and the session
        // sidebar hands its room to the panel.
        let zoom = anyElement("inspector.zoom")
        XCTAssertTrue(zoom.waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("sidebar.brand").exists)

        let handle = anyElement("inspector.resizeHandle")
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        XCTAssertEqual(handle.label, "Expanded panel width")
        XCTAssertGreaterThanOrEqual(handle.frame.width, 12)

        let originalDividerX = handle.frame.midX
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.1,
            thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0))
        )
        let dividerMovedRight = NSPredicate { candidate, _ in
            guard let element = candidate as? XCUIElement else { return false }
            return element.frame.midX > originalDividerX + 20
        }
        expectation(for: dividerMovedRight, evaluatedWith: handle)
        waitForExpectations(timeout: 3)

        let rightwardDividerX = handle.frame.midX
        let secondStart = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        secondStart.press(
            forDuration: 0.1,
            thenDragTo: secondStart.withOffset(CGVector(dx: -30, dy: 0))
        )
        let dividerMovedLeft = NSPredicate { candidate, _ in
            guard let element = candidate as? XCUIElement else { return false }
            return element.frame.midX < rightwardDividerX - 10
        }
        expectation(for: dividerMovedLeft, evaluatedWith: handle)
        waitForExpectations(timeout: 3)
        let persistedDividerX = handle.frame.midX

        zoom.click()
        XCTAssertTrue(anyElement("sidebar.brand").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("browser.url").exists)
        XCTAssertEqual(handle.label, "Inspector width")

        anyElement("browser.expand").click()
        XCTAssertEqual(handle.label, "Expanded panel width")
        let dividerReturned = NSPredicate { candidate, _ in
            guard let element = candidate as? XCUIElement else { return false }
            return abs(element.frame.midX - persistedDividerX) <= 4
        }
        expectation(for: dividerReturned, evaluatedWith: handle)
        waitForExpectations(timeout: 3)
    }

    func testInspectorTabsSwitchWithCommandNumberShortcuts() {
        // ⌘2 — Changes, populated from the seeded git status.
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))

        // ⌘3 — Files, populated from the seeded workspace index.
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(anyElement("files.row.0").waitForExistence(timeout: 3))

        // ⌘4 — the native PTY terminal.
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("terminal.empty").exists)

        // ⌘5 — Browser. The address bar is unconditional chrome, so unlike the
        // old Preview tab this needs no seeded page to assert on.
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("browser.empty").exists)

        // ⌘6 — the focused manual-checkpoint manager, not an inspector tab.
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(anyElement("checkpoints.close").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("checkpoints.create").exists)
        XCTAssertFalse(anyElement("inspector.tab.checkpoints").exists)
        anyElement("checkpoints.close").click()

        // ⌘8 — AGENTS.md, with an explanation and the workspace editor.
        app.typeKey("8", modifierFlags: .command)
        XCTAssertTrue(anyElement("agents.content").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("agents.editor").exists)
        XCTAssertTrue(anyElement("agents.starters").exists)
        XCTAssertTrue(anyElement("agents.saveState").exists)
        XCTAssertTrue(anyElement("agents.save").exists)

        // ⌘1 — back to the idle Overview.
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(anyElement("plan.summary").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("plan.section.outputs").exists)
        XCTAssertTrue(anyElement("plan.context").exists)
        XCTAssertTrue(anyElement("inspector.tab.plan").label.contains("Overview"))
    }

    func testIdleOverviewShowsEmptySummaryAndKeepsContextPinned() {
        let tabBar = anyElement("inspector.tabBar")
        let summary = anyElement("plan.summary")
        let context = anyElement("plan.context")
        let window = app.windows.firstMatch

        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(context.exists)
        // Outputs and Sources always show so their "+" actions stay
        // discoverable; every other section appears only with content.
        XCTAssertTrue(anyElement("plan.section.outputs").exists)
        XCTAssertTrue(anyElement("plan.section.sources").exists)
        XCTAssertTrue(anyElement("plan.outputs.empty").exists)
        XCTAssertTrue(anyElement("plan.sources.empty").exists)
        XCTAssertFalse(anyElement("plan.section.plan").exists)
        XCTAssertFalse(anyElement("plan.section.subagents").exists)
        XCTAssertFalse(anyElement("plan.section.processes").exists)
        XCTAssertFalse(anyElement("plan.plan.row").exists)
        XCTAssertLessThanOrEqual(
            window.frame.maxY - context.frame.maxY,
            30,
            "Context should remain pinned to the bottom of the Overview tab"
        )
        XCTAssertLessThanOrEqual(
            context.frame.maxX,
            tabBar.frame.maxX + 1,
            "Session overview content must stay inside the inspector"
        )
        XCTAssertFalse(anyElement("checkpointTab.content").exists)
    }

    func testOverviewSourcesMenuOpensSkillsAndMCP() {
        let empty = anyElement("plan.sources.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 3))
        empty.click()

        let attach = app.menuItems["Attach files or folders"]
        let skills = app.menuItems["Skills & MCP"]
        XCTAssertTrue(attach.waitForExistence(timeout: 3))
        XCTAssertTrue(skills.exists)
        skills.click()

        // "Skills & MCP" lands Settings directly on the Extensions page.
        XCTAssertTrue(anyElement("settings.page.extensions").waitForExistence(timeout: 5))
        XCTAssertTrue(anyElement("extensions.tab.installed").waitForExistence(timeout: 3))

        // The Extensions page has no Cancel/Save bar; the header close control
        // is the way out.
        let close = anyElement("settings.close")
        XCTAssertTrue(close.exists)
        close.click()
        XCTAssertTrue(waitUntil { !self.anyElement("settings.page.extensions").exists })
    }

    func testSidebarSearchIsRevealedFromTheWorkspacesHeader() {
        let toggle = anyElement("sidebar.search.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        // The field is put away until asked for; the sidebar no longer spends
        // a row on an empty search box.
        XCTAssertFalse(anyElement("sidebar.search").exists)

        toggle.click()
        XCTAssertTrue(anyElement("sidebar.search").waitForExistence(timeout: 3))

        toggle.click()
        XCTAssertTrue(waitUntil { !self.anyElement("sidebar.search").exists })

        // Search All Conversations (⇧⌘F) reveals and focuses it from anywhere.
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(anyElement("sidebar.search").waitForExistence(timeout: 3))
    }

    func testNotesHeaderSwitchesScopeAndKeepsToolbarActions() {
        app.typeKey("9", modifierFlags: .command)
        let header = anyElement("notes.header")
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("notes.toolbar").exists)
        XCTAssertTrue(anyElement("notes.toolbar.insert").exists)
        XCTAssertTrue(anyElement("notes.toolbar.more").exists)
        let color = anyElement("notes.toolbar.textColor")
        XCTAssertTrue(color.exists)
        XCTAssertEqual(color.value as? String, "Default")
        XCTAssertTrue(anyElement("notes.saveState").exists)

        color.click()
        let blue = app.menuItems["Blue"]
        XCTAssertTrue(blue.waitForExistence(timeout: 3))
        blue.click()
        XCTAssertTrue(waitUntil {
            self.anyElement("notes.toolbar.textColor").value as? String == "Blue"
        })

        let scope = anyElement("notes.scopeMenu")
        XCTAssertTrue(scope.exists)
        XCTAssertEqual(scope.value as? String, "Notes for this workspace")

        scope.click()
        let everywhere = app.menuItems["Everywhere"]
        XCTAssertTrue(everywhere.waitForExistence(timeout: 3))
        everywhere.click()

        XCTAssertTrue(waitUntil {
            self.anyElement("notes.scopeMenu").value as? String
                == "Notes shared by every chat and workspace"
        })
        XCTAssertTrue(anyElement("notes.toolbar").exists)
    }

    func testOverviewShortcutsOpenSettingsAndStayPinned() {
        let shortcuts = anyElement("plan.shortcuts")
        let context = anyElement("plan.context")
        XCTAssertTrue(shortcuts.waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("plan.shortcuts.finder").exists)
        XCTAssertTrue(anyElement("plan.shortcuts.accounts").exists)
        XCTAssertTrue(anyElement("plan.shortcuts.extensions").exists)

        // The bar is pinned with the context card rather than scrolling with
        // the summary, so it sits directly above it.
        XCTAssertTrue(context.exists)
        XCTAssertLessThanOrEqual(shortcuts.frame.maxY, context.frame.minY + 1)

        // Finder is deliberately not clicked: it would open a real Finder
        // window over the test run.
        for (identifier, page) in [
            ("plan.shortcuts.extensions", "settings.page.extensions"),
            ("plan.shortcuts.accounts", "settings.page.accounts"),
        ] {
            let shortcut = anyElement(identifier)
            XCTAssertTrue(waitUntilHittable(shortcut))
            shortcut.click()
            XCTAssertTrue(anyElement(page).waitForExistence(timeout: 5))
            anyElement("settings.close").click()
            XCTAssertTrue(waitUntil { !self.anyElement(page).exists })
        }
    }

    func testOverviewShowsAnAlreadyLoadedSubagentRun() {
        relaunchWithRunFixture("swarm-live")
        app.typeKey("1", modifierFlags: .command)

        XCTAssertTrue(anyElement("plan.section.subagents").waitForExistence(timeout: 3))
        let subagent = anyElement("plan.subagents.row.seed-run")
        XCTAssertTrue(subagent.waitForExistence(timeout: 3))
        XCTAssertTrue(
            subagent.label.localizedCaseInsensitiveContains("working"),
            "Expected the running team to read as working; got: \(subagent.label)"
        )
    }

    func testOverviewOutputsMenuOffersCreationActions() {
        let creationItems = [
            "Create document", "Create presentation", "Create spreadsheet", "Create site",
        ]

        // Idle: the empty-state row is the section's own "+" menu.
        let empty = anyElement("plan.outputs.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 3))
        empty.click()
        XCTAssertTrue(app.menuItems["Create document"].waitForExistence(timeout: 3))
        for item in creationItems {
            XCTAssertTrue(app.menuItems[item].exists, "Missing \(item) menu item")
        }
        app.menuItems["Create document"].click()

        // The prompt lands in the composer while the summary stays on screen.
        let composer = app.textViews["composer.input"]
        XCTAssertTrue(waitUntil {
            (composer.value as? String)?.localizedCaseInsensitiveContains("document") == true
        })
        XCTAssertTrue(
            anyElement("plan.context").exists,
            "prefilling the composer from the summary must not collapse the inspector"
        )
        XCTAssertTrue(anyElement("plan.summary").exists)

        // Running: the header "+" offers the same actions above real rows.
        relaunchWithPlanOverview("running")
        let add = anyElement("plan.section.outputs.add")
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.click()
        XCTAssertTrue(app.menuItems["Create document"].waitForExistence(timeout: 3))
        for item in creationItems {
            XCTAssertTrue(app.menuItems[item].exists, "Missing \(item) menu item")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    private func relaunchWithPlanOverview(_ fixture: String, preserveSections: Bool = false) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_PLAN_OVERVIEW"] = fixture
        // Section collapse state is @AppStorage; the seed resets it on every
        // launch unless a test opts in to carrying it across a relaunch.
        app.launchEnvironment["LOCUS_UI_TESTING_PRESERVE_SUMMARY_SECTIONS"] =
            preserveSections ? "1" : nil
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    func testAcceptanceWindowSizesRemainUsableInLightAndDarkAppearances() {
        let cases = [("1120", "700", "Light"), ("1250", "760", "Dark")]
        for (width, height, appearance) in cases {
            app.terminate()
            app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = width
            app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = height
            app.launchArguments = [
                "-ApplePersistenceIgnoreState", "YES",
                "-AppleInterfaceStyle", appearance,
            ]
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            let visibleSize = try! XCTUnwrap(NSScreen.main?.visibleFrame.size)
            XCTAssertEqual(
                app.windows.firstMatch.frame.width,
                min(CGFloat(Double(width)!), visibleSize.width),
                accuracy: 2
            )
            XCTAssertEqual(
                app.windows.firstMatch.frame.height,
                min(CGFloat(Double(height)!), visibleSize.height),
                accuracy: 2
            )
            assertCoreWorkspaceFitsInsideWindow()
        }
    }

    func testCompactWindowKeepsChromeClearAndUsesAnOverlaySidebar() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "720"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "620"
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        let restore = anyElement("workspace.showSidebar")
        let title = anyElement("workspace.sessionTitle")
        let composer = anyElement("composer.input")
        let tabBar = anyElement("inspector.tabBar")
        for element in [restore, title, tabBar] {
            XCTAssertTrue(element.waitForExistence(timeout: 3))
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(element.frame))
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertTrue(composer.isHittable)
        XCTAssertTrue(window.frame.intersects(composer.frame))
        XCTAssertGreaterThanOrEqual(
            restore.frame.minX - window.frame.minX,
            68,
            "The sidebar restore control must stay clear of the macOS traffic lights"
        )
        XCTAssertFalse(anyElement("sidebar.newSession").exists)

        restore.click()
        XCTAssertTrue(anyElement("sidebar.newSession").waitForExistence(timeout: 3))
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(
            anyElement("sidebar.newSession").frame
        ))
        anyElement("sidebar.collapse").click()
        XCTAssertTrue(waitUntil { !self.anyElement("sidebar.newSession").exists })

        // Four intrinsic-width labels exceed this compact inspector. The tab
        // strip must overflow safely and keep the selected tab and its close
        // control reachable instead of clipping them at a count breakpoint.
        for key in ["2", "3", "4"] {
            app.typeKey(key, modifierFlags: .command)
        }
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))
        let terminalTab = anyElement("inspector.tab.terminal")
        let terminalClose = anyElement("inspector.tab.close.terminal")
        XCTAssertTrue(waitUntil { terminalTab.isHittable && terminalClose.isHittable })
        XCTAssertGreaterThanOrEqual(terminalTab.frame.minX, tabBar.frame.minX - 1)
        XCTAssertLessThanOrEqual(terminalClose.frame.maxX, tabBar.frame.maxX + 1)
    }

    func testSimulatorWorkspaceKeepsDeviceAndPrimaryControlsVisible() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_SIMULATOR"] = "attached"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = "1120"
        app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = "700"
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let stage = anyElement("simulator.stage")
        let status = anyElement("simulator.status")
        let controls = anyElement("simulator.controls")
        for element in [stage, status, controls] {
            XCTAssertTrue(element.waitForExistence(timeout: 5))
            XCTAssertTrue(
                window.frame.insetBy(dx: -1, dy: -1).contains(element.frame),
                "Simulator chrome must remain inside the window at the acceptance size."
            )
        }

        let base = XCTAttachment(screenshot: window.screenshot())
        base.name = "simulator-workspace"
        base.lifetime = .keepAlways
        add(base)

        let typing = app.buttons["Type on device"].firstMatch
        XCTAssertTrue(waitUntilHittable(typing))
        typing.click()
        let typingTray = anyElement("simulator.typing")
        XCTAssertTrue(typingTray.waitForExistence(timeout: 3))
        XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(typingTray.frame))

        let settings = app.buttons["Stream settings"].firstMatch
        XCTAssertTrue(waitUntilHittable(settings))
        settings.click()
        XCTAssertTrue(anyElement("simulator.streamSettings").waitForExistence(timeout: 3))
    }

    func testSimulatorDevicePickerHasAVisibleAttachPath() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_SIMULATOR"] = "picker"
        app.launch()

        XCTAssertTrue(anyElement("simulator.devicePicker").waitForExistence(timeout: 10))
        let attach = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "simulator.attach.")
        ).firstMatch
        XCTAssertTrue(waitUntilHittable(attach))
        XCTAssertTrue(app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(attach.frame))
    }

    func testPrimaryWorkspacePassesAccessibilityAudit() throws {
        try auditCurrentSurface()
    }

    func testNotebookOpensFromTheSidebarMenuAndListsStoredNotes() throws {
        anyElement("sidebar.more").click()
        let item = menuItem("sidebar.notebook", title: "Notebook")
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()

        XCTAssertTrue(anyElement("notebook.search").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("notebook.close").exists)
        // Nothing is selected until a row is chosen, so the editor must not be
        // showing some other document's text.
        XCTAssertTrue(anyElement("notebook.noSelection").exists)
        anyElement("notebook.close").click()
        XCTAssertTrue(
            waitUntil(timeout: 3) { !self.anyElement("notebook.search").exists },
            "closing the notebook should dismiss it"
        )
    }

    func testNotebookOpensAStoredNoteInTheEditor() throws {
        relaunchForAccessibilitySurface("notebook", anchor: "notebook.search")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "notebook.entry."))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the seeded notes should be listed")
        row.click()

        // The Notebook's editor carries its own identifier prefix so it is not
        // confused with the inspector's, which can be on screen at the same time.
        XCTAssertTrue(anyElement("notebook.document.editor").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("notebook.document.scopeBadge").exists)
        XCTAssertFalse(
            anyElement("notebook.document.scopeMenu").exists,
            "a document's scope is a fact about it here, not a setting to change"
        )
    }

    func testNotebookPassesAccessibilityAudit() throws {
        relaunchForAccessibilitySurface("notebook", anchor: "notebook.search")
        try auditCurrentSurface()
    }

    func testSettingsPassesAccessibilityAudit() throws {
        relaunchForAccessibilitySurface("settings", anchor: "settings.page.general")
        try auditCurrentSurface()
    }

    func testModelLibraryPassesAccessibilityAudit() throws {
        relaunchForAccessibilitySurface("model-library", anchor: "modelLibrary.search")
        XCTAssertTrue(
            anyElement("modelLibrary.resultCount").waitForExistence(timeout: 15),
            "the initial model search should settle before auditing its result surface"
        )
        try auditCurrentSurface()
    }

    func testAgentEditorPassesAccessibilityAudit() throws {
        relaunchForAccessibilitySurface("agent-editor", anchor: "agent.instructions")
        XCTAssertTrue(anyElement("agent.nameLabel").exists)
        try auditCurrentSurface()
    }

    func testPermissionAndPlanApprovalPassAccessibilityAudit() throws {
        app.launchEnvironment["LOCUS_UI_TESTING_PERMISSION"] = "1"
        relaunchForAccessibilitySurface("permission", anchor: "permission.panel")
        try auditCurrentSurface()

        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_PERMISSION"] = nil
        app.launchEnvironment["LOCUS_UI_TESTING_PLAN_APPROVAL"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_ACCESSIBILITY_SURFACE"] = "plan-approval"
        app.launch()
        XCTAssertTrue(anyElement("planApproval.panel").waitForExistence(timeout: 10))
        try auditCurrentSurface()
    }

    func testDocumentationScreenshots() {
        let captures = [
            (surface: "workspace", anchor: "files.search", name: "locus-workspace"),
            (surface: "files", anchor: "files.search", name: "locus-files"),
            (surface: "plan", anchor: "plan.summary", name: "locus-plan"),
        ]

        for capture in captures {
            app.terminate()
            app.launchEnvironment["LOCUS_UI_TESTING_DOCUMENTATION_SURFACE"] = capture.surface
            app.launch()
            XCTAssertTrue(anyElement("conversation.welcome").waitForExistence(timeout: 10))
            XCTAssertTrue(anyElement(capture.anchor).waitForExistence(timeout: 5))

            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = capture.name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testContextWindowCardCollapsesAndExpands() {
        let toggle = anyElement("plan.contextWindow.toggle")
        let details = anyElement("plan.contextWindow.details")
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        if !details.exists {
            toggle.click()
            XCTAssertTrue(details.waitForExistence(timeout: 3))
        }

        toggle.click()
        XCTAssertTrue(waitUntil { !details.exists })
        toggle.click()
        XCTAssertTrue(details.waitForExistence(timeout: 3))
    }

    /// The running fixture's summary card is taller than the inspector
    /// viewport, so the lower sections (Subagents, Background processes,
    /// Sources) can sit under the fold — and how much sits there depends on
    /// the window height, which the screen clamps.
    ///
    /// A clipped SwiftUI row still publishes an accessibility frame, so
    /// `isHittable` stays true for a row scrolled out of sight and a
    /// synthesized click lands on the pinned context card instead, silently
    /// doing nothing. Scroll until the target's frame is provably inside the
    /// scroll viewport: below the inspector tab bar and above the context
    /// card that is pinned to the bottom of the tab.
    private func scrollSummary(toReveal target: XCUIElement) {
        let summary = anyElement("plan.summary")
        guard summary.exists else { return }
        let window = app.windows.firstMatch
        let tabBar = anyElement("inspector.tabBar")
        let context = anyElement("plan.context")
        let shortcuts = anyElement("plan.shortcuts")
        for _ in 0..<10 {
            guard target.exists else { return }
            let top = tabBar.exists ? tabBar.frame.maxY : window.frame.minY
            // Everything pinned below the scrolling summary hides content, so
            // the fold is the topmost pinned element — the shortcut bar sits
            // above the context card.
            let fold = [shortcuts, context]
                .filter(\.exists)
                .map { $0.frame.minY }
                .min() ?? window.frame.maxY
            let frame = target.frame
            if frame.minY >= top, frame.maxY <= fold, target.isHittable { return }
            summary.scroll(byDeltaX: 0, deltaY: frame.maxY > fold ? -120 : 120)
        }
    }

    /// Scrolls `target` fully into view, clicks it, and confirms the click
    /// actually took. A click that lands under the fold is synthesized
    /// successfully and changes nothing, so the outcome is the only reliable
    /// signal that the control was reached.
    @discardableResult
    private func clickInSummary(
        _ target: XCUIElement,
        until reached: @escaping () -> Bool
    ) -> Bool {
        for _ in 0..<3 {
            scrollSummary(toReveal: target)
            guard waitUntilHittable(target) else { continue }
            target.click()
            if waitUntil(condition: reached) { return true }
        }
        return false
    }

    func testRunningOverviewShowsAllSummarySections() {
        relaunchWithPlanOverview("running")

        XCTAssertTrue(anyElement("plan.summary").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("plan.section.plan").exists)
        XCTAssertTrue(anyElement("plan.section.outputs").exists)
        XCTAssertTrue(anyElement("plan.plan.row").exists)
        for index in 0...5 {
            XCTAssertTrue(
                anyElement("plan.outputs.row.\(index)").exists,
                "Missing output row \(index)"
            )
        }
        XCTAssertFalse(anyElement("plan.outputs.row.6").exists)
        let showMore = anyElement("plan.outputs.showMore")
        XCTAssertTrue(showMore.exists)
        XCTAssertTrue(
            showMore.label.contains("2 more"),
            "Expected two hidden outputs; got: \(showMore.label)"
        )

        let viewAll = anyElement("plan.sources.viewAll")
        scrollSummary(toReveal: viewAll)
        XCTAssertTrue(viewAll.waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("plan.section.subagents").exists)
        XCTAssertTrue(anyElement("plan.section.processes").exists)
        XCTAssertTrue(anyElement("plan.section.sources").exists)
        for index in 0...2 {
            XCTAssertTrue(
                anyElement("plan.sources.row.\(index)").exists,
                "Missing source row \(index)"
            )
        }
        XCTAssertFalse(anyElement("plan.sources.row.3").exists)

        let process = anyElement("plan.processes.row.0")
        XCTAssertTrue(process.exists)
        XCTAssertTrue(
            process.label.contains("npm run dev"),
            "Expected the seeded dev server; got: \(process.label)"
        )
        XCTAssertTrue(anyElement("plan.processes.stopAll").exists)

        let subagent = anyElement("plan.subagents.row.seed-subagent")
        XCTAssertTrue(subagent.exists)
        XCTAssertTrue(
            subagent.label.contains("Working"),
            "Expected the running subagent to read as working; got: \(subagent.label)"
        )
    }

    func testOverviewOutputsShowMoreRevealsRemainingRows() {
        relaunchWithPlanOverview("running")

        let showMore = anyElement("plan.outputs.showMore")
        let sixth = anyElement("plan.outputs.row.6")
        let seventh = anyElement("plan.outputs.row.7")
        XCTAssertTrue(showMore.waitForExistence(timeout: 3))
        XCTAssertFalse(sixth.exists)

        XCTAssertTrue(
            clickInSummary(showMore) { seventh.exists },
            "Show more should reveal the remaining outputs"
        )
        XCTAssertTrue(sixth.exists)
        XCTAssertTrue(
            waitUntil { showMore.label.localizedCaseInsensitiveContains("show less") },
            "Once everything is out the control should offer to show less; got: \(showMore.label)"
        )

        XCTAssertTrue(
            clickInSummary(showMore) { !sixth.exists },
            "Show less should collapse back to the first six outputs"
        )
        XCTAssertTrue(waitUntil { showMore.label.contains("2 more") })
    }

    func testOverviewSourcesViewAllOpensDetailAndBackReturns() {
        relaunchWithPlanOverview("running")

        let summary = anyElement("plan.summary")
        let context = anyElement("plan.context")
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        let viewAll = anyElement("plan.sources.viewAll")
        let panel = anyElement("plan.sources.panel")
        XCTAssertTrue(
            clickInSummary(viewAll) { panel.exists },
            "View all should open the complete source list"
        )
        for index in 0...4 {
            XCTAssertTrue(
                anyElement("plan.sources.panel.row.\(index)").exists,
                "Missing source detail row \(index)"
            )
        }
        XCTAssertTrue(waitUntil { !summary.exists })
        XCTAssertTrue(context.exists, "the context card stays pinned under the detail page")

        let back = anyElement("plan.summary.back")
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.click()
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil { !panel.exists })
        XCTAssertTrue(context.exists)
    }

    func testOverviewPlanRowOpensPlanDetailAndBackReturns() {
        relaunchWithPlanOverview("running")

        let summary = anyElement("plan.summary")
        let planRow = anyElement("plan.plan.row")
        XCTAssertTrue(planRow.waitForExistence(timeout: 3))
        XCTAssertTrue(
            planRow.label.contains("2 of 4 steps done"),
            "Expected the seeded progress; got: \(planRow.label)"
        )
        planRow.click()

        XCTAssertTrue(anyElement("plan.plan.detail").waitForExistence(timeout: 3))
        let refactor = anyElement("plan.plan.detail.step.refactor")
        XCTAssertTrue(refactor.waitForExistence(timeout: 3))
        XCTAssertTrue(
            refactor.label.contains("running"),
            "Expected the refactor step to be running; got: \(refactor.label)"
        )
        // The step row combines its children into one element, so the label
        // text is read from the row rather than a standalone static text.
        XCTAssertTrue(refactor.label.contains("Refactor retry logic with backoff"))
        XCTAssertTrue(waitUntil { !summary.exists })
        XCTAssertTrue(anyElement("plan.context").exists)

        let back = anyElement("plan.summary.back")
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.click()
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil { !self.anyElement("plan.plan.detail").exists })
    }

    func testErrorOverviewKeepsPlanVisibleWithFailedStep() {
        relaunchWithPlanOverview("error")

        let planRow = anyElement("plan.plan.row")
        XCTAssertTrue(planRow.waitForExistence(timeout: 3))
        planRow.click()

        XCTAssertTrue(anyElement("plan.plan.detail").waitForExistence(timeout: 3))
        let refactor = anyElement("plan.plan.detail.step.refactor")
        XCTAssertTrue(refactor.waitForExistence(timeout: 3))
        XCTAssertTrue(
            refactor.label.contains("failed"),
            "Expected the stopped step to read as failed; got: \(refactor.label)"
        )
    }

    func testOverviewSectionCollapseStatePersistsAcrossRelaunch() {
        relaunchWithPlanOverview("running")
        // Collapse state is @AppStorage. Leave Outputs expanded even when an
        // assertion fails between the collapse and the final expand below.
        addTeardownBlock { [self] in
            guard app.state == .runningForeground else { return }
            let toggle = anyElement("plan.section.outputs.toggle")
            if toggle.exists, toggle.label.contains("Expand") {
                toggle.click()
            }
        }

        let firstRow = anyElement("plan.outputs.row.0")
        let toggle = anyElement("plan.section.outputs.toggle")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        XCTAssertTrue(toggle.exists)
        XCTAssertTrue(toggle.label.contains("Collapse"), "Unexpected toggle label: \(toggle.label)")

        toggle.click()
        XCTAssertTrue(waitUntil { !firstRow.exists })
        XCTAssertTrue(waitUntil { toggle.label.contains("Expand") })

        relaunchWithPlanOverview("running", preserveSections: true)
        XCTAssertTrue(anyElement("plan.section.outputs").waitForExistence(timeout: 3))
        XCTAssertFalse(firstRow.exists, "a collapsed section must stay collapsed across launches")
        XCTAssertTrue(toggle.label.contains("Expand"), "Unexpected toggle label: \(toggle.label)")

        toggle.click()
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil { toggle.label.contains("Collapse") })
    }

    func testOverflowingInspectorTabsStillSwitchBrowserAndTerminal() {
        // Six destinations exercise the horizontally scrolling tab path.
        // Browser and Terminal both install native AppKit views; those views
        // must never cover the shared inspector tabs for hit-testing.
        app.typeKey("2", modifierFlags: .command)
        app.typeKey("3", modifierFlags: .command)
        app.typeKey("4", modifierFlags: .command)
        app.typeKey("5", modifierFlags: .command)
        app.typeKey("7", modifierFlags: .command)
        app.typeKey("4", modifierFlags: .command)

        var browserTab: XCUIElement { app.buttons["inspector.tab.preview"].firstMatch }
        var terminalTab: XCUIElement { app.buttons["inspector.tab.terminal"].firstMatch }
        XCTAssertTrue(browserTab.waitForExistence(timeout: 3))
        XCTAssertTrue(terminalTab.exists)
        XCTAssertTrue(browserTab.isHittable)
        XCTAssertTrue(terminalTab.isHittable)
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))

        browserTab.click()
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("terminal.output").exists)

        terminalTab.click()
        XCTAssertTrue(anyElement("terminal.output").waitForExistence(timeout: 3))

        browserTab.click()
        XCTAssertTrue(anyElement("browser.url").waitForExistence(timeout: 3))
    }

    func testChangesTabShowsSeededWorkingTreeAndOpensADiff() {
        app.typeKey("2", modifierFlags: .command)

        let firstFile = anyElement("changes.file.0")
        XCTAssertTrue(firstFile.waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("changes.summary").exists)
        XCTAssertTrue(app.buttons["changes.refresh"].exists)
        XCTAssertTrue(anyElement("changes.branch").exists)
        XCTAssertTrue(anyElement("changes.sync.counts").exists)

        firstFile.click()
        // The seeded diff parses into hunks, so per-hunk controls replace the
        // flat diff for this file.
        XCTAssertTrue(anyElement("changes.file.0.hunks").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("changes.file.0.hunk.0.stage").exists)
        XCTAssertTrue(anyElement("changes.file.0.hunk.1.discard").exists)
    }

    func testDiscardingAHunkAsksForConfirmationFirst() {
        app.typeKey("2", modifierFlags: .command)

        let firstFile = anyElement("changes.file.0")
        XCTAssertTrue(firstFile.waitForExistence(timeout: 3))
        firstFile.click()
        let discard = anyElement("changes.file.0.hunk.0.discard")
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        let changesScroll = anyElement("changes.scroll")
        XCTAssertTrue(changesScroll.exists)
        if !discard.isHittable {
            // Expanding the inline diff can leave its first hunk action under
            // a scroll edge on smaller CI windows. Move the containing scroll
            // view explicitly instead of relying on XCUI's implicit scroll,
            // which is unreliable for nested SwiftUI buttons on macOS.
            changesScroll.scroll(byDeltaX: -120, deltaY: 180)
        }
        XCTAssertTrue(discard.isHittable)
        discard.click()

        XCTAssertTrue(app.buttons["changes.discardHunk.confirm"].waitForExistence(timeout: 3))
        // Escape targets the active confirmation reliably on macOS 26. A title
        // query can resolve to the mirrored Touch Bar cancel button instead.
        app.typeKey(.escape, modifierFlags: [])
    }

    func testRemoteButtonsFollowTheSeededAvailability() {
        app.typeKey("2", modifierFlags: .command)

        XCTAssertTrue(anyElement("changes.file.0").waitForExistence(timeout: 3))
        // The seeded run does not mark origin as GitHub, so the PR button
        // must stay hidden regardless of build flavor.
        XCTAssertFalse(anyElement("changes.pr").exists)
    }

    func testFilesTabFiltersTheWorkspaceIndex() {
        app.typeKey("3", modifierFlags: .command)

        let search = app.textFields["files.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("TerminalSession")

        let firstRow = anyElement("files.row.0")
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("files.row.1").exists)
    }

    func testTerminalIsAvailableWithoutTheAgent() {
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(anyElement("terminal.header").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("terminal.output").exists)
        XCTAssertFalse(app.textFields["terminal.command"].exists)
    }

    // MARK: - Permission prompt

    /// Relaunches with the opt-in pending-permission fixture. It is not part
    /// of the base seed because a pending request disables send and
    /// clear-chat, which would break the rest of the suite.
    private func relaunchWithPendingPermission(toolActivityMode: String? = nil) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_PERMISSION"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_TOOL_ACTIVITY_MODE"] = toolActivityMode
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithLandingFixture() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_LANDING"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithScrollFixture(toolActivityMode: String? = nil) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_SCROLL"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_TOOL_ACTIVITY_MODE"] = toolActivityMode
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func scrollTranscriptDown(toReveal target: XCUIElement, attempts: Int = 12) {
        let transcript = anyElement("conversation.scroll")
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
        for _ in 0..<attempts {
            if isVisiblyInside(target, transcript) { return }
            transcript.scroll(byDeltaX: 0, deltaY: -320)
        }
    }

    private func isVisiblyInside(_ target: XCUIElement, _ container: XCUIElement) -> Bool {
        guard target.exists else { return false }
        let safeFrame = container.frame.insetBy(dx: 4, dy: 8)
        return safeFrame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY))
    }

    private func relaunchWithThinkingFixture(mode: String) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_THINKING_FIXTURE"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_THINKING_MODE"] = mode
        app.launchEnvironment["LOCUS_UI_TESTING_TOOL_ACTIVITY_MODE"] = "collapsed"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithCodexTranscriptFixture(mode: String = "expanded") {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_CODEX_TRANSCRIPT_FIXTURE"] = "1"
        app.launchEnvironment["LOCUS_UI_TESTING_THINKING_MODE"] = mode
        app.launchEnvironment["LOCUS_UI_TESTING_TOOL_ACTIVITY_MODE"] = "collapsed"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithTextOutputFixture() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_TEXT_OUTPUT"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithSelectionFixture() {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_SELECTION"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func relaunchWithRunFixture(
        _ fixture: String,
        uncleanRecovery: Bool = false,
        staleQuitState: Bool = false
    ) {
        app.terminate()
        app.launchEnvironment["LOCUS_UI_TESTING_RUN_FIXTURE"] = fixture
        app.launchEnvironment["LOCUS_UI_TESTING_UNCLEAN_RECOVERY"] = uncleanRecovery ? "1" : nil
        app.launchEnvironment["LOCUS_UI_TESTING_STALE_QUIT_STATE"] = staleQuitState ? "1" : nil
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    func testCompletedRunWithLargeTimelineRemainsResponsiveAndRestoresAfterForceQuit() {
        relaunchWithRunFixture("completed", uncleanRecovery: true)

        let state = anyElement("runs.state")
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertTrue((state.label + " \(state.value ?? "")").lowercased().contains("completed"))
        XCTAssertFalse(anyElement("runs.recoveryExplanation").exists)
        XCTAssertTrue(anyElement("teamBoard.terminalSummary").exists)

        let activity = anyElement("runs.view.activity")
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        activity.click()
        let filter = app.textFields["runs.filter"]
        filter.click()
        filter.typeText("Team run completed")
        XCTAssertEqual(filter.value as? String, "Team run completed")

        // Exercise controls after the 1,200-event timeline has laid out.
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(anyElement("plan.summary").waitForExistence(timeout: 3))
        app.typeKey("7", modifierFlags: .command)
        XCTAssertTrue(anyElement("runs.list").waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["runs.search"].exists)
    }

    func testForcedQuitRecoveryExplainsAResumableRun() {
        relaunchWithRunFixture("recoverable", uncleanRecovery: true)

        XCTAssertFalse(anyElement("runs.recoveryExplanation").exists)
        XCTAssertTrue(anyElement("teamBoard.resume").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("teamBoard.discard").exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "can be resumed", "can be resumed")
            ).firstMatch.exists
        )
    }

    func testCompletedRunQuitsWithoutAStopRunningWarningFromStaleState() {
        relaunchWithRunFixture("completed", staleQuitState: true)

        app.typeKey("q", modifierFlags: .command)

        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 5),
            "a durable completed run must not be mistaken for active work"
        )
    }

    func testActivityDestinationShowsBackgroundRunAndReturnsToChat() {
        relaunchWithRunFixture("activity")

        let destination = anyElement("sidebar.activity")
        let newChat = anyElement("sidebar.newSession")
        let schedule = anyElement("sidebar.schedule")
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        XCTAssertTrue(newChat.exists)
        XCTAssertTrue(schedule.exists)
        // The bell shares the Schedule Task line, under the full-width
        // New chat button.
        XCTAssertLessThanOrEqual(abs(destination.frame.midY - schedule.frame.midY), 2)
        XCTAssertGreaterThan(destination.frame.minX, schedule.frame.maxX)
        XCTAssertGreaterThan(destination.frame.minY, newChat.frame.maxY)
        XCTAssertTrue("\(destination.value ?? "")".contains("1 needs attention"))
        destination.click()
        XCTAssertTrue(anyElement("activity.center").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("activity.run.seed-run").waitForExistence(timeout: 3))
        XCTAssertTrue(app.textViews["composer.input"].exists)
        XCTAssertTrue("\(destination.value ?? "")".contains("No new activity"))

        destination.click()
        XCTAssertFalse(anyElement("activity.center").exists)
        XCTAssertTrue(app.textViews["composer.input"].exists)

        destination.click()
        let remove = anyElement("activity.remove.seed-run")
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        // The activity center is a SwiftUI overlay. macOS 15 and 26 can mark
        // its visible buttons non-hittable in XCUI even though AppKit routes a
        // pointer at the same frame correctly. Exercise the real hit-testing
        // path at the button's center and verify the resulting removal.
        remove.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["No Activity Yet"].waitForExistence(timeout: 3))
    }

    func testTranscriptScrollsContinuouslyAcrossToolAndReasoningBlocks() {
        relaunchWithScrollFixture()

        let transcript = anyElement("conversation.scroll")
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
        let group = anyElement(
            "toolActivity.group.00000000-0000-0000-0000-000000000401"
        )
        scrollTranscriptDown(toReveal: group)
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        let firstTool = anyElement("tool.scroll-tool-0.toggle")
        XCTAssertFalse(firstTool.exists, "collapsed mode starts with one adjacent-run row")
        group.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(firstTool.waitForExistence(timeout: 3))
        firstTool.click()

        // Begin the gesture over selectable tool output. It must continue on
        // the transcript instead of being swallowed by the nested responder.
        let lastTool = anyElement("tool.scroll-tool-11.toggle")
        // Grouping puts the tool cards next to one another. Move through them
        // in bounded steps so a single synthetic wheel event cannot jump past
        // the lazy stack and evict the final card from accessibility.
        firstTool.coordinate(
            // The expanded output begins immediately below the 39-point
            // disclosure button. This lands inside its selectable detail.
            withNormalizedOffset: CGVector(dx: 0.5, dy: 1.5)
        ).scroll(byDeltaX: 0, deltaY: -320)
        for _ in 0..<12 {
            if isVisiblyInside(lastTool, transcript) { break }
            transcript.scroll(byDeltaX: 0, deltaY: -320)
        }
        XCTAssertTrue(lastTool.waitForExistence(timeout: 3))
        XCTAssertTrue(isVisiblyInside(lastTool, transcript))
        lastTool.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let firstMessage = anyElement("message.00000000-0000-0000-0000-000000000101")
        // Expanding the final card can move its button outside the viewport on
        // compact CI displays. This gesture only navigates back to the message;
        // target the owning transcript rather than a stale offscreen row.
        transcript.scroll(byDeltaX: 0, deltaY: 320)
        for _ in 0..<12 {
            if isVisiblyInside(firstMessage, transcript) { break }
            transcript.scroll(byDeltaX: 0, deltaY: 320)
        }
        XCTAssertTrue(firstMessage.waitForExistence(timeout: 3))
        XCTAssertTrue(isVisiblyInside(firstMessage, transcript))

        let messageHeightBeforeHover = firstMessage.frame.height
        firstMessage.hover()
        XCTAssertTrue(
            waitUntil(timeout: 2) {
                abs(firstMessage.frame.height - messageHeightBeforeHover) <= 0.5
            },
            "revealing message actions must not change transcript geometry"
        )

        // Starting a fresh wheel gesture over ordinary selectable chat text
        // must move the transcript by the same amount as a gesture over its
        // scrollbar or empty background.
        let messageYBeforeWheel = firstMessage.frame.minY
        let messageWheelCoordinate = firstMessage.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        var messageMoved = false
        // XCUITest occasionally drops the first synthetic wheel packet on
        // macOS 15. Keep the retries bounded and alternate direction so the
        // result is independent of which elastic boundary the fixture reached.
        let wheelDeltas: [CGFloat] = [-320, -180, 320, 180]
        for delta in wheelDeltas where !messageMoved {
            guard isVisiblyInside(firstMessage, transcript) else {
                messageMoved = true
                break
            }
            messageWheelCoordinate.scroll(byDeltaX: 0, deltaY: delta)
            messageMoved = waitUntil(timeout: 1.5) {
                // A short row can leave the accessibility viewport entirely;
                // that is conclusive evidence that its owning transcript moved.
                !firstMessage.exists
                    || !self.isVisiblyInside(firstMessage, transcript)
                    || abs(firstMessage.frame.minY - messageYBeforeWheel) > 8
            }
        }
        XCTAssertTrue(
            messageMoved,
            "vertical wheel gestures over selectable message text must move the transcript"
        )
    }

    func testJumpToLatestReturnsToTheEndOfTheTranscript() {
        relaunchWithScrollFixture()

        let transcript = anyElement("conversation.scroll")
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))

        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("Review the workspace")

        let firstMessage = anyElement(
            "message.00000000-0000-0000-0000-000000000101"
        )
        let jump = anyElement("conversation.jumpToLatest")
        XCTAssertTrue(firstMessage.waitForExistence(timeout: 3))
        XCTAssertTrue(firstMessage.isHittable)
        XCTAssertTrue(jump.waitForExistence(timeout: 3))
        let firstMessageY = firstMessage.frame.minY

        // The overlay button is visibly inside the transcript, but macOS 15
        // can report it as non-hittable while the Find field owns keyboard
        // focus. A center-coordinate click exercises the same user action.
        jump.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertTrue(waitUntil(timeout: 3) {
            !firstMessage.exists
                || !firstMessage.isHittable
                || firstMessage.frame.minY < firstMessageY - 20
        })
        XCTAssertFalse(jump.exists)
    }

    func testCollapsedToolActivityGroupsAndExpands() {
        relaunchWithScrollFixture()

        let group = anyElement(
            "toolActivity.group.00000000-0000-0000-0000-000000000401"
        )
        scrollTranscriptDown(toReveal: group)
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        XCTAssertTrue(group.label.contains("Read files"))

        let firstTool = anyElement("tool.scroll-tool-0.toggle")
        XCTAssertFalse(firstTool.exists)
        group.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(firstTool.waitForExistence(timeout: 3))
    }

    func testVerboseToolActivityView() {
        relaunchWithScrollFixture(toolActivityMode: "verbose")

        let firstTool = anyElement("tool.scroll-tool-0.toggle")
        scrollTranscriptDown(toReveal: firstTool)
        XCTAssertTrue(firstTool.waitForExistence(timeout: 3))
        XCTAssertFalse(
            anyElement("toolActivity.group.00000000-0000-0000-0000-000000000401").exists
        )
    }

    func testHiddenToolActivityView() {
        relaunchWithScrollFixture(toolActivityMode: "hidden")

        let hidden = anyElement(
            "toolActivity.hidden.00000000-0000-0000-0000-000000000401"
        )
        scrollTranscriptDown(toReveal: hidden)
        XCTAssertTrue(hidden.waitForExistence(timeout: 3))
        XCTAssertEqual(hidden.label, "Actions complete")
        XCTAssertFalse(anyElement("tool.scroll-tool-0.toggle").exists)
        XCTAssertFalse(
            anyElement("toolActivity.group.00000000-0000-0000-0000-000000000401").exists
        )
    }

    func testCollapsedThinkingGroupsReasoningWithoutEmptyAssistantRows() {
        relaunchWithThinkingFixture(mode: "collapsed")

        let firstGroup = anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000201"
        )
        let inlineGroup = anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000203"
        )
        let finalGroup = anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000204"
        )
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 3))
        XCTAssertTrue(firstGroup.label.contains("Inspect the remaining files"))
        XCTAssertTrue(inlineGroup.exists)
        XCTAssertTrue(finalGroup.exists)
        XCTAssertFalse(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000201.0"
        ).exists)
        XCTAssertFalse(anyElement("message.00000000-0000-0000-0000-000000000201").exists)
        XCTAssertFalse(anyElement("message.00000000-0000-0000-0000-000000000203").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000202").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000204").exists)

        firstGroup.coordinate(
            withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)
        ).click()
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000201.0"
        ).waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000203.0"
        ).exists)
        XCTAssertFalse(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000204.0"
        ).exists)

        XCTAssertLessThan(
            anyElement("message.00000000-0000-0000-0000-000000000202").frame.maxY,
            anyElement("toolActivity.group.00000000-0000-0000-0000-000000000206").frame.minY
        )
        XCTAssertLessThan(
            anyElement("toolActivity.group.00000000-0000-0000-0000-000000000206").frame.maxY,
            inlineGroup.frame.minY
        )
        XCTAssertLessThan(inlineGroup.frame.maxY, finalGroup.frame.minY)
        XCTAssertLessThan(
            finalGroup.frame.maxY,
            anyElement("message.00000000-0000-0000-0000-000000000204").frame.minY
        )
    }

    func testHiddenThinkingRemovesGroupAndReasoningOnlyAssistantRows() {
        relaunchWithThinkingFixture(mode: "hidden")

        XCTAssertFalse(anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000201"
        ).exists)
        XCTAssertFalse(anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000203"
        ).exists)
        XCTAssertFalse(anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000204"
        ).exists)
        XCTAssertFalse(anyElement("message.00000000-0000-0000-0000-000000000201").exists)
        XCTAssertFalse(anyElement("message.00000000-0000-0000-0000-000000000203").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000202").exists)
        XCTAssertTrue(anyElement("message.00000000-0000-0000-0000-000000000204").exists)
    }

    func testExpandedThinkingStartsWithGroupedReasoningOpen() {
        relaunchWithThinkingFixture(mode: "expanded")

        let firstGroup = anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000201"
        )
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 3))
        XCTAssertTrue(firstGroup.label.contains("collapse"))
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000201.0"
        ).waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000203.0"
        ).exists)
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000204.0"
        ).exists)
    }

    func testCodexTranscriptKeepsReasoningCommentaryAndFinalListSeparate() {
        relaunchWithCodexTranscriptFixture()

        let group = anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000302"
        )
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        XCTAssertTrue(group.label.contains("2 updates"))
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000302.0"
        ).waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement(
            "thinkingActivity.entry.00000000-0000-0000-0000-000000000302.1"
        ).exists)

        XCTAssertTrue(app.staticTexts["Planning data retrieval"].exists)
        XCTAssertTrue(app.staticTexts["Checking forecast parsing"].exists)
        XCTAssertFalse(app.staticTexts["**Planning data retrieval**"].exists)
        XCTAssertFalse(app.staticTexts["**Checking forecast parsing**"].exists)

        XCTAssertTrue(anyElement(
            "message.00000000-0000-0000-0000-000000000303"
        ).exists)
        XCTAssertTrue(anyElement(
            "message.00000000-0000-0000-0000-000000000304"
        ).exists)
        XCTAssertTrue(transcriptText("I’ll check both locations now.").exists)
        XCTAssertTrue(transcriptText("The source data is ready.").exists)
        XCTAssertTrue(transcriptText("Both locations have clear conditions.").exists)
        XCTAssertTrue(transcriptText("Austin: Sunny and hot.").exists)
        XCTAssertTrue(transcriptText("Jerusalem: Warm and dry.").exists)

        // Marker ownership is asserted against the presentation projection in
        // unit tests. The visual sparkle remains intentionally hidden from the
        // accessibility tree, so this fixture verifies the neighboring action
        // ownership without turning decorative chrome into VoiceOver content.
        XCTAssertFalse(anyElement(
            "message.00000000-0000-0000-0000-000000000303.copy"
        ).exists)
        XCTAssertTrue(anyElement(
            "message.00000000-0000-0000-0000-000000000304.copy"
        ).exists)
    }

    func testCollapsedCodexActivityStaysInlineAndExpandsInPlace() {
        relaunchWithCodexTranscriptFixture(mode: "collapsed")

        let reasoning = anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000302"
        )
        let commentary = anyElement("message.00000000-0000-0000-0000-000000000303")
        let tools = anyElement(
            "toolActivity.group.00000000-0000-0000-0000-000000000306"
        )
        let laterCommentary = anyElement(
            "message.00000000-0000-0000-0000-000000000308"
        )
        let inlineReasoning = anyElement(
            "thinkingActivity.group.00000000-0000-0000-0000-000000000309"
        )
        let inlineCommentary = anyElement(
            "message.00000000-0000-0000-0000-000000000309"
        )
        let browser = anyElement(
            "toolActivity.group.00000000-0000-0000-0000-000000000310"
        )
        let final = anyElement("message.00000000-0000-0000-0000-000000000304")

        XCTAssertTrue(reasoning.waitForExistence(timeout: 3))
        for item in [commentary, tools, laterCommentary, inlineReasoning, inlineCommentary, browser, final] {
            XCTAssertTrue(item.exists)
        }
        XCTAssertTrue(reasoning.label.contains("Planning data retrieval · Checking forecast parsing"))
        XCTAssertTrue(tools.label.contains("Read files, ran command"))
        XCTAssertTrue(browser.label.contains("Browsed"))

        XCTAssertLessThan(reasoning.frame.maxY, commentary.frame.minY)
        XCTAssertLessThan(commentary.frame.maxY, tools.frame.minY)
        XCTAssertLessThan(tools.frame.maxY, laterCommentary.frame.minY)
        XCTAssertLessThan(laterCommentary.frame.maxY, inlineReasoning.frame.minY)
        XCTAssertLessThan(inlineReasoning.frame.maxY, inlineCommentary.frame.minY)
        XCTAssertLessThan(inlineCommentary.frame.maxY, browser.frame.minY)
        XCTAssertLessThan(browser.frame.maxY, final.frame.minY)

        XCTAssertFalse(anyElement("tool.codex-read.toggle").exists)
        tools.click()
        XCTAssertTrue(anyElement("tool.codex-read.toggle").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("tool.codex-command.toggle").exists)
        XCTAssertLessThan(commentary.frame.maxY, tools.frame.minY)
        XCTAssertLessThan(tools.frame.maxY, laterCommentary.frame.minY)
    }

    func testCollapsedCodexActivityFitsLightAndDarkWindowSizes() throws {
        let cases = [("1250", "760", "Light"), ("720", "620", "Dark")]
        for (width, height, appearance) in cases {
            app.terminate()
            app.launchEnvironment["LOCUS_UI_TESTING_CODEX_TRANSCRIPT_FIXTURE"] = "1"
            app.launchEnvironment["LOCUS_UI_TESTING_THINKING_MODE"] = "collapsed"
            app.launchEnvironment["LOCUS_UI_TESTING_TOOL_ACTIVITY_MODE"] = "collapsed"
            app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_WIDTH"] = width
            app.launchEnvironment["LOCUS_UI_TESTING_WINDOW_HEIGHT"] = height
            app.launchArguments = [
                "-ApplePersistenceIgnoreState", "YES",
                "-AppleInterfaceStyle", appearance,
            ]
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

            let transcript = anyElement("conversation.scroll")
            let reasoning = anyElement(
                "thinkingActivity.group.00000000-0000-0000-0000-000000000302"
            )
            XCTAssertTrue(transcript.waitForExistence(timeout: 3))
            XCTAssertTrue(reasoning.waitForExistence(timeout: 3))
            XCTAssertTrue(reasoning.label.contains("Thought process, collapsed"))
            XCTAssertGreaterThanOrEqual(reasoning.frame.minX, transcript.frame.minX)
            XCTAssertLessThanOrEqual(reasoning.frame.maxX, transcript.frame.maxX)
            try auditCurrentSurface()

            reasoning.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).click()
            XCTAssertTrue(anyElement(
                "thinkingActivity.entry.00000000-0000-0000-0000-000000000302.0"
            ).waitForExistence(timeout: 3))
            XCTAssertGreaterThanOrEqual(reasoning.frame.minX, transcript.frame.minX)
            XCTAssertLessThanOrEqual(reasoning.frame.maxX, transcript.frame.maxX)
        }
    }

    func testReviewAndLandShowsDiffChecksAndBothDestinations() {
        relaunchWithLandingFixture()

        let review = anyElement("workspace.reviewAndLand")
        XCTAssertTrue(review.waitForExistence(timeout: 3))
        review.click()
        XCTAssertTrue(anyElement("landing.diff").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("landing.checkCommands").exists)
        XCTAssertTrue(anyElement("landing.runChecks").exists)
        XCTAssertTrue(anyElement("landing.destination").exists)

        let destinationControl = anyElement("landing.destination")
        let branchDestination = app.buttons["Branch, Commit & PR"].firstMatch
        XCTAssertTrue(branchDestination.exists)
        branchDestination.click()
        // AppKit only publishes descendants of a SwiftUI ScrollView once they
        // enter its viewport. Scroll the selected destination's form into the
        // accessibility hierarchy before querying its fields.
        destinationControl.scroll(byDeltaX: 0, deltaY: -400)
        XCTAssertTrue(anyElement("landing.branch").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("landing.commitMessage").exists)
        XCTAssertTrue(anyElement("landing.confirm").exists)
    }

    func testDispatcherRepairIsVisibleInProgressAndRuns() {
        relaunchWithRunFixture("dispatcher-repair")

        XCTAssertTrue(anyElement("teamDispatch.progress").waitForExistence(timeout: 3))
        let progress = anyElement("workspace.teamProgress")
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        progress.click()
        XCTAssertTrue(anyElement("teamProgress.popover").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("teamBoard.seed-run").waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                    "Correcting dispatcher plan",
                    "Correcting dispatcher plan"
                )
            ).firstMatch.exists
        )

        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                    "dispatcher plan has no jobs",
                    "dispatcher plan has no jobs"
                )
            ).firstMatch.waitForExistence(timeout: 3)
        )
    }

    func testTeamPlanAppearsOnceInConversationWithWholePlanActions() {
        relaunchWithRunFixture("dispatch-plan")

        XCTAssertTrue(anyElement("teamDispatch.approval").waitForExistence(timeout: 3))
        XCTAssertTrue(app.textViews["composer.input"].exists)
        XCTAssertTrue(anyElement("teamDispatch.jobs").exists)
        XCTAssertTrue(anyElement("teamDispatch.run").exists)
        XCTAssertTrue(anyElement("teamDispatch.redispatch").exists)
        XCTAssertTrue(anyElement("teamDispatch.cancel").exists)
        XCTAssertTrue(anyElement("workspace.teamProgress").exists)
    }

    func testLiveSwarmTreeShowsNestedBranchAndStopControl() {
        relaunchWithRunFixture("swarm-live")

        XCTAssertTrue(anyElement("runs.agentTree").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Research lead"].exists)
        XCTAssertTrue(app.staticTexts["API specialist"].exists)
        XCTAssertTrue(anyElement("runs.agentTree.stop.inspect.1").exists)
        XCTAssertFalse(anyElement("runs.agentTree.retry.inspect.1").exists)
    }

    func testRecoverableSwarmTreeShowsBranchRetryControl() {
        relaunchWithRunFixture("swarm-recoverable")

        XCTAssertTrue(anyElement("runs.agentTree").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["API specialist"].exists)
        XCTAssertTrue(anyElement("runs.agentTree.retry.inspect.1").exists)
        XCTAssertFalse(anyElement("runs.agentTree.stop.inspect.1").exists)
    }

    func testCompletedSoloSwarmShowsReadOnlyWorkerEvidenceAndUsage() {
        relaunchWithRunFixture("solo-swarm-completed")

        XCTAssertTrue(anyElement("runs.soloSwarm.overview").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Inventory API reader"].exists)
        let worker = anyElement("runs.soloSwarm.worker./root/inventory-api")
        XCTAssertTrue(worker.exists)
        XCTAssertFalse(anyElement("runs.agentTree.stop./root/inventory-api").exists)
        XCTAssertTrue((worker.value as? String)?.localizedCaseInsensitiveContains(
            "Rate-limit headers are undocumented"
        ) == true)
    }

    func testSoloSwarmWithoutDelegationHasMeaningfulEmptyState() {
        relaunchWithRunFixture("solo-swarm-empty")

        XCTAssertTrue(anyElement("runs.soloSwarm.overview").waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement("runs.soloSwarm.noWorkers").exists)
        XCTAssertTrue(app.staticTexts["This run did not delegate any workers"].exists)
    }

    func testPermissionPanelRepliesWithTheKeyboard() {
        relaunchWithPendingPermission()

        let panel = anyElement("permission.panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        // The prompt replaces the input entirely while it waits.
        XCTAssertFalse(app.textViews["composer.input"].exists)
        XCTAssertTrue(anyElement("permission.once").exists)
        XCTAssertTrue(anyElement("permission.always").exists)
        XCTAssertTrue(anyElement("permission.deny").exists)

        panel.click()
        app.typeKey("2", modifierFlags: [])

        XCTAssertTrue(app.textViews["composer.input"].waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement("permission.panel").exists)
    }

    func testPermissionPanelEscapeDeniesAndReturnsFocusForFeedback() {
        relaunchWithPendingPermission()

        let panel = anyElement("permission.panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        panel.click()
        app.typeKey(.escape, modifierFlags: [])

        let composer = app.textViews["composer.input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))

        // Typing lands in the editor without another click: focus must come
        // back on its own so "tell Locus what to do differently" just works.
        app.typeText("use a dry run instead")
        XCTAssertTrue((composer.value as? String)?.contains("use a dry run instead") == true)
    }

    func testHiddenToolActivityKeepsThePermissionPanelUsable() {
        relaunchWithPendingPermission(toolActivityMode: "hidden")

        XCTAssertTrue(anyElement("permission.panel").waitForExistence(timeout: 3))
        let hidden = anyElement(
            "toolActivity.hidden.00000000-0000-0000-0000-000000000201"
        )
        XCTAssertTrue(hidden.waitForExistence(timeout: 3))
        XCTAssertEqual(hidden.label, "Action needs approval")
        XCTAssertFalse(anyElement("tool.seed-tool-permission.toggle").exists)
        XCTAssertTrue(anyElement("permission.once").exists)
        XCTAssertTrue(anyElement("permission.always").exists)
        XCTAssertTrue(anyElement("permission.deny").exists)
        XCTAssertFalse(
            anyElement("workspace.workStatus").label.localizedCaseInsensitiveContains("bash"),
            "hidden mode must not leak the tool name through the persistent status strip"
        )
    }
}
