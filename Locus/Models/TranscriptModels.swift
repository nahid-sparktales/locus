import Combine
import Foundation

struct AppToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let systemImage: String
    let actionTitle: String?

    init(
        message: String,
        systemImage: String = "checkmark",
        actionTitle: String? = nil
    ) {
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
    }
}

struct StreamingReplySnapshot: Equatable {
    var id: UUID?
    var text = ""
    var reasoning = ""
    var reasoningSections: [String] = []
    var turnCharacterCount = 0

    var isActive: Bool { id != nil }
}

/// Mutable, append-oriented storage for one live response. The UI receives a
/// cheap revision publication; a value snapshot is materialized only when a
/// consumer actually renders or finalizes the response.
final class StreamingReplyAccumulator {
    private(set) var id: UUID?
    private(set) var text = ""
    private(set) var directReasoning = ""
    private(set) var reasoningSections: [String] = []
    private(set) var turnCharacterCount = 0

    func begin(id: UUID) {
        self.id = id
        text.removeAll(keepingCapacity: true)
        directReasoning.removeAll(keepingCapacity: true)
        reasoningSections.removeAll(keepingCapacity: true)
    }

    @discardableResult
    func append(
        text textDelta: String,
        reasoning reasoningDelta: String,
        sectionDeltas: [Int: String] = [:]
    ) -> Bool {
        guard id != nil,
              !textDelta.isEmpty || !reasoningDelta.isEmpty || !sectionDeltas.isEmpty
        else { return false }
        text += textDelta
        directReasoning += reasoningDelta
        turnCharacterCount += textDelta.count + reasoningDelta.count
        for index in sectionDeltas.keys.sorted() {
            let safeIndex = max(index, 0)
            while reasoningSections.count <= safeIndex {
                reasoningSections.append("")
            }
            let delta = sectionDeltas[index] ?? ""
            reasoningSections[safeIndex] += delta
            turnCharacterCount += delta.count
        }
        return true
    }

    func snapshot() -> StreamingReplySnapshot {
        let sectionReasoning = reasoningSections.joined(separator: "\n\n")
        return StreamingReplySnapshot(
            id: id,
            text: text,
            reasoning: sectionReasoning.isEmpty ? directReasoning : sectionReasoning,
            reasoningSections: reasoningSections,
            turnCharacterCount: turnCharacterCount
        )
    }

    func finish(
        authoritativeText: String?,
        authoritativeReasoningSections: [String]?
    ) -> StreamingReplySnapshot {
        var result = snapshot()
        if let authoritativeText { result.text = authoritativeText }
        if let authoritativeReasoningSections {
            result.reasoningSections = authoritativeReasoningSections
            result.reasoning = authoritativeReasoningSections.joined(separator: "\n\n")
        }
        id = nil
        text = ""
        directReasoning = ""
        reasoningSections = []
        return result
    }

    func reset() {
        id = nil
        text = ""
        directReasoning = ""
        reasoningSections = []
        turnCharacterCount = 0
    }
}

/// Token-level state lives outside AppModel's published transcript array.
/// Consequently an append invalidates only the active row and token label,
/// rather than every historical row, sidebar and composer.
@MainActor
final class StreamingReplyState: ObservableObject {
    @Published private(set) var revision: UInt = 0
    private let accumulator = StreamingReplyAccumulator()

    var snapshot: StreamingReplySnapshot { accumulator.snapshot() }

    func begin(id: UUID) {
        accumulator.begin(id: id)
        revision &+= 1
        locusPerformanceSignposter.emitEvent("Publish Streaming Revision", "begin")
    }

    func append(text: String, reasoning: String) {
        append(text: text, reasoning: reasoning, reasoningSections: [:])
    }

    func append(
        text: String,
        reasoning: String,
        reasoningSections: [Int: String]
    ) {
        guard accumulator.append(
            text: text,
            reasoning: reasoning,
            sectionDeltas: reasoningSections
        ) else { return }
        revision &+= 1
        locusPerformanceSignposter.emitEvent(
            "Publish Streaming Revision",
            "revision=\(self.revision)"
        )
    }

    func appendReasoning(_ text: String, sectionIndex: Int) {
        append(text: "", reasoning: "", reasoningSections: [sectionIndex: text])
    }

