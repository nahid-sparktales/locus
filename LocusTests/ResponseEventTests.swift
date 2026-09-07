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

private extension Array where Element == ChatBlock {
    var onlyAssistant: ChatBlock? {
        let values = filter { $0.kind == .assistant }
        return values.count == 1 ? values.first : nil
    }
}
