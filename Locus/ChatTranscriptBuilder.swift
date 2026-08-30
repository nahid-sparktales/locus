import Foundation

/// UI-free transcript derivations, static so formatting and ordering rules
/// can be unit tested without an AppModel.
enum ChatTranscriptBuilder {
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
                    reasoningText: message.reasoning,
                    reasoningSections: message.reasoningSections,
                    historyIndex: index
                )
            case "tool":
                ChatBlock(
                    kind: .tool,
                    tool: ToolPayload(
                        toolID: UUID().uuidString,
                        tool: message.name ?? "tool",
                        summary: message.name ?? "tool",
                        detail: "",
                        status: .done,
                        result: message.content
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
