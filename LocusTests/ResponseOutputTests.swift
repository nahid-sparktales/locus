import AppKit
import XCTest
@testable import Locus

@MainActor
final class ResponseOutputTests: XCTestCase {
    private func fixture() throws -> (root: URL, workspace: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResponseOutputTests-\(UUID())")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, workspace)
    }

    private func tenFiles(workspace: String) -> ResponseDocument {
        let names = [
            "AGENTS.md", "audit_findings_report.pdf", "code_audit_report.pdf", "generate_audit_report.py",
            "pokemoncenter_stock.py", "reddit_latest.py", "requirements.txt",
            "storybookbible-influencer-intro-email.pdf", "test_pokemoncenter_stock.py", "test_reddit_latest.py",
        ]
        return ResponseDocument(version: 1, parts: [ResponsePart(
            type: "file_collection", id: "directory", title: "Workspace files", workspace: workspace,
            entries: names.enumerated().map { index, path in
                ResponseFileEntry(path: path, size: Int64(index + 1), exists: true, description: "Description of \(path)")
            }, totalCount: names.count, complete: true
        )])
    }

    private func writing(body: String = "Hello there.\n\nHere is the original draft.") -> ResponsePart {
        ResponsePart(type: "writing", id: "email", title: "Introduction", variant: "email", subject: "Hello", body: body)
    }

