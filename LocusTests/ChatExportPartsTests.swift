import AppKit
import XCTest
@testable import Locus

/// Exported transcripts carry image and interactive answer parts additively:
/// the sidecar folder receives the bytes and the Markdown fallback the backend
/// wrote is rewritten in place, never duplicated.
@MainActor
final class ChatExportPartsTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    /// The production wrapper, put back after each test: the property is
    /// process-wide, and another suite may rely on the CSP shell it adds.
    private var originalWrapInteractiveHTML: ((String) -> String)!

    override func setUpWithError() throws {
        originalWrapInteractiveHTML = ResponseExportProjection.wrapInteractiveHTML
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatExportPartsTests-\(UUID())")
        workspace = root.appendingPathComponent("My Workspace (test)")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Locus Images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("exports"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ResponseExportProjection.wrapInteractiveHTML = originalWrapInteractiveHTML
        try? FileManager.default.removeItem(at: root)
    }

    private var workspacePath: String { OutputsLibraryStore.canonical(workspace.path) }

    private func writePNG(_ relativePath: String, width: Int = 64, height: Int = 48) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.7, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: workspace.appendingPathComponent(relativePath))
        return png
    }

    private func imagePart(id: String = "picture", path: String = "Locus Images/harbour.png", title: String? = "Harbour at dusk",
                           alt: String? = "Harbour [dusk]\\night", workspace: String? = nil) -> ResponsePart {
        ResponsePart(type: "image", id: id, title: title, workspace: workspace ?? workspacePath, path: path,
                     alt: alt, prompt: "A quiet harbour at dusk", width: 64, height: 48, format: "png", byteSize: 1_024)
    }

    private func interactivePart() -> ResponsePart {
        ResponsePart(type: "interactive", id: "widget", title: "Binary search: Ünïcode & friends",
                     height: 420, summary: "Step through a search over seven numbers.",
                     html: "<div id=\"widget\"><button>Step</button></div>")
    }

    private func message(_ content: String, parts: [ResponsePart]) -> ChatExportMessage {
        ChatExportMessage(role: "assistant", content: content, name: nil, reasoning: nil, reasoningSections: nil,
                          phase: .finalAnswer, itemID: "item", attachments: nil,
                          responseParts: ResponseDocument(version: 1, parts: parts), reasoningFormat: .native, runID: "run")
    }

    private func document(_ messages: [ChatExportMessage]) -> ChatExportDocument {
        ChatExportDocument(id: "session", title: "Harbour session", cwd: workspacePath, model: "m", provider: "p",
                           started: "now", messages: messages)
    }

    private func fallback(for part: ResponsePart) -> String {
        ResponseExportProjection.fallbackImageLink(for: part) + "\n\n" + (part.title ?? "")
    }

    // Paired with the Python side: urllib.parse.quote(path, safe='/') for this
    // exact path must produce this exact string.
    func testPythonQuotedMatchesUrllibQuoteForSpacesParenthesesUnicodeAndHash() {
        let path = "/Users/nahid/My Workspace (test)/Locus Images/café #1 [v2]\\draft.png"
        XCTAssertEqual(ResponseExportProjection.pythonQuoted(path),
                       "/Users/nahid/My%20Workspace%20%28test%29/Locus%20Images/caf%C3%A9%20%231%20%5Bv2%5D%5Cdraft.png")
        XCTAssertEqual(ResponseExportProjection.pythonQuoted("/plain/ok_path-1.2~x"), "/plain/ok_path-1.2~x")
        XCTAssertEqual(ResponseExportProjection.pythonQuoted("a b\nc?d=e&f%"), "a%20b%0Ac%3Fd%3De%26f%25")
        let part = imagePart(workspace: "/tmp/ws/")
        XCTAssertEqual(ResponseExportProjection.fallbackImageLink(for: part),
                       "![Harbour \\[dusk\\]\\\\night](/tmp/ws/Locus%20Images/harbour.png)",
                       "The link must match '!' + _link(alt, quote(str(Path(workspace) / path), safe='/')) byte for byte")
        XCTAssertEqual(ResponseExportProjection.imageLabel(for: imagePart(alt: nil)), "Harbour at dusk")
        XCTAssertEqual(ResponseExportProjection.imageLabel(for: imagePart(title: nil, alt: "")), "harbour.png")
    }

    func testMarkdownExportCopiesImagesRewritesTheFallbackLinkAndWritesWrappedInteractiveDocuments() throws {
        let png = try writePNG("Locus Images/harbour.png")
        let picture = imagePart()
        let widget = interactivePart()
        ResponseExportProjection.wrapInteractiveHTML = { "<!doctype html><html><body>" + $0 + "</body></html>" }
        let prose = "Here is the harbour.\n\n" + fallback(for: picture) + "\n\n### Binary search\n\nStep through a search over seven numbers.\n\nInteractive version available in Locus for Mac."
        let destination = root.appendingPathComponent("exports/Harbour session.md")
        try ChatExportRenderer.write(document([message(prose, parts: [picture, widget])]), format: .markdown, to: destination)

        let markdown = try String(contentsOf: destination, encoding: .utf8)
        let assets = root.appendingPathComponent("exports/Harbour session-assets")
        XCTAssertTrue(FileManager.default.fileExists(atPath: assets.path))
        XCTAssertEqual(try Data(contentsOf: assets.appendingPathComponent("001-harbour.png")), png)
        XCTAssertTrue(markdown.contains("Here is the harbour.\n\n![Harbour \\[dusk\\]\\\\night](Harbour session-assets/001-harbour.png)\n\nHarbour at dusk"), markdown)
        XCTAssertFalse(markdown.contains(ResponseExportProjection.pythonQuoted(workspacePath)), "The absolute workspace link must be replaced, not duplicated")
        XCTAssertEqual(markdown.components(separatedBy: "001-harbour.png").count, 2)
        let html = try String(contentsOf: assets.appendingPathComponent("002-binary-search-unicode-friends.html"), encoding: .utf8)
        XCTAssertEqual(html, "<!doctype html><html><body><div id=\"widget\"><button>Step</button></div></body></html>")
        XCTAssertTrue(markdown.hasSuffix("[Interactive: Binary search: Ünïcode & friends](Harbour session-assets/002-binary-search-unicode-friends.html)\n"), markdown)
    }

    func testMarkdownExportAppendsUnmentionedImagesAndMarksMissingOrEscapingFilesWithoutCopyingThem() throws {
        _ = try writePNG("Locus Images/harbour.png")
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.png"))
        let mentioned = imagePart()
        let missing = imagePart(id: "missing", path: "Locus Images/gone.png", title: "Gone", alt: "Gone")
        let escaping = imagePart(id: "escape", path: "../outside.png", title: "Outside", alt: "Outside")
        let other = imagePart(id: "other", path: "Locus Images/harbour.png", title: "Elsewhere", alt: "Elsewhere",
                              workspace: root.appendingPathComponent("elsewhere").path)
        let prose = "No link in the prose.\n\n" + fallback(for: missing)
        let destination = root.appendingPathComponent("exports/session.md")
        try ChatExportRenderer.write(document([message(prose, parts: [mentioned, missing, escaping, other])]), format: .markdown, to: destination)
        let markdown = try String(contentsOf: destination, encoding: .utf8)
        let assets = root.appendingPathComponent("exports/session-assets")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: assets.path), ["001-harbour.png"])
        XCTAssertTrue(markdown.contains("No link in the prose.\n\n[Image unavailable: Locus Images/gone.png]\n\nGone"), markdown)
        XCTAssertTrue(markdown.contains("\n\n![Harbour \\[dusk\\]\\\\night](session-assets/001-harbour.png)\n"), markdown)
        XCTAssertTrue(markdown.contains("\n\n[Image unavailable: ../outside.png]\n"), markdown)
        XCTAssertTrue(markdown.contains("\n\n[Image unavailable: Locus Images/harbour.png]\n"), "A part from another workspace must not read this one's files")
        XCTAssertFalse(markdown.contains("outside.png)"))
    }

    func testMarkdownWithoutPartsOrAttachmentsCreatesNoAssetFolder() throws {
        let destination = root.appendingPathComponent("exports/plain.md")
        try ChatExportRenderer.write(document([message("Just prose.", parts: [])]), format: .markdown, to: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exports/plain-assets").path))
        let unsupported = ChatExportMessage(role: "assistant", content: "Prose", name: nil, reasoning: nil, reasoningSections: nil,
            phase: nil, itemID: nil, attachments: nil,
            responseParts: ResponseDocument(version: 1, parts: [ResponsePart(type: "image", id: "no-workspace", path: "x.png")]))
        XCTAssertTrue(ResponseExportProjection.imageParts(unsupported).isEmpty, "Unsupported documents export as their fallback only")
    }

    func testPlainTextAndPDFDescribeImagesAndKeepInteractiveSummaries() throws {
        _ = try writePNG("Locus Images/harbour.png")
        let picture = imagePart()
        let silent = imagePart(id: "silent", path: "Locus Images/gone.png", title: "Silent", alt: "Silent")
        let widget = interactivePart()
        let prose = "Here is the harbour.\n\n" + fallback(for: picture) + "\n\n### Binary search: Ünïcode & friends\n\nStep through a search over seven numbers."
        let text = root.appendingPathComponent("exports/session.txt")
        try ChatExportRenderer.write(document([message(prose, parts: [picture, widget, silent])]), format: .plainText, to: text)
        let plain = try String(contentsOf: text, encoding: .utf8)
        XCTAssertTrue(plain.contains("Here is the harbour.\n\n[Image: Harbour at dusk — Locus Images/harbour.png]\n\nHarbour at dusk"), plain)
        XCTAssertTrue(plain.contains("Step through a search over seven numbers."))
        XCTAssertTrue(plain.contains("\n\n[Image: Silent — Locus Images/gone.png]\n"), plain)
        XCTAssertFalse(plain.contains("%20"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exports/session-assets").path))

        let pdf = root.appendingPathComponent("exports/session.pdf")
        try ChatExportRenderer.write(document([message(prose, parts: [picture, widget, silent])]), format: .pdf, to: pdf)
        let bytes = try Data(contentsOf: pdf)
        XCTAssertTrue(bytes.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(bytes.count, 1_000)
    }
}
