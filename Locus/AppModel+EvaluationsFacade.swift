import Foundation

/// Forwarders kept while consumers still reach evaluations through AppModel;
/// each is deleted once its last caller observes `model.evaluations` directly.
extension AppModel {
    var evaluationSuites: [EvaluationSuite] { evaluations.evaluationSuites }
    var activeEvaluationID: String? { evaluations.activeEvaluationID }
    var evaluationStatus: String? { evaluations.evaluationStatus }

    func refreshEvaluations() async {
        await evaluations.refreshEvaluations()
    }

    func loadEvaluationReport(_ suite: EvaluationSuite) async -> EvaluationReport? {
        await evaluations.loadEvaluationReport(suite)
    }

    func createEvaluationSuite() {
        evaluations.createEvaluationSuite()
    }

    func saveEvaluationSuite(_ suite: EvaluationSuite) {
        evaluations.saveEvaluationSuite(suite)
    }

    func deleteEvaluationSuite(_ suite: EvaluationSuite) {
        evaluations.deleteEvaluationSuite(suite)
    }

    func importEvaluationSuite() {
        evaluations.importEvaluationSuite()
    }

    func exportEvaluationSuite(_ suite: EvaluationSuite) {
        evaluations.exportEvaluationSuite(suite)
    }

    func runEvaluationSuite(_ suite: EvaluationSuite) {
        evaluations.runEvaluationSuite(suite)
    }
}
