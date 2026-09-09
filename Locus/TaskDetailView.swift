import SwiftUI

struct TaskDetailSnapshot: Decodable {
    var id: String
    var request: String
    var state: String
    var revision: Int
    var blocker: String
    var plan: PlanDocument?
    var usage: TaskUsageSummary
    var files: [TaskFileChange]
    var progress: [[String: JSONValue]]
    var links: [String]
    var restorations: [[String: JSONValue]]
    var reviews: [[String: JSONValue]]
    var exclusions: [[String: JSONValue]]?
    var can_retry_checks: Bool?
    var verification: [String: JSONValue]?
    var execution_path: String?
    var run_id: String?
    var owner_kind: String?
    var actions: [String]?
    var capsule: TaskCapsule?
    var goal: PersistentGoal?
    var interface_version: Int?
    var outputs: [TaskOutput]?
    var recovery_history: [[String: JSONValue]]?

    /// Older servers still render history, but cannot authorize new controls.
    func allows(_ action: String) -> Bool { actions?.contains(action) == true }
    var verificationState: String {
        verification?["current_status"]?.string ?? goal?.verificationStatus
            ?? capsule?.attempts.first?.verificationStatus ?? "unverified"
    }
}

struct TaskOutput: Decodable, Identifiable {
    var path: String
    var state: String
    var reason: String?
    var id: String { path }
}

struct TaskUsageSummary: Decodable {
    var known_subtotal: Double
    var coverage: String
    var unknown_entries: Int
    var pending_entries: Int
    var subscription_entries: Int
    var local_entries: Int
    var limit: Double?
    var entries: [[String: JSONValue]]
    var spans: [[String: JSONValue]]
    var elapsed_seconds: Double?

    var label: String {
        let amount = known_subtotal.formatted(.currency(code: "USD"))
        return coverage == "complete" ? "\(amount) known API estimate" : "\(amount) known · \(coverage) coverage"
    }
}

struct TaskFileChange: Decodable, Identifiable {
    var id: String
    var path: String
    var state: String
    var reason: String?
    var created_at: Double?
}

struct TaskRestorePreview: Decodable {
    struct Entry: Decodable, Identifiable {
        var path: String
        var status: String
        var reason: String?
        var diff: String?
        var current: [String: JSONValue]?
        var id: String { path }
    }
    var token: String
    var revision: Int
    var entries: [Entry]
}

