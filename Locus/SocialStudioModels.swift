import Foundation

enum SocialChannel: String, Codable, CaseIterable, Identifiable {
    case linkedin, x, bluesky, threads, mastodon, instagram, facebook, tiktok, youtube, pinterest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .linkedin: "LinkedIn"
        case .x: "X"
        case .bluesky: "Bluesky"
        case .threads: "Threads"
        case .mastodon: "Mastodon"
        case .instagram: "Instagram"
        case .facebook: "Facebook"
        case .tiktok: "TikTok"
        case .youtube: "YouTube"
        case .pinterest: "Pinterest"
        }
    }
    var monogram: String { self == .linkedin ? "in" : String(title.prefix(1)) }
}

struct SocialDraft: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var text = ""
    var channels: [SocialChannel] = [.linkedin]
    var variants: [String: String] = [:]
    var plannedAt: Date?
    var updatedAt = Date()
    // Persist the exact request before sending. A lost response can be retried
    // with the same body and key, even after restarting the application.
    var handoff: SocialHandoff?

    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled post" : title }
    func text(for channel: SocialChannel) -> String { variants[channel.rawValue] ?? text }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func copy() -> SocialDraft {
        var value = self
        value.id = UUID(); value.title = displayTitle + " · copy"
        value.handoff = nil; value.plannedAt = nil; value.updatedAt = Date()
        return value
    }
}

struct SocialHandoff: Codable, Equatable {
    let origin: String
    let workspaceID: String
    let key: String
    let body: Data
    var publicationID: String?
}

struct SocialBrand: Codable, Equatable {
    var name = ""
    var audience = ""
    var voice = "Clear, useful, conversational. Avoid hype."
    var topics = ""
}

struct SocialConnection: Codable, Equatable {
    var origin: String
    var workspaceID: String
    var workspaceName: String
    var credentialID: String
}

struct SocialStudioDocument: Codable, Equatable {
    var version = 1
    var drafts: [SocialDraft] = []
    var brand = SocialBrand()
    var connection: SocialConnection?
}

struct OpenPostWorkspace: Decodable, Identifiable {
    let id: String
    let name: String
    let canEdit: Bool
}

struct OpenPostAccount: Decodable, Identifiable {
    let id: String
    let platform: String
    let accountUsername: String
    let isActive: Bool
    var channel: SocialChannel? { SocialChannel(rawValue: platform) }
    var label: String { "\(channel?.title ?? platform.capitalized) · @\(accountUsername)" }
}

struct OpenPostPublication: Decodable, Identifiable {
    let id: String
    let workspaceId: String
    let title: String
    let sourceText: String
    let status: String
    let revision: Int
    let scheduledAt: String?
    let renditions: [OpenPostRendition]?
    var displayTitle: String { title.isEmpty ? String(sourceText.prefix(70)) : title }
    var scheduledDate: Date? {
        guard let scheduledAt else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: scheduledAt) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: scheduledAt)
    }
}

struct OpenPostRendition: Decodable, Identifiable {
    let id: String
    let platform: String
    let status: String
    let errorMessage: String?
    let externalUrl: String?
    let body: String?
    let socialAccountId: String?
}

struct OpenPostValidation: Decodable {
    struct Issue: Decodable { let message: String; let severity: String }
    let valid: Bool
    let issues: [Issue]?
}

struct OpenPostActionResult: Decodable { let message: String; let jobId: String? }

enum SocialStudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

enum SocialAssistantAction: String {
    case research, adapt, ideas
    func prompt(topic: String, draft: SocialDraft?, brand: SocialBrand) -> String {
        let context = "Brand: \(brand.name)\nAudience: \(brand.audience)\nVoice: \(brand.voice)\nContent themes: \(brand.topics)"
        let request: String
        switch self {
        case .research:
            request = "Use the last30days skill to research \(topic). Focus on the last 30 days. Include dated source links, recurring questions, emerging discussions, and 5 specific social post angles. Distinguish evidence from suggestions. If a source or the skill is unavailable, say so."
        case .adapt:
            request = "Adapt this draft for \(draft?.channels.map(\.title).joined(separator: ", ") ?? "my social channels"). Keep the facts intact and follow each platform's current constraints. Return a clearly labeled version for each channel.\n\nDraft: \(draft?.text ?? "")"
        case .ideas:
            request = "Develop 5 concrete social post ideas about \(topic). Give each a hook, useful takeaway, recommended channel, and a draft. Do not invent statistics or customer claims."
        }
        return "\(request)\n\n\(context)\n\nPrepare content for review in Locus Social Studio. Do not schedule or publish anything."
    }
}
