import XCTest
@testable import Locus

@MainActor
final class ResponseEventTests: XCTestCase {
    private func document(_ body: String) -> [String: Any] {
        ["version": 1, "parts": [
            ["type": "writing", "id": "email", "variant": "email", "title": "Outreach", "body": body],
        ]]
    }

    func testClassicFinalEventPreservesExactContentPartsAndOrigin() throws {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "message_start", "item_id": "classic-item", "run_id": "classic-run"])
        model.handleEventForTesting(["type": "thinking", "text": "Private reasoning"])
        model.handleEventForTesting(["type": "token", "text": "Incomplete draft"])
        XCTAssertNil(model.blocks.first?.responseParts)
        let complete = "Keep the literal <think>example</think> tag in this email.\n"
        model.handleEventForTesting([
            "type": "message_end", "item_id": "classic-item", "run_id": "classic-run",
            "phase": "final_answer", "content": complete, "reasoning_format": "native",
            "response_parts": document(complete),
        ])

        let block = try XCTUnwrap(model.blocks.onlyAssistant)
        XCTAssertEqual(block.text, complete)
        XCTAssertEqual(block.sourceItemID, "classic-item")
        XCTAssertEqual(block.runID, "classic-run")
        XCTAssertEqual(block.assistantPhase, .finalAnswer)
        XCTAssertEqual(block.reasoningFormat, .native)
        XCTAssertEqual(block.reasoningText, "Private reasoning")
        XCTAssertEqual(block.responseParts?.parts.first?.body, complete)
        XCTAssertTrue(block.responseParts?.isSupported == true)
        XCTAssertFalse(block.isStreaming)
    }

    func testClassicDuplicateCompletionDoesNotDuplicateBlocksAndReplacementUpdatesParts() throws {
        let model = AppModel(startImmediately: false)
        let first: [String: Any] = ["type": "message_end", "item_id": "classic-final", "run_id": "run-one",
            "content": "First final.", "response_parts": document("First final.")]
        model.handleEventForTesting(first)
        let originalID = try XCTUnwrap(model.blocks.onlyAssistant?.id)
        model.handleEventForTesting(first)
        XCTAssertEqual(model.blocks.filter { $0.kind == .assistant }.count, 1)
        XCTAssertEqual(model.blocks.onlyAssistant?.id, originalID)

        model.handleEventForTesting(["type": "message_end", "item_id": "classic-final", "run_id": "run-one",
            "content": "Authoritative replacement.", "response_parts": document("Authoritative replacement.")])
        let replacement = try XCTUnwrap(model.blocks.onlyAssistant)
        XCTAssertEqual(replacement.id, originalID)
        XCTAssertEqual(replacement.text, "Authoritative replacement.")
        XCTAssertEqual(replacement.responseParts?.parts.first?.body, "Authoritative replacement.")
        XCTAssertEqual(replacement.runID, "run-one")
    }

    func testNativeFinalReplacesStreamAndIgnoresLateStartAndDelta() throws {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "assistant_item_start", "item_id": "native-final",
            "run_id": "native-run", "kind": "message", "phase": "final_answer"])
        model.handleEventForTesting(["type": "assistant_item_delta", "item_id": "native-final", "kind": "message",
            "text": "Partial text that is replaced"])
        let complete: [String: Any] = ["type": "assistant_item_end", "item_id": "native-final", "kind": "message",
            "run_id": "native-run", "phase": "final_answer", "text": "The native final answer.",
            "reasoning_format": "native", "response_parts": document("The native final answer.")]
        model.handleEventForTesting(complete)
        let identity = try XCTUnwrap(model.blocks.onlyAssistant?.id)
        model.handleEventForTesting(complete)
        model.handleEventForTesting(["type": "assistant_item_start", "item_id": "native-final", "kind": "message"])
        model.handleEventForTesting(["type": "assistant_item_delta", "item_id": "native-final", "kind": "message", "text": "Late text"])

        let block = try XCTUnwrap(model.blocks.onlyAssistant)
        XCTAssertEqual(block.id, identity)
        XCTAssertEqual(block.text, "The native final answer.")
        XCTAssertEqual(block.responseParts?.parts.first?.body, "The native final answer.")
        XCTAssertEqual(block.sourceItemID, "native-final")
        XCTAssertEqual(block.runID, "native-run")
        XCTAssertEqual(block.reasoningFormat, .native)
        XCTAssertFalse(block.isStreaming)

        model.handleEventForTesting(["type": "assistant_item_end", "item_id": "native-final", "kind": "message",
            "run_id": "native-run", "phase": "final_answer", "text": "Corrected native answer.",
            "response_parts": document("Corrected native answer.")])
        XCTAssertEqual(model.blocks.onlyAssistant?.id, identity)
        XCTAssertEqual(model.blocks.onlyAssistant?.text, "Corrected native answer.")
        XCTAssertEqual(model.blocks.onlyAssistant?.responseParts?.parts.first?.body, "Corrected native answer.")
    }

    func testChangedAuthoritativePlainAnswerClearsObsoletePartsOnBothRoutes() throws {
        for native in [false, true] {
            let model = AppModel(startImmediately: false)
            var final: [String: Any] = ["type": native ? "assistant_item_end" : "message_end",
                "item_id": "final", "run_id": "run", "kind": "message", "phase": "final_answer",
                "response_parts": document("Original draft")]
            final[native ? "text" : "content"] = "Original draft"
            model.handleEventForTesting(final)
            final.removeValue(forKey: "response_parts")
            model.handleEventForTesting(final)
            XCTAssertNotNil(model.blocks.onlyAssistant?.responseParts, "An unchanged duplicate should retain metadata")
            final[native ? "text" : "content"] = "Corrected ordinary answer"
            model.handleEventForTesting(final)
            let block = try XCTUnwrap(model.blocks.onlyAssistant)
            XCTAssertEqual(block.text, "Corrected ordinary answer")
            XCTAssertNil(block.responseParts, "Changed authoritative text must not be hidden behind obsolete parts")
        }
    }

    func testLateMetadataAttachesToExistingCompletionAndMalformedReplacementFallsBack() throws {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "message_end", "item_id": "late-final", "run_id": "late-run", "content": "Complete fallback."])
        let identity = try XCTUnwrap(model.blocks.onlyAssistant?.id)
        model.handleEventForTesting(["type": "message_end", "item_id": "late-final", "run_id": "late-run",
            "content": "Complete fallback.", "response_parts": document("Complete fallback.")])
        XCTAssertEqual(model.blocks.onlyAssistant?.id, identity)
        XCTAssertEqual(model.blocks.onlyAssistant?.responseParts?.parts.first?.body, "Complete fallback.")
        model.handleEventForTesting(["type": "message_end", "item_id": "late-final", "run_id": "late-run",
            "content": "Replacement fallback.", "response_parts": ["version": 1, "parts": "malformed"]])
        XCTAssertEqual(model.blocks.onlyAssistant?.id, identity)
        XCTAssertEqual(model.blocks.onlyAssistant?.text, "Replacement fallback.")
        XCTAssertNil(model.blocks.onlyAssistant?.responseParts)
    }
}