    func finish(
        id: UUID,
        authoritativeText: String? = nil,
        authoritativeReasoningSections: [String]? = nil
    ) -> StreamingReplySnapshot? {
        guard accumulator.id == id else { return nil }
        let finished = accumulator.finish(
            authoritativeText: authoritativeText,
            authoritativeReasoningSections: authoritativeReasoningSections
        )
        revision &+= 1
        locusPerformanceSignposter.emitEvent("Publish Streaming Revision", "finish")
        return finished
    }

    func resetTurn() {
        accumulator.reset()
        revision &+= 1
        locusPerformanceSignposter.emitEvent("Publish Streaming Revision", "reset")
    }
}

struct HealthResponse: Codable {
    let ok: Bool
    let version: String?
    let ollama: Bool
    let host: String?
    let model: String?
    let error: String?
    let updateAvailable: Bool?
    var capabilities: [String: Bool]? = nil
}

struct HistoryMessage: Codable {
    let role: String
    let content: String
    let name: String?
    let reasoning: String?
    let reasoningSections: [String]?
    let phase: AssistantPhase?
    let itemID: String?
    let runID: String?
    let eventTrigger: EventTranscriptContext?

    var teamRunID: String? { runID }

    private enum CodingKeys: String, CodingKey {
        case role, content, name, reasoning, phase
        case reasoningSections = "reasoning_sections"
        case itemID = "item_id"
        case runID = "run_id"
        case legacyTeamRunID = "team_run_id"
        case eventTrigger = "event_trigger"
    }

    // A single null-content tool message must not fail an entire resume.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        reasoning = try? container.decodeIfPresent(String.self, forKey: .reasoning)
        reasoningSections = try? container.decodeIfPresent([String].self, forKey: .reasoningSections)
        phase = try? container.decodeIfPresent(AssistantPhase.self, forKey: .phase)
        itemID = try? container.decodeIfPresent(String.self, forKey: .itemID)
        runID = (try? container.decodeIfPresent(String.self, forKey: .runID))
            ?? (try? container.decodeIfPresent(String.self, forKey: .legacyTeamRunID))
        eventTrigger = try? container.decodeIfPresent(
            EventTranscriptContext.self, forKey: .eventTrigger
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(reasoningSections, forKey: .reasoningSections)
        try container.encodeIfPresent(phase, forKey: .phase)
        try container.encodeIfPresent(itemID, forKey: .itemID)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encodeIfPresent(eventTrigger, forKey: .eventTrigger)
    }
}

enum ToolStatus: String, Codable {
    case awaitingPermission
    case running
    case done
    case error
    case denied
}

struct ToolPayload: Codable, Hashable {
    var toolID: String
    var tool: String
    var summary: String
    var detail: String
    var status: ToolStatus
    var requestID: String?
    var result: String?
}

/// The status a compact tool-activity row presents for a group. Active work
/// wins over earlier failures, while terminal groups preserve the most useful
/// attention state instead of reading as successfully complete.
enum ToolActivityAggregateStatus: Equatable {
    case awaitingPermission
    case running
    case error
    case denied
    case done

    init(tools: [ToolPayload]) {
        if tools.contains(where: { $0.status == .awaitingPermission }) {
            self = .awaitingPermission
        } else if tools.contains(where: { $0.status == .running }) {
            self = .running
        } else if tools.contains(where: { $0.status == .error }) {
            self = .error
        } else if tools.contains(where: { $0.status == .denied }) {
            self = .denied
        } else {
            self = .done
        }
    }
}

/// Human-readable compact activity for one adjacent run of tools. The detailed
/// provider summary remains available after disclosure; this formatter keeps
/// the transcript's resting state quiet and familiar.
struct CompactToolActivitySummary: Equatable {
    let title: String
    let systemImage: String

    init(tools: [ToolPayload]) {
        var order: [Family] = []
        var counts: [Family: Int] = [:]
        for tool in tools {
            let family = Family(tool: tool)
            if counts[family] == nil { order.append(family) }
            counts[family, default: 0] += 1
        }

        let phrases = order.map { family in
            family.phrase(count: counts[family, default: 1])
        }
        let shown = phrases.prefix(3)
        var pieces = shown.enumerated().map { index, phrase in
            index == 0 ? phrase : phrase.lowercasingFirstCharacter
        }
        if phrases.count > shown.count {
            pieces.append("and \(phrases.count - shown.count) more")
        }
        title = pieces.joined(separator: ", ").nilIfEmpty ?? "Used tools"
        systemImage = order.first?.systemImage ?? "wrench.and.screwdriver"
    }

