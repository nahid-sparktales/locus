import Combine
import Foundation
import os

struct TranscriptPresentationSnapshot: Equatable {
    let blocks: [ChatBlock]
    let blocksByID: [UUID: ChatBlock]
    let items: [TranscriptPresentationItem]
    let assistantMarkerItemIDs: Set<TranscriptPresentationItem.ID>
    let assistantActionItemIDs: Set<TranscriptPresentationItem.ID>
    let toolActivityVisibility: ToolActivityVisibility
    let thinkingVisibility: ThinkingVisibility
    let hasPendingPermission: Bool

    var isEmpty: Bool { blocks.isEmpty }

    static let empty = TranscriptPresentationSnapshot(
        blocks: [],
        blocksByID: [:],
        items: [],
        assistantMarkerItemIDs: [],
        assistantActionItemIDs: [],
        toolActivityVisibility: .collapsed,
        thinkingVisibility: .collapsed,
        hasPendingPermission: false
    )
}

/// Authoritative transcript input and its immutable presentation projection.
/// Construction happens only at explicit commit points, never while SwiftUI
/// evaluates a body because some unrelated AppModel property changed.
@MainActor
final class TranscriptPresentationModel: ObservableObject {
    private struct State: Equatable {
        var blocks: [ChatBlock] = []
        var toolActivityVisibility = ToolActivityVisibility.collapsed
        var thinkingVisibility = ThinkingVisibility.collapsed
    }

    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "io.sparktales.locus",
        category: "Transcript Presentation"
    )

    @Published private(set) var snapshot = TranscriptPresentationSnapshot.empty

    /// Deterministic structural metric used by tests. Timings stay advisory;
    /// this counter is the CI gate for accidental reconstruction.
#if DEBUG
    private(set) var snapshotBuildCountForTesting = 0
#endif

    private var state = State()
    private var pendingPermissionDidChange: (Bool) -> Void = { _ in }

    init() {
        rebuildSnapshot()
    }

    func configure(
        toolActivityVisibility: ToolActivityVisibility,
        thinkingVisibility: ThinkingVisibility,
        pendingPermissionDidChange: @escaping (Bool) -> Void
    ) {
        self.pendingPermissionDidChange = pendingPermissionDidChange
        setPresentationVisibility(
            toolActivity: toolActivityVisibility,
            thinking: thinkingVisibility
        )
    }

    func replaceBlocks(_ blocks: [ChatBlock]) {
        commit { $0.blocks = blocks }
    }

    func updateBlocks(_ update: (inout [ChatBlock]) -> Void) {
        commit { state in update(&state.blocks) }
    }

    func setPresentationVisibility(
        toolActivity: ToolActivityVisibility,
        thinking: ThinkingVisibility
    ) {
        commit { state in
            state.toolActivityVisibility = toolActivity
            state.thinkingVisibility = thinking
        }
    }

    @discardableResult
    private func commit(_ update: (inout State) -> Void) -> Bool {
        let previous = state
        update(&state)
        guard state != previous else { return false }
        rebuildSnapshot()
        return true
    }

    private func rebuildSnapshot() {
        let signpostID = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval(
            "Build Transcript Snapshot",
            id: signpostID,
            "blocks=\(self.state.blocks.count)"
        )
        defer { Self.signposter.endInterval("Build Transcript Snapshot", interval) }

#if DEBUG
        snapshotBuildCountForTesting += 1
#endif
        let previousPendingPermission = snapshot.hasPendingPermission
        snapshot = Self.makeSnapshot(state: state)
        if snapshot.hasPendingPermission != previousPendingPermission {
            pendingPermissionDidChange(snapshot.hasPendingPermission)
        }
    }

    private static func makeSnapshot(state: State) -> TranscriptPresentationSnapshot {
        let items = state.blocks.isEmpty ? [] : TranscriptPresentation.items(
            from: state.blocks,
            toolVisibility: state.toolActivityVisibility,
            thinkingVisibility: state.thinkingVisibility
        )
        return TranscriptPresentationSnapshot(
            blocks: state.blocks,
            blocksByID: Dictionary(
                state.blocks.map { ($0.id, $0) },
                uniquingKeysWith: { existing, _ in existing }
            ),
            items: items,
            assistantMarkerItemIDs: TranscriptPresentation.assistantMarkerItemIDs(in: items),
            assistantActionItemIDs: TranscriptPresentation.assistantActionItemIDs(in: items),
            toolActivityVisibility: state.toolActivityVisibility,
            thinkingVisibility: state.thinkingVisibility,
            hasPendingPermission: state.blocks.contains {
                $0.tool?.status == .awaitingPermission
            }
        )
    }
}
