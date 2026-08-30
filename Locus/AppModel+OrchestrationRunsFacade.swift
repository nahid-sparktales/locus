import Foundation

// Facade API — kept for InspectorView (a concurrent branch owns it),
// AppModelTests, and the dispatcher/run-queue seams. Shrinks to nothing
// once that branch lands and the tests are re-pointed in the follow-up.
extension AppModel {
    var orchestrationRuns: [OrchestrationRun] {
        get { runs.orchestrationRuns }
        set { runs.orchestrationRuns = newValue }
    }

    var selectedOrchestrationRun: OrchestrationRun? {
        get { runs.selectedOrchestrationRun }
        set { runs.selectedOrchestrationRun = newValue }
    }

    var runDetailsByID: [String: OrchestrationRun] {
        get { runs.runDetailsByID }
        set { runs.runDetailsByID = newValue }
    }

    var orchestrationEvents: [OrchestrationEvent] {
        get { runs.orchestrationEvents }
        set { runs.orchestrationEvents = newValue }
    }

    var orchestrationEventIDs: Set<String> {
        get { runs.orchestrationEventIDs }
        set { runs.orchestrationEventIDs = newValue }
    }

    var isLoadingOrchestrationRuns: Bool { runs.isLoadingOrchestrationRuns }

    func refreshOrchestrationRuns(
        select runID: String? = nil,
        terminal: Bool = false
    ) async {
        await runs.refreshOrchestrationRuns(select: runID, terminal: terminal)
    }

    func loadOrchestrationRun(_ runID: String, terminal: Bool = false) async {
        await runs.loadOrchestrationRun(runID, terminal: terminal)
    }

    func backfillOrchestrationEvents(_ runID: String) async {
        await runs.backfillOrchestrationEvents(runID)
    }

    func orchestrationEvents(for runID: String) -> [OrchestrationEvent] {
        runs.orchestrationEvents(for: runID)
    }

    nonisolated static func runScopedEvents(
        _ events: [OrchestrationEvent],
        runID: String
    ) -> [OrchestrationEvent] {
        OrchestrationRunsModel.runScopedEvents(events, runID: runID)
    }

    nonisolated static func mergeOrchestrationEvents(
        _ existing: [OrchestrationEvent],
        with incoming: [OrchestrationEvent]
    ) -> [OrchestrationEvent] {
        OrchestrationRunsModel.mergeOrchestrationEvents(existing, with: incoming)
    }

    nonisolated static func orchestrationPickerRuns(
        _ runs: [OrchestrationRun],
        selected: OrchestrationRun?
    ) -> [OrchestrationRun] {
        OrchestrationRunsModel.orchestrationPickerRuns(runs, selected: selected)
    }
}