    private enum Family: Hashable {
        case command
        case readFiles
        case editFiles
        case browse
        case question
        case plan
        case image
        case fallback(String)

        init(tool: ToolPayload) {
            let name = tool.tool.lowercased()
            let leaf = name
                .split(whereSeparator: { ".:/".contains($0) })
                .last
                .map(String.init) ?? name

            if name.contains("request_user_input") || name.contains("ask_question")
                || name.contains("user_question") {
                self = .question
            } else if name.contains("update_plan") || name.contains("todo_write")
                        || name.contains("submit_plan") {
                self = .plan
            } else if name.contains("imagegen") || name.contains("image_gen") {
                self = .image
            } else if name.contains("browser") || name.contains("web_fetch")
                        || name.contains("web__run") || name.contains("web.run") {
                self = .browse
            } else if ["bash", "exec", "exec_command", "write_stdin", "background_service"]
                        .contains(leaf) || name.contains("terminal") {
                self = .command
            } else if ["write_file", "edit_file", "multi_edit", "apply_patch"]
                        .contains(leaf) || name.contains("apply_patch") {
                self = .editFiles
            } else if ["read_file", "list_dir", "glob", "grep", "find", "search"]
                        .contains(leaf) || name.contains("read_file") {
                self = .readFiles
            } else {
                self = .fallback(Self.fallbackTitle(tool))
            }
        }

        var systemImage: String {
            switch self {
            case .command: "terminal"
            case .readFiles: "magnifyingglass"
            case .editFiles: "square.and.pencil"
            case .browse: "globe"
            case .question: "questionmark.circle"
            case .plan: "checklist"
            case .image: "photo"
            case .fallback: "wrench.and.screwdriver"
            }
        }

        func phrase(count: Int) -> String {
            switch self {
            case .command: count == 1 ? "Ran command" : "Ran commands"
            case .readFiles: "Read files"
            case .editFiles: count == 1 ? "Edited file" : "Edited files"
            case .browse: "Browsed"
            case .question: count == 1 ? "Asked a question" : "Asked \(count) questions"
            case .plan: "Updated plan"
            case .image: count == 1 ? "Created image" : "Created images"
            case .fallback(let title): title
            }
        }

        private static func fallbackTitle(_ tool: ToolPayload) -> String {
            let rendered = MarkdownPlainTextRenderer.render(tool.summary)
            let normalized = rendered
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !normalized.isEmpty else { return "Used tools" }
            return String(normalized.prefix(96))
        }
    }
}

