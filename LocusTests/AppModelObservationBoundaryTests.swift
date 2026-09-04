import Combine
import XCTest

@testable import Locus

@MainActor
final class AppModelObservationBoundaryTests: XCTestCase {
    private struct FeatureEvent {
        let name: String
        let emit: () -> Void
    }

    func testFeaturePublicationsStayAtTheirDirectObservationBoundary() async {
        let app = AppModel(startImmediately: false)
        let catalogBuilds = app.sessionCatalog.snapshotBuildCountForTesting
        let transcriptBuilds = app.transcriptPresentation.snapshotBuildCountForTesting
        var appPublications = 0
        let subscription = app.objectWillChange.sink { appPublications += 1 }
        let events = featureEvents(for: app)

        for event in events {
            let publicationsBeforeEvent = appPublications
            event.emit()
            // Provider and application-context events retain side effects on
            // the next main-actor turn. Give those observations time to run so
            // this proves they do not republish AppModel either.
            await Task.yield()
            await Task.yield()

            XCTAssertEqual(
                appPublications,
                publicationsBeforeEvent,
                "\(event.name) must be observed directly"
            )
            XCTAssertEqual(
                app.sessionCatalog.snapshotBuildCountForTesting,
                catalogBuilds,
                "\(event.name) must not rebuild the session catalog"
            )
            XCTAssertEqual(
                app.transcriptPresentation.snapshotBuildCountForTesting,
                transcriptBuilds,
                "\(event.name) must not rebuild transcript presentation"
            )
        }

        XCTAssertEqual(events.count, 23, "Keep this table complete as feature ownership grows")
        withExtendedLifetime(subscription) {}
    }

    func testHighFrequencyComposerStateDoesNotPublishAppModel() async {
        let app = AppModel(startImmediately: false)
        var appPublications = 0
        var composerPublications = 0
        let appSubscription = app.objectWillChange.sink { appPublications += 1 }
        let composerSubscription = app.composerState.objectWillChange.sink {
            composerPublications += 1
        }

        app.draftText = "A long draft that changes while the user types"
        app.queuedMessages.append("queued")
        app.chatAttachments = []
        await Task.yield()

        XCTAssertEqual(appPublications, 0)
        XCTAssertGreaterThanOrEqual(composerPublications, 2)
        withExtendedLifetime((appSubscription, composerSubscription)) {}
    }

    func testAdvisoryRepeatedFeaturePublicationFixture() {
        let app = AppModel(startImmediately: false)
        let catalogBuilds = app.sessionCatalog.snapshotBuildCountForTesting
        let transcriptBuilds = app.transcriptPresentation.snapshotBuildCountForTesting
        var appPublications = 0
        let subscription = app.objectWillChange.sink { appPublications += 1 }

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<100 {
                app.gitWorkspace.objectWillChange.send()
                app.providerAccountsModel.objectWillChange.send()
                app.agentTeamsModel.objectWillChange.send()
                app.activity.objectWillChange.send()
                app.simulatorControl.objectWillChange.send()
            }
        }

