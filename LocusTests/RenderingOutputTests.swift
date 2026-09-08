import AppKit
import SwiftUI
import XCTest
@testable import Locus

@MainActor
final class RenderingOutputTests: XCTestCase {
    func testLegacyReasoningPreservesLiteralCodeEscapesAndProse() {
        let examples = [
            "```xml\n<think>literal</think>\n```\n",
            "````markdown\n```xml\n<think>literal</think>\n```\n````\n",
            "~~~xml\n<thinking>literal</thinking>\n~~~",
            "`<think>literal</think>`",
            "``code ` <think>literal</think>``",
            "    <think>indented code</think>\n",
            "\\<think>escaped</think>",
            "The <think> tag is literal text.",
            "> ```xml\n> <think>quoted code</think>\n> ```",
            "```xml\r\n<think>CRLF literal</think>\r\n```\r\n",
        ]
        for source in examples {
            XCTAssertEqual(AssistantSegment.parse(source), [.visible(source)], source)
            XCTAssertEqual(ResponseCopyPayload.text(from: source, format: .markdown), source)
        }
    }

    func testReasoningFormatDistinguishesNativeTextFromLegacyEnvelopes() {
        let source = "<think>literal document</think>\nAnswer"
        XCTAssertEqual(AssistantSegment.parse(source, reasoningFormat: .native), [.visible(source)])
        XCTAssertEqual(AssistantSegment.parse(source, reasoningFormat: .none), [.visible(source)])
        XCTAssertEqual(AssistantSegment.copyableText(from: source), "Answer")
        XCTAssertEqual(AssistantSegment.copyableText(from: "<think></think>\nAnswer"), "Answer")
        XCTAssertEqual(AssistantSegment.parse("<think>unfinished"), [.thinking(text: "unfinished", isComplete: false)])
        XCTAssertEqual(AssistantSegment.copyableText(from: "    keep indentation\n"), "    keep indentation\n")
        XCTAssertEqual(AssistantSegment.copyableText(from: "left\n<think>hidden</think>\nright"), "left\n\nright")
    }

    func testFenceBoundariesRespectLengthCharacterAndClosingSuffix() throws {
        for source in [
            "````markdown\n```swift\n\nstill inside outer fence",
            "~~~text\n```\n\nstill inside tilde fence",
            "```text\n```not a closing fence\n\nstill inside",
            "```xml\r\n<think>literal</think>\r\n\r\nstill inside",
        ] {
            XCTAssertNil(StreamingMarkdownBoundary.lastStableBoundary(in: source), source)
        }
        let source = "````markdown\n```swift\n\n```\n````\n\nTail"
        let boundary = try XCTUnwrap(StreamingMarkdownBoundary.lastStableBoundary(in: source))
        XCTAssertEqual(String(source[boundary...]), "Tail")
        let crlf = "Done\r\n\r\nTail"
        let crlfBoundary = try XCTUnwrap(StreamingMarkdownBoundary.lastStableBoundary(in: crlf))
        XCTAssertEqual(String(crlf[crlfBoundary...]), "Tail")
        XCTAssertNil(StreamingMarkdownBoundary.lastStableBoundary(in: "Paragraph\n"))
    }