private extension String {
    var lowercasingFirstCharacter: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

struct ChatBlock: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case user
        case assistant
        case tool
        case note
        case error
    }

    var id: UUID
    var kind: Kind
    var text: String
    /// Codex App Server phase for visible assistant-message items. A missing
    /// value is a legacy answer and therefore behaves as final output.
    var assistantPhase: AssistantPhase?
    /// Provider item identity used to reconcile starts, deltas, duplicate
    /// completions, and authoritative final content without guessing from text.
    var sourceItemID: String?
    /// Native provider reasoning, kept separate from visible answer text.
    /// Optional decoding keeps existing checkpoints readable.
    var reasoningText: String?
    /// Ordered Codex reasoning summaries. The legacy flattened field remains
    /// encoded beside these sections so older checkpoints stay readable.
    var reasoningSections: [String]?
    var isStreaming: Bool
    var tool: ToolPayload?
    /// Present only for the quiet end-of-turn note rendered after a run.
    /// Optional keeps checkpoints written by older Locus releases decodable.
    var completion: TurnCompletion?
    /// Links a request to its durable run. Ordinary Solo rows remain unchanged
    /// because their activity panel stays hidden until delegation begins.
    var runID: String?
    /// Present on an automation-created user turn. Kept out of provider
    /// history and used only to render trusted configuration separately from
    /// untrusted external content.
    var eventTrigger: EventTranscriptContext?
    var teamRunID: String? {
        get { runID }
        set { runID = newValue }
    }
    /// Position in the restored message array, so a cross-session search hit
    /// can address this block even after empty messages were dropped.
    /// Optional decoding keeps existing checkpoints.
    var historyIndex: Int?

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, assistantPhase, sourceItemID
        case reasoningText, reasoningSections, isStreaming, tool, completion, historyIndex
        case runID = "run_id"
        case eventTrigger
        case legacyRunID = "runID"
        case legacyTeamRunID = "teamRunID"
    }

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String = "",
        assistantPhase: AssistantPhase? = nil,
        sourceItemID: String? = nil,
        reasoningText: String? = nil,
        reasoningSections: [String]? = nil,
        isStreaming: Bool = false,
        tool: ToolPayload? = nil,
        completion: TurnCompletion? = nil,
        runID: String? = nil,
        eventTrigger: EventTranscriptContext? = nil,
        teamRunID: String? = nil,
        historyIndex: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.assistantPhase = assistantPhase
        self.sourceItemID = sourceItemID
        self.reasoningText = reasoningText
        self.reasoningSections = reasoningSections
        self.isStreaming = isStreaming
        self.tool = tool
        self.completion = completion
        self.runID = runID ?? teamRunID
        self.eventTrigger = eventTrigger
        self.historyIndex = historyIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        assistantPhase = try container.decodeIfPresent(AssistantPhase.self, forKey: .assistantPhase)
        sourceItemID = try container.decodeIfPresent(String.self, forKey: .sourceItemID)
        reasoningText = try container.decodeIfPresent(String.self, forKey: .reasoningText)
        reasoningSections = try container.decodeIfPresent([String].self, forKey: .reasoningSections)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        tool = try container.decodeIfPresent(ToolPayload.self, forKey: .tool)
        completion = try container.decodeIfPresent(TurnCompletion.self, forKey: .completion)
        runID = try container.decodeIfPresent(String.self, forKey: .runID)
            ?? container.decodeIfPresent(String.self, forKey: .legacyRunID)
            ?? container.decodeIfPresent(String.self, forKey: .legacyTeamRunID)
        eventTrigger = try container.decodeIfPresent(
            EventTranscriptContext.self, forKey: .eventTrigger
        )
        historyIndex = try container.decodeIfPresent(Int.self, forKey: .historyIndex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(assistantPhase, forKey: .assistantPhase)
        try container.encodeIfPresent(sourceItemID, forKey: .sourceItemID)
        let compatibleReasoning = reasoningText
            ?? reasoningSections?.joined(separator: "\n\n").nilIfEmpty
        try container.encodeIfPresent(compatibleReasoning, forKey: .reasoningText)
        try container.encodeIfPresent(reasoningSections, forKey: .reasoningSections)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encodeIfPresent(tool, forKey: .tool)
        try container.encodeIfPresent(completion, forKey: .completion)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encodeIfPresent(eventTrigger, forKey: .eventTrigger)
        try container.encodeIfPresent(historyIndex, forKey: .historyIndex)
    }

    var resolvedReasoningSections: [String] {
        let sections = (reasoningSections ?? []).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !sections.isEmpty { return sections }
        guard let reasoningText,
              !reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        return [reasoningText]
    }
}

/// A stable presentation-only projection of transcript blocks. Assistant text,
/// provider reasoning, inline thinking, and adjacent tool runs keep their
/// source order while the stored blocks remain untouched.
enum TranscriptPresentationItem: Identifiable, Equatable {
    enum ID: Hashable {
        case block(UUID)
        case assistantSegment(AssistantPresentationSegment.ID)
        case toolGroup(UUID)
        case thinkingGroup(ThinkingPresentationGroupID)

        /// A stable string name for this row, used to scope selection spans.
        ///
        /// Position cannot do that job: rows are created and destroyed as the
        /// transcript scrolls, so anything index-based invalidates a live
        /// selection the moment the list realizes differently.
        var stableKey: String {
            switch self {
            case .block(let id):
                "block:\(id.uuidString)"
            case .assistantSegment(let id):
                "segment:\(id.sourceBlockID.uuidString):\(id.ordinal)"
            case .toolGroup(let id):
                "toolGroup:\(id.uuidString)"
            case .thinkingGroup(let id):
                "thinking:\(id.sourceBlockID.uuidString):\(id.ordinal)"
            }
        }
    }

    case block(ChatBlock)
    case assistantSegment(AssistantPresentationSegment)
    case toolGroup(id: UUID, tools: [ToolPayload])
    case thinkingGroup(id: ThinkingPresentationGroupID, entries: [ThinkingPresentationEntry])

    var id: ID {
        switch self {
        case .block(let block): .block(block.id)
        case .assistantSegment(let segment): .assistantSegment(segment.id)
        case .toolGroup(let id, _): .toolGroup(id)
        case .thinkingGroup(let id, _): .thinkingGroup(id)
        }
    }

