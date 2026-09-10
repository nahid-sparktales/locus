import Foundation

/// Common Image API sizes. Model-aware validation also admits custom sizes
/// before a request can reach the provider.
enum ImageGenerationSize: String, CaseIterable, Identifiable {
    case auto
    case square = "1024x1024"
    case landscape = "1536x1024"
    case portrait = "1024x1536"
    case square2K = "2048x2048"
    case landscape2K = "2048x1152"
    case landscape4K = "3840x2160"
    case portrait4K = "2160x3840"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .square: "Square (1024 × 1024)"
        case .landscape: "Landscape (1536 × 1024)"
        case .portrait: "Portrait (1024 × 1536)"
        case .square2K: "2K square (2048 × 2048)"
        case .landscape2K: "2K landscape (2048 × 1152)"
        case .landscape4K: "4K landscape (3840 × 2160)"
        case .portrait4K: "4K portrait (2160 × 3840)"
        }
    }
}

enum ImageGenerationQuality: String, CaseIterable, Identifiable {
    case auto, low, medium, high, xhigh, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }
}

/// Image API options vary by model. Snapshots retain their family's contract;
/// unknown compatible models keep the established baseline options.
enum ImageGenerationOptions {
    static func hasExtendedQuality(_ model: String) -> Bool {
        model.lowercased().range(of: "^gpt-image-2\\.5-(sunburst|flare)(-\\d{4}-\\d{2}-\\d{2})?$",
                                 options: .regularExpression) != nil
    }

    static func hasCustomSizes(_ model: String) -> Bool {
        hasExtendedQuality(model) || model.lowercased().range(
            of: "^gpt-image-2(-\\d{4}-\\d{2}-\\d{2})?$", options: .regularExpression
        ) != nil
    }

    static func qualities(for model: String) -> [ImageGenerationQuality] {
        hasExtendedQuality(model) ? ImageGenerationQuality.allCases : [.auto, .low, .medium, .high]
    }

    static func sizes(for model: String) -> [ImageGenerationSize] {
        hasCustomSizes(model) ? ImageGenerationSize.allCases : [.auto, .square, .landscape, .portrait]
    }

    static func isValidSize(_ size: String, model: String) -> Bool {
        if sizes(for: model).contains(where: { $0.rawValue == size }) { return true }
        guard hasCustomSizes(model),
              size.range(of: "^[1-9][0-9]{0,3}x[1-9][0-9]{0,3}$", options: .regularExpression) != nil else { return false }
        let edges = size.split(separator: "x").compactMap { Int($0) }
        guard edges.count == 2 else { return false }
        let width = edges[0], height = edges[1]
        return width % 16 == 0 && height % 16 == 0 && max(width, height) <= 3840
            && max(width, height) <= 3 * min(width, height)
            && (655_360...8_294_400).contains(width * height)
    }

    static let sizeHelp = "Use width × height, with edges divisible by 16 and no larger than 3840 pixels. The aspect ratio must be between 1:3 and 3:1, with 655,360–8,294,400 total pixels. Resolutions above 2560 × 1440 are experimental."
}

/// Owns what the agent reports about its image provider: the public state
/// after each push and the last push that failed. AppModel wires it via
/// configure(...) and builds the request body — the key travels in that body
/// and is never retained here. The Settings section observes this model.
@MainActor
final class ImageGenerationModel: ObservableObject {
    /// The agent's public view of the provider after the latest successful
    /// push or refresh; nil until the agent has answered once.
    @Published private(set) var state: ImageProviderStateResponse?
    /// Why the most recent push or refresh failed, cleared by the next success.
    @Published private(set) var lastError: String?
    @Published private(set) var isApplying = false
    /// Set when an agent refused a push because a turn was running; AppModel
    /// re-pushes once that turn ends, so Settings and the agent converge.
    private(set) var pushDeferredUntilIdle = false

    private var backend: BackendService?

    func configure(backend: BackendService) {
        self.backend = backend
    }

    /// Pushes a provider body built by AppModel to the main agent and records
    /// the answer. Throws so the caller can decide whether to announce.
    @discardableResult
    func apply(body: [String: Any]) async throws -> ImageProviderStateResponse {
        guard let backend else {
            throw ImageGenerationError.notConfigured
        }
        isApplying = true
        defer { isApplying = false }
        do {
            let state = try await push(body: body, to: backend)
            record(state)
            return state
        } catch {
            recordFailure(error.localizedDescription)
            throw error
        }
    }

    /// The one request every agent process receives — the main agent through
    /// `apply`, each chat worker directly. Records nothing: a worker's answer
    /// is not the state Settings shows.
    func push(
        body: [String: Any],
        to service: BackendService
    ) async throws -> ImageProviderStateResponse {
        try await service.post(
            "/api/images/provider",
            body: body,
            as: ImageProviderStateResponse.self
        )
    }

    /// Whether a push failure means "try again when the turn is over": the
    /// agent answers 409 from `state_mutation` while a turn runs.
    static func isBusyRefusal(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "Locus.Backend" && nsError.code == 409
    }

    func deferPushUntilIdle() {
        pushDeferredUntilIdle = true
    }

    /// Clears and reports the deferred push, so it is retried exactly once.
    func takeDeferredPush() -> Bool {
        defer { pushDeferredUntilIdle = false }
        return pushDeferredUntilIdle
    }

    /// Reads the agent's current state without changing it, so the Settings
    /// section can show the truth after a restart or a push from elsewhere.
    func refresh() async {
        guard let backend else { return }
        do {
            record(try await backend.get(
                "/api/images/provider",
                as: ImageProviderStateResponse.self
            ))
        } catch {
            recordFailure(error.localizedDescription)
        }
    }

    func record(_ state: ImageProviderStateResponse) {
        self.state = state
        lastError = nil
    }

    func recordFailure(_ message: String) {
        lastError = message
    }
}

enum ImageGenerationError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured: "The local agent is not connected."
        }
    }
}
