import Combine
import Foundation

struct ModelInfo: Codable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let size: Int64
    let parameterSize: String
    /// The window the model is actually running in — 0 when it is not loaded
    /// or the agent cannot tell. This is what sessions are metered against.
    let contextLength: Int
    /// The window the model was built for; the number to compare models by.
    let trainedContextLength: Int
    /// Whether the model accepts image input. Ollama states it outright; a
    /// remote listing says nothing, so nil means "not known", never a guess.
    let visionCapable: Bool?

    enum CodingKeys: String, CodingKey {
        case name, size
        case parameterSize = "parameter_size"
        case contextLength = "context_length"
        case trainedContextLength = "trained_context_length"
        case visionCapable = "vision"
    }

    init(
        name: String,
        size: Int64,
        parameterSize: String,
        contextLength: Int,
        trainedContextLength: Int = 0,
        visionCapable: Bool? = nil
    ) {
        self.name = name
        self.size = size
        self.parameterSize = parameterSize
        self.contextLength = contextLength
        self.trainedContextLength = trainedContextLength
        self.visionCapable = visionCapable
    }

    // Only the name is essential; a model whose metadata is missing must
    // still appear in the picker rather than vanish from the list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        parameterSize = try container.decodeIfPresent(String.self, forKey: .parameterSize) ?? ""
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength) ?? 0
        trainedContextLength = try container.decodeIfPresent(Int.self, forKey: .trainedContextLength) ?? 0
        visionCapable = try container.decodeIfPresent(Bool.self, forKey: .visionCapable)
    }

    var detail: String {
        // The picker compares models, so it shows the trained window; older
        // agents only report the single context_length, which fills in.
        let window = trainedContextLength > 0 ? trainedContextLength : contextLength
        let context = window > 0 ? "\(max(window / 1024, 1))k ctx" : ""
        return [parameterSize, context].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var sizeLabel: String {
        guard size > 0 else { return "Size unavailable" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// What the solo-message router should optimize. The scorecard remains fully
/// visible whichever preset is selected; a preset changes weights, not the
/// eligibility or privacy rules.
enum ModelRoutingPolicy: String, Codable, CaseIterable, Identifiable {
    case balanced
    case bestAnswer = "best_answer"
    case fast
    case privateLocal = "private_local"
    case lowCost = "low_cost"
    case smallerFootprint = "smaller_footprint"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .bestAnswer: "Best answer"
        case .fast: "Fast"
        case .privateLocal: "Private / local"
        case .lowCost: "Lower cost"
        case .smallerFootprint: "Smaller footprint"
        }
    }

    var weights: [String: Double] {
        switch self {
        case .balanced:
            ["quality": 0.32, "reliability": 0.16, "privacy": 0.14,
             "latency": 0.14, "cost": 0.12, "efficiency": 0.12]
        case .bestAnswer:
            ["quality": 0.52, "reliability": 0.18, "privacy": 0.08,
             "latency": 0.07, "cost": 0.05, "efficiency": 0.10]
        case .fast:
            ["quality": 0.22, "reliability": 0.15, "privacy": 0.08,
             "latency": 0.38, "cost": 0.07, "efficiency": 0.10]
        case .privateLocal:
            ["quality": 0.22, "reliability": 0.13, "privacy": 0.37,
             "latency": 0.08, "cost": 0.10, "efficiency": 0.10]
        case .lowCost:
            ["quality": 0.22, "reliability": 0.13, "privacy": 0.10,
             "latency": 0.09, "cost": 0.36, "efficiency": 0.10]
        case .smallerFootprint:
            ["quality": 0.22, "reliability": 0.13, "privacy": 0.12,
             "latency": 0.10, "cost": 0.08, "efficiency": 0.35]
        }
    }
}

struct ModelRoutingScorecard: Codable, Hashable, Identifiable {
    let routeID: String
    let name: String
    let model: String
    let provider: String
    let local: Bool
    let current: Bool
    let selected: Bool
    let score: Double
    let components: [String: Double]
    let weights: [String: Double]
    let sampleCount: Int
    let evaluationCount: Int
    let limitedData: Bool

    var id: String { routeID }

    enum CodingKeys: String, CodingKey {
        case name, model, provider, local, current, selected, score, components, weights
        case routeID = "route_id"
        case sampleCount = "sample_count"
        case evaluationCount = "evaluation_count"
        case limitedData = "limited_data"
    }
}

struct ModelRoutingDecision: Codable, Hashable {
    let selectedID: String
    let limitedData: Bool
    let reason: String
    let tags: [String]
    let candidates: [ModelRoutingScorecard]

    enum CodingKeys: String, CodingKey {
        case reason, tags, candidates
        case selectedID = "selected_id"
        case limitedData = "limited_data"
    }
}

enum ModelProvider: String, Codable, CaseIterable, Identifiable {
    case ollama
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama: "Local Ollama"
        case .remote: "Remote endpoint"
        }
    }

    var detail: String {
        switch self {
        case .ollama: "Models installed on this Mac"
        case .remote: "A Hugging Face endpoint, vLLM, or TGI on a rented GPU"
        }
    }
}

