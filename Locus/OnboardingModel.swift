import Combine
import Foundation

enum OnboardingStartingPoint: String, Codable, CaseIterable, Identifiable {
    case documents, coding
    var id: String { rawValue }
    var title: String { self == .documents ? "Documents and research" : "Coding" }
    var outputPath: String { self == .documents ? "Locus Summary.md" : "Repository Overview.md" }
}

struct OnboardingRun: Codable, Equatable {
    let sessionID: String
    let workspace: String
    let outputPath: String
    let startedAt: Date
    let requestStartedAt: Int
    var startingCompletionTokens: Int? = nil
    /// Optional so progress saved before durable run tracking still decodes.
    var runID: String? = nil
}

/// The stable task receipt is independent of the current chat and its bounded
/// Overview event history. These fields come from GET /api/runs/{run_id}.
struct OnboardingRunReceipt: Decodable, Equatable {
    let id: String
    let sessionID: String?
    let workspaceRoot: String?
    let state: String
    let createdAt: Double
    let updatedAt: Double
    let completedAt: Double?
    var usage: Usage? = nil

    struct Usage: Decodable, Equatable {
        let completionTokens: Int?
        enum CodingKeys: String, CodingKey { case completionTokens = "completion_tokens" }
    }
    enum CodingKeys: String, CodingKey {
        case id, state, usage
        case sessionID = "session_id", workspaceRoot = "workspace_root"
        case createdAt = "created_at", updatedAt = "updated_at", completedAt = "completed_at"
    }

    func observation(for run: OnboardingRun, savedOutput: Bool, now: Date = Date()) -> OnboardingRunObservation {
        guard id == run.runID, sessionID == run.sessionID,
              workspaceRoot.map(Self.canonical) == Self.canonical(run.workspace) else {
            return .failed("The saved task does not match this example. Open its chat or start a new example.")
        }
        guard state == "completed" else {
            if ["failed", "interrupted", "cancelled", "discarded"].contains(state) {
                return .failed("The task stopped before finishing. Open its chat or retry the example.")
            }
            return .running
        }
        let endedAt = completedAt ?? updatedAt
        let duration = Int(max(0, endedAt - createdAt) * 1_000)
        guard savedOutput else {
            if now.timeIntervalSince1970 - endedAt > 30 {
                return .failed("The reply finished, but its output was not saved. Check the chat and Library storage, then retry.")
            }
            return .awaitingOutput(durationMilliseconds: duration)
        }
        let throughput = usage?.completionTokens.flatMap { tokens -> Double? in
            guard tokens > 0, duration > 0 else { return nil }
            return Double(tokens) / (Double(duration) / 1_000)
        }
        return .completed(durationMilliseconds: duration, outputTokensPerSecond: throughput)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct OnboardingReadiness: Equatable {
    let agentReady: Bool
    let modelReady: Bool
    let modelName: String
    let detail: String
    var ready: Bool { agentReady && modelReady && !modelName.isEmpty }
    static let unknown = Self(agentReady: false, modelReady: false, modelName: "", detail: "Checking your connection…")
}

enum OnboardingRunObservation: Equatable {
    case running
    case awaitingOutput(durationMilliseconds: Int)
    case completed(durationMilliseconds: Int, firstResponseMilliseconds: Int? = nil, outputTokensPerSecond: Double? = nil)
    case failed(String)
}

/// Owns setup progress independently of the chat/provider state machines.
/// Construction is inert; persistence and actions are injected by the app.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, Codable, CaseIterable {
        case startingPoint, model, workspace, firstTask
        var title: String {
            switch self {
            case .startingPoint: "Choose your starting point"
            case .model: "Connect a model"
            case .workspace: "Choose a workspace"
            case .firstTask: "Complete your first task"
            }
        }
    }

    struct Progress: Codable, Equatable {
        var version = 1
        var step: Step = .startingPoint
        var startingPoint: OnboardingStartingPoint = .documents
        var workspace: String?
        var usesSample = false
        var dismissed = false
        var run: OnboardingRun?
        var firstTaskCompleted = false
        var durationMilliseconds: Int?
        var firstResponseMilliseconds: Int?
        var outputTokensPerSecond: Double?
        var failure: String?
    }

    @Published var isPresented = false
    @Published private(set) var progress = Progress()
    @Published private(set) var readiness = OnboardingReadiness.unknown
    @Published private(set) var isStarting = false
    @Published private(set) var isChecking = false
    @Published private(set) var isWaitingForOutput = false
    @Published private(set) var error: String?

