import Combine
import Foundation
import os

/// Viewport work belongs to one logical conversation and one committed
/// presentation. A server-assigned name is deliberately not scroll identity.
struct TranscriptRenderToken: Equatable {
    let sessionGeneration: UInt64
    let contentRevision: UInt64
    let tailID: TranscriptPresentationItem.ID?
}

/// An async load must still own both the conversation and the most recent
/// request when it returns, including two requests for the same conversation.
struct TranscriptSessionLoadToken: Equatable {
    let sessionGeneration: UInt64
    let requestRevision: UInt64
}

enum TranscriptScrollTarget: Hashable {
    case item(UInt64, TranscriptPresentationItem.ID)
    case end(UInt64)
}

/// The lazy stack's indexed, session-scoped rows are built once per content
/// commit. Layout, tab changes and selection can reuse the same array storage.
struct TranscriptRenderRow: Identifiable, Equatable {
    let index: Int
    let item: TranscriptPresentationItem
    let generation: UInt64
    var id: TranscriptScrollTarget { .item(generation, item.id) }
}

enum TranscriptPanelLayoutPolicy {
    /// A long answer can contain hundreds of native text leaves even when
    /// history has only a few rows. Avoid rewrapping them at every spring frame.
    static func prefersImmediateLayout(blocks: [ChatBlock], itemCount: Int) -> Bool {
        if itemCount >= 100 { return true }
        var bytes = 0
        for block in blocks {
            bytes += block.text.utf8.count
            bytes += block.reasoningText?.utf8.count ?? 0
            bytes += block.tool?.detail.utf8.count ?? 0
            if bytes >= 16_384 { return true }
        }
        return false
    }
}

struct TranscriptPresentationSnapshot: Equatable {
    let sessionID: String
    let renderToken: TranscriptRenderToken
    let blocks: [ChatBlock]
    let blocksByID: [UUID: ChatBlock]
    let items: [TranscriptPresentationItem]
    let rows: [TranscriptRenderRow]
    let prefersImmediatePanelLayout: Bool
    let assistantMarkerItemIDs: Set<TranscriptPresentationItem.ID>
    let assistantActionItemIDs: Set<TranscriptPresentationItem.ID>
    let toolActivityVisibility: ToolActivityVisibility
    let thinkingVisibility: ThinkingVisibility
    let hasPendingPermission: Bool

    var isEmpty: Bool { blocks.isEmpty }

    static let empty = TranscriptPresentationSnapshot(
        sessionID: "",
        renderToken: TranscriptRenderToken(sessionGeneration: 0, contentRevision: 0, tailID: nil),
        blocks: [],
        blocksByID: [:],
        items: [],
        rows: [],
        prefersImmediatePanelLayout: false,
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
        var sessionID = ""
        var sessionGeneration: UInt64 = 0
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
    private var contentRevision: UInt64 = 0
    private var loadRevision: UInt64 = 0
    private(set) var loadingSessionID: String?
    var sessionOwnershipToken: TranscriptSessionLoadToken {
        TranscriptSessionLoadToken(sessionGeneration: state.sessionGeneration, requestRevision: loadRevision)
    }
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

    /// Installs identity and content in a single published snapshot. Reusing
    /// a backend ID for a fresh chat still needs a fresh logical generation.
    func installSession(_ sessionID: String, blocks: [ChatBlock], forceNewGeneration: Bool = false) {
        loadRevision &+= 1
        loadingSessionID = nil
        commit { state in
            if state.sessionID != sessionID || forceNewGeneration {
                state.sessionGeneration &+= 1
            }
            state.sessionID = sessionID
            state.blocks = blocks
        }
    }

    func beginSession(_ sessionID: String) {
        guard state.sessionID != sessionID else { return }
        installSession(sessionID, blocks: [])
    }

    /// A rename of the same logical chat preserves content, selection IDs and
    /// its render token. No presentation arrays are reconstructed for a name.
    func rekeySession(from previousID: String, to sessionID: String) {
        guard state.sessionID == previousID, previousID != sessionID else { return }
        state.sessionID = sessionID
        if loadingSessionID == previousID { loadingSessionID = sessionID }
        let previous = snapshot
        snapshot = TranscriptPresentationSnapshot(
            sessionID: sessionID,
            renderToken: previous.renderToken,
            blocks: previous.blocks,
            blocksByID: previous.blocksByID,
            items: previous.items,
            rows: previous.rows,
            prefersImmediatePanelLayout: previous.prefersImmediatePanelLayout,
            assistantMarkerItemIDs: previous.assistantMarkerItemIDs,
            assistantActionItemIDs: previous.assistantActionItemIDs,
            toolActivityVisibility: previous.toolActivityVisibility,
            thinkingVisibility: previous.thinkingVisibility,
            hasPendingPermission: previous.hasPendingPermission
        )
    }

    func beginSessionLoad(_ sessionID: String) -> TranscriptSessionLoadToken {
        beginSession(sessionID)
        loadRevision &+= 1
        loadingSessionID = sessionID
        return TranscriptSessionLoadToken(
            sessionGeneration: state.sessionGeneration, requestRevision: loadRevision
        )
    }

    func ownsSessionLoad(_ token: TranscriptSessionLoadToken) -> Bool {
        token.sessionGeneration == state.sessionGeneration && token.requestRevision == loadRevision
    }

    func cancelSessionLoad(_ token: TranscriptSessionLoadToken) {
        guard ownsSessionLoad(token) else { return }
        loadRevision &+= 1
        loadingSessionID = nil
    }

    @discardableResult
    func completeSessionLoad(
        _ token: TranscriptSessionLoadToken, sessionID: String, blocks: [ChatBlock]
    ) -> Bool {
        guard ownsSessionLoad(token), loadingSessionID != nil else { return false }
        loadingSessionID = nil
        // The response may assign a server ID to this same requested chat.
        // Keep the load lease valid for other awaited metadata in its caller.
        commit { state in
            state.sessionID = sessionID
            state.blocks = blocks
        }
        return true
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
        contentRevision &+= 1
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
        snapshot = Self.makeSnapshot(state: state, revision: contentRevision)
        if snapshot.hasPendingPermission != previousPendingPermission {
            pendingPermissionDidChange(snapshot.hasPendingPermission)
        }
    }

    private static func makeSnapshot(state: State, revision: UInt64) -> TranscriptPresentationSnapshot {
        let items = state.blocks.isEmpty ? [] : TranscriptPresentation.items(
            from: state.blocks,
            toolVisibility: state.toolActivityVisibility,
            thinkingVisibility: state.thinkingVisibility
        )
        return TranscriptPresentationSnapshot(
            sessionID: state.sessionID,
            renderToken: TranscriptRenderToken(
                sessionGeneration: state.sessionGeneration,
                contentRevision: revision,
                tailID: items.last?.id
            ),
            blocks: state.blocks,
            blocksByID: Dictionary(
                state.blocks.map { ($0.id, $0) },
                uniquingKeysWith: { existing, _ in existing }
            ),
            items: items,
            rows: items.enumerated().map {
                TranscriptRenderRow(index: $0.offset, item: $0.element, generation: state.sessionGeneration)
            },
            prefersImmediatePanelLayout: TranscriptPanelLayoutPolicy.prefersImmediateLayout(
                blocks: state.blocks, itemCount: items.count
            ),
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