    private func history(content: String, metadata: Any?, reasoning: String = "native") throws -> HistoryMessage {
        var value: [String: Any] = ["role": "assistant", "content": content, "item_id": "durable-item",
                                     "run_id": "producing-run", "reasoning_format": reasoning]
        value["response_parts"] = metadata
        return try JSONDecoder().decode(HistoryMessage.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testVerifiedActivityLabelsSurviveHistoryAndCheckpointWithLegacyFallback() throws {
        let source = Data(#"{"role":"tool","name":"list_dir","content":"10 files","item_id":"list-operation","activity_label":"Checked locus-tests"}"#.utf8)
        let history = try JSONDecoder().decode(HistoryMessage.self, from: source)
        let restoredHistory = try JSONDecoder().decode(HistoryMessage.self, from: JSONEncoder().encode(history))
        let block = try XCTUnwrap(ChatTranscriptBuilder.blocks(from: [restoredHistory]).first)
        let restoredBlock = try JSONDecoder().decode(ChatBlock.self, from: JSONEncoder().encode(block))
        let tool = try XCTUnwrap(restoredBlock.tool)
        XCTAssertEqual(tool.toolID, "list-operation")
        XCTAssertEqual(tool.result, "10 files")
        XCTAssertEqual(tool.activityLabel, "Checked locus-tests")
        XCTAssertEqual(CompactToolActivitySummary(tools: [tool]).title, "Checked locus-tests")

        let legacy = try JSONDecoder().decode(ToolPayload.self, from: Data(
            #"{"toolID":"old","tool":"list_dir","summary":"list_dir","detail":"","status":"done"}"#.utf8
        ))
        XCTAssertNil(legacy.activityLabel)
        XCTAssertEqual(CompactToolActivitySummary(tools: [legacy]).title, "Read files")
    }

    func testVerifiedActivitySummaryRequiresCompletedResultsAndPreservesGenericActivities() {
        let labelled = ToolPayload(toolID: "read", tool: "read_file", summary: "read_file", detail: "", status: .done,
                                   result: "contents", activityLabel: "Read Sources/App.swift")
        let generic = ToolPayload(toolID: "command", tool: "bash", summary: "python check.py", detail: "", status: .done)
        let summary = CompactToolActivitySummary(tools: [labelled, generic, labelled])
        XCTAssertEqual(summary.title, "Read Sources/App.swift, ran command")
        XCTAssertEqual(summary.systemImage, "magnifyingglass")
        for state in [ToolStatus.awaitingPermission, .running, .error, .denied] {
            var pending = labelled
            pending.status = state
            XCTAssertEqual(CompactToolActivitySummary(tools: [pending]).title, "Read files")
        }
        var empty = labelled
        empty.activityLabel = " \n "
        XCTAssertEqual(CompactToolActivitySummary(tools: [empty]).title, "Read files")
    }

    func testVerifiedActivityLabelsPropagateOnlyFromSuccessfulToolResults() throws {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "tool_call_proposed", "id": "listing", "tool": "list_dir",
                                     "summary": "list_dir", "auto": true, "activity_label": "Unverified proposal"])
        XCTAssertNil(model.blocks.last?.tool?.activityLabel)
        model.handleEventForTesting(["type": "tool_result", "id": "listing", "ok": true,
                                     "result": "10 files", "activity_label": "Checked locus-tests"])
        XCTAssertEqual(model.blocks.last?.tool?.activityLabel, "Checked locus-tests")
        model.handleEventForTesting(["type": "tool_result", "id": "orphan", "tool": "read_file", "ok": true,
                                     "result": "contents", "activity_label": "Read README.md"])
        XCTAssertEqual(model.blocks.last?.tool?.activityLabel, "Read README.md")
        model.handleEventForTesting(["type": "tool_result", "id": "orphan", "ok": false,
                                     "result": "Read failed", "activity_label": "Read README.md"])
        XCTAssertEqual(model.blocks.last?.tool?.status, .error)
        XCTAssertNil(model.blocks.last?.tool?.activityLabel)
        model.handleEventForTesting(["type": "tool_result", "id": "denied", "tool": "write_file", "ok": true,
                                     "denied": true, "activity_label": "Updated README.md"])
        XCTAssertEqual(model.blocks.last?.tool?.status, .denied)
        XCTAssertNil(model.blocks.last?.tool?.activityLabel)
    }

    func testDraftSelectionReplacesOriginalSubtreeWithoutDroppingNeighboringParts() {
        let store = TranscriptSelectionStore()
        store.syncRows(["answer", "next"])
        func span(_ text: String, _ path: [Int], row: String = "answer") -> TranscriptSelectionSpan {
            .init(treePath: path, displayedText: text, separatorBefore: "\n\n", copyPrefix: "", rowID: row)
        }
        let intro = span("Introduction", [0, 0, 0])
        let original = [span("Original opening", [0, 1, 0]), span("Original ending", [0, 1, 1])]
        let nextPart = span("Other artifact", [0, 2, 0])
        let nextRow = span("Next answer", [0], row: "next")
        for value in [intro] + original + [nextPart, nextRow] { store.register(value, view: .make()) }
        let edited = ResponseWritingDrafts.selectionSpan(text: "Edited opening\n\nEdited ending", rootPath: [0, 1], rowID: "answer")
        XCTAssertTrue(store.retainSpanIDs(in: "answer", under: [0, 1], keeping: [edited.id]))
        store.register(edited, view: .make())
        store.selectForTesting(from: .init(spanID: intro.id, utf16Offset: 0),
            to: .init(spanID: nextRow.id, utf16Offset: nextRow.utf16Length))
        XCTAssertEqual(store.selectedText, "Introduction\n\nEdited opening\n\nEdited ending\n\nOther artifact\n\nNext answer")

        store.clearSelection()
        XCTAssertTrue(store.retainSpanIDs(in: "answer", under: [0, 1], keeping: Set(original.map(\.id))))
        for value in original { store.register(value, view: .make()) }
        store.selectForTesting(from: .init(spanID: intro.id, utf16Offset: 0),
            to: .init(spanID: nextRow.id, utf16Offset: nextRow.utf16Length))
        XCTAssertEqual(store.selectedText, "Introduction\n\nOriginal opening\n\nOriginal ending\n\nOther artifact\n\nNext answer")
    }

    func testSelectedRowsIncludeTheMiddleAndKeepContentUntilSelectionClears() {
        let store = TranscriptSelectionStore()
        store.syncRows(["first", "middle", "last"])
        let spans = ["first", "middle", "last"].map {
            TranscriptSelectionSpan(treePath: [0], displayedText: $0, separatorBefore: "\n\n", copyPrefix: "", rowID: $0)
        }
        for span in spans { store.register(span, view: .make()) }
        store.selectForTesting(from: .init(spanID: spans[0].id, utf16Offset: 0),
            to: .init(spanID: spans[2].id, utf16Offset: spans[2].utf16Length))
        XCTAssertTrue(store.activeRowIDs.isEmpty, "A selected passage can remain after the drag finishes")
        XCTAssertEqual(store.selectedRowIDs, ["first", "middle", "last"])
        XCTAssertFalse(store.retainSpanIDs(in: "middle", keeping: []))
        XCTAssertEqual(store.selectedText, "first\n\nmiddle\n\nlast")
        store.clearSelection()
        XCTAssertTrue(store.selectedRowIDs.isEmpty)
        XCTAssertTrue(store.retainSpanIDs(in: "middle", keeping: []))
    }

    func testStreamingSpanIsReplacedByTypedFinalOnlyAfterSelectionRelease() throws {
        let store = TranscriptSelectionStore()
        store.syncRows(["before", "answer", "after"])
        let before = ResponseWritingDrafts.selectionSpan(text: "Before", rootPath: [], rowID: "before")
        let after = ResponseWritingDrafts.selectionSpan(text: "After", rootPath: [], rowID: "after")
        let streamed = try XCTUnwrap(MarkdownSelectionProjection.spans(
            for: MarkdownDocumentParser.parse("Original streamed paragraph."), rootPath: [0],
            firstSeparator: "\n\n", rowID: "answer").values.first)
        let finalDocument = ResponseDocument(version: 1, parts: [
            ResponsePart(type: "markdown", id: "result", text: "Authoritative final answer."),
        ])
        let final = try XCTUnwrap(ResponseSelectionProjection.spans(document: finalDocument, rowID: "answer").first)
        XCTAssertEqual(streamed.treePath, [0, 0])
        XCTAssertEqual(final.treePath, [0, 0, 0])
        let oldView = ResponseSelectableTextView.make()
        store.register(before, view: .make())
        store.register(streamed, view: oldView)
        store.register(after, view: .make())
        func selectPassage() {
            store.selectForTesting(from: .init(spanID: before.id, utf16Offset: 0),
                to: .init(spanID: after.id, utf16Offset: after.utf16Length))
        }
        selectPassage()
        XCTAssertFalse(store.retainSpanIDs(in: "answer", keeping: [final.id]),
            "The renderer must retain its streaming presentation while the selection owns this row")
        XCTAssertEqual(store.selectedText, "Before\n\nOriginal streamed paragraph.\n\nAfter")

        store.clearSelection()
        XCTAssertTrue(store.retainSpanIDs(in: "answer", keeping: [final.id]))
        store.register(final, view: .make())
        // Lazy teardown can arrive after the final native leaf was registered.
        store.unregister(spanID: streamed.id, view: oldView)
        selectPassage()
        XCTAssertEqual(store.selectedText, "Before\n\nAuthoritative final answer.\n\nAfter",
            "The obsolete streaming path must not duplicate or leak into a later selection")
    }

    func testReconciliationInvalidatesOffscreenOriginalWritingProjection() {
        let store = TranscriptSelectionStore()
        store.syncRows(["first", "writing", "last"])
        let first = ResponseWritingDrafts.selectionSpan(text: "Before", rootPath: [], rowID: "first")
        let last = ResponseWritingDrafts.selectionSpan(text: "After", rootPath: [], rowID: "last")
        var text = "Original writing"
        store.spanProvider = { rowID in
            rowID == "writing" ? [ResponseWritingDrafts.selectionSpan(text: text, rootPath: [0, 0], rowID: rowID)] : []
        }
        store.register(first, view: .make()); store.register(last, view: .make())
        func select() {
            store.selectForTesting(from: .init(spanID: first.id, utf16Offset: 0),
                to: .init(spanID: last.id, utf16Offset: last.utf16Length))
        }
        select()
        XCTAssertEqual(store.selectedText, "Before\n\nOriginal writing\n\nAfter")
        store.clearSelection()
        text = "Saved edited writing"
        XCTAssertTrue(store.retainSpanIDs(in: "writing", under: [0, 0], keeping: []))
        select()
        XCTAssertEqual(store.selectedText, "Before\n\nSaved edited writing\n\nAfter")
    }

    func testTypedMetadataSurvivesHistoryAndCheckpointRoundTrips() throws {
        let (_, workspace) = try fixture()
        let document = tenFiles(workspace: workspace.path)
        let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
        let original = "All ten files are listed below.\n"
        let decoded = try history(content: original, metadata: metadata)
        let historyRoundTrip = try JSONDecoder().decode(HistoryMessage.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(historyRoundTrip.content, original)
        XCTAssertEqual(historyRoundTrip.responseParts, document)
        XCTAssertEqual(historyRoundTrip.reasoningFormat, .native)
        XCTAssertEqual(historyRoundTrip.itemID, "durable-item")
        let block = try XCTUnwrap(ChatTranscriptBuilder.blocks(from: [historyRoundTrip]).first)
        XCTAssertEqual(block.responseParts, document)
        XCTAssertEqual(block.runID, "producing-run")
        let restored = try JSONDecoder().decode(ChatBlock.self, from: JSONEncoder().encode(block))
        XCTAssertEqual(restored.responseParts, document)
        XCTAssertEqual(restored.sourceItemID, block.sourceItemID)
        XCTAssertEqual(restored.reasoningFormat, .native)
        XCTAssertEqual(restored.text, original)
        XCTAssertEqual(ResponseCopyPayload.text(from: restored.text, format: .markdown, reasoningFormat: .native), original)
    }

    func testUnsupportedAndMalformedMetadataKeepTheOrdinaryAnswer() throws {
        let fallback = "The **complete answer** remains available.\n"
        let payloads: [Any] = [
            ["version": 99, "parts": [["type": "markdown", "id": "future", "text": "Future presentation"]]],
            ["version": 1, "parts": [["type": "unknown_future_type", "id": "future", "text": "Future presentation"]]],
            ["version": 1, "parts": "malformed"],
            ["version": 1, "parts": [["type": "markdown", "id": "duplicate", "text": "A"], ["type": "markdown", "id": "duplicate", "text": "B"]]],
        ]
        for metadata in payloads {
            let decoded = try history(content: fallback, metadata: metadata)
            XCTAssertFalse(decoded.responseParts?.isSupported == true)
            let block = try XCTUnwrap(ChatTranscriptBuilder.blocks(from: [decoded]).first)
            let checkpoint = try JSONDecoder().decode(ChatBlock.self, from: JSONEncoder().encode(block))
            let visible = TranscriptPresentation.items(from: [checkpoint], toolVisibility: .collapsed, thinkingVisibility: .hidden)
                .compactMap { item -> String? in
                    if case .assistantSegment(let segment) = item { return segment.text }
                    return nil
                }.joined()
            XCTAssertEqual(visible, fallback)
            XCTAssertEqual(checkpoint.text, fallback)
        }
        let legacy = try history(content: fallback, metadata: nil, reasoning: "future-reasoning-format")
        XCTAssertNil(legacy.responseParts)
        XCTAssertEqual(legacy.reasoningFormat, AssistantReasoningFormat.none)
        XCTAssertEqual(legacy.content, fallback)
    }

    func testCompleteTenFileCollectionRetainsEveryPathDescriptionAndCategory() throws {
        let (_, workspace) = try fixture()
        let document = tenFiles(workspace: workspace.path)
        XCTAssertTrue(document.isSupported)
        let part = try XCTUnwrap(document.parts.first)
        let entries = try XCTUnwrap(part.entries)
        XCTAssertEqual(part.totalCount, 10)
        XCTAssertEqual(part.complete, true)
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(Set(entries.map(\.path)).count, 10)
        let categories = Dictionary(grouping: entries, by: { WorkspaceFileCollectionCategory.category(for: $0.path) })
        XCTAssertEqual(categories[.documents]?.count, 3)
        XCTAssertEqual(categories[.scripts]?.count, 3)
        XCTAssertEqual(categories[.tests]?.count, 2)
        XCTAssertEqual(categories[.setup]?.count, 2)
        let spans = ResponseSelectionProjection.spans(document: document, rowID: "row")
        XCTAssertEqual(spans.count, 10)
        for (entry, span) in zip(ResponseSelectionProjection.orderedEntries(part), spans) {
            XCTAssertEqual(span.displayedText, entry.path)
            XCTAssertEqual(entry.description, "Description of \(entry.path)")
        }
    }

    func testDraftEditingIsIdempotentAndPersistsAcrossStoreReconstruction() throws {
        let (root, workspace) = try fixture()
        let part = writing()
        let original = part.originalWriting
        let id = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "session", itemID: "item", part: part)
        XCTAssertNil(ResponseWritingDrafts.existing(id: id, root: root))
        let first = try ResponseWritingDrafts.edit(id: id, part: part, root: root)
        first.update("My edited introduction.\n\nLatest unsaved paragraph.")
        let second = try ResponseWritingDrafts.edit(id: id, part: part, root: root)
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.text, "My edited introduction.\n\nLatest unsaved paragraph.")
        try first.flush()
        let reconstructed = NotesStore.testingStore(documentID: id, scope: .global, applicationSupport: root)
        XCTAssertEqual(reconstructed.text, first.text)
        XCTAssertTrue(reconstructed.attributedText.isEqual(to: first.attributedText))
        XCTAssertTrue(ResponseWritingDrafts.existing(id: id, root: root) === first)
        XCTAssertEqual(try first.catalog.snapshot().count, 1)
        XCTAssertEqual(part.originalWriting, original)
        XCTAssertEqual(ResponseCopyPayload.text(from: original, format: .markdown, reasoningFormat: .native), original)
    }

