import Foundation

enum VoiceAttentionKind: String, Codable, Hashable {
    case permission
    case planApproval = "plan_approval"
    case structuredQuestion = "structured_question"
    case appleNetworkRecognition = "apple_network_recognition"

    var announcement: String {
        switch self {
        case .permission:
            "A permission request needs your attention on screen."
        case .planApproval:
            "A plan is ready for your approval on screen."
        case .structuredQuestion:
            "Locus has a question for you on screen."
        case .appleNetworkRecognition:
            "This Mac needs your approval to use Apple online speech recognition."
        }
    }
}

enum VoiceSessionState: Equatable {
    case idle
    case listening
    case transcribing
    case waiting
    case speaking
    case attention(VoiceAttentionKind)
    case error(String)

    var title: String {
        switch self {
        case .idle: "Ready"
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .waiting: "Waiting for reply…"
        case .speaking: "Speaking…"
        case .attention: "Needs attention"
        case .error: "Voice unavailable"
        }
    }
}

enum VoiceInputPurpose: Equatable {
    case dictation
    case conversation
    case capabilityTest
}

struct VoiceCloudConfiguration: Equatable {
    let accountID: String
    let baseURL: URL
    let apiKey: String
    let transcriptionModel: String
    let speechModel: String
    let voiceIdentifier: String
    let languageIdentifier: String
}

enum VoiceControlError: LocalizedError, Equatable {
    case microphoneDenied
    case speechRecognitionDenied
    case speechRecognizerUnavailable
    case appleNetworkConsentRequired
    case cloudAccountUnavailable
    case invalidEndpoint
    case recordingTooLarge
    case emptyTranscript
    case invalidResponse(String)
    case responseTooLarge
    case unsupportedAudio

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Enable it for Locus in System Settings → Privacy & Security."
        case .speechRecognitionDenied:
            "Speech Recognition access is off. Enable it for Locus in System Settings → Privacy & Security."
        case .speechRecognizerUnavailable:
            "Speech recognition is not currently available for the selected language."
        case .appleNetworkConsentRequired:
            "On-device recognition is unavailable. Allow Apple online recognition to continue."
        case .cloudAccountUnavailable:
            "Choose an OpenAI API or compatible custom account in Settings → Chat."
        case .invalidEndpoint:
            "The selected speech endpoint is not a valid URL."
        case .recordingTooLarge:
            "The recording reached the 20 MB limit."
        case .emptyTranscript:
            "No speech was detected."
        case .invalidResponse(let detail):
            detail
        case .responseTooLarge:
            "The speech service returned more audio or text than Locus accepts."
        case .unsupportedAudio:
            "The speech service returned an unsupported audio response."
        }
    }
}

/// The only assistant content voice mode may speak. Commentary, tool output,
/// reasoning, and everything before the most recent user message are excluded.
struct VoiceReplyProjection: Equatable {
    static let maximumCharacters = 4_000
    static let remainderNotice = "The rest is available on screen."
    static let codeNotice = "Code is available on screen."
    static let tableNotice = "A table is available on screen."

    let text: String
    let wasTruncated: Bool

    static func project(blocks: [ChatBlock]) -> VoiceReplyProjection? {
        let lastUserIndex = blocks.lastIndex(where: { $0.kind == .user }) ?? -1
        let markdown = blocks.enumerated().compactMap { index, block -> String? in
            guard index > lastUserIndex,
                  block.kind == .assistant,
                  AssistantPhase.resolved(block.assistantPhase?.rawValue) == .finalAnswer
            else { return nil }
            let visible = AssistantSegment.copyableText(from: block.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return visible.isEmpty ? nil : visible
        }.joined(separator: "\n\n")
        guard !markdown.isEmpty else { return nil }

        let rendered = VoiceMarkdownRenderer.render(markdown)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !rendered.isEmpty else { return nil }
        guard rendered.count > maximumCharacters else {
            return VoiceReplyProjection(text: rendered, wasTruncated: false)
        }
        let available = maximumCharacters - remainderNotice.count - 1
        let prefix = rendered.prefix(max(available, 0))
        return VoiceReplyProjection(
            text: "\(prefix) \(remainderNotice)",
            wasTruncated: true
        )
    }
}

enum VoiceMarkdownRenderer {
    static func render(_ source: String) -> String {
        render(blocks: MarkdownDocumentParser.parse(source))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(blocks: [MarkdownRenderBlock]) -> String {
        blocks.map(render(block:)).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func render(block: MarkdownRenderBlock) -> String {
        switch block {
        case .paragraph(let runs), .heading(_, let runs):
            return runs.map(\.text).joined()
        case .code:
            return VoiceReplyProjection.codeNotice
        case .table:
            return VoiceReplyProjection.tableNotice
        case .unordered(let items):
            return items.map { render(blocks: $0.blocks) }.joined(separator: ". ")
        case .ordered(_, let items):
            return items.enumerated().map { index, item in
                "\(index + 1). \(render(blocks: item.blocks))"
            }.joined(separator: ". ")
        case .quote(let nested):
            return render(blocks: nested)
        case .rule:
            return ""
        case .rawText(let value):
            return value
        }
    }
}

enum VoiceSpeechChunker {
    static func chunks(_ text: String, maximumCharacters: Int = 800) -> [String] {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, maximumCharacters > 0 else { return [] }
        var chunks: [String] = []
        var remainder = normalized[...]
        while remainder.count > maximumCharacters {
            let limit = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
            let candidate = remainder[..<limit]
            let boundary = candidate.lastIndex(where: { ".!?;:\n".contains($0) })
                ?? candidate.lastIndex(where: \Character.isWhitespace)
                ?? limit
            let end = boundary == remainder.startIndex ? limit : boundary
            let piece = remainder[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            remainder = remainder[end...].drop(while: { $0.isWhitespace || ".!?;:".contains($0) })
        }
        let tail = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }
}