extension ResponseEventTests {
    private func imageAndInteractive(workspace: String) -> [String: Any] {
        ["version": 1, "parts": [
            ["type": "image", "id": "picture", "title": "Harbour at dusk", "workspace": workspace,
             "path": "Locus Images/harbour.png", "alt": "A harbour", "prompt": "A quiet harbour",
             "source_path": "Locus Images/source.png", "width": 1024, "height": 1024, "format": "png", "size": 2048],
            ["type": "interactive", "id": "widget", "title": "Binary search", "summary": "Step through the search.",
             "html": "<div><button>Step</button></div>", "height": 420],
        ]]
    }

    func testClassicAndNativeCompletionsAttachImageAndInteractiveParts() throws {
        for native in [false, true] {
            let model = AppModel(startImmediately: false)
            var final: [String: Any] = ["type": native ? "assistant_item_end" : "message_end",
                "item_id": "final", "run_id": "run", "kind": "message", "phase": "final_answer",
                "response_parts": imageAndInteractive(workspace: "/tmp/workspace")]
            final[native ? "text" : "content"] = "![A harbour](/tmp/workspace/Locus%20Images/harbour.png)\n\nHarbour at dusk"
            model.handleEventForTesting(final)
            let block = try XCTUnwrap(model.blocks.onlyAssistant, native ? "native" : "classic")
            let document = try XCTUnwrap(block.responseParts)
            XCTAssertTrue(document.isSupported)
            XCTAssertEqual(document.parts.map(\.type), ["image", "interactive"])
            XCTAssertEqual(document.parts[0].width, 1024)
            XCTAssertEqual(document.parts[0].byteSize, 2048)
            XCTAssertEqual(document.parts[0].sourcePath, "Locus Images/source.png")
            XCTAssertEqual(document.parts[1].interactiveHeight, 420)
            XCTAssertEqual(document.parts[1].summary, "Step through the search.")
            XCTAssertTrue(block.text.hasPrefix("![A harbour]"), "The Markdown fallback stays the message text")
        }
    }