    func testFenceClosingIndentationIsRelativeToItsOriginalContainer() throws {
        let top = try XCTUnwrap(MarkdownSourceScanner.Fence.opening(in: "```swift"))
        XCTAssertTrue(top.closes(in: "   ```"))
        XCTAssertFalse(top.closes(in: "    ```"))
        XCTAssertFalse(top.closes(in: "\t```"))
        XCTAssertFalse(top.closes(in: "> ```"))
        XCTAssertFalse(top.closes(in: "- ```"))
        XCTAssertNil(MarkdownSourceScanner.Fence.opening(in: "    ```"))

        let list = try XCTUnwrap(MarkdownSourceScanner.Fence.opening(in: "- ```swift"))
        XCTAssertTrue(list.closes(in: "  ```"))
        XCTAssertTrue(list.closes(in: "     ```"))
        XCTAssertFalse(list.closes(in: "      ```"))
        XCTAssertFalse(list.closes(in: "```"))
        XCTAssertFalse(list.closes(in: "- ```"))
        var context = MarkdownSourceScanner.BlockContext()
        XCTAssertNil(context.opening(in: "- list introduction"))
        let continuation = try XCTUnwrap(context.opening(in: "  ```swift"))
        XCTAssertTrue(continuation.closes(in: "     ```"))
        XCTAssertFalse(continuation.closes(in: "      ```"))

        let quote = try XCTUnwrap(MarkdownSourceScanner.Fence.opening(in: "> ```swift"))
        XCTAssertTrue(quote.closes(in: "> ```"))
        XCTAssertTrue(quote.closes(in: ">    ```"))
        XCTAssertFalse(quote.closes(in: ">     ```"))
        XCTAssertFalse(quote.closes(in: "> > ```"))
        XCTAssertFalse(quote.closes(in: "```"))
        XCTAssertFalse(quote.containerContinues(in: "Outside quote"))

        XCTAssertNil(StreamingMarkdownBoundary.lastStableBoundary(in: "```\n    ```\n\nStill in code"))
        let source = "- introduction\n  ```\n  body\n     ```\n\nTail"
        let boundary = try XCTUnwrap(StreamingMarkdownBoundary.lastStableBoundary(in: source))
        XCTAssertEqual(String(source[boundary...]), "Tail")
    }

    func testStreamingIncomingDeltaRetainsTheExistingStablePrefix() async {
        let coordinator = StreamingRenderCoordinator()
        let source = "# Stable heading\n\nMutable"
        coordinator.update(text: source)
        await drain(coordinator)
        let stable = coordinator.stableBlocks
        XCTAssertEqual(stable.count, 1)
        XCTAssertTrue(coordinator.canPresentStablePrefix(for: source + " tail"))
        XCTAssertEqual(coordinator.provisionalText(for: source + " tail"), "Mutable tail")
        XCTAssertEqual(coordinator.stableBlocks, stable)
        XCTAssertFalse(coordinator.canPresentStablePrefix(for: "Replaced source"))
        coordinator.update(text: source + " tail", isFinal: true)
        XCTAssertEqual(coordinator.provisionalText(for: source + " tail"), "Mutable tail")
        await drain(coordinator)
        XCTAssertTrue(coordinator.provisionalText.isEmpty)
    }

    func testTableExportPreservesQuotesMultilineUnicodeAndEmptyCells() {
        let headers = [[MarkdownInlineRun(text: "Name")], [.init(text: "Value")]]
        let rows: [[[MarkdownInlineRun]]] = [
            [[.init(text: "Café, 東京")], [.init(text: "a\"b")]],
            [[.init(text: "two\nlines")], [.init(text: "tab\there")]],
            [[.init(text: "last")]],
        ]
        XCTAssertEqual(
            MarkdownTableExport.render(headers: headers, rows: rows, format: .csv),
            "Name,Value\r\n\"Café, 東京\",\"a\"\"b\"\r\n\"two\nlines\",tab\there\r\nlast,"
        )
        XCTAssertEqual(
            MarkdownTableExport.render(headers: headers, rows: rows, format: .tsv),
            "Name\tValue\nCafé, 東京\t\"a\"\"b\"\n\"two\nlines\"\t\"tab\there\"\nlast\t"
        )
        let manyRows = (1...30).map { [[MarkdownInlineRun(text: "\($0)")]] }
        XCTAssertTrue(MarkdownTableExport.render(headers: [[.init(text: "Count")]], rows: manyRows, format: .tsv).hasSuffix("\n30"))
    }

