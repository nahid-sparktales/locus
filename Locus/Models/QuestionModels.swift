import Foundation

/// A question the agent asked the user, surfaced as an answer popup once the
/// turn completes. Every field has a default so older agents and the
/// text-detection fallback remain tolerant.
struct UserQuestion: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var question: String
    var options: [UserQuestionOption]
    var recommended: String

    init(
        id: String = UUID().uuidString,
        title: String = "Question",
        question: String = "",
        options: [UserQuestionOption] = [],
        recommended: String = ""
    ) {
        self.id = id
        self.title = title
        self.question = question
        self.options = options
        self.recommended = recommended
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, question, options, recommended
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Question"
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        options = try container.decodeIfPresent([UserQuestionOption].self, forKey: .options) ?? []
        recommended = try container.decodeIfPresent(String.self, forKey: .recommended) ?? ""
    }

    /// The option the recommendation names, when it matches one exactly.
    var recommendedOptionIndex: Int? {
        guard !recommended.isEmpty else { return nil }
        return options.firstIndex {
            $0.label.caseInsensitiveCompare(recommended) == .orderedSame
        }
    }
}

/// One selectable answer. Decodes from either a bare string or an object.
struct UserQuestionOption: Codable, Hashable {
    var label: String
    var detail: String

    init(label: String, detail: String = "") {
        self.label = label
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case label, detail
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let text = try? single.decode(String.self)
        {
            label = text
            detail = ""
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

/// Recovers a question from a completed turn's text when the agent wrote the
/// Grill skill's `❓ **Qn** - **Title**: body` + `➡️ recommendation` block but
/// did not call the `ask_user_question` tool (or the backend predates it).
///
/// Deliberately conservative: without the ❓ marker there is no question, so
/// ordinary prose that happens to end in a question mark never raises the
/// popup — that broader sniff is `PlanSignalDetector.isClarifyingResponse`'s
/// separate, suppression-only job.
enum QuestionSignalDetector {
    static func question(from text: String) -> UserQuestion? {
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = allLines.lastIndex(where: { line in
            stripped(line.trimmingCharacters(in: .whitespaces), prefixes: questionMarkers) != nil
        }) else { return nil }

        var bodyLines: [String] = []
        var recommended = ""
        for raw in allLines[start...] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let rest = stripped(trimmed, prefixes: recommendationMarkers) {
                recommended = stripEmphasis(rest)
                break
            }
            bodyLines.append(raw)
        }

        guard let firstLine = bodyLines.first?.trimmingCharacters(in: .whitespaces),
              let headline = stripped(firstLine, prefixes: questionMarkers)
        else { return nil }

        let (title, remainder) = titleAndRemainder(in: headline)
        let restLines = remainder.nilIfEmpty.map { [$0] } ?? []
        let tail = bodyLines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        let options = listItems(in: tail).map {
            UserQuestionOption(label: stripEmphasis($0))
        }
        // Extracted choices become option rows; keeping them in the body too
        // would show every choice twice.
        let prose = options.isEmpty ? Array(tail) : tail.filter { listItem(in: $0) == nil }
        let body = (restLines + prose)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty || !title.isEmpty else { return nil }
        return UserQuestion(
            title: title.nilIfEmpty ?? "Question",
            question: body,
            options: Array(options.prefix(8)),
            recommended: recommended
        )
    }

    /// Emoji markers with and without the variation selector: the two forms
    /// are distinct graphemes, and models emit both.
    private static let questionMarkers = ["\u{2753}\u{FE0F}", "\u{2753}"]
    private static let recommendationMarkers = ["\u{27A1}\u{FE0F}", "\u{27A1}"]

    private static func stripped(_ line: String, prefixes: [String]) -> String? {
        for prefix in prefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Splits `**Q1** - **Reddit scope**: Should …` into the title and the
    /// question text that follows it, tolerating a missing Qn label.
    private static func titleAndRemainder(in headline: String) -> (String, String) {
        let patterns = [
            #"^\*\*[^*]*\*\*\s*[-–—]\s*\*\*([^*]+)\*\*\s*:?\s*"#,
            #"^\*\*([^*]+)\*\*\s*:?\s*"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: headline,
                    range: NSRange(headline.startIndex..., in: headline)
                  ),
                  let whole = Range(match.range(at: 0), in: headline),
                  let titleRange = Range(match.range(at: 1), in: headline)
            else { continue }
            return (
                String(headline[titleRange]).trimmingCharacters(in: .whitespaces),
                String(headline[whole.upperBound...]).trimmingCharacters(in: .whitespaces)
            )
        }
        return ("", headline)
    }

    private static func listItems(in lines: [String]) -> [String] {
        lines.compactMap(listItem(in:))
    }

    private static func listItem(in line: String) -> String? {
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

    private static func stripEmphasis(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// One suggested answer for a blocking question. `description` explains the
/// impact of choosing it, while the label is the stable value returned to the
/// waiting agent.
struct AgentQuestionOption: Codable, Hashable, Identifiable {
    var label: String = ""
    var description: String = ""

    var id: String { label }

    init(label: String = "", description: String = "") {
        self.label = label
        self.description = description
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? container.decode(String.self, forKey: .label)) ?? ""
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
    }
}

struct AgentQuestion: Codable, Hashable, Identifiable {
    var id: String = "q1"
    var header: String = ""
    var question: String = ""
    var multiSelect = false
    var options: [AgentQuestionOption] = []

    private enum CodingKeys: String, CodingKey {
        case id, header, question, options
        case multiSelect = "multi_select"
    }

    init(
        id: String = "q1",
        header: String = "",
        question: String = "",
        multiSelect: Bool = false,
        options: [AgentQuestionOption] = []
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.multiSelect = multiSelect
        self.options = options
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? "q1"
        header = (try? container.decode(String.self, forKey: .header)) ?? ""
        question = (try? container.decode(String.self, forKey: .question)) ?? ""
        multiSelect = (try? container.decode(Bool.self, forKey: .multiSelect)) ?? false
        options = (try? container.decode([AgentQuestionOption].self, forKey: .options)) ?? []
    }
}

/// A blocking `question_required` request. Lenient decoding is important: a
/// worker is waiting for a response, so malformed optional fields must not
/// strand the turn without a visible way to cancel it.
struct AgentQuestionRequest: Codable, Hashable, Identifiable {
    var id: String = ""
    var toolID: String = ""
    var tool: String = "ask_question"
    var questions: [AgentQuestion] = []

    private enum CodingKeys: String, CodingKey {
        case tool, questions
        case id = "request_id"
        case toolID = "id"
    }

    init(
        id: String = "",
        toolID: String = "",
        tool: String = "ask_question",
        questions: [AgentQuestion] = []
    ) {
        self.id = id
        self.toolID = toolID
        self.tool = tool
        self.questions = questions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        toolID = (try? container.decode(String.self, forKey: .toolID)) ?? ""
        tool = (try? container.decode(String.self, forKey: .tool)) ?? "ask_question"
        questions = (try? container.decode([AgentQuestion].self, forKey: .questions)) ?? []
    }
}

struct AgentQuestionAnswer: Codable, Hashable {
    var id: String
    var selected: [String] = []
    var text: String = ""
}
