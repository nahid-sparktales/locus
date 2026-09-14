import Foundation

struct TranscriptTaskResult: Equatable {
    let runID: String
    let title: String
    let agentName: String?
    let completedAt: Date?
}

/// UI-free transcript derivations, static so formatting and ordering rules
/// can be unit tested without an AppModel.
enum ChatTranscriptBuilder {
    @MainActor
    static func taskResults(in blocks: [ChatBlock], runs: [OrchestrationRun],
                            session: SessionSummary?, profiles: [AgentProfile]) -> [UUID: TranscriptTaskResult] {
        let index = ResultIndex(blocks: blocks)
        let knownRunIDs = Set(runs.map(\.id))
        var results: [UUID: TranscriptTaskResult] = [:]
        for run in runs where run.state == "completed" && run.sessionID == session?.id {
            let hasEventAnchor = index.turnsByRun[run.id]?.contains { $0.user.eventTrigger != nil } == true
            guard run.scheduleID != nil || run.manifest?["event_trigger_id"]?.string != nil
                    || run.taskID != nil || run.runKind == "team" || session?.isAgentEventChat == true
                    || hasEventAnchor,
                  let blockID = index.resultBlockID(runID: run.id, request: run.request) else { continue }
            let request = displayUserText(run.request).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = session?.isAgentEventChat == true
                ? session?.agentName?.nilIfEmpty ?? session?.displayTitle ?? "Task result"
                : String((request.components(separatedBy: .newlines).first ?? "").prefix(100)).nilIfEmpty ?? "Task result"
            results[blockID] = TranscriptTaskResult(runID: run.id, title: title,
                agentName: ActivityCenterModel.agentName(for: run, session: session, profiles: profiles),
                completedAt: run.completedAt.map(Date.init(timeIntervalSince1970:)))
        }
        // Event metadata is persisted in the transcript itself. Keep older
        // automation results distinct even before the run list loads, while
        // offline, or after they fall outside the run list's history window.
        let owner = session?.savedAgentProfileID.flatMap { id in profiles.first { $0.id == id }?.name }
        for turn in index.turns where turn.user.eventTrigger != nil || session?.isAgentEventChat == true {
            guard let blockID = turn.resultBlockID, results[blockID] == nil,
                  !knownRunIDs.contains(turn.user.runID ?? "") else { continue }
            let context = turn.user.eventTrigger
            let title = session?.agentName?.nilIfEmpty ?? session?.displayTitle
                ?? context?.instruction.components(separatedBy: .newlines).first?.nilIfEmpty ?? "Task result"
            let runID = turn.user.runID ?? context?.deliveryID ?? turn.user.id.uuidString
            results[blockID] = TranscriptTaskResult(runID: runID, title: String(title.prefix(100)),
                agentName: owner, completedAt: nil)
        }
        return results
    }

    /// Resolve a saved run's answer without substituting the latest reply in
    /// a chat that may contain many runs. Older histories only tag the user
    /// message, so their answer is bounded by that turn's next user message.
    static func activityResultBlockID(for run: OrchestrationRun, in blocks: [ChatBlock]) -> UUID? {
        ResultIndex(blocks: blocks).resultBlockID(runID: run.id, request: run.request)
    }

    /// One linear pass supports every result card in a long transcript. Never
    /// rescan the entire history for each saved run during a view update.
    private struct ResultIndex {
        struct Turn {
            let user: ChatBlock
            var resultBlockID: UUID?
        }
        var finalByRun: [String: UUID] = [:]
        var turnsByRun: [String: [Turn]] = [:]
        var turnsByRequest: [String: [Turn]] = [:]
        var turns: [Turn] = []

        init(blocks: [ChatBlock]) {
            var current: Turn?
            for block in blocks {
                if block.kind == .user {
                    if let current { turns.append(current) }
                    current = Turn(user: block)
                } else if Self.isResult(block) {
                    if let runID = block.runID { finalByRun[runID] = block.id }
                    if block.runID == nil || block.runID == current?.user.runID {
                        current?.resultBlockID = block.id
                    }
                }
            }
            if let current { turns.append(current) }
            for turn in turns {
                if let runID = turn.user.runID { turnsByRun[runID, default: []].append(turn) }
                else {
                    let request = turn.user.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    turnsByRequest[request, default: []].append(turn)
                }
            }
        }

        func resultBlockID(runID: String, request: String) -> UUID? {
            if let exact = finalByRun[runID] { return exact }
            let request = displayUserText(request).trimmingCharacters(in: .whitespacesAndNewlines)
            let anchors = turnsByRun[runID] ?? (request.isEmpty ? [] : turnsByRequest[request] ?? [])
            // Identical requests without durable run IDs are ambiguous.
            guard anchors.count == 1 else { return nil }
            return anchors.first?.resultBlockID
        }

        static func isResult(_ block: ChatBlock) -> Bool {
            block.kind == .assistant && block.assistantPhase != .commentary && !block.isStreaming
                && !AssistantSegment.copyableText(from: block.text,
                    reasoningFormat: block.reasoningFormat ?? .legacyTags)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func safeFilename(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(
            of: #"[^a-zA-Z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        return String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(60))
            .nilIfEmpty ?? "locus-session"
    }

    /// The user's own words, with the composer's `[Locus mode: …]` wrapper and
    /// context sections removed. The transcript has always shown this; the Runs
    /// panel showed the raw decorated prompt, so the request itself was the part
    /// that got truncated away.
    static func displayUserText(_ content: String) -> String {
        guard let range = content.range(of: "User request:\n", options: .backwards) else {
            return content
        }
        return String(content[range.upperBound...])
    }

    static func blocks(from messages: [HistoryMessage]) -> [ChatBlock] {
        messages.enumerated().compactMap { index, message in
            switch message.role {
            case "user":
                ChatBlock(
                    kind: .user,
                    text: displayUserText(message.content),
                    runID: message.runID,
                    eventTrigger: message.eventTrigger,
                    historyIndex: index
                )
            case "assistant" where !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(message.reasoning?.isEmpty ?? true)
                || !(message.reasoningSections?.isEmpty ?? true):
                ChatBlock(
                    kind: .assistant,
                    text: message.content,
                    assistantPhase: message.phase,
                    sourceItemID: message.itemID,
                    responseParts: message.responseParts,
                    reasoningFormat: message.reasoningFormat,
                    reasoningText: message.reasoning,
                    reasoningSections: message.reasoningSections,
                    runID: message.runID,
                    historyIndex: index
                )
            case "tool":
                ChatBlock(
                    kind: .tool,
                    tool: ToolPayload(
                        toolID: message.itemID ?? UUID().uuidString,
                        tool: message.name ?? "tool",
                        summary: message.name ?? "tool",
                        detail: "",
                        status: .done,
                        result: message.content,
                        activityLabel: message.activityLabel,
                        media: message.media
                    ),
                    historyIndex: index
                )
            default:
                nil
            }
        }
    }

    static func transcriptContext(from blocks: [ChatBlock]) -> String {
        blocks.compactMap { block -> String? in
            switch block.kind {
            case .user: "User: \(block.text)"
            case .assistant: "Assistant: \(block.text)"
            case .note: block.completion == nil ? "Note: \(block.text)" : nil
            case .tool, .error: nil
            }
        }
        .suffix(12)
        .joined(separator: "\n\n")
    }
}

extension AppModel {
    /// Temporary forwarder while InspectorView still reads this through
    /// AppModel; it migrates with that view's own commit.
    nonisolated static func displayUserText(_ content: String) -> String {
        ChatTranscriptBuilder.displayUserText(content)
    }
}
