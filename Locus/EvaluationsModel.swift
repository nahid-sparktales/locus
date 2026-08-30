import AppKit
import Foundation

/// Owns workspace evaluation suites: CRUD against the backend, JSON
/// import/export, kicking off runs (building per-case team manifests through
/// an injected provider), and the run-progress status fed by backend events.
/// AppModel wires it via configure(...) and bridges its publication; it never
/// retains AppModel.
@MainActor
final class EvaluationsModel: ObservableObject {
    @Published private(set) var evaluationSuites: [EvaluationSuite] = []
    @Published private(set) var activeEvaluationID: String?
    @Published private(set) var evaluationStatus: String?

    private var backend: BackendService?
    private var workspacePathProvider: () -> String = { "" }
    private var selectedTeamIDProvider: () -> UUID? = { nil }
    private var manifestProvider: (String, UUID) -> [String: Any]? = { _, _ in nil }
    private var toastHandler: (String) -> Void = { _ in }

    func configure(
        backend: BackendService,
        workspacePathProvider: @escaping () -> String,
        selectedTeamIDProvider: @escaping () -> UUID?,
        manifestProvider: @escaping (String, UUID) -> [String: Any]?,
        toastHandler: @escaping (String) -> Void
    ) {
        self.backend = backend
        self.workspacePathProvider = workspacePathProvider
        self.selectedTeamIDProvider = selectedTeamIDProvider
        self.manifestProvider = manifestProvider
        self.toastHandler = toastHandler
    }

    /// Backend evaluation_* events, routed here by AppModel's dispatcher.
    func ingest(_ type: String, _ event: [String: Any]) {
        switch type {
        case "evaluation_started":
            activeEvaluationID = event["evaluation_id"] as? String
            evaluationStatus = "Starting evaluation"

        case "evaluation_case_started":
            let index = (event["case_index"] as? Int ?? 0) + 1
            let count = event["case_count"] as? Int
            evaluationStatus = count.map { "Running case \(index) of \($0)" }
                ?? "Running case \(index)"

        case "evaluation_case_completed":
            evaluationStatus = "Grading results"

        case "evaluation_completed":
            activeEvaluationID = nil
            evaluationStatus = (event["state"] as? String) == "interrupted"
                ? "Evaluation interrupted" : "Evaluation complete"
            Task { @MainActor [weak self] in await self?.refreshEvaluations() }

        default:
            break
        }
    }

    func refreshEvaluations() async {
        guard let backend else { return }
        do {
            let response: EvaluationSuitesResponse = try await backend.get(
                "/api/evaluations",
                query: [URLQueryItem(name: "workspace", value: workspacePathProvider())],
                as: EvaluationSuitesResponse.self
            )
            evaluationSuites = response.suites
        } catch {
            toastHandler("Could not load evaluations: \(error.localizedDescription)")
        }
    }

    func loadEvaluationReport(_ suite: EvaluationSuite) async -> EvaluationReport? {
        guard let backend else { return nil }
        do {
            return try await backend.get(
                "/api/evaluations/\(suite.id)", as: EvaluationReport.self
            )
        } catch {
            toastHandler("Could not load evaluation results: \(error.localizedDescription)")
            return nil
        }
    }

    func createEvaluationSuite() {
        let suite = EvaluationSuite(
            name: "Workspace checks",
            workspaceRoot: workspacePathProvider(),
            cases: [EvaluationCase(name: "First case", prompt: "Describe the expected task here.")]
        )
        saveEvaluationSuite(suite)
    }

    func saveEvaluationSuite(_ suite: EvaluationSuite) {
        guard let backend else { return }
        guard let body = encodedJSONObject(suite) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: EvaluationSuiteResponse = try await backend.post(
                    "/api/evaluations", body: body, as: EvaluationSuiteResponse.self
                )
                evaluationSuites.removeAll { $0.id == response.suite.id }
                evaluationSuites.insert(response.suite, at: 0)
                toastHandler("Saved evaluation suite")
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }

    func deleteEvaluationSuite(_ suite: EvaluationSuite) {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/evaluations/\(suite.id)", as: SimpleActionResponse.self
                )
                evaluationSuites.removeAll { $0.id == suite.id }
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }

    func importEvaluationSuite() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var suite = try JSONDecoder().decode(EvaluationSuite.self, from: Data(contentsOf: url))
            suite.id = UUID().uuidString
            saveEvaluationSuite(suite)
        } catch {
            toastHandler("Could not import evaluation suite: \(error.localizedDescription)")
        }
    }

    func exportEvaluationSuite(_ suite: EvaluationSuite) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(suite)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(suite.name.replacingOccurrences(of: "/", with: "-")) evaluation.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            toastHandler("Evaluation suite exported")
        } catch {
            toastHandler("Could not export evaluation suite: \(error.localizedDescription)")
        }
    }

    func runEvaluationSuite(_ suite: EvaluationSuite) {
        guard let backend else { return }
        let needsTeam = suite.cases.contains { $0.target.caseInsensitiveCompare("team") == .orderedSame }
        var body: [String: Any] = [:]
        var manifests: [String: Any] = [:]
        for evaluationCase in suite.cases where evaluationCase.target == "team" {
            let requestedID = UUID(uuidString: evaluationCase.teamID) ?? selectedTeamIDProvider()
            guard let requestedID,
                  let manifest = manifestProvider(evaluationCase.prompt, requestedID)
            else {
                toastHandler("Select or repair every team used by this suite")
                return
            }
            manifests[requestedID.uuidString] = manifest
        }
        if !manifests.isEmpty { body["manifests"] = manifests }
        if let selectedTeamID = selectedTeamIDProvider(),
           let fallback = manifestProvider(suite.cases.first?.prompt ?? "", selectedTeamID)
        {
            body["manifest"] = fallback
        }
        if needsTeam && manifests.isEmpty {
            toastHandler("Select a configured team before running this suite")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: EvaluationRunResponse = try await backend.post(
                    "/api/evaluations/\(suite.id)/run",
                    body: body,
                    as: EvaluationRunResponse.self
                )
                activeEvaluationID = response.evaluationID
                evaluationStatus = "Queued"
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }
}
