import Combine
import XCTest

@testable import Locus

@MainActor
final class TranscriptPresentationModelTests: XCTestCase {
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