    func testToolResultFileEffectsCaptureGeneratedImageIntoOutputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResponseEventTests-\(UUID())")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Locus Images"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 64)
        try png.write(to: workspace.appendingPathComponent("Locus Images/sunset.png"))
        let store = OutputsLibraryStore(directory: root.appendingPathComponent("library"))
        let outputs = OutputsLibraryModel(store: store)
        outputs.configure(emitter: SessionStateEmitter(), enabled: true)
        outputs.activate(workspace: workspace.path)
        outputs.beginRun(workspace: workspace.path, sessionID: "chat", runID: "run")
        let event: [String: Any] = ["type": "tool_result", "id": "image-call", "tool": "generate_image", "ok": true,
            "run_id": "run", "result": "Created image Locus Images/sunset.png (1024×1024 PNG, 72 bytes, gpt-image-1).",
            "activity_label": "Created image Locus Images/sunset.png",
            "file_effects": [["path": "Locus Images/sunset.png", "effect": "create"]]]
        outputs.recordToolEffects(event, workspace: workspace.path, sessionID: "chat", runID: "run")
        outputs.endRun(sessionID: "chat")
        await outputs.flush()
        let items = try await store.list(workspace: workspace.path)
        XCTAssertEqual(items.map(\.target), ["Locus Images/sunset.png"])
        XCTAssertEqual(items.first?.kind, "image")
        XCTAssertTrue(items.first?.latest?.belongsTo(sessionID: "chat", runID: "run") == true)
        XCTAssertEqual(items.first?.latest?.byteCount, Int64(png.count))

        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "tool_call_proposed", "id": "image-call", "tool": "generate_image", "auto": true,
                                     "summary": "generate image: \"sunset\"", "detail": ""])
        model.handleEventForTesting(event)
        let tool = try XCTUnwrap(model.blocks.last?.tool)
        XCTAssertEqual(tool.status, .done)
        XCTAssertEqual(tool.activityLabel, "Created image Locus Images/sunset.png")
        XCTAssertEqual(CompactToolActivitySummary(tools: [tool]).title, "Created image Locus Images/sunset.png")
        XCTAssertEqual(CompactToolActivitySummary(tools: [tool]).systemImage, "photo")
    }
}

private extension Array where Element == ChatBlock {
    var onlyAssistant: ChatBlock? {
        let values = filter { $0.kind == .assistant }
        return values.count == 1 ? values.first : nil
    }
}