        XCTAssertEqual(appPublications, 0)
        XCTAssertEqual(app.sessionCatalog.snapshotBuildCountForTesting, catalogBuilds)
        XCTAssertEqual(app.transcriptPresentation.snapshotBuildCountForTesting, transcriptBuilds)
        add(XCTAttachment(string: "AppModel publications: \(appPublications)"))
        withExtendedLifetime(subscription) {}
    }

    private func featureEvents(for app: AppModel) -> [FeatureEvent] {
        var events = [
            FeatureEvent(name: "workspace layout") { app.workspaceLayout.objectWillChange.send() },
            FeatureEvent(name: "composer state") { app.composerState.objectWillChange.send() },
            FeatureEvent(name: "runtime status") { app.runtimeStatus.objectWillChange.send() },
            FeatureEvent(name: "provider accounts") { app.providerAccountsModel.objectWillChange.send() },
            FeatureEvent(name: "voice control") { app.voiceControl.objectWillChange.send() },
            FeatureEvent(name: "agent teams") { app.agentTeamsModel.objectWillChange.send() },
            FeatureEvent(name: "live team run") { app.teamRunLive.objectWillChange.send() },
            FeatureEvent(name: "landing flow") { app.landingFlow.objectWillChange.send() },
            FeatureEvent(name: "run history") { app.runs.objectWillChange.send() },
            FeatureEvent(name: "evaluations") { app.evaluations.objectWillChange.send() },
            FeatureEvent(name: "knowledge") { app.knowledge.objectWillChange.send() },
            FeatureEvent(name: "activity") { app.activity.objectWillChange.send() },
            FeatureEvent(name: "schedule") { app.schedule.objectWillChange.send() },
            FeatureEvent(name: "background services") { app.backgroundServicesModel.objectWillChange.send() },
            FeatureEvent(name: "extensions") { app.extensionsModel.objectWillChange.send() },
            FeatureEvent(name: "Git") { app.gitWorkspace.objectWillChange.send() },
            FeatureEvent(name: "workspace files") { app.workspaceFiles.objectWillChange.send() },
            FeatureEvent(name: "agent instructions") { app.agentInstructions.objectWillChange.send() },
            FeatureEvent(name: "application context") { app.applicationContext.objectWillChange.send() },
            FeatureEvent(name: "toasts") { app.toastCenter.objectWillChange.send() },
            FeatureEvent(name: "computer control") { app.computerControl.objectWillChange.send() },
            FeatureEvent(name: "simulator control") { app.simulatorControl.objectWillChange.send() },
        ]
#if !LOCUS_APP_STORE
        events.append(FeatureEvent(name: "component installer") {
            app.codexComponent.objectWillChange.send()
        })
#else
        // The direct-download-only installer is deliberately absent from MAS,
        // but the table's shape remains deterministic in both configurations.
        events.append(FeatureEvent(name: "component installer unavailable in MAS") {})
#endif
        return events
    }
}

final class AppModelObservationBoundaryStructureTests: XCTestCase {
    func testAppModelHasNoFeatureRepublishingBridges() throws {
        let appModelSources = try sourceFiles(in: "Locus").filter {
            $0.lastPathComponent.hasPrefix("AppModel")
        }
        let source = try appModelSources.map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertEqual(
            matches(of: #"objectWillChange\s*\.\s*send\s*\("#, in: source),
            [],
            "AppModel must not republish child feature changes"
        )
        XCTAssertEqual(
            matches(of: #"private\s+var\s+\w*[Bb]ridge\w*\s*:\s*AnyCancellable"#, in: source),
            [],
            "Feature bridge storage must not return to AppModel"
        )
    }

    func testReactiveViewsDoNotReachThroughAppModelFeatureFacades() throws {
        let allowedCompositionFile = "AppFeatureEnvironment.swift"
        let patterns = [
            "providerAccountsModel", "voiceControl", "codexComponent", "agentTeamsModel",
            "teamRunLive", "landingFlow", "runs", "evaluations", "knowledge", "activity",
            "schedule", "backgroundServicesModel", "extensionsModel", "gitWorkspace",
            "workspaceFiles", "agentInstructions", "applicationContext", "toastCenter",
            "computerControl", "simulatorControl", "models", "localModels",
            "installedLocalModels", "providerAccounts", "accountModels", "accountStatus",
            "accountModelCatalogs", "primaryAgentBehavior", "teamRoutingConsentAccountIDs",
            "selectedAgentTeam", "teamModeEnabled", "agentProfiles", "agentTeams",
            "globalAgentConcurrency", "selectedAgentTeamID", "soloSwarmEnabled",
            "visibleActivityRuns", "taskHasChanges", "orchestrationRuns",
            "selectedOrchestrationRun", "runDetailsByID", "orchestrationEvents",
            "isLoadingOrchestrationRuns",
        ].map { #"model\.\#($0)\b"# }

        for file in try sourceFiles(in: "Locus")
            where file.lastPathComponent != allowedCompositionFile {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains(": View") else { continue }
            for pattern in patterns {
                XCTAssertEqual(
                    matches(of: pattern, in: source),
                    [],
                    "Reactive feature access escaped the direct boundary in \(file.lastPathComponent)"
                )
            }
        }
    }

    private func sourceFiles(in directory: String) throws -> [URL] {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = repository.appendingPathComponent(directory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func matches(of pattern: String, in source: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [pattern] }
        let range = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        }
    }
}
