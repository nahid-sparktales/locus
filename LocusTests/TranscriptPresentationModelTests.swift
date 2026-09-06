import Combine
import XCTest

@testable import Locus

@MainActor
final class TranscriptPresentationModelTests: XCTestCase {
    func testSessionInstallPublishesIdentityAndContentAsOneSnapshot() {
        let model = TranscriptPresentationModel()
        model.installSession("old", blocks: [ChatBlock(kind: .user, text: "Old")])
        let oldGeneration = model.snapshot.renderToken.sessionGeneration
        let next = ChatBlock(kind: .assistant, text: "New")
        var published: [TranscriptPresentationSnapshot] = []
        let subscription = model.$snapshot.dropFirst().sink { published.append($0) }

        model.installSession("new", blocks: [next])

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.sessionID, "new")
        XCTAssertEqual(published.first?.blocks, [next])
        XCTAssertEqual(model.snapshot.renderToken.sessionGeneration, oldGeneration + 1)
        XCTAssertEqual(model.snapshot.renderToken.tailID, model.snapshot.items.last?.id)
        withExtendedLifetime(subscription) {}
    }

    func testNewSessionLoadPublishesEmptyNewIdentityInsteadOfOldRows() {
        let model = TranscriptPresentationModel()
        model.installSession("old", blocks: [ChatBlock(kind: .user, text: "Old")])
        let lease = model.beginSessionLoad("new")
        XCTAssertEqual(model.snapshot.sessionID, "new")
        XCTAssertTrue(model.snapshot.blocks.isEmpty)
        XCTAssertNil(model.snapshot.renderToken.tailID)
        XCTAssertEqual(model.loadingSessionID, "new")
        XCTAssertTrue(model.ownsSessionLoad(lease))
    }

    func testLateSessionLoadCannotReplaceNewConversationOrItsRevision() {
        let model = TranscriptPresentationModel()
        let first = model.beginSessionLoad("first")
        let second = model.beginSessionLoad("second")
        let current = ChatBlock(kind: .assistant, text: "Second conversation")
        XCTAssertTrue(model.completeSessionLoad(second, sessionID: "second", blocks: [current]))
        let snapshot = model.snapshot
        let builds = model.snapshotBuildCountForTesting

        XCTAssertFalse(model.completeSessionLoad(first, sessionID: "first", blocks: [
            ChatBlock(kind: .assistant, text: "Late first conversation"),
        ]))
        XCTAssertEqual(model.snapshot, snapshot)
        XCTAssertEqual(model.snapshotBuildCountForTesting, builds)
        XCTAssertFalse(model.ownsSessionLoad(first))
    }

    func testRepeatedLoadOfSameSessionRejectsOldRequestAndDuplicateCompletion() {
        let model = TranscriptPresentationModel()
        let first = model.beginSessionLoad("same")
        let second = model.beginSessionLoad("same")
        XCTAssertEqual(first.sessionGeneration, second.sessionGeneration)
        XCTAssertFalse(model.completeSessionLoad(first, sessionID: "same", blocks: []))
        XCTAssertTrue(model.completeSessionLoad(second, sessionID: "same", blocks: []))
        let snapshot = model.snapshot
        XCTAssertFalse(model.completeSessionLoad(second, sessionID: "same", blocks: [
            ChatBlock(kind: .error, text: "Replayed response"),
        ]))
        XCTAssertEqual(model.snapshot, snapshot)
        XCTAssertTrue(model.ownsSessionLoad(second), "The owner can still guard separately awaited metadata")
    }

    func testCancelledLoadCannotInstallAndDoesNotCancelANewerLoad() {
        let model = TranscriptPresentationModel()
        let first = model.beginSessionLoad("first")
        let second = model.beginSessionLoad("second")
        model.cancelSessionLoad(first)
        XCTAssertTrue(model.ownsSessionLoad(second))
        model.cancelSessionLoad(second)
        XCTAssertFalse(model.completeSessionLoad(second, sessionID: "second", blocks: []))
        XCTAssertNil(model.loadingSessionID)
    }

    func testRekeyPreservesContentTokenRowIdentityAndLoadOwnershipWithoutRebuilding() {
        let model = TranscriptPresentationModel()
        let load = model.beginSessionLoad("draft")
        model.replaceBlocks([ChatBlock(kind: .assistant, text: "Already visible")])
        let original = model.snapshot
        let builds = model.snapshotBuildCountForTesting

        model.rekeySession(from: "draft", to: "server-id")

        XCTAssertEqual(model.snapshot.sessionID, "server-id")
        XCTAssertEqual(model.snapshot.renderToken, original.renderToken)
        XCTAssertEqual(model.snapshot.items, original.items)
        XCTAssertEqual(model.snapshotBuildCountForTesting, builds)
        XCTAssertEqual(model.loadingSessionID, "server-id")
        XCTAssertTrue(model.ownsSessionLoad(load))
        model.rekeySession(from: "draft", to: "stale-id")
        XCTAssertEqual(model.snapshot.sessionID, "server-id")
    }

    func testEqualCountReplacementAndSameIDContentCommitAdvanceRevisionNotSession() {
        let model = TranscriptPresentationModel()
        model.installSession("same", blocks: [ChatBlock(kind: .assistant, text: "First")])
        let first = model.snapshot.renderToken
        model.replaceBlocks([ChatBlock(kind: .assistant, text: "Replacement")])
        let replacement = model.snapshot.renderToken
        XCTAssertEqual(replacement.sessionGeneration, first.sessionGeneration)
        XCTAssertEqual(replacement.contentRevision, first.contentRevision + 1)
        XCTAssertNotEqual(replacement.tailID, first.tailID)
        model.updateBlocks { $0[0].text = "A longer replacement with the same block ID" }
        XCTAssertEqual(model.snapshot.renderToken.sessionGeneration, first.sessionGeneration)
        XCTAssertEqual(model.snapshot.renderToken.contentRevision, replacement.contentRevision + 1)
        XCTAssertEqual(model.snapshot.renderToken.tailID, replacement.tailID)
        let stable = model.snapshot.renderToken
        model.replaceBlocks(model.snapshot.blocks)
        XCTAssertEqual(model.snapshot.renderToken, stable)
    }

    func testHiddenReasoningRegroupsTailWithoutChangingBlockCountOrGeneration() {
        let model = TranscriptPresentationModel()
        model.installSession("same", blocks: [
            ChatBlock(kind: .assistant, text: "", reasoningText: "Reasoning-only final row"),
        ])
        let visible = model.snapshot.renderToken
        XCTAssertNotNil(visible.tailID)
        model.setPresentationVisibility(toolActivity: .collapsed, thinking: .hidden)
        XCTAssertEqual(model.snapshot.blocks.count, 1)
        XCTAssertNil(model.snapshot.renderToken.tailID)
        XCTAssertEqual(model.snapshot.renderToken.sessionGeneration, visible.sessionGeneration)
        XCTAssertEqual(model.snapshot.renderToken.contentRevision, visible.contentRevision + 1)
    }

    func testFreshConversationCanReuseBackendIDWithoutReusingRenderGeneration() {
        let model = TranscriptPresentationModel()
        model.installSession("same", blocks: [ChatBlock(kind: .user, text: "Old")])
        let generation = model.snapshot.renderToken.sessionGeneration
        model.installSession("same", blocks: [], forceNewGeneration: true)
        XCTAssertEqual(model.snapshot.renderToken.sessionGeneration, generation + 1)
        XCTAssertTrue(model.snapshot.blocks.isEmpty)
    }

    func testAppModelCompatibilityCannotExposeOldBlocksUnderNewSessionID() {
        let app = AppModel(startImmediately: false)
        app.installTranscriptSession("old", blocks: [ChatBlock(kind: .user, text: "Old")])
        app.currentSessionID = "new"
        XCTAssertEqual(app.currentSessionID, app.transcriptPresentation.snapshot.sessionID)
        XCTAssertTrue(app.blocks.isEmpty)
        app.blocks = [ChatBlock(kind: .assistant, text: "New")]
        XCTAssertEqual(app.transcriptPresentation.snapshot.sessionID, "new")
        XCTAssertEqual(app.blocks.map(\.text), ["New"])
    }

    func testAppModelRekeyPreservesReadingTokenAndSynchronousInstalledBlocks() {
        let app = AppModel(startImmediately: false)
        app.blocks = [ChatBlock(kind: .user, text: "Unassigned draft")]
        let token = app.transcriptPresentation.snapshot.renderToken
        app.rekeyTranscriptSession(to: "server-assigned")
        XCTAssertEqual(app.currentSessionID, "server-assigned")
        XCTAssertEqual(app.blocks.map(\.text), ["Unassigned draft"])
        XCTAssertEqual(app.transcriptPresentation.snapshot.renderToken, token)
    }

    func testStreamingTokensDoNotRebuildOrAdvanceCommittedRenderToken() {
        let app = AppModel(startImmediately: false)
        app.handleEventForTesting(["type": "message_start"])
        let token = app.transcriptPresentation.snapshot.renderToken
        let builds = app.transcriptPresentation.snapshotBuildCountForTesting
        for _ in 0..<10 {
            app.handleEventForTesting(["type": "token", "text": "stream "])
            app.flushPendingTokens()
        }
        XCTAssertEqual(app.transcriptPresentation.snapshot.renderToken, token)
        XCTAssertEqual(app.transcriptPresentation.snapshotBuildCountForTesting, builds)
    }

    func testLateSessionInfoDoesNotChangeSelectedConversationOrItsMetadata() {
        let app = AppModel(startImmediately: false)
        app.installTranscriptSession("selected", blocks: [ChatBlock(kind: .assistant, text: "Selected")])
        let snapshot = app.transcriptPresentation.snapshot
        var event = sessionInfoFixture("old")
        event["type"] = "session_info"
        app.handleEventForTesting(event)
        XCTAssertEqual(app.transcriptPresentation.snapshot, snapshot)
        XCTAssertNil(app.sessionInfo, "A stale identity must be rejected before any session metadata is applied")
    }

    func testInitialServerSessionInfoNamesDraftWithoutClearingItsContentOrToken() {
        BackendStub.reset()
        let app = AppModel(startImmediately: false, backendOverride: stubbedBackendService())
        defer { app.knowledge.cancelAll(); app.agentInstructions.cancelAll(); app.eventAutomations.stop() }
        app.appliedWorkspacePath = "/tmp"
        app.blocks = [ChatBlock(kind: .user, text: "Draft waiting for server identity")]
        let token = app.transcriptPresentation.snapshot.renderToken
        var event = sessionInfoFixture("assigned")
        event["type"] = "session_info"
        app.handleEventForTesting(event)
        XCTAssertEqual(app.currentSessionID, "assigned")
        XCTAssertEqual(app.blocks.map(\.text), ["Draft waiting for server identity"])
        XCTAssertEqual(app.transcriptPresentation.snapshot.renderToken, token)
    }

    func testRetryBranchPublishesNewIdentityWithRetainedPrefixWithoutAnEmptyIntermediate() {
        let app = AppModel(startImmediately: false)
        let request = ChatBlock(kind: .user, text: "Retry this request")
        app.installTranscriptSession("original", blocks: [
            request, ChatBlock(kind: .assistant, text: "Previous response"),
        ])
        _ = app.beginTranscriptTransition(
            source: app.backend, reasons: ["retry"], acceptsSocketAcknowledgement: true
        )
        var published: [TranscriptPresentationSnapshot] = []
        let subscription = app.transcriptPresentation.$snapshot.dropFirst().sink { published.append($0) }
        app.handleEventForTesting([
            "type": "session_started", "reason": "retry", "session_info": sessionInfoFixture("branch"),
        ])
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.sessionID, "branch")
        XCTAssertEqual(published.first?.blocks, [request])
        XCTAssertEqual(app.currentSessionID, "branch")
        withExtendedLifetime(subscription) {}
    }

    private func sessionInfoFixture(_ id: String) -> [String: Any] {
        [
            "model": "fixture", "host": "http://127.0.0.1:1", "cwd": "/tmp",
            "session": "/tmp/\(id).jsonl", "session_id": id, "messages": 0,
            "approx_tokens": 0, "prompt_tokens": 0, "completion_tokens": 0,
            "max_iterations": 40, "has_project_context": false,
            "permissions": ["skip_all": false, "allowed": []],
        ]
    }

    func testSnapshotPrecomputesPresentationLookupsAndActionOwnership() {
        let user = ChatBlock(kind: .user, text: "Review the extraction")
        let assistant = ChatBlock(
            kind: .assistant,
            text: "The ownership boundary is sound.",
            reasoningText: "Checking invalidation paths"
        )
        let model = TranscriptPresentationModel()

        model.replaceBlocks([user, assistant])

        let snapshot = model.snapshot
        XCTAssertEqual(snapshot.blocksByID[user.id], user)
        XCTAssertEqual(snapshot.blocksByID[assistant.id], assistant)
        XCTAssertEqual(snapshot.items.count, 3)
        XCTAssertTrue(snapshot.assistantMarkerItemIDs.contains(snapshot.items[1].id))
        XCTAssertTrue(snapshot.assistantActionItemIDs.contains(snapshot.items[2].id))
        XCTAssertFalse(snapshot.hasPendingPermission)
    }

    func testBatchedBlockMutationBuildsAndPublishesExactlyOnce() {
        let model = TranscriptPresentationModel()
        model.replaceBlocks([
            ChatBlock(kind: .assistant, text: "", isStreaming: true),
        ])
        let baseline = model.snapshotBuildCountForTesting
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }

        model.updateBlocks {
            $0[0].text = "Finished"
            $0[0].reasoningText = "Verified"
            $0[0].isStreaming = false
        }

        XCTAssertEqual(model.snapshotBuildCountForTesting, baseline + 1)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(model.snapshot.blocks[0].text, "Finished")
        XCTAssertEqual(model.snapshot.blocks[0].reasoningText, "Verified")
        XCTAssertFalse(model.snapshot.blocks[0].isStreaming)
        withExtendedLifetime(subscription) {}
    }

    func testRepeatedSnapshotReadsAndEquivalentCommitsDoNotRebuild() {
        let block = ChatBlock(kind: .user, text: "Stable")
        let model = TranscriptPresentationModel()
        model.replaceBlocks([block])
        let baseline = model.snapshotBuildCountForTesting

        for _ in 0..<20 {
            _ = model.snapshot.items
            _ = model.snapshot.blocksByID[block.id]
        }
        model.replaceBlocks([block])
        model.setPresentationVisibility(toolActivity: .collapsed, thinking: .collapsed)

        XCTAssertEqual(model.snapshotBuildCountForTesting, baseline)
    }

    func testVisibilityCommitRebuildsOneCompleteProjection() {
        let tool = ToolPayload(
            toolID: "tool-1",
            tool: "read_file",
            summary: "Read one file",
            detail: "README.md",
            status: .done
        )
        let model = TranscriptPresentationModel()
        model.replaceBlocks([ChatBlock(kind: .tool, tool: tool)])
        let baseline = model.snapshotBuildCountForTesting
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }

        model.setPresentationVisibility(toolActivity: .verbose, thinking: .expanded)

        XCTAssertEqual(model.snapshotBuildCountForTesting, baseline + 1)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(model.snapshot.toolActivityVisibility, .verbose)
        XCTAssertEqual(model.snapshot.thinkingVisibility, .expanded)
        guard case .block(let block) = model.snapshot.items.first else {
            return XCTFail("Verbose tool activity must expose the source block")
        }
        XCTAssertEqual(block.tool?.toolID, "tool-1")
        withExtendedLifetime(subscription) {}
    }

    func testUnrelatedAppAndChildPublicationsDoNotRebuildTranscript() {
        let app = AppModel(startImmediately: false)
        app.blocks = [ChatBlock(kind: .user, text: "Owned by transcript")]
        let baseline = app.transcriptPresentation.snapshotBuildCountForTesting

        app.backendLogHint = "changed"
        app.toastCenter.objectWillChange.send()

        XCTAssertEqual(app.transcriptPresentation.snapshotBuildCountForTesting, baseline)
    }

    func testOrdinaryTranscriptChangesDoNotPublishAppModel() {
        let app = AppModel(startImmediately: false)
        var appPublications = 0
        let subscription = app.objectWillChange.sink { appPublications += 1 }

        app.blocks.append(ChatBlock(kind: .user, text: "Isolated publication"))

        XCTAssertEqual(appPublications, 0)
        XCTAssertEqual(app.transcriptPresentation.snapshot.blocks.count, 1)
        withExtendedLifetime(subscription) {}
    }

    func testPendingPermissionCompatibilityPublishesOnlyWhenAvailabilityChanges() {
        let app = AppModel(startImmediately: false)
        let tool = ToolPayload(
            toolID: "tool-1",
            tool: "shell",
            summary: "Run command",
            detail: "swift test",
            status: .awaitingPermission,
            requestID: "request-1"
        )
        var appPublications = 0
        let subscription = app.objectWillChange.sink { appPublications += 1 }

        app.blocks = [ChatBlock(kind: .tool, tool: tool)]
        let permissionPublicationCount = appPublications
        app.blocks[0].tool?.summary = "Run the focused tests"

        XCTAssertTrue(app.hasPendingPermission)
        XCTAssertEqual(permissionPublicationCount, 1)
        XCTAssertEqual(appPublications, permissionPublicationCount)

        app.blocks[0].tool?.status = .done
        XCTAssertFalse(app.hasPendingPermission)
        XCTAssertEqual(appPublications, permissionPublicationCount + 1)
        withExtendedLifetime(subscription) {}
    }

    func testBenchmarkInitialConstructionWithLargeTranscriptFixture() {
        let fixture = benchmarkFixture()

        measure(metrics: [XCTClockMetric()]) {
            let model = TranscriptPresentationModel()
            model.replaceBlocks(fixture)
            _ = model.snapshot.items.count
        }
    }

    func testBenchmarkVisibilityUpdatesWithLargeTranscriptFixture() {
        let model = TranscriptPresentationModel()
        model.replaceBlocks(benchmarkFixture())
        var expanded = false

        measure(metrics: [XCTClockMetric()]) {
            expanded.toggle()
            model.setPresentationVisibility(
                toolActivity: expanded ? .verbose : .collapsed,
                thinking: expanded ? .expanded : .collapsed
            )
            _ = model.snapshot.assistantActionItemIDs.count
        }
    }

    private func benchmarkFixture() -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        blocks.reserveCapacity(500)
        for index in 0..<125 {
            blocks.append(ChatBlock(kind: .user, text: "Request \(index)"))
            blocks.append(ChatBlock(
                kind: .assistant,
                text: "Commentary for request \(index)",
                assistantPhase: .commentary,
                reasoningText: "Inspecting dependency \(index)"
            ))
            blocks.append(ChatBlock(kind: .tool, tool: ToolPayload(
                toolID: "tool-\(index)",
                tool: "read_file",
                summary: "Read source \(index)",
                detail: "Source\(index).swift",
                status: .done
            )))
            blocks.append(ChatBlock(
                kind: .assistant,
                text: "Final answer for request \(index)",
                assistantPhase: .finalAnswer
            ))
        }
        return blocks
    }
}
