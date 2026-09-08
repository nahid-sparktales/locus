import Foundation

/// The image sizes the agent's `/api/images/provider` route accepts. Fixed
/// enums rather than free text: a typo here would otherwise travel all the
/// way to the provider before anyone noticed.
enum ImageGenerationSize: String, CaseIterable, Identifiable {
    case auto
    case square = "1024x1024"
    case landscape = "1536x1024"
    case portrait = "1024x1536"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .square: "Square (1024 × 1024)"
        case .landscape: "Landscape (1536 × 1024)"
        case .portrait: "Portrait (1024 × 1536)"
        }
    }
}

enum ImageGenerationQuality: String, CaseIterable, Identifiable {
    case auto, low, medium, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
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