    func testDraftIdentitySeparatesMessagesSessionsWorkspacesPartsAndRegeneration() throws {
        let (_, workspace) = try fixture()
        let part = writing()
        let original = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "m", part: part)
        XCTAssertEqual(original, ResponseWritingDrafts.documentID(workspace: workspace.appendingPathComponent(".").path, sessionID: "s", itemID: "m", part: part))
        let otherMessage = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "other", part: part)
        let otherSession = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "other", itemID: "m", part: part)
        let otherWorkspace = ResponseWritingDrafts.documentID(workspace: workspace.appendingPathComponent("other").path, sessionID: "s", itemID: "m", part: part)
        var otherPart = part
        otherPart.id = "second-writing"
        let otherPartID = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "m", part: otherPart)
        let regeneration = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "m", part: writing(body: "Regenerated content"))
        XCTAssertEqual(Set([original, otherMessage, otherSession, otherWorkspace, otherPartID, regeneration]).count, 6)
        XCTAssertTrue(original.isStandalone)
        XCTAssertTrue(original.isValid)
    }

    func testRegeneratedDraftCannotOverwriteEditedEarlierVersion() throws {
        let (root, workspace) = try fixture()
        let firstPart = writing()
        let firstID = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "reused", part: firstPart)
        let first = try ResponseWritingDrafts.edit(id: firstID, part: firstPart, root: root)
        first.update("User revision that must survive")
        try first.flush()
        let replacement = writing(body: "New provider answer")
        let replacementID = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "reused", part: replacement)
        let second = try ResponseWritingDrafts.edit(id: replacementID, part: replacement, root: root)
        XCTAssertNotEqual(first.documentID, second.documentID)
        XCTAssertEqual(first.text, "User revision that must survive")
        XCTAssertTrue(second.text.contains("New provider answer"))
        XCTAssertEqual(try first.catalog.snapshot().count, 2)
    }

    func testDraftRecoveryUsesStyledArchiveWhenPlainMirrorIsMissing() throws {
        let (root, workspace) = try fixture()
        let part = writing()
        let id = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "m", part: part)
        let first = try ResponseWritingDrafts.edit(id: id, part: part, root: root)
        first.updateAttributed(NSAttributedString(string: "Preserve rich recovery", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
        try first.flush()
        try FileManager.default.removeItem(at: first.fileURL)
        XCTAssertNotNil(ResponseWritingDrafts.existing(id: id, root: root))
        let recovered = try ResponseWritingDrafts.edit(id: id, part: part, root: root)
        XCTAssertEqual(recovered.text, "Preserve rich recovery")
        let reconstructed = NotesStore.testingStore(documentID: id, scope: .global, applicationSupport: root)
        XCTAssertEqual(reconstructed.text, "Preserve rich recovery")
        XCTAssertTrue(reconstructed.attributedText.isEqual(to: recovered.attributedText))
    }

    func testDraftImportsUsableNativeFormattingAndPreservesLiteralText() throws {
        let (root, workspace) = try fixture()
        let part = ResponsePart(type: "writing", id: "rich", variant: "standard", body: "**Bold** and *italic* with `<think>literal</think>`.")
        let id = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "m", part: part)
        let draft = try ResponseWritingDrafts.edit(id: id, part: part, root: root)
        XCTAssertEqual(draft.text, "Bold and italic with <think>literal</think>.")
        let bold = try XCTUnwrap(draft.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let italicRange = (draft.text as NSString).range(of: "italic")
        let italic = try XCTUnwrap(draft.attributedText.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        XCTAssertEqual(part.body, "**Bold** and *italic* with `<think>literal</think>`.")
    }

    func testDraftImportPreservesFencedCodeLineBreaksAndLiteralTags() throws {
        let (root, workspace) = try fixture()
        let body = "Example:\n\n```xml\n<think>literal</think>\n<value>42</value>\n```\n\nAfter."
        let part = ResponsePart(type: "writing", id: "example", variant: "document", body: body)
        let id = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "m", part: part)
        let draft = try ResponseWritingDrafts.edit(id: id, part: part, root: root)
        XCTAssertTrue(draft.text.contains("<think>literal</think>\n<value>42</value>"))
        XCTAssertTrue(draft.text.hasPrefix("Example:"))
        XCTAssertTrue(draft.text.hasSuffix("After."))
        XCTAssertFalse(draft.text.contains("xml <think>"), "The code fence's language must not turn into body text")
        XCTAssertEqual(part.body, body)
    }

    func testDraftSaveFailureKeepsEditsRetryableAndOriginalUnchanged() throws {
        let (root, workspace) = try fixture()
        let part = writing()
        let original = part.originalWriting
        let id = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "m", part: part)
        let draft = try ResponseWritingDrafts.edit(id: id, part: part, root: root)
        try FileManager.default.removeItem(at: draft.styledFileURL)
        try FileManager.default.createDirectory(at: draft.styledFileURL, withIntermediateDirectories: false)
        let edited = NSAttributedString(string: "Unsaved latest edit", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        draft.updateAttributed(edited)
        XCTAssertThrowsError(try draft.flush())
        XCTAssertTrue(draft.hasUnsavedChanges)
        XCTAssertNotNil(draft.saveError)
        XCTAssertTrue(draft.attributedText.isEqual(to: edited))
        XCTAssertEqual(part.originalWriting, original)
        try FileManager.default.removeItem(at: draft.styledFileURL)
        try draft.flush()
        XCTAssertFalse(draft.hasUnsavedChanges)
        XCTAssertNil(draft.saveError)
        let reopened = NotesStore.testingStore(documentID: id, scope: .global, applicationSupport: root)
        XCTAssertTrue(reopened.attributedText.isEqual(to: edited))
    }

    func testDeletedDraftDoesNotResurrectOnReopeningItsResponse() throws {
        let (root, workspace) = try fixture()
        let part = writing()
        let id = ResponseWritingDrafts.documentID(workspace: workspace.path, sessionID: "s", itemID: "m", part: part)
        let draft = try ResponseWritingDrafts.edit(id: id, part: part, root: root)
        try draft.moveToTrash()
        XCTAssertEqual(try ResponseWritingDrafts.edit(id: id, part: part, root: root).lifecycle, .trashed)
        try draft.deletePermanently()
        let reopened = try ResponseWritingDrafts.edit(id: id, part: part, root: root)
        XCTAssertEqual(reopened.lifecycle, .purged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.fileURL.path))
        XCTAssertEqual(part.body, writing().body)
    }

    func testArtifactBindingRequiresTheExactProducingSessionAndRun() async throws {
        let (root, workspace) = try fixture()
        let store = OutputsLibraryStore(directory: root.appendingPathComponent("library"))
        try Data("Produced content".utf8).write(to: workspace.appendingPathComponent("report.md"))
        _ = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "session", runID: "run"))
        let wrongRun = try await store.bindResponse(key: "wrong-run", workspace: workspace.path, path: "report.md", sessionID: "session", runID: "other")
        let wrongSession = try await store.bindResponse(key: "wrong-session", workspace: workspace.path, path: "report.md", sessionID: "other", runID: "run")
        let missingRun = try await store.bindResponse(key: "missing-run", workspace: workspace.path, path: "report.md", sessionID: "session", runID: "")
        XCTAssertNil(wrongRun)
        XCTAssertNil(wrongSession)
        XCTAssertNil(missingRun)
        let exact = try await store.bindResponse(key: "exact", workspace: workspace.path, path: "report.md", sessionID: "session", runID: "run")
        XCTAssertNotNil(exact)
    }

    func testArtifactBindingStaysOnItsSavedVersionAfterOverwriteAndReload() async throws {
        let (root, workspace) = try fixture()
        let directory = root.appendingPathComponent("library")
        let store = OutputsLibraryStore(directory: directory)
        let source = workspace.appendingPathComponent("report.md")
        try Data("First version".utf8).write(to: source)
        let captured = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "session", runID: "run"))
        let firstOutput = try XCTUnwrap(captured)
        let bound = try await store.bindResponse(key: "response", workspace: workspace.path, path: "report.md", sessionID: "session", runID: "run")
        let first = try XCTUnwrap(bound)
        try Data("Later version in same run".utf8).write(to: source, options: .atomic)
        let newer = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "session", runID: "run"))
        XCTAssertNotEqual(newer?.latest?.id, first.versionID)
        let restoredStore = OutputsLibraryStore(directory: directory)
        let reopened = try await restoredStore.bindResponse(key: "response", workspace: workspace.path, path: "report.md", sessionID: "session", runID: "run")
        XCTAssertEqual(reopened, first)
        let savedURL = await restoredStore.versionURL(firstOutput, version: try XCTUnwrap(firstOutput.latest))
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(savedURL), encoding: .utf8), "First version")
        try FileManager.default.removeItem(at: source)
        let available = try await restoredStore.responseVersionAvailable(first, workspace: workspace.path)
        XCTAssertTrue(available)
    }

    func testMissingBoundSnapshotNeverFallsForwardToNewerBytes() async throws {
        let (root, workspace) = try fixture()
        let store = OutputsLibraryStore(directory: root.appendingPathComponent("library"))
        let source = workspace.appendingPathComponent("report.md")
        try Data("First bytes".utf8).write(to: source)
        let captured = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "s", runID: "r"))
        let output = try XCTUnwrap(captured)
        let bound = try await store.bindResponse(key: "card", workspace: workspace.path, path: "report.md", sessionID: "s", runID: "r")
        let binding = try XCTUnwrap(bound)
        let snapshot = await store.versionURL(output, version: try XCTUnwrap(output.latest))
        try FileManager.default.removeItem(at: XCTUnwrap(snapshot))
        try Data("Later bytes".utf8).write(to: source, options: .atomic)
        _ = try await store.capture(OutputCapture(workspace: workspace.path, path: "report.md", sessionID: "s", runID: "r"))
        let stillBound = try await store.bindResponse(key: "card", workspace: workspace.path, path: "report.md", sessionID: "s", runID: "r")
        let available = try await store.responseVersionAvailable(binding, workspace: workspace.path)
        XCTAssertEqual(stillBound, binding)
        XCTAssertFalse(available)
    }

    func testUnavailableProducingVersionRetainsItsFailureAfterFileAppears() async throws {
        let (root, workspace) = try fixture()
        let store = OutputsLibraryStore(directory: root.appendingPathComponent("library"))
        _ = try await store.capture(OutputCapture(workspace: workspace.path, path: "missing.md", sessionID: "s", runID: "r"))
        let bound = try await store.bindResponse(key: "missing", workspace: workspace.path, path: "missing.md", sessionID: "s", runID: "r")
        let unavailable = try XCTUnwrap(bound)
        XCTAssertNotNil(unavailable.unavailableReason)
        try Data("Created later".utf8).write(to: workspace.appendingPathComponent("missing.md"))
        _ = try await store.capture(OutputCapture(workspace: workspace.path, path: "missing.md", sessionID: "s", runID: "r"))
        let reopened = try await store.bindResponse(key: "missing", workspace: workspace.path, path: "missing.md", sessionID: "s", runID: "r")
        XCTAssertEqual(reopened, unavailable)
        let available = try await store.responseVersionAvailable(unavailable, workspace: workspace.path)
        XCTAssertFalse(available)
    }
}