    func testNativeTableTextReceivesParagraphAlignment() throws {
        for alignment in [MarkdownColumnAlignment.left, .center, .right] {
            let value = MarkdownNativeText.attributed(
                [.init(text: "42")], size: 12, weight: .regular, color: .primary,
                lineSpacing: 2, inlineCodeSize: 12, workspacePath: nil, alignment: alignment
            )
            let paragraph = try XCTUnwrap(value.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(paragraph.alignment, alignment.nsTextAlignment)
        }
    }

    func testRegisteredCitationDecorationPreservesTextAndDestination() throws {
        let destination = "https://example.com/research#result"
        let run = MarkdownInlineRun(text: "Study results", destination: destination)
        let source = ResponseSource(id: "study", title: "Study", url: destination)
        let ordinary = MarkdownNativeText.attributed(
            [run], size: 13, weight: .regular, color: .primary, lineSpacing: 5,
            inlineCodeSize: 12, workspacePath: nil
        )
        let cited = MarkdownNativeText.attributed(
            [run], size: 13, weight: .regular, color: .primary, lineSpacing: 5,
            inlineCodeSize: 12, workspacePath: nil, registeredSources: [source]
        )
        XCTAssertEqual(cited.string, ordinary.string)
        XCTAssertEqual(cited.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: destination))
        XCTAssertNil(ordinary.attribute(.locusInlineCodePill, at: 0, effectiveRange: nil))
        XCTAssertNotNil(cited.attribute(.locusInlineCodePill, at: 0, effectiveRange: nil))
        XCTAssertTrue((cited.attribute(.toolTip, at: 0, effectiveRange: nil) as? String)?.contains(destination) == true)
        XCTAssertNil(ResponseCitationDecoration.source(
            for: .init(text: "Unrelated", destination: "https://example.com/other"),
            renderedURL: URL(string: "https://example.com/other"), registered: [source]
        ))
        XCTAssertNil(ResponseCitationDecoration.source(
            for: .init(text: "Image", destination: destination, isImage: true),
            renderedURL: URL(string: destination), registered: [source]
        ))
    }

    func testLegacyCollectionDetectionIsConservativeAndRetainsSourceOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["report.pdf", "main.py"] { try Data("test".utf8).write(to: root.appendingPathComponent(name)) }
        let resolve: (String?) -> WorkspaceArtifactReference? = { WorkspaceArtifactReference.classify($0, workspacePath: root.path) }
        let items: [MarkdownRenderListItem] = [
            .init(checked: nil, blocks: [.paragraph([.init(text: "main.py", style: .code), .init(text: " — script")])]),
            .init(checked: nil, blocks: [.paragraph([.init(text: "report.pdf", destination: "report.pdf")])]),
        ]
        XCTAssertEqual(MarkdownFileCollectionDetector.references(in: items, resolve: resolve)?.map(\.relativePath), ["main.py", "report.pdf"])
        XCTAssertNil(MarkdownFileCollectionDetector.references(in: [items[0]], resolve: resolve))
        XCTAssertNil(MarkdownFileCollectionDetector.references(in: [items[0], .init(checked: false, blocks: items[1].blocks)], resolve: resolve))
        XCTAssertNil(MarkdownFileCollectionDetector.references(in: [items[0], .init(checked: nil, blocks: [.paragraph([.init(text: "missing.py", style: .code)])])], resolve: resolve))
        XCTAssertNil(MarkdownFileCollectionDetector.references(in: [items[0], .init(checked: nil, blocks: [.paragraph([.init(text: "main.py", style: .code), .init(text: " should be changed")])])], resolve: resolve))
    }

    func testCollectionDescriptionsCanHideWithoutMutatingOriginalRuns() {
        let original: [MarkdownInlineRun] = [.init(text: "main.py", style: .code), .init(text: " — Script details")]
        let entry = WorkspaceFileCollectionEntry(id: "one", path: "main.py", runs: original)
        XCTAssertEqual(WorkspaceFileCollectionText.runs(for: entry, showsDescriptions: false).map(\.text).joined(), "main.py")
        XCTAssertEqual(WorkspaceFileCollectionText.runs(for: entry, showsDescriptions: true).map(\.text).joined(), "main.py\nScript details")
        XCTAssertEqual(entry.runs, original)
        XCTAssertEqual(WorkspaceFileCollectionCategory.category(for: "requirements.txt"), .setup)
        XCTAssertEqual(WorkspaceFileCollectionCategory.category(for: "test_main.py"), .tests)
        XCTAssertEqual(WorkspaceFileCollectionCategory.category(for: "report.pdf"), .documents)
    }

    private func drain(_ coordinator: StreamingRenderCoordinator) async {
        for _ in 0..<100 where coordinator.isParsingForTesting {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(coordinator.isParsingForTesting)
    }
}
