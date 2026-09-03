import Foundation

/// One suggested answer. `description` says what choosing it commits to.
struct AgentQuestionOption: Codable, Hashable, Identifiable {
    var label: String = ""
    var description: String = ""

    /// Answers travel back by label rather than by index, so the panel and the
    /// backend can never disagree about ordering. The backend drops duplicate
    /// labels for the same reason, which is what makes this a usable id.
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
    var multiSelect: Bool = false
    /// Empty is the free-text case, and is a first-class shape rather than a
    /// degenerate one: the panel still renders, with the entry field focused.
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

/// A `question_required` event.
///
/// Every field is defaulted and decoded leniently on purpose. Unlike a plan,
/// which the client may simply decline to render, a question has a worker
/// thread parked on the other end of it: a decode failure here would drop the
/// panel *and* wedge the agent until Stop. `AppModel` answers a payload it
/// cannot render with an explicit cancel for the same reason.
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
