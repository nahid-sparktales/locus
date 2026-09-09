import Combine
import Foundation

/// Owns presentation and admission of persistent goals. Durable state and the
/// continuation claim are always read from the authenticated backend.
@MainActor
final class GoalModel: ObservableObject {
    @Published private(set) var goals: [String: PersistentGoal] = [:]
    @Published var isPresented = false
    @Published var draftObjective = ""
    @Published var draftModelCallBudget = ""
    @Published var draftTokenBudget = ""
    @Published private(set) var draftRouteLabel = ""
    @Published private(set) var isSaving = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var supportsGoals = true
    @Published var error: String?

    private var backend: BackendService?
    private var canContinue: (PersistentGoal) -> Bool = { _ in false }
    private var dispatch: (PersistentGoal, OrchestrationRun) async -> Bool = { _, _ in false }
    private var stopTurn: (String) -> Void = { _ in }
    private var prepareResume: (String) -> Void = { _ in }
    private var notify: (PersistentGoal) -> Void = { _ in }
    private var isShuttingDown: () -> Bool = { true }
    private var isStopped = false
    private var coordinator: Task<Void, Never>?
    private var wakeRequested = false
    private var generation = UUID()
    private var refreshGeneration = UUID()
    private var suspendedSessionIDs = Set<String>()
    private var inputSuspendedSessionIDs = Set<String>()
    private var handedOffRunIDs: [String: String] = [:]
    private struct DispatchState {
        var runID: String
        var token: UUID
        var task: Task<Void, Never>
    }
    private var dispatches: [String: DispatchState] = [:]
    private var userInputTasks: [String: Task<PersistentGoal?, Never>] = [:]
    private var userInputTaskTokens: [String: UUID] = [:]
    private var pendingInputIDs: [String: [String]] = [:]
    private struct UserInput { var id: String; var text: String }
    private var userInputs: [String: [UserInput]] = [:]
    private var discardingInputSessionIDs = Set<String>()
    private var retiredGoalIDs = Set<String>()
    private var draftSessionID: String?
    private var editingGoalID: String?
    private var editingRevision: Int?
    private var draftExecution: [String: Any] = [:]

    var isEditing: Bool { editingGoalID != nil }
    var canSave: Bool { !isSaving && draftValidationError == nil && draftSessionID != nil }
    var draftValidationError: String? {
        if draftObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Describe what the goal should accomplish." }
        if Self.invalidBudget(draftModelCallBudget) || Self.invalidBudget(draftTokenBudget) {
            return "Enter a positive whole number for an allowance, or leave it empty."
        }
        return nil
    }

    func configure(
        backend: BackendService,
        canContinue: @escaping (PersistentGoal) -> Bool,
        dispatch: @escaping (PersistentGoal, OrchestrationRun) async -> Bool,
        stopTurn: @escaping (String) -> Void = { _ in },
        prepareResume: @escaping (String) -> Void = { _ in },
        notify: @escaping (PersistentGoal) -> Void = { _ in },
        isShuttingDown: @escaping () -> Bool = { false }
    ) {
        self.backend = backend
        self.canContinue = canContinue
        self.dispatch = dispatch
        self.stopTurn = stopTurn
        self.prepareResume = prepareResume
        self.notify = notify
        self.isShuttingDown = isShuttingDown
    }

    func goal(for sessionID: String) -> PersistentGoal? { goals[sessionID] }

    func open(sessionID: String, objective: String = "", execution: [String: Any] = [:], routeLabel: String = "") {
        guard !sessionID.isEmpty else { return }
        draftSessionID = sessionID
        error = nil
        if let goal = goals[sessionID], !goal.status.isTerminal {
            editingGoalID = goal.id
            editingRevision = goal.revision
            draftObjective = goal.objective
            draftModelCallBudget = goal.modelCallBudget.map(String.init) ?? ""
            draftTokenBudget = goal.tokenBudget.map(String.init) ?? ""
            draftRouteLabel = goal.routeLabel
            draftExecution = execution
            if !execution.isEmpty, !routeLabel.isEmpty { draftRouteLabel = routeLabel }
        } else {
            editingGoalID = nil
            editingRevision = nil
            draftObjective = objective
            draftModelCallBudget = ""
            draftTokenBudget = ""
            draftRouteLabel = routeLabel
            draftExecution = execution
        }
        isPresented = true
    }