    /// The persisted transcript block represented by this row. Derived
    /// assistant segments and activity groups retain their source identity so
    /// search and overview jumps never need to infer it from rendered text.
    var sourceBlockIDs: Set<UUID> {
        switch self {
        case .block(let block): [block.id]
        case .assistantSegment(let segment): [segment.sourceBlock.id]
        case .toolGroup(let id, _): [id]
        case .thinkingGroup(let id, _): [id.sourceBlockID]
        }
    }
}

/// One visible assistant segment projected from a persisted response. A single
/// block can yield several segments when inline thinking appears between
/// visible text, so identity includes the source-local ordinal.
struct AssistantPresentationSegment: Equatable {
    struct ID: Hashable {
        let sourceBlockID: UUID
        let ordinal: Int
    }

    let id: ID
    let sourceBlock: ChatBlock
    let text: String

    var displayBlock: ChatBlock {
        var block = sourceBlock
        block.text = text
        block.reasoningText = nil
        block.reasoningSections = nil
        return block
    }
}

/// Stable identity for one reasoning item or inline-thinking boundary.
struct ThinkingPresentationGroupID: Hashable {
    let sourceBlockID: UUID
    let ordinal: Int
}

/// One provider-supplied reasoning section inside a source-local thought
/// group. The source block and ordinal keep SwiftUI identity stable without
/// changing the persisted transcript model.
struct ThinkingPresentationEntry: Identifiable, Equatable {
    struct ID: Hashable {
        let sourceBlockID: UUID
        let ordinal: Int
    }

    let id: ID
    let text: String
}

enum TranscriptPresentation {
    static func items(
        from blocks: [ChatBlock],
        toolVisibility: ToolActivityVisibility,
        thinkingVisibility: ThinkingVisibility
    ) -> [TranscriptPresentationItem] {
        var items: [TranscriptPresentationItem] = []
        var pendingToolBlocks: [ChatBlock] = []

        func flushTools() {
            guard !pendingToolBlocks.isEmpty else { return }
            if toolVisibility == .verbose {
                items.append(contentsOf: pendingToolBlocks.map(TranscriptPresentationItem.block))
            } else if let first = pendingToolBlocks.first {
                items.append(.toolGroup(
                    id: first.id,
                    tools: pendingToolBlocks.compactMap(\.tool)
                ))
            }
            pendingToolBlocks.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if block.kind == .tool {
                pendingToolBlocks.append(block)
                continue
            }

            flushTools()
            if block.kind == .assistant {
                items.append(contentsOf: assistantItems(
                    for: block,
                    thinkingVisibility: thinkingVisibility
                ))
            } else {
                items.append(.block(block))
            }
        }
        flushTools()
        return items
    }

    /// The first visible assistant activity owns the Locus marker for its
    /// whole turn. This includes reasoning and tools so the marker appears as
    /// soon as work begins, while every later row in the turn stays unmarked.
    static func assistantMarkerItemIDs(
        in items: [TranscriptPresentationItem]
    ) -> Set<TranscriptPresentationItem.ID> {
        var result: Set<TranscriptPresentationItem.ID> = []
        var responseAlreadyHasMarker = false

        for item in items {
            if item.isTurnBoundary {
                responseAlreadyHasMarker = false
                continue
            }
            guard item.isVisibleAssistantActivity else { continue }
            if !responseAlreadyHasMarker {
                result.insert(item.id)
                responseAlreadyHasMarker = true
            }
        }
        return result
    }

    /// Final-answer items own response actions. If a provider ends a turn with
    /// commentary only, the last visible assistant item is the explicit
    /// fallback so copy/use-as-draft never disappear entirely.
    static func assistantActionItemIDs(
        in items: [TranscriptPresentationItem]
    ) -> Set<TranscriptPresentationItem.ID> {
        var result: Set<TranscriptPresentationItem.ID> = []
        var visible: [TranscriptPresentationItem] = []

        func flushTurn() {
            guard !visible.isEmpty else { return }
            let owner = visible.last(where: { $0.assistantPhase != .commentary })
                ?? visible.last
            if let owner { result.insert(owner.id) }
            visible.removeAll(keepingCapacity: true)
        }

        for item in items {
            if item.isTurnBoundary {
                flushTurn()
            } else if item.isVisibleAssistantItem {
                visible.append(item)
            }
        }
        flushTurn()
        return result
    }

