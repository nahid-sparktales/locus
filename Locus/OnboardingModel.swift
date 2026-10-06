import Combine
import Foundation

enum OnboardingStartingPoint: String, Codable, CaseIterable, Identifiable {
    case documents, coding, agents
    var id: String { rawValue }
    var title: String {
        switch self {
        case .documents: "Documents and research"
        case .coding: "Coding"
        case .agents: "Agents and recurring tasks"
        }
    }
    var summary: String {
        switch self {
        case .documents: "Ask questions, explore a topic, or summarize your files."
        case .coding: "Get to know a code project and find your next steps."
        case .agents: "Let Locus handle regular work or respond to new events."
        }
    }
    var symbol: String {
        switch self {
        case .documents: "doc.text.magnifyingglass"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .agents: "clock.arrow.circlepath"
        }
    }
    var outputPath: String? {
        switch self {
        case .documents: "Locus Summary.md"
        case .coding: "Repository Overview.md"
        case .agents: nil
        }
    }
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
            case .startingPoint: "What would you like to do?"
            case .model: "Choose your AI"
            case .workspace: "Choose a folder to work in"
            case .firstTask: "Try your first task"
            }
        }
    }

    struct Progress: Codable, Equatable {
        var version = 2
        var step: Step = .startingPoint
        var startingPoint: OnboardingStartingPoint = .documents
        var workspace: String?
        var usesSample = false
        var dismissed = false
        /// Optional for setup progress saved before first-launch presentation was tracked.
        var presentedOnLaunch: Bool? = nil
        var run: OnboardingRun?
        var firstTaskCompleted = false
        var durationMilliseconds: Int?
        var firstResponseMilliseconds: Int?
        var outputTokensPerSecond: Double?
        var failure: String?
        /// Optional when decoding the original Getting Started progress.
        var companion: CompanionOnboardingProgress?
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
    private var pendingAgentSetup = false
    private var pendingLaunchPresentation = false
    private var companionCommitter: (CompanionOnboardingDraft) throws -> UUID = { _ in
        throw CocoaError(.featureUnsupported)
    }
    private var primaryCompanionProvider: () -> UUID? = { nil }

    var companion: CompanionOnboardingProgress { progress.companion ?? .init() }
    var showsCompanionSetup: Bool { companion.showsSetup && companion.status != .completed }
    var companionNameError: String? {
        do { _ = try CompanionValidationError.validatedName(companion.draft.name); return nil }
        catch { return error.localizedDescription }
    }

    var isRunning: Bool { progress.run != nil && !progress.firstTaskCompleted && progress.failure == nil }
    var steps: [Step] {
        progress.startingPoint == .agents ? [.startingPoint, .firstTask] : Step.allCases
    }
    var stepNumber: Int { (steps.firstIndex(of: progress.step) ?? 0) + 1 }
    var stepTitle: String {
        progress.startingPoint == .agents && progress.step == .firstTask
            ? "Set up your first agent" : progress.step.title
    }

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
        progress = Progress()
        let hasSavedProgress = defaults?.data(forKey: persistenceKey) != nil
        if let data = defaults?.data(forKey: persistenceKey),
           let saved = try? JSONDecoder().decode(Progress.self, from: data), (1...2).contains(saved.version) {
            progress = saved
            // An existing Getting Started record is itself installation evidence.
            // Adding a field in an upgrade must never produce a fresh-install offer.
            if progress.companion == nil {
                progress.companion = CompanionOnboardingProgress(status: .deferred, showsSetup: false)
            }
        } else {
            let existing = isExistingInstallation || hasSavedProgress
            progress.dismissed = existing
            progress.companion = CompanionOnboardingProgress(
                status: existing ? .deferred : .notOffered,
                showsSetup: !existing
            )
        }
        progress.version = 2
        // The main window consumes this after mounting its sheet host.
        pendingLaunchPresentation = autoPresent && !isExistingInstallation && !progress.dismissed
            && !progress.firstTaskCompleted && progress.presentedOnLaunch != true
            && companion.status == .notOffered
        self.readiness = readiness()
        if isRunning { monitor() }
    }

    func presentOnLaunchIfNeeded() {
        guard pendingLaunchPresentation else { return }
        pendingLaunchPresentation = false
        // Multiple sheet hosts (or model instances sharing this edition's
        // defaults) must claim the offer on the main actor before presenting.
        if let data = defaults?.data(forKey: persistenceKey),
           let saved = try? JSONDecoder().decode(Progress.self, from: data),
           saved.presentedOnLaunch == true || saved.dismissed || saved.companion?.status != .notOffered {
            progress = saved
            return
        }
        // Save immediately so quitting with setup still open does not make it
        // reappear on the next launch. Manual setup remains resumable from Help.
        progress.presentedOnLaunch = true
        progress.companion?.status = .inProgress
        persist()
        present()
    }

    func present() {
        isPresented = true
        error = showsCompanionSetup ? nil : progress.failure
        readiness = readinessProvider()
        if isRunning { monitor() }
    }

    func dismiss() {
        pendingLaunchPresentation = false
        progress.dismissed = true
        if companion.status != .completed { progress.companion?.status = .deferred }
        isPresented = false
        persist()
    }

    func configureCompanion(
        commit: @escaping (CompanionOnboardingDraft) throws -> UUID,
        primaryProfileID: @escaping () -> UUID?
    ) {
        companionCommitter = commit
        primaryCompanionProvider = primaryProfileID
        if let id = primaryProfileID() {
            // Reconcile a crash after the profile store committed and before
            // Getting Started recorded completion. Never create a second agent.
            recordCompanionCompletion(id)
        }
    }

    func beginCompanionSetup() {
        guard companion.status != .completed || primaryCompanionProvider() == nil else { return }
        if progress.companion == nil || companion.status == .completed {
            progress.companion = .init()
        }
        progress.companion?.status = .inProgress
        progress.companion?.showsSetup = true
        persist()
        present()
    }

    func showGettingStarted(step: Step? = nil) {
        progress.companion?.showsSetup = false
        if let step { progress.step = step }
        persist()
    }

    func setCompanionName(_ name: String) {
        guard companion.status != .completed else { return }
        progress.companion?.draft.name = name
        progress.companion?.draft.nameIsCustomized = true
        error = nil
        persist()
    }

    func setCompanionInstructions(_ instructions: String) {
        guard companion.status != .completed else { return }
        progress.companion?.draft.customInstructions = instructions
        persist()
    }

    func selectCompanionAppearance(_ appearance: CompanionAppearance, avatarData: Data? = nil) {
        guard companion.status != .completed else { return }
        progress.companion?.draft.selectAppearance(appearance, avatarData: avatarData)
        error = nil
        persist()
    }

    func selectExistingCompanion(_ id: UUID?) {
        guard companion.status != .completed else { return }
        progress.companion?.draft.existingProfileID = id
        error = nil
        persist()
    }

    func companionNext() {
        error = nil
        switch companion.step {
        case .welcome:
            progress.companion?.step = companion.draft.existingProfileID == nil ? .appearance : .introduction
        case .appearance:
            progress.companion?.step = companion.draft.existingProfileID == nil ? .name : .introduction
        case .name:
            do {
                let name = try CompanionValidationError.validatedName(companion.draft.name)
                progress.companion?.draft.name = name
                progress.companion?.step = .introduction
            } catch { self.error = error.localizedDescription }
        case .introduction: break
        }
        persist()
    }

    func companionBack() {
        error = nil
        switch companion.step {
        case .welcome: break
        case .appearance: progress.companion?.step = .welcome
        case .name: progress.companion?.step = .appearance
        case .introduction:
            progress.companion?.step = companion.draft.existingProfileID == nil ? .name : .appearance
        }
        persist()
    }

    @discardableResult
    func completeCompanion() -> UUID? {
        if let id = primaryCompanionProvider() ?? companion.completedProfileID {
            recordCompanionCompletion(id)
            return id
        }
        do {
            // Persist the reserved identity before invoking the canonical owner.
            // Its commit is synchronous on MainActor, so double clicks serialize.
            if companion.draft.existingProfileID == nil {
                progress.companion?.draft.name = try CompanionValidationError.validatedName(companion.draft.name)
            }
            persist()
            let id = try companionCommitter(companion.draft)
            recordCompanionCompletion(id)
            return id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func recordCompanionCompletion(_ id: UUID) {
        progress.companion?.completedProfileID = id
        progress.companion?.status = .completed
        progress.companion?.showsSetup = false
        // Approved pixels now belong exclusively to the canonical portrait store.
        progress.companion?.draft.avatarData = nil
        progress.dismissed = true
        pendingLaunchPresentation = false
        error = nil
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

    func requestAgentSetup() {
        guard progress.startingPoint == .agents, !isStarting, !isRunning else { return }
        pendingAgentSetup = true
        dismiss()
    }

    func takeAgentSetupRequest() -> Bool {
        defer { pendingAgentSetup = false }
        return pendingAgentSetup
    }

    func select(_ point: OnboardingStartingPoint) {
        guard !isStarting, !isRunning, progress.startingPoint != point else { return }
        if progress.usesSample {
            progress.workspace = nil
            progress.usesSample = false
        }
        progress.startingPoint = point
        progress.run = nil
        progress.firstTaskCompleted = false
        progress.durationMilliseconds = nil
        progress.firstResponseMilliseconds = nil
        progress.outputTokensPerSecond = nil
        progress.failure = nil
        isWaitingForOutput = false
        error = nil
        if !steps.contains(progress.step) { progress.step = .startingPoint }
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
        guard !isStarting, let index = steps.firstIndex(of: progress.step), index + 1 < steps.count else { return }
        progress.step = steps[index + 1]
        error = nil
        persist()
    }

    func back() {
        guard !isStarting, let index = steps.firstIndex(of: progress.step), index > 0 else { return }
        progress.step = steps[index - 1]
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
        guard progress.startingPoint != .agents, !isStarting, !isRunning, !progress.firstTaskCompleted else { return }
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