/// How outbound traffic leaves the machine. `off` is the pre-proxy behavior:
/// the app's own requests follow macOS system settings on their own, and the
/// agent keeps whatever environment the shell provided.
struct ProviderStateResponse: Codable {
    let provider: String
    let host: String
    let model: String
    let remoteBaseURL: String
    let remoteModel: String
    let hasAPIKey: Bool

    enum CodingKeys: String, CodingKey {
        case provider, host, model
        case remoteBaseURL = "remote_base_url"
        case remoteModel = "remote_model"
        case hasAPIKey = "has_api_key"
    }
}

struct ChatGPTAccountResponse: Codable, Hashable {
    let status: String
    let runtimeAvailable: Bool
    let runtimeVersion: String?
    let email: String?
    let planType: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status, email, message
        case runtimeAvailable = "runtime_available"
        case runtimeVersion = "runtime_version"
        case planType = "plan_type"
    }
}

struct ChatGPTLoginResponse: Codable, Hashable {
    let status: String
    let loginID: String
    let authURL: String

    enum CodingKeys: String, CodingKey {
        case status
        case loginID = "login_id"
        case authURL = "auth_url"
    }
}

struct ChatGPTModelsResponse: Codable, Hashable {
    struct EffortOption: Codable, Hashable {
        let effort: String
        let description: String?
    }

    struct Model: Codable, Hashable, Identifiable {
        let id: String
        let displayName: String
        let description: String
        let isDefault: Bool
        /// Optional so rows from a backend that predates reasoning-effort
        /// reporting decode unchanged.
        let supportedReasoningEfforts: [EffortOption]?
        let defaultReasoningEffort: String?

        enum CodingKeys: String, CodingKey {
            case id, description
            case displayName = "display_name"
            case isDefault = "is_default"
            case supportedReasoningEfforts = "supported_reasoning_efforts"
            case defaultReasoningEffort = "default_reasoning_effort"
        }
    }

    let status: String
    let models: [Model]
    let message: String?
}

struct ChatGPTUsageResponse: Codable, Hashable {
    struct Window: Codable, Hashable {
        let usedPercent: Int
        let resetsAt: Int?
        let windowDurationMins: Int?
    }

    struct Snapshot: Codable, Hashable {
        let planType: String?
        let primary: Window?
        let secondary: Window?
        let spendControlReached: Bool?
    }

    struct RateLimits: Codable, Hashable {
        let rateLimits: Snapshot?
    }

    struct ActivitySummary: Codable, Hashable {
        let lifetimeTokens: Int?
        let peakDailyTokens: Int?
        let longestRunningTurnSec: Int?
        let currentStreakDays: Int?
        let longestStreakDays: Int?
    }

    struct Activity: Codable, Hashable {
        let summary: ActivitySummary?
    }

    let status: String
    let planType: String?
    let rateLimits: RateLimits
    let activity: Activity
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status, activity, message
        case planType = "plan_type"
        case rateLimits = "rate_limits"
    }
}