    private static func assistantItems(
        for block: ChatBlock,
        thinkingVisibility: ThinkingVisibility
    ) -> [TranscriptPresentationItem] {
        // The active row is rendered from StreamingReplyState. Give it the same
        // presentation identity its ordinary completed message will use.
        if block.isStreaming {
            return [.assistantSegment(AssistantPresentationSegment(
                id: .init(sourceBlockID: block.id, ordinal: 0),
                sourceBlock: block,
                text: block.text
            ))]
        }

        var result: [TranscriptPresentationItem] = []
        var thinkingEntryOrdinal = 0
        var thinkingGroupOrdinal = 0
        var visibleOrdinal = 0

        func appendThinkingGroup(_ sections: [String]) {
            guard thinkingVisibility != .hidden else { return }
            let entries = sections.compactMap { text -> ThinkingPresentationEntry? in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                defer { thinkingEntryOrdinal += 1 }
                return ThinkingPresentationEntry(
                    id: .init(sourceBlockID: block.id, ordinal: thinkingEntryOrdinal),
                    text: trimmed
                )
            }
            guard !entries.isEmpty else { return }
            result.append(.thinkingGroup(
                id: .init(sourceBlockID: block.id, ordinal: thinkingGroupOrdinal),
                entries: entries
            ))
            thinkingGroupOrdinal += 1
        }

        func appendVisible(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result.append(.assistantSegment(AssistantPresentationSegment(
                id: .init(sourceBlockID: block.id, ordinal: visibleOrdinal),
                sourceBlock: block,
                text: trimmed
            )))
            visibleOrdinal += 1
        }

        appendThinkingGroup(block.resolvedReasoningSections)
        for segment in AssistantSegment.parse(block.text) {
            switch segment {
            case .thinking(let text, _):
                appendThinkingGroup([text])
            case .visible(let text):
                appendVisible(text)
            }
        }
        return result
    }
}

private extension TranscriptPresentationItem {
    var isTurnBoundary: Bool {
        guard case .block(let block) = self else { return false }
        return block.kind == .user || block.completion != nil
    }

    var isVisibleAssistantActivity: Bool {
        switch self {
        case .assistantSegment, .thinkingGroup, .toolGroup:
            return true
        case .block(let block):
            return block.kind == .tool
        }
    }

    var isVisibleAssistantItem: Bool {
        guard case .assistantSegment = self else { return false }
        return true
    }

    var assistantPhase: AssistantPhase? {
        guard case .assistantSegment(let segment) = self else { return nil }
        return segment.sourceBlock.assistantPhase
    }
}

/// One `/api/sessions/search` hit — a message position inside a saved session.
struct TranscriptSearchHit: Codable, Hashable, Identifiable {
    let sessionID: String
    let title: String?
    let pinned: Bool
    let mtime: Double
    let messageIndex: Int
    let role: String
    let snippet: String
    let phase: AssistantPhase?
    let itemID: String?
    let reasoningSections: [String]?
    /// `[start, length]` character ranges inside `snippet` to emphasize.
    let highlights: [[Int]]
    let score: Double

    var id: String { "\(sessionID):\(messageIndex)" }

    enum CodingKeys: String, CodingKey {
        case title, pinned, mtime, role, snippet, phase, highlights, score
        case sessionID = "session_id"
        case messageIndex = "message_index"
        case itemID = "item_id"
        case reasoningSections = "reasoning_sections"
    }

    /// The first term the index actually matched — by construction it appears
    /// verbatim in the message text, so it can drive the in-conversation find.
    var firstMatchedTerm: String? {
        guard let range = stringRange(of: highlights.first) else { return nil }
        return String(snippet[range])
    }

    /// Highlight offsets are Python `str` positions — Unicode scalars, not
    /// Swift's grapheme clusters — so index math must run on the scalar view
    /// or any emoji in a snippet shifts every later highlight.
    func stringRange(of highlight: [Int]?) -> Range<String.Index>? {
        guard let highlight, highlight.count == 2 else { return nil }
        let scalars = snippet.unicodeScalars
        guard let start = scalars.index(
            scalars.startIndex, offsetBy: highlight[0], limitedBy: scalars.endIndex
        ), let end = scalars.index(
            start, offsetBy: highlight[1], limitedBy: scalars.endIndex
        ) else { return nil }
        return start..<end
    }
}

