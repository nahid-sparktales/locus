import Foundation

struct AgentCrewChatRecipient: Identifiable, Equatable {
    let id: UUID
    let name: String
    let reason: String
}

struct AgentCrewChatRoutingDecision: Equatable {
    var recipients: [AgentCrewChatRecipient] = []
    var explanation: String
    var issues: [String] = []
    var isExplicit = false
    var canDispatch: Bool { !recipients.isEmpty && issues.isEmpty }
}

/// Routing uses declared capabilities and roles, never agent-authored instructions
/// or an extra model call. An unresolved mention cannot silently become a broadcast.
enum AgentCrewChatRouter {
    static func route(_ text: String, profiles: [AgentProfile], fallbackProfileID: UUID? = nil, availability: (AgentProfile) -> String? = { _ in nil }) -> AgentCrewChatRoutingDecision {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .init(explanation: "Mention an agent, or describe a task to find a capable crew member.") }
        let mentions = parseMentions(clean, profiles: profiles)
        if mentions.found {
            var issues = mentions.issues
            let selected = mentions.ids.compactMap { id in profiles.first { $0.id == id } }
            for profile in selected {
                if let reason = availability(profile) { issues.append("\(profile.name): \(reason)") }
            }
            return .init(recipients: selected.map { .init(id: $0.id, name: $0.name, reason: "You mentioned this agent.") },
                         explanation: issues.isEmpty ? "Only the agents you mentioned will respond." : "Resolve these mentions before sending.",
                         issues: issues, isExplicit: true)
        }
        let tokens = words(clean)
        let scored = profiles.compactMap { profile -> Candidate? in
            guard availability(profile) == nil else { return nil }
            let hits = profile.capabilityTags.filter { tag in
                let terms = words(tag)
                return !terms.isEmpty && terms.isSubset(of: tokens)
            }
            let intents = tokens.intersection(roleTerms[profile.role] ?? [])
            let score = hits.count * 10 + min(intents.count, 3) * 6
            guard score >= 6 else { return nil }
            let reason = !hits.isEmpty ? "Matches \(hits.prefix(3).joined(separator: ", "))." : "Their \(profile.specialtyTitle.lowercased()) role fits this request."
            return Candidate(profile: profile, score: score, intents: intents, reason: reason)
        }.sorted { $0.score == $1.score ? $0.profile.id.uuidString < $1.profile.id.uuidString : $0.score > $1.score }
        guard let first = scored.first else {
            let available = profiles.filter { availability($0) == nil }
            let generalists = available.filter { $0.role == .generalist && $0.capabilityTags.isEmpty }
            if let fallback = available.first(where: { $0.id == fallbackProfileID })
                ?? (generalists.count == 1 ? generalists.first : nil)
                ?? (available.count == 1 ? available.first : nil) {
                return .init(recipients: [.init(id: fallback.id, name: fallback.name, reason: "Handles the conversation and chooses the appropriate tools.")],
                             explanation: "\(fallback.name) will handle this request.")
            }
            return .init(explanation: "No available agent has a clear capability match. Mention an agent or add more detail.")
        }
        var selected = [first]
        // A helper needs its own explicit task intent, not merely a shared tag.
        if tokens.contains("and"), let helper = scored.dropFirst().first(where: {
            $0.profile.role != first.profile.role && !$0.intents.isEmpty && !first.intents.isEmpty
                && $0.intents.isDisjoint(with: first.intents)
        }) { selected.append(helper) }
        return .init(recipients: selected.map { .init(id: $0.profile.id, name: $0.profile.name, reason: $0.reason) },
                     explanation: selected.count == 1 ? "One agent has the strongest match." : "A specialist and a complementary helper match the requested tasks.")
    }

    static func mention(for profile: AgentProfile, profiles: [AgentProfile]) -> String {
        let ambiguous = profiles.filter { normalize($0.name) == normalize(profile.name) }.count > 1
        return ambiguous || profile.name.contains("\"") ? "@{\(profile.id.uuidString)}" : "@\"\(profile.name)\""
    }

    private struct Candidate { let profile: AgentProfile; let score: Int; let intents: Set<String>; let reason: String }
    private static let roleTerms: [AgentRole: Set<String>] = [
        .implementer: ["implement", "build", "code", "coding", "fix", "debug", "refactor", "develop"],
        .tester: ["test", "testing", "verify", "validation", "regression", "coverage", "qa"],
        .reviewer: ["review", "audit", "security", "vulnerability"],
        .researcher: ["research", "investigate", "compare", "evidence", "sources", "lookup"],
        .planner: ["plan", "roadmap", "architecture", "design", "strategy"],
        .dispatcher: ["coordinate", "delegate", "orchestrate"],
        .generalist: []
    ]
    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func words(_ value: String) -> Set<String> {
        Set(normalize(value).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.map {
            switch $0 { case "tests": "test"; case "reviews": "review"; case "bugs": "bug"; default: $0 }
        })
    }
    private static func parseMentions(_ text: String, profiles: [AgentProfile]) -> (found: Bool, ids: [UUID], issues: [String]) {
        // Preserve UTF-16 offsets while excluding quoted code and email addresses.
        let source = text as NSString
        let code = try! NSRegularExpression(pattern: "```[\\s\\S]*?(?:```|$)|`[^`\\n]*(?:`|$)")
        let ignored = code.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        let markers = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_.%+\\-])@")
        let known = profiles.sorted { $0.name.count > $1.name.count }
        var ids: [UUID] = [], issues: [String] = [], consumed = 0, found = false
        for marker in markers.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard marker.range.location >= consumed, !ignored.contains(where: { NSLocationInRange(marker.range.location, $0) }) else { continue }
            found = true
            let start = marker.range.location + 1
            let tail = source.substring(from: start)
            let first = tail.first
            if first == "\"" || first == "{" {
                let close: Character = first == "{" ? "}" : "\""
                if let end = tail.dropFirst().firstIndex(of: close) {
                    let raw = String(tail[tail.index(after: tail.startIndex)..<end])
                    consumed = start + (String(tail[...end]) as NSString).length
                    let matches = profiles.filter { normalize($0.name) == normalize(raw) || $0.id.uuidString.lowercased() == raw.lowercased() }
                    resolve(matches, label: raw, ids: &ids, issues: &issues)
                } else { issues.append("Close the quoted agent mention after @.") }
                continue
            }
            var matched = false
            for profile in known {
                let pattern = "^" + profile.name.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}_\\-])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                      let match = regex.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) else { continue }
                let matches = profiles.filter { normalize($0.name) == normalize(profile.name) }
                resolve(matches, label: profile.name, ids: &ids, issues: &issues)
                consumed = start + match.range.length; matched = true; break
            }
            if !matched {
                let unknown = tail.prefix { !$0.isWhitespace && !",;:!?()".contains($0) }
                issues.append("No saved agent matches @\(unknown).")
            }
        }
        return (found, ids, issues)
    }
    private static func resolve(_ matches: [AgentProfile], label: String, ids: inout [UUID], issues: inout [String]) {
        if matches.count == 1 {
            if !ids.contains(matches[0].id) { ids.append(matches[0].id) }
        } else if matches.isEmpty { issues.append("No saved agent matches @\(label).") }
        else { issues.append("More than one agent is named \(label). Choose one from the crew list.") }
    }
}
