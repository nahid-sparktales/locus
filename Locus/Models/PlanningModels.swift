import Combine
import Foundation

enum PlanApprovalDecision {
    /// Switch to Build mode and implement with the current permissions.
    case proceed
    /// Dismiss the decision and continue refining in Plan mode.
    case revise
    /// Keep the plan for reference and return to adaptive Work.
    case cancel
}

/// A final, decision-complete plan submitted by the model for user approval.
/// Every field has a default so checkpoints and older agents remain tolerant.
struct PlanDocument: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var steps: [String]
    var tests: [String]

    init(
        id: String = UUID().uuidString,
        title: String = "Implementation plan",
        summary: String = "",
        steps: [String] = [],
        tests: [String] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.steps = steps
        self.tests = tests
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, steps, tests
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Implementation plan"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
        tests = try container.decodeIfPresent([String].self, forKey: .tests) ?? []
    }
}

enum PlanSignalDetector {
    static func document(from text: String, changedTodos: [TodoItem] = []) -> PlanDocument? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tagged = taggedPlan(in: trimmed)
        let source = tagged ?? trimmed
        var steps = listItems(in: source)
        if steps.isEmpty { steps = changedTodos.map(\.content) }
        let hasPlanHeading = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                let heading = line.trimmingCharacters(in: .whitespaces).lowercased()
                return heading.hasPrefix("#") && heading.contains("plan")
            }
        guard !isClarifyingResponse(source),
              tagged != nil || !changedTodos.isEmpty || (hasPlanHeading && steps.count >= 2),
              !steps.isEmpty
        else { return nil }
        let title = source
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix("#") && $0.lowercased().contains("plan") })?
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            .nilIfEmpty ?? "Implementation plan"
        return PlanDocument(title: title, summary: source, steps: steps, tests: [])
    }

    private static func taggedPlan(in text: String) -> String? {
        guard let open = text.range(of: "<proposed_plan>"),
              let close = text.range(of: "</proposed_plan>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func listItems(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.range(
                of: #"^(?:[-*+]\s+|\d+[.)]\s+)(.+)$"#,
                options: .regularExpression
            ) != nil else { return nil }
            return line.replacingOccurrences(
                of: #"^(?:[-*+]\s+|\d+[.)]\s+)"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces).nilIfEmpty
        }
    }

    static func isClarifyingResponse(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let question = lines.last(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
              question.hasSuffix("?")
        else { return false }
        let lower = question.lowercased()
        if lower.contains("proceed")
            || lower.contains("implement this plan")
            || lower.contains("go ahead with this plan")
        {
            return false
        }
        return lower.hasPrefix("which ")
            || lower.hasPrefix("what ")
            || lower.hasPrefix("would ")
            || lower.hasPrefix("should ")
            || lower.hasPrefix("could ")
            || lower.hasPrefix("do you ")
            || lower.contains("clarify")
    }
}