/// A projection of existing task owners. Loading this view never dispatches work.
struct TaskDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var sessionID: String? = nil
    var compact = false
    @State private var snapshot: TaskDetailSnapshot?
    @State private var error: String?
    @State private var loading = false
    @State private var selectedFiles: Set<String> = []
    @State private var visibleFileCount = 100
    @State private var preview: TaskRestorePreview?
    @State private var selectedRestorePaths: Set<String> = []
    @State private var notice: String?
    @State private var requestGeneration = UUID()
    @State private var showRestorationHistory = false
    @State private var limit = ""
    @State private var reviewedUsage = ""
    @State private var reviewedAmount = ""
    @State private var reviewedEvidence = ""

    private var taskSession: String { sessionID ?? model.currentSessionID }
    private var endpoint: String { "/api/sessions/\(taskSession)/task" }
    private var actionLayout: AnyLayout { compact ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Task").font(.title2.weight(.semibold))
                    Spacer()
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh task")
                        .disabled(loading)
                    if !compact { Button("Done") { dismiss() } }
                }
                if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
                if let notice { Text(notice).foregroundStyle(LocusTheme.textSecondary).accessibilityIdentifier("task.notice") }
                if loading && snapshot == nil { ProgressView("Loading task…") }
                if let snapshot {
                    Text(snapshot.request).font(.headline).textSelection(.enabled)
                    Label(snapshot.state.replacingOccurrences(of: "_", with: " ").capitalized,
                          systemImage: snapshot.verificationState == "passed" ? "checkmark.circle" : "circle.dotted")
                        .accessibilityIdentifier("task.status")
                    if !snapshot.blocker.isEmpty {
                        Text(snapshot.blocker).foregroundStyle(LocusTheme.warning).textSelection(.enabled)
                    }
                    controls(snapshot)
                    if let plan = snapshot.plan {
                        DisclosureGroup("Saved plan · \(plan.title)") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(plan.summary).textSelection(.enabled)
                                if let revision = plan.approvalReference?["revision"] {
                                    Text("Saved revision \(revision.string ?? "Unknown")").font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                                    Text("\(index + 1). \(step)").textSelection(.enabled)
                                }
                                planItems("Constraints", plan.constraints)
                                planItems("Decisions", plan.decisions)
                                planItems("Acceptance criteria", plan.acceptanceChecks.compactMap { $0["requirement"]?.string })
                                planItems("Validation", plan.tests)
                            }.padding(.top, 8)
                        }.accessibilityIdentifier("task.plan")
                    }
                    GroupBox("Progress and evidence") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(snapshot.progress.count) recorded milestones").accessibilityIdentifier("task.progress")
                            Text(snapshot.verificationState == "accepted" ? "Accepted by you · Not machine verified" : "Verification: \(snapshot.verificationState.replacingOccurrences(of: "_", with: " "))")
                                .font(.caption).accessibilityIdentifier("task.verification")
                            ForEach(Array(snapshot.progress.prefix(12).enumerated()), id: \.offset) { _, progress in
                                VStack(alignment: .leading, spacing: 3) {
                                    Label(milestoneLabel(progress["kind"]?.string ?? ""), systemImage: "checkmark.circle")
                                    if case .object(let evidence) = progress["evidence"],
                                       let detail = evidence["path"]?.string ?? evidence["requirement"]?.string ?? evidence["step_id"]?.string {
                                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }
                            ForEach(Array(snapshot.reviews.enumerated()), id: \.offset) { _, review in
                                if review["current"]?.boolean == false {
                                    Text("Files changed after this review. A fresh review is required.").foregroundStyle(LocusTheme.warning)
                                }
                                if case .array(let findings) = review["reviews"] {
                                    ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                                        if case .object(let item) = finding {
                                            DisclosureGroup(item["agent_name"]?.string ?? "Review findings") {
                                                Text(readableReview(item["output"]?.string ?? ""))
                                                    .textSelection(.enabled).font(.caption)
                                            }
                                        }
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let outputs = snapshot.outputs, !outputs.isEmpty {
                        GroupBox("Outputs") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(outputs) { output in
                                    HStack {
                                        Text(output.path).textSelection(.enabled)
                                        Spacer()
                                        Text(output.state.capitalized).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let reason = output.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("task.outputs")
                    }
                    usage(snapshot.usage)
                    files(snapshot.files)
                    if let exclusions = snapshot.exclusions, !exclusions.isEmpty {
                        DisclosureGroup("Changes unavailable for automatic restoration") {
                            ForEach(Array(exclusions.enumerated()), id: \.offset) { _, entry in
                                Text(entry["reason"]?.string ?? "Uncertain file ownership").font(.caption)
                            }
                        }
                    }
                    if let preview { restoration(preview) }
                    if !snapshot.restorations.isEmpty {
                        DisclosureGroup("Restoration history", isExpanded: $showRestorationHistory) {
                            ForEach(Array(snapshot.restorations.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    Text(item["state"]?.string?.replacingOccurrences(of: "_", with: " ") ?? "Restoration")
                                    Spacer()
                                    if ["applying", "needs_recovery", "completed"].contains(item["state"]?.string ?? "") {
                                        Button(item["state"]?.string == "completed" ? "Undo restoration" : "Recover previous files") {
                                            Task { await action("/restore", body: ["action": "recover", "token": item["token"]?.string ?? ""]) }
                                        }.disabled(model.isBusy || loading || !snapshot.allows("restore"))
                                            .accessibilityIdentifier("task.restoreRecover")
                                    }
                                }
                                if case .array(let paths) = item["paths"] {
                                    Text(paths.compactMap(\.string).joined(separator: ", ")).font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if let recovery = snapshot.recovery_history, !recovery.isEmpty {
                        DisclosureGroup("Execution and recovery history") {
                            ForEach(Array(recovery.enumerated()), id: \.offset) { _, run in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(run["state"]?.string?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Recorded attempt").font(.caption.weight(.semibold))
                                    if let reason = run["reason"]?.string, !reason.isEmpty { Text(reason).font(.caption).textSelection(.enabled) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.accessibilityIdentifier("task.recoveryHistory")
                    }
                } else if !loading {
                    Text("Your plan, progress, outputs, and usage will appear after the task starts.").foregroundStyle(.secondary)
                }
                if compact {
                    DisclosureGroup("Conversation overview") {
                        SessionOverviewView(session: model.sessionOverview).environmentObject(model)
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: compact ? 240 : 560, minHeight: compact ? 200 : 560)
        .background(LocusTheme.surfaceCanvas)
        .foregroundStyle(LocusTheme.textPrimary)
        .buttonStyle(.locus())
        .accessibilityIdentifier("task.detail")
        .task(id: taskSession) { snapshot = nil; preview = nil; selectedFiles = []; selectedRestorePaths = []; notice = nil; showRestorationHistory = false; visibleFileCount = 100; await refresh() }
        .onChange(of: model.isBusy) { _, busy in if !busy && !loading { Task { await refresh() } } }
    }

    @ViewBuilder private func controls(_ value: TaskDetailSnapshot) -> some View {
        if value.owner_kind == "goal" {
            actionLayout {
                if value.allows("resume") {
                    Button("Resume") { Task { _ = await model.goals.resume(sessionID: taskSession); await refresh() } }
                        .accessibilityIdentifier("task.resume")
                }
                if value.allows("accept") {
                    Button("Accept result") {
                        let session = taskSession
                        Task {
                            let current = await model.goals.refresh(sessionID: session)
                            guard session == taskSession, current?.id == value.goal?.id, current?.revision == value.goal?.revision else {
                                error = "The goal changed. Refresh its result before accepting it."
                                return
                            }
                            await model.goals.acceptResult(sessionID: session)
                            await refresh()
                        }
                    }.accessibilityIdentifier("task.accept")
                }
            }.disabled(model.isBusy || loading)
        } else if let capsule = value.capsule, value.owner_kind == "capsule" {
            actionLayout {
                if let attempt = capsule.resumableAttempt {
                    if value.allows("resume") { Button("Resume") { model.startCapsuleStage(capsule, stage: "execute", resumeAttemptID: attempt.id) }.accessibilityIdentifier("task.resume") }
                    if value.allows("retry_checks") { Button("Retry checks") { model.startCapsuleStage(capsule, stage: "execute", resumeAttemptID: attempt.id, checksOnly: true) }.accessibilityIdentifier("task.retryChecks") }
                    if value.allows("accept") {
                        Button("Accept result") {
                            Task { await acceptCapsule(capsule, attemptID: attempt.id) }
                        }.accessibilityIdentifier("task.accept")
                    }
                }
                if value.allows("run_again") { Button("Run again") { model.startCapsuleStage(capsule, stage: "execute") }.accessibilityIdentifier("task.runAgain") }
                Button("Recipe settings") { model.showTaskRecipe(capsule.id) }
            }.disabled(model.isBusy || loading || taskSession != model.currentSessionID)
        } else {
            actionLayout {
                if value.allows("resume"), let runID = value.run_id {
                    Button("Resume") {
                        Task {
                            do { let run = try await model.backend.get("/api/runs/\(runID)", as: OrchestrationRun.self); model.resumeTaskRun(run) }
                            catch { self.error = error.localizedDescription }
                        }
                    }.accessibilityIdentifier("task.resume")
                }
                if value.allows("run_again") {
                    Button("Run again") { model.send(value.request) }
                        .disabled(taskSession != model.currentSessionID).accessibilityIdentifier("task.runAgain")
                }
                if value.allows("retry_checks") {
                    Button("Retry checks") { Task { await action("/checks", body: ["revision": value.revision]) } }
                        .disabled(taskSession != model.currentSessionID).accessibilityIdentifier("task.retryChecks")
                }
                if value.allows("accept") {
                    Button("Accept result") { Task { await action("/accept", body: ["revision": value.revision]) } }
                        .accessibilityIdentifier("task.accept")
                }
            }.disabled(model.isBusy || loading)
            if value.state == "planned" { Text("Approve the saved plan in this conversation when you are ready to implement it.").font(.caption) }
        }
    }

    private func usage(_ value: TaskUsageSummary) -> some View {
        GroupBox("Whole-task usage") {
            VStack(alignment: .leading, spacing: 10) {
                Text(value.label).font(.headline).accessibilityIdentifier("task.usage")
                Text("\(value.subscription_entries) subscription requests · \(value.local_entries) local operations · \(value.unknown_entries) unknown charges")
                    .font(.caption).foregroundStyle(.secondary)
                if value.pending_entries > 0 { Text("Unsettled requests: \(value.pending_entries)").foregroundStyle(LocusTheme.warning) }
                if let elapsed = value.elapsed_seconds {
                    Text("Elapsed: \(Duration.seconds(elapsed).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))").font(.caption)
                }
                DisclosureGroup("Usage by stage") {
                    ForEach(Array(value.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(entry["stage"]?.string?.capitalized ?? "Call") · \(entry["model"]?.string ?? "")").font(.caption.weight(.semibold))
                            Text("Model calls: \(entry["model_calls"]?.string ?? "unreported")").font(.caption)
                            Text(entry["cost"]?.string.map { "$\($0) estimated" } ?? (entry["metering"]?.string == "subscription" ? "Subscription usage" : entry["metering"]?.string == "local" ? "Local execution" : "Charge unknown")).font(.caption)
                            if case .object(let counts) = entry["usage"] {
                                ForEach(counts.keys.sorted(), id: \.self) { key in
                                    Text("\(key.replacingOccurrences(of: "_", with: " ")): \(usageCount(counts[key]))").font(.caption2)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DisclosureGroup("Cost limit and reconciliation") {
                    HStack {
                        TextField("Optional task limit (USD)", text: $limit).textFieldStyle(.roundedBorder)
                        Button("Save limit") { Task { await action("/limit", body: ["amount": Double(limit).map { $0 as Any } ?? NSNull()]) } }
                            .disabled(!limit.isEmpty && (Double(limit) == nil || (Double(limit) ?? -1) < 0))
                    }
                    Text("The limit covers known metered estimates across all stages. Unpriced calls pause when a limit is enabled.").font(.caption)
                    Picker("Usage entry", selection: $reviewedUsage) {
                        Text("Select an interrupted or unknown call").tag("")
                        ForEach(Array(value.entries.enumerated()), id: \.offset) { _, entry in
                            if let id = entry["id"]?.string {
                                Text("\(entry["stage"]?.string ?? "Call") · \(entry["model"]?.string ?? "")").tag(id)
                            }
                        }
                    }
                    TextField("Reviewed cost (USD)", text: $reviewedAmount)
                    TextField("Evidence for this amount", text: $reviewedEvidence)
                    Button("Record reviewed usage") {
                        Task { await action("/usage", body: ["id": reviewedUsage, "amount": Double(reviewedAmount) ?? 0, "note": reviewedEvidence]) }
                    }.disabled(reviewedUsage.isEmpty || Double(reviewedAmount) == nil || reviewedEvidence.isEmpty)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func files(_ values: [TaskFileChange]) -> some View {
        GroupBox("Files and restoration") {
            VStack(alignment: .leading, spacing: 8) {
                if values.isEmpty { Text("No captured file changes yet.").foregroundStyle(.secondary) }
                ForEach(values.prefix(visibleFileCount)) { file in
                    Toggle(isOn: Binding(get: { selectedFiles.contains(file.id) }, set: { selected in
                        if selected {
                            // The backend reverses one captured edit per path.
                            selectedFiles.subtract(values.filter { $0.path == file.path }.map(\.id))
                            selectedFiles.insert(file.id)
                        } else { selectedFiles.remove(file.id) }
                        preview = nil
                    })) {
                        VStack(alignment: .leading) {
                            Text(file.path).textSelection(.enabled)
                            if taskSession == model.currentSessionID && snapshot?.execution_path == model.workspacePath {
                                Button("Open file") { model.openSessionFile(file.path) }.font(.caption)
                            }
                            if let timestamp = file.created_at {
                                Text(Date(timeIntervalSince1970: timestamp), style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                            if file.state != "captured" { Text(file.reason ?? file.state).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.disabled(file.state != "captured" || loading)
                        .accessibilityIdentifier("task.file.\(file.id)")
                }
                if values.count > visibleFileCount {
                    Button("Show more file changes") { visibleFileCount += 100 }
                }
                Button("Preview restoration") { Task { await previewFiles() } }
                    .disabled(selectedFiles.isEmpty || model.isBusy || loading || snapshot?.allows("restore") != true)
                    .accessibilityIdentifier("task.restorePreview")
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func restoration(_ value: TaskRestorePreview) -> some View {
        GroupBox("Restoration preview") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Select the files to restore. Conflicting files keep their current contents.").font(.caption)
                ForEach(value.entries) { entry in
                    Toggle(entry.path, isOn: Binding(get: { selectedRestorePaths.contains(entry.path) }, set: { selected in
                        if selected { selectedRestorePaths.insert(entry.path) } else { selectedRestorePaths.remove(entry.path) }
                    })).font(.headline).disabled(entry.status != "ready" || loading)
                        .accessibilityIdentifier("task.restoreFile.\(entry.path)")
                    if let reason = entry.reason { Text(reason).foregroundStyle(LocusTheme.warning) }
                    if let diff = entry.diff {
                        ScrollView(.horizontal) { Text(diff).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    } else if entry.status == "ready" { Text("Binary content or file permissions will return to the recorded state.").font(.caption) }
                }
                Button("Restore selected files") {
                    let ready = value.entries.filter { $0.status == "ready" && selectedRestorePaths.contains($0.path) }
                    let fingerprints = Dictionary(uniqueKeysWithValues: ready.map { ($0.path, $0.current ?? [:]) })
                    Task { await action("/restore", body: ["action": "apply", "token": value.token, "revision": value.revision,
                        "selected_paths": ready.map(\.path), "fingerprints": encodedJSONObject(fingerprints) ?? [:]]) }
                }.disabled(selectedRestorePaths.isEmpty || model.isBusy || loading || snapshot?.revision != value.revision || snapshot?.allows("restore") != true)
                    .accessibilityIdentifier("task.restoreApply")
            }
        }
    }

    private func milestoneLabel(_ kind: String) -> String {
        switch kind {
        case "artifact_changed": "Updated task files"
        case "check_passed": "Acceptance check passed"
        case "step_verified": "Plan step verified"
        case "source_finding": "Recorded a source finding"
        case "question_resolved": "Resolved a decision"
        default: "Recorded progress"
        }
    }

    @ViewBuilder private func planItems(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Text(title).font(.caption.weight(.semibold)).padding(.top, 4)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item).font(.caption).textSelection(.enabled)
            }
        }
    }

    private func usageCount(_ value: JSONValue?) -> String {
        guard let value, let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "Unknown" }
        return text
    }

    private func readableReview(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return text.isEmpty ? "Required review is unresolved." : text
        }
        var lines = [(value["verdict"]?.string ?? "Unresolved").capitalized]
        if case .array(let findings) = value["findings"] {
            for finding in findings {
                if case .object(let item) = finding {
                    lines.append(item["message"]?.string ?? item["description"]?.string ?? "Review finding")
                } else if let message = finding.string { lines.append(message) }
            }
        }
        if let request = value["revision_request"]?.string { lines.append(request) }
        return lines.joined(separator: "\n\n")
    }

    @MainActor private func refresh() async {
        let session = taskSession
        let generation = UUID()
        requestGeneration = generation
        loading = true
        defer { if requestGeneration == generation { loading = false } }
        do {
            let value = try await model.backend.get(endpoint, as: TaskDetailSnapshot.self)
            guard session == taskSession, requestGeneration == generation else { return }
            if let preview, preview.revision != value.revision { self.preview = nil; selectedRestorePaths = [] }
            snapshot = value; error = nil
            selectedFiles.formIntersection(value.files.filter { $0.state == "captured" }.map(\.id))
            limit = value.usage.limit.map { String($0) } ?? ""
        } catch { if session == taskSession, requestGeneration == generation { self.error = error.localizedDescription } }
    }

    @MainActor private func action(_ suffix: String, body: [String: Any]) async {
        let session = taskSession
        let generation = UUID()
        requestGeneration = generation
        loading = true
        error = nil; notice = nil
        defer { if requestGeneration == generation { loading = false } }
        do {
            let _: SimpleActionResponse = try await model.backend.post(endpoint + suffix, body: body, as: SimpleActionResponse.self)
            guard session == taskSession, requestGeneration == generation else { return }
            if suffix == "/restore" {
                notice = body["action"] as? String == "recover" ? "Previous files recovered. Later edits were preserved." : "Selected files restored. You can undo this restoration from its history."
                showRestorationHistory = true
            }
            preview = nil; selectedFiles = []; selectedRestorePaths = []; await refresh()
        } catch {
            if session == taskSession, requestGeneration == generation {
                self.error = error.localizedDescription
                if suffix == "/restore" { preview = nil; selectedRestorePaths = [] }
            }
        }
    }

    @MainActor private func previewFiles() async {
        let session = taskSession
        let generation = UUID()
        requestGeneration = generation
        loading = true
        error = nil; notice = nil
        defer { if requestGeneration == generation { loading = false } }
        do {
            let value = try await model.backend.post(endpoint + "/restore", body: ["change_ids": Array(selectedFiles)], as: TaskRestorePreview.self)
            if session == taskSession, requestGeneration == generation {
                preview = value
                selectedRestorePaths = Set(value.entries.filter { $0.status == "ready" }.map(\.path))
            }
        }
        catch { if session == taskSession, requestGeneration == generation { self.error = error.localizedDescription } }
    }

    @MainActor private func acceptCapsule(_ capsule: TaskCapsule, attemptID: String) async {
        loading = true
        defer { loading = false }
        do {
            // Keep acceptance with the capsule API and its persisted revision.
            let _: TaskCapsuleResponse = try await model.backend.patch("/api/capsules/\(capsule.id)", body: [
                "workspace_root": capsule.workspaceRoot, "expected_revision": capsule.revision,
                "action": "accept", "attempt_id": attemptID], as: TaskCapsuleResponse.self)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

extension AppModel {
    func resumeTaskRun(_ run: OrchestrationRun) {
        if run.runKind == "team" || run.teamID != nil {
            resumeOrchestration(run)
        } else { retryRun(run) }
    }

    func showTaskDetail(sessionID: String? = nil) {
        taskDetailSessionID = sessionID ?? currentSessionID
        if taskCapsules.isPresented {
            taskDetailAfterCapsuleDismissal = true
            taskCapsules.isPresented = false
        } else {
            taskDetailAfterCapsuleDismissal = false
            taskDetailPresented = true
        }
    }

    func completeCapsuleTaskDismissal() {
        guard taskDetailAfterCapsuleDismissal else { return }
        taskDetailAfterCapsuleDismissal = false
        taskDetailPresented = true
    }

    func showTaskRecipe(_ capsuleID: String) {
        if taskDetailPresented {
            taskRecipeAfterDetailDismissal = capsuleID
            taskDetailPresented = false
        } else { taskCapsules.open(selecting: capsuleID) }
    }

    func completeTaskDetailDismissal() {
        guard let capsuleID = taskRecipeAfterDetailDismissal else { return }
        taskRecipeAfterDetailDismissal = nil
        taskCapsules.open(selecting: capsuleID)
    }

    func showTaskDetail(runID: String) {
        Task {
            do {
                let run = try await backend.get("/api/runs/\(runID)", as: OrchestrationRun.self)
                guard let session = run.sessionID else { return }
                showTaskDetail(sessionID: session)
            } catch { showToast(error.localizedDescription) }
        }
    }
}