    func saveDraft() async {
        guard let backend, let sessionID = draftSessionID, canSave, !isStopped, !isShuttingDown() else { return }
        let goalID = editingGoalID
        let revision = editingRevision
        let capturedGeneration = generation
        var body: [String: Any] = [
            "objective": draftObjective.trimmingCharacters(in: .whitespacesAndNewlines),
            "model_call_budget": Self.budget(draftModelCallBudget).map { $0 as Any } ?? NSNull(),
            "token_budget": Self.budget(draftTokenBudget).map { $0 as Any } ?? NSNull(),
        ]
        isSaving = true
        defer { isSaving = false }
        do {
            let goal: PersistentGoal
            if let goalID, let revision {
                suspend(sessionID: sessionID)
                guard let paused = await update(sessionID: sessionID, action: "pause",
                    reason: "Goal edited. Resume when ready.", expectedRevision: revision) else { return }
                stopTurn(sessionID)
                editingRevision = paused.revision
                body["action"] = "edit"
                body["expected_revision"] = paused.revision
                if !draftExecution.isEmpty { body["execution"] = draftExecution }
                goal = try await backend.patch("/api/goals/\(goalID)", body: body, as: PersistentGoal.self)
            } else {
                body["execution"] = draftExecution
                for key in ["workspace_root", "execution_path", "environment"] {
                    if let value = draftExecution[key] { body[key] = value }
                }
                goal = try await backend.post("/api/sessions/\(sessionID)/goal", body: body, as: PersistentGoal.self)
            }
            guard capturedGeneration == generation, !isShuttingDown(), goal.sessionID == sessionID else { return }
            ingest(goal)
            if draftSessionID == sessionID, editingGoalID == goalID {
                isPresented = false
                error = nil
            }
            if goal.status == .active { suspendedSessionIDs.remove(sessionID); prepareResume(sessionID) }
            wake()
        } catch {
            guard capturedGeneration == generation else { return }
            self.error = "Could not save the goal: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        guard let backend, !isStopped, !isShuttingDown() else { return }
        let token = UUID()
        refreshGeneration = token
        let capturedGeneration = generation
        isRefreshing = true
        defer { if refreshGeneration == token { isRefreshing = false } }
        do {
            let response = try await backend.get("/api/goals", as: GoalsResponse.self)
            guard refreshGeneration == token, generation == capturedGeneration, !isShuttingDown() else { return }
            let previousIDs = goals.mapValues(\.id)
            for goal in response.goals { ingest(goal) }
            for goal in goals.values where goal.status == .active && previousIDs[goal.sessionID] != goal.id {
                prepareResume(goal.sessionID)
            }
            supportsGoals = true
            wake()
        } catch {
            guard refreshGeneration == token, generation == capturedGeneration else { return }
            if (error as NSError).domain == "Locus.Backend", [404, 405].contains((error as NSError).code) {
                supportsGoals = false
                return
            }
            self.error = "Could not load goals: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func refresh(sessionID: String) async -> PersistentGoal? {
        guard let backend, !sessionID.isEmpty, !isStopped, !isShuttingDown() else { return nil }
        let capturedGeneration = generation
        do {
            let response = try await backend.get("/api/sessions/\(sessionID)/goal", as: SessionGoalResponse.self)
            guard generation == capturedGeneration, !isShuttingDown() else { return nil }
            if let goal = response.goal, goal.sessionID == sessionID { ingest(goal) }
            return goals[sessionID]
        } catch { return nil }
    }

    @discardableResult
    func handleEvent(_ event: [String: Any], sessionID: String) -> Bool {
        guard !isStopped, !isShuttingDown(), let type = event["type"] as? String else { return false }
        if let raw = event["goal"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let goal = try? JSONDecoder().decode(PersistentGoal.self, from: data),
           sessionID.isEmpty || goal.sessionID == sessionID {
            ingest(goal)
        }
        if type == "task_verification", let state = event["state"] as? String,
           let goal = goals[sessionID], event["task_id"] as? String == "goal:" + goal.id {
            goals[sessionID]?.verificationStatus = state
            return true
        }
        if type == "turn_done" || type == "error" {
            let runID = event["run_id"] as? String
            if runID == nil || handedOffRunIDs[sessionID] == runID { handedOffRunIDs[sessionID] = nil }
            Task { [weak self] in
                guard let self else { return }
                _ = await refresh(sessionID: sessionID)
                wake()
            }
        }
        if type == "goal_snapshot" || type == "goal_updated" { wake(); return true }
        return false
    }

    /// Called before awaiting a user action, so an in-flight claim cannot
    /// dispatch after Pause or a new user message has already taken priority.
    func suspend(sessionID: String) {
        suspendedSessionIDs.insert(sessionID)
        dispatches[sessionID]?.task.cancel()
        dispatches.removeValue(forKey: sessionID)
    }

    @discardableResult
    func pause(sessionID: String, reason: String = "Paused by you") async -> Bool {
        suspend(sessionID: sessionID)
        return await update(sessionID: sessionID, action: "pause", reason: reason) != nil
    }

    func pauseAndStop(sessionID: String) {
        suspend(sessionID: sessionID)
        Task { [weak self] in
            guard let self, await pause(sessionID: sessionID) else { return }
            stopTurn(sessionID)
        }
    }

    @discardableResult
    func acceptResult(sessionID: String) async {
        guard let goal = goals[sessionID], goal.status == .needsReview else { return }
        _ = await update(sessionID: sessionID, action: "accept", expectedRevision: goal.revision)
    }

    func resume(sessionID: String) async -> Bool {
        guard let goal = await update(sessionID: sessionID, action: "resume"), goal.status == .active else { return false }
        handedOffRunIDs[sessionID] = nil
        suspendedSessionIDs.remove(sessionID)
        inputSuspendedSessionIDs.remove(sessionID)
        prepareResume(sessionID)
        wake()
        return true
    }

    @discardableResult
    func cancel(sessionID: String) async -> Bool {
        suspend(sessionID: sessionID)
        guard await update(sessionID: sessionID, action: "cancel") != nil else { return false }
        stopTurn(sessionID)
        return true
    }

    @discardableResult
    func block(sessionID: String, reason: String) async -> Bool {
        // Dispatch itself can discover the blocker; do not cancel the task
        // that must persist that authoritative transition.
        suspendedSessionIDs.insert(sessionID)
        return await update(sessionID: sessionID, action: "block", reason: reason) != nil
    }

    @discardableResult
    func noteUserInput(sessionID: String, text: String = "") -> String? {
        guard !isStopped, let goal = goals[sessionID], goal.status == .active else { return nil }
        let inputID = UUID().uuidString
        inputSuspendedSessionIDs.insert(sessionID)
        handedOffRunIDs[sessionID] = nil
        dispatches[sessionID]?.task.cancel()
        dispatches.removeValue(forKey: sessionID)
        userInputs[sessionID, default: []].append(UserInput(id: inputID, text: Self.inputText(text)))
        pendingInputIDs[sessionID, default: []].append(inputID)
        startUserInputFence(sessionID: sessionID)
        return inputID
    }

    /// Queue entries can have identical text; consume the first matching entry
    /// so removing or retrying one message never releases another's fence.
    func takeUserInput(sessionID: String, text: String) -> String? {
        guard let index = userInputs[sessionID]?.firstIndex(where: { $0.text == Self.inputText(text) }) else { return nil }
        return userInputs[sessionID]?.remove(at: index).id
    }

    func restoreUserInput(sessionID: String, text: String, inputID: String) {
        guard !isStopped, !userInputs[sessionID, default: []].contains(where: { $0.id == inputID }) else { return }
        userInputs[sessionID, default: []].insert(UserInput(id: inputID, text: Self.inputText(text)), at: 0)
        inputSuspendedSessionIDs.insert(sessionID)
    }

    func isDiscardingUserInput(sessionID: String) -> Bool {
        discardingInputSessionIDs.contains(sessionID)
    }

    @discardableResult
    func discardUserInput(sessionID: String, text: String) async -> Bool {
        guard !discardingInputSessionIDs.contains(sessionID) else { return false }
        guard let inputID = takeUserInput(sessionID: sessionID, text: text) else { return true }
        discardingInputSessionIDs.insert(sessionID)
        defer { discardingInputSessionIDs.remove(sessionID) }
        let goalID = goals[sessionID]?.id
        inputSuspendedSessionIDs.insert(sessionID)
        guard await flushUserInput(sessionID: sessionID) != nil,
              goals[sessionID]?.id == goalID,
              let goal = await update(sessionID: sessionID, action: "discard_input", inputID: inputID) else {
            if goals[sessionID]?.id == goalID, goals[sessionID]?.status.isTerminal != true {
                restoreUserInput(sessionID: sessionID, text: text, inputID: inputID)
            }
            return false
        }
        if !goal.pendingUserInput { inputSuspendedSessionIDs.remove(sessionID) }
        wake()
        return true
    }

    private func startUserInputFence(sessionID: String) {
        guard userInputTasks[sessionID] == nil, !isStopped, !isShuttingDown(),
              !pendingInputIDs[sessionID, default: []].isEmpty else { return }
        userInputTaskTokens[sessionID] = UUID()
        let goalID = goals[sessionID]?.id
        userInputTasks[sessionID] = Task { [weak self] in
            guard let self else { return nil }
            while let inputID = pendingInputIDs[sessionID]?.first {
                guard !Task.isCancelled, !isStopped,
                      await update(sessionID: sessionID, action: "steer", inputID: inputID) != nil else { return nil }
                guard !Task.isCancelled, goals[sessionID]?.id == goalID else { return nil }
                pendingInputIDs[sessionID]?.removeFirst()
            }
            return goals[sessionID]
        }
    }

    func flushUserInput(sessionID: String) async -> PersistentGoal? {
        while !isStopped {
            startUserInputFence(sessionID: sessionID)
            guard let task = userInputTasks[sessionID] else { return goals[sessionID] }
            let token = userInputTaskTokens[sessionID]
            let goal = await task.value
            if userInputTaskTokens[sessionID] == token {
                userInputTasks[sessionID] = nil
                userInputTaskTokens[sessionID] = nil
            }
            guard goal != nil else { return nil }
            if pendingInputIDs[sessionID, default: []].isEmpty { return goals[sessionID] }
        }
        return nil
    }

    /// Wakeups are hints. A single coordinator checks authoritative state and
    /// root admission again after the claim before handing a run to dispatch.
    func wake() {
        guard supportsGoals, !isStopped, !isShuttingDown() else { return }
        guard coordinator == nil else { wakeRequested = true; return }
        wakeRequested = false
        let capturedGeneration = generation
        coordinator = Task { [weak self] in
            guard let self else { return }
            defer {
                if capturedGeneration == generation {
                    coordinator = nil
                    if wakeRequested { wake() }
                }
            }
            for goal in goals.values.sorted(by: { $0.sessionID < $1.sessionID }) {
                guard !Task.isCancelled, capturedGeneration == generation, !isShuttingDown() else { return }
                guard eligible(goal), let backend else { continue }
                do {
                    let response = try await backend.post("/api/goals/\(goal.id)/claim",
                        body: ["expected_revision": goal.revision], as: GoalClaimResponse.self)
                    guard !Task.isCancelled, capturedGeneration == generation, !isShuttingDown() else { return }
                    ingest(response.goal)
                    guard let run = response.run, let latest = goals[goal.sessionID],
                          latest.id == response.goal.id, latest.revision == response.goal.revision,
                          eligible(latest) else { continue }
                    handedOffRunIDs[goal.sessionID] = run.id
                    dispatchClaim(latest, run: run, generation: capturedGeneration)
                } catch {
                    guard capturedGeneration == generation else { return }
                    // A competing user action can invalidate the claim. Read
                    // its result without manufacturing another continuation.
                    _ = await refresh(sessionID: goal.sessionID)
                }
            }
        }
    }

    /// Slot admission can wait for a busy workspace. Keep that wait scoped to
    /// its session so another goal can use an unrelated available workspace.
    private func dispatchClaim(_ goal: PersistentGoal, run: OrchestrationRun, generation capturedGeneration: UUID) {
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if dispatches[goal.sessionID]?.token == token { dispatches[goal.sessionID] = nil }
                wake()
            }
            guard !Task.isCancelled, capturedGeneration == generation, !isStopped,
                  !isShuttingDown(), goals[goal.sessionID]?.status == .active,
                  !suspendedSessionIDs.contains(goal.sessionID),
                  !inputSuspendedSessionIDs.contains(goal.sessionID) else { return }
            let accepted = await dispatch(goal, run)
            guard !Task.isCancelled, capturedGeneration == generation, !isStopped, !isShuttingDown() else { return }
            if !accepted, goals[goal.sessionID]?.status == .active,
               !suspendedSessionIDs.contains(goal.sessionID),
               !inputSuspendedSessionIDs.contains(goal.sessionID) {
                _ = await block(sessionID: goal.sessionID, reason: "The saved execution route could not start. Review the task and resume when it is ready.")
            }
        }
        dispatches[goal.sessionID] = DispatchState(runID: run.id, token: token, task: task)
    }

    func shutdown() {
        isStopped = true
        generation = UUID()
        refreshGeneration = UUID()
        coordinator?.cancel()
        coordinator = nil
        wakeRequested = false
        for dispatch in dispatches.values { dispatch.task.cancel() }
        dispatches.removeAll()
        for task in userInputTasks.values { task.cancel() }
        userInputTasks.removeAll()
        userInputTaskTokens.removeAll()
    }

    private func eligible(_ goal: PersistentGoal) -> Bool {
        !isStopped && goal.status == .active && !goal.pendingUserInput
            && !suspendedSessionIDs.contains(goal.sessionID)
            && !inputSuspendedSessionIDs.contains(goal.sessionID)
            && dispatches[goal.sessionID] == nil
            && handedOffRunIDs[goal.sessionID] == nil && canContinue(goal)
    }

    private func ingest(_ goal: PersistentGoal) {
        let previous = goals[goal.sessionID]
        guard !retiredGoalIDs.contains(goal.id) else { return }
        if let previous, previous.id != goal.id {
            if Self.older(goal.createdAt, than: previous.createdAt) {
                retiredGoalIDs.insert(goal.id)
                return
            }
            let newer = Self.older(previous.createdAt, than: goal.createdAt)
            if !newer, !previous.status.isTerminal, goal.status.isTerminal { return }
            retiredGoalIDs.insert(previous.id)
            clearUserInputTracking(sessionID: goal.sessionID)
            suspendedSessionIDs.remove(goal.sessionID)
            handedOffRunIDs[goal.sessionID] = nil
            dispatches[goal.sessionID]?.task.cancel()
            dispatches[goal.sessionID] = nil
        }
        if let previous, previous.id == goal.id, previous.revision > goal.revision { return }
        if let previous, previous.id == goal.id, previous.revision == goal.revision,
           previous.status != .active, goal.status == .active { return }
        if let previous, previous.id == goal.id, previous.revision == goal.revision,
           Self.older(goal.updatedAt, than: previous.updatedAt) { return }
        goals[goal.sessionID] = goal
        if goal.status.isTerminal { clearUserInputTracking(sessionID: goal.sessionID) }
        if let previous, previous.id == goal.id, previous.status != goal.status,
           goal.status == .completed || goal.status == .blocked || goal.status == .limitReached
            || (goal.status == .paused && !suspendedSessionIDs.contains(goal.sessionID)) {
            notify(goal)
        }
        if !goal.pendingUserInput, previous?.pendingUserInput == true {
            inputSuspendedSessionIDs.remove(goal.sessionID)
        }
    }

    private func clearUserInputTracking(sessionID: String) {
        userInputTasks[sessionID]?.cancel()
        userInputTasks[sessionID] = nil
        userInputTaskTokens[sessionID] = nil
        pendingInputIDs[sessionID] = nil
        userInputs[sessionID] = nil
        inputSuspendedSessionIDs.remove(sessionID)
    }

    private func update(sessionID: String, action: String, reason: String? = nil,
                        expectedRevision: Int? = nil, inputID: String? = nil) async -> PersistentGoal? {
        guard let backend, let goal = goals[sessionID], !isStopped, !isShuttingDown() else { return nil }
        let capturedGeneration = generation
        var body: [String: Any] = ["action": action]
        if let reason { body["reason"] = reason }
        if let expectedRevision { body["expected_revision"] = expectedRevision }
        if let inputID { body["input_id"] = inputID }
        do {
            let updated = try await backend.patch("/api/goals/\(goal.id)", body: body, as: PersistentGoal.self)
            guard capturedGeneration == generation, !isShuttingDown(), updated.sessionID == sessionID,
                  updated.id == goal.id, goals[sessionID]?.id == goal.id else { return nil }
            ingest(updated)
            error = nil
            return updated
        } catch {
            guard capturedGeneration == generation else { return nil }
            self.error = "Could not update the goal: \(error.localizedDescription)"
            return nil
        }
    }

    private static func budget(_ text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private static func inputText(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func older(_ value: JSONValue?, than other: JSONValue?) -> Bool {
        switch (value, other) {
        case (.number(let left), .number(let right)): left < right
        case (.string(let left), .string(let right)): left < right
        default: false
        }
    }
    private static func invalidBudget(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && (budget(value).map { $0 <= 0 } ?? true)
    }
}