struct TranscriptSearchResponse: Codable {
    let query: String
    let indexing: Bool
    let results: [TranscriptSearchHit]
}

struct ContextFile: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL
    var content: String
    var isIncluded: Bool
    var modificationDate: Date?
    var issue: String?

    init(
        id: UUID = UUID(),
        url: URL,
        content: String = "",
        isIncluded: Bool = true,
        modificationDate: Date? = nil,
        issue: String? = nil
    ) {
        self.id = id
        self.url = url
        self.content = content
        self.isIncluded = isIncluded
        self.modificationDate = modificationDate
        self.issue = issue
    }

    var name: String { url.lastPathComponent }
    var displayPath: String { url.path(percentEncoded: false) }
    var estimatedTokens: Int { max(content.count / 4, 1) }
    var isAvailable: Bool { issue == nil && !content.isEmpty }

    enum CodingKeys: String, CodingKey {
        case id, url, isIncluded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try container.decode(URL.self, forKey: .url)
        content = ""
        isIncluded = try container.decodeIfPresent(Bool.self, forKey: .isIncluded) ?? true
        modificationDate = nil
        issue = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(isIncluded, forKey: .isIncluded)
    }
}

enum ChatAttachmentKind: String, Hashable, Sendable {
    case text
    case image
    case applicationSnapshot = "application_snapshot"
}

struct ApplicationSnapshotContext: Hashable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let applicationName: String
    let windowTitle: String
    let windowIdentifier: UInt32?
    let accessibilityText: String
    let iconData: Data?
}

/// An explicitly selected, one-message input for the composer, valid in every
/// mode. Unlike a Work context pack, these attachments do not grant access to
/// their path or to any neighboring workspace files, and they are removed
/// after a successful send.
struct ChatAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let kind: ChatAttachmentKind
    let textContent: String?
    let imageData: Data?
    let mimeType: String?
    let issue: String?
    let applicationContext: ApplicationSnapshotContext?
    /// Display name for content with no real file behind it (pasted images);
    /// the synthesized `url` then only provides Hashable/dedupe identity.
    let overrideName: String?

    init(
        id: UUID = UUID(),
        url: URL,
        kind: ChatAttachmentKind,
        textContent: String? = nil,
        imageData: Data? = nil,
        mimeType: String? = nil,
        issue: String? = nil,
        overrideName: String? = nil,
        applicationContext: ApplicationSnapshotContext? = nil
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.textContent = textContent
        self.imageData = imageData
        self.mimeType = mimeType
        self.issue = issue
        self.overrideName = overrideName
        self.applicationContext = applicationContext
    }

    static func pasted(
        imageData: Data,
        mimeType: String,
        date: Date = Date(),
        nameStem: String = "Pasted image"
    ) -> ChatAttachment {
        let stamp = date.formatted(
            Date.FormatStyle()
                .year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        )
        let fileExtension = mimeType.split(separator: "/").last.map(String.init) ?? "png"
        let identity = UUID()
        return ChatAttachment(
            id: identity,
            url: URL(fileURLWithPath: "/dev/null/pasted-\(identity.uuidString).\(fileExtension)"),
            kind: .image,
            imageData: imageData,
            mimeType: mimeType,
            overrideName: "\(nameStem) \(stamp).\(fileExtension)"
        )
    }

    var name: String { overrideName ?? url.lastPathComponent }
    var isAvailable: Bool {
        guard issue == nil else { return false }
        switch kind {
        case .text: return !(textContent?.isEmpty ?? true)
        case .image: return !(imageData?.isEmpty ?? true) && mimeType != nil
        case .applicationSnapshot:
            return !(imageData?.isEmpty ?? true)
                && mimeType == "image/png"
                && applicationContext != nil
        }
    }

    var detail: String {
        if let issue { return issue }
        switch kind {
        case .text:
            return "\(max((textContent?.count ?? 0) / 4, 1).formatted()) estimated tokens"
        case .image:
            return ByteCountFormatter.string(
                fromByteCount: Int64(imageData?.count ?? 0),
                countStyle: .file
            )
        case .applicationSnapshot:
            let bytes = ByteCountFormatter.string(
                fromByteCount: Int64(imageData?.count ?? 0),
                countStyle: .file
            )
            let title = applicationContext?.windowTitle.nilIfEmpty
            return [title, bytes].compactMap { $0 }.joined(separator: " · ")
        }
    }
}
