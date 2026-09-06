import SwiftUI

/// Installs the feature models that own reactive UI state.
///
/// Views observe these objects directly instead of relying on `AppModel` to
/// republish every child change. `AppModel` remains available for orchestration
/// and cross-feature actions.
struct AppFeatureEnvironmentModifier: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        featureEnvironment(content)
    }

    @ViewBuilder
    private func featureEnvironment(_ content: Content) -> some View {
        content
            .environmentObject(model)
            .environmentObject(model.sessionCatalog)
            .environmentObject(model.transcriptPresentation)
            .environmentObject(model.providerAccountsModel)
            .environmentObject(model.voiceControl)
            .environmentObject(model.agentTeamsModel)
            .environmentObject(model.teamRunLive)
            .environmentObject(model.landingFlow)
            .environmentObject(model.runs)
            .environmentObject(model.evaluations)
            .environmentObject(model.knowledge)
            .environmentObject(model.activity)
            .environmentObject(model.schedule)
            .environmentObject(model.backgroundServicesModel)
            .environmentObject(model.extensionsModel)
            .environmentObject(model.gitWorkspace)
            .environmentObject(model.workspaceFiles)
            .environmentObject(model.library)
            .environmentObject(model.outputsLibrary)
            .environmentObject(model.onboarding)
            .environmentObject(model.agentInspector)
            .environmentObject(model.agentInstructions)
            .environmentObject(model.applicationContext)
            .environmentObject(model.toastCenter)
            .environmentObject(model.computerControl)
            .environmentObject(model.simulatorControl)
#if !LOCUS_APP_STORE
            .environmentObject(model.codexComponent)
#endif
    }
}

extension View {
    func appFeatureEnvironment(from model: AppModel) -> some View {
        modifier(AppFeatureEnvironmentModifier(model: model))
    }
}