    private var defaults: UserDefaults?
    private let persistenceKey = "Locus.onboarding.v1"
    private var readinessProvider: () -> OnboardingReadiness = { .unknown }
    private var refreshConnection: () async -> Void = {}
    private var starter: (OnboardingStartingPoint, String) async throws -> OnboardingRun = { _, _ in
        throw CocoaError(.featureUnsupported)
    }
    private var observer: (OnboardingRun) async -> OnboardingRunObservation = { _ in .running }
    private var monitorTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var pendingOutput: OnboardingRun?

    var isRunning: Bool { progress.run != nil && !progress.firstTaskCompleted && progress.failure == nil }

    func configure(
        defaults: UserDefaults? = nil,
        isExistingInstallation: Bool,
        autoPresent: Bool,
        readiness: @escaping () -> OnboardingReadiness,
        refresh: @escaping () async -> Void,
        start: @escaping (OnboardingStartingPoint, String) async throws -> OnboardingRun,
        observe: @escaping (OnboardingRun) async -> OnboardingRunObservation
    ) {
        self.defaults = defaults
        readinessProvider = readiness
        refreshConnection = refresh
        starter = start
        observer = observe
        if let data = defaults?.data(forKey: persistenceKey),
           let saved = try? JSONDecoder().decode(Progress.self, from: data), saved.version == 1 {
            progress = saved
        } else {
            progress.dismissed = isExistingInstallation
        }
        isPresented = autoPresent && !progress.dismissed && !progress.firstTaskCompleted
        self.readiness = readiness()
        if isRunning { monitor() }
    }

    func present() {
        isPresented = true
        error = progress.failure
        readiness = readinessProvider()
        if isRunning { monitor() }
    }

    func dismiss() {
        progress.dismissed = true
        isPresented = false
        persist()
    }

    func requestOutputs() {
        guard progress.firstTaskCompleted, let run = progress.run else { return }
        pendingOutput = run
        dismiss()
    }

    func takeOutputRequest() -> OnboardingRun? {
        defer { pendingOutput = nil }
        return pendingOutput
    }

    func select(_ point: OnboardingStartingPoint) {
        guard !isStarting, !isRunning else { return }
        if progress.startingPoint != point, progress.usesSample {
            progress.workspace = nil
            progress.usesSample = false
        }
        progress.startingPoint = point
        persist()
    }

    func selectWorkspace(_ path: String, sample: Bool) {
        guard !isStarting, !isRunning else { return }
        progress.workspace = path
        progress.usesSample = sample
        error = nil
        persist()
    }

    func next() {
        guard let step = Step(rawValue: progress.step.rawValue + 1) else { return }
        progress.step = step
        error = nil
        persist()
    }

    func back() {
        guard !isStarting, let step = Step(rawValue: progress.step.rawValue - 1) else { return }
        progress.step = step
        error = nil
        persist()
    }

    func refreshReadiness() {
        readiness = readinessProvider()
    }

    func checkConnection() {
        guard !isChecking else { return }
        isChecking = true
        checkTask = Task { [weak self] in
            guard let self else { return }
            await refreshConnection()
            readiness = readinessProvider()
            isChecking = false
        }
    }

    func reportError(_ message: String) { error = message }

    func runFirstTask() {
        guard !isStarting, !isRunning, !progress.firstTaskCompleted else { return }
        readiness = readinessProvider()
        guard readiness.ready else { error = "Connect a ready model before starting."; return }
        guard let workspace = progress.workspace else { error = "Choose a workspace first."; return }
        isStarting = true
        progress.failure = nil
        error = nil
        startTask = Task { [weak self] in
            guard let self else { return }
            defer { isStarting = false }
            do {
                progress.run = try await starter(progress.startingPoint, workspace)
                persist()
                // The normal chat owns approvals and progress. Setup stays
                // resumable in Help while the user works in that chat.
                isPresented = false
                monitor()
            } catch {
                self.error = error.localizedDescription
                progress.failure = error.localizedDescription
                persist()
            }
        }
    }

    func refreshRun() async {
        guard let run = progress.run, isRunning else { return }
        let result = await observer(run)
        guard progress.run == run else { return }
        switch result {
        case .running:
            isWaitingForOutput = false
        case .awaitingOutput(let duration):
            isWaitingForOutput = true
            progress.durationMilliseconds = duration
        case .completed(let duration, let firstResponse, let throughput):
            progress.firstTaskCompleted = true
            progress.dismissed = true
            progress.durationMilliseconds = duration
            progress.firstResponseMilliseconds = firstResponse
            progress.outputTokensPerSecond = throughput
            isWaitingForOutput = false
            persist()
        case .failed(let message):
            progress.failure = message
            error = message
            isWaitingForOutput = false
            persist()
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func monitor() {
        stopMonitoring()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                await self.refreshRun()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults?.set(data, forKey: persistenceKey)
    }
}
