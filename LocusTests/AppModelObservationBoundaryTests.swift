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

    func testTranscriptChildPublicationsAndContentCommitsDoNotRepublishAppModel() {
        let app = AppModel(startImmediately: false)
        app.installTranscriptSession("selected", blocks: [ChatBlock(kind: .assistant, text: "Initial")])
        var appPublications = 0
        var transcriptPublications = 0
        let appSubscription = app.objectWillChange.sink { appPublications += 1 }
        let transcriptSubscription = app.transcriptPresentation.objectWillChange.sink {
            transcriptPublications += 1
        }

        app.transcriptPresentation.objectWillChange.send()
        app.blocks = [ChatBlock(kind: .assistant, text: "Replacement")]
        app.updateTranscriptBlocks { $0[0].text += " with committed growth" }
        app.installTranscriptSession("selected", blocks: [ChatBlock(kind: .assistant, text: "Same identity")])
        app.transcriptPresentation.replaceBlocks([ChatBlock(kind: .assistant, text: "Direct child commit")])

        XCTAssertEqual(appPublications, 0)
        XCTAssertGreaterThanOrEqual(transcriptPublications, 5)
        XCTAssertEqual(app.currentSessionID, "selected")
        withExtendedLifetime((appSubscription, transcriptSubscription)) {}
    }

    func testExplicitTranscriptIdentityTransitionsPublishOnceAfterTheCoherentCommit() {
        let app = AppModel(startImmediately: false)
        app.installTranscriptSession("old", blocks: [ChatBlock(kind: .assistant, text: "Old rows")])
        let next = ChatBlock(kind: .assistant, text: "New rows")
        var snapshots: [TranscriptPresentationSnapshot] = []
        let subscription = app.objectWillChange.sink {
            let snapshot = app.transcriptPresentation.snapshot
            XCTAssertEqual(app.currentSessionID, snapshot.sessionID)
            XCTAssertEqual(app.blocks, snapshot.blocks)
            snapshots.append(snapshot)
        }

        app.installTranscriptSession("new", blocks: [next])
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.last?.sessionID, "new")
        XCTAssertEqual(snapshots.last?.blocks, [next])

        let renderToken = app.transcriptPresentation.snapshot.renderToken
        let builds = app.transcriptPresentation.snapshotBuildCountForTesting
        app.rekeyTranscriptSession(to: "server-assigned")
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.last?.sessionID, "server-assigned")
        XCTAssertEqual(snapshots.last?.blocks, [next])
        XCTAssertEqual(snapshots.last?.renderToken, renderToken)
        XCTAssertEqual(app.transcriptPresentation.snapshotBuildCountForTesting, builds)

        app.currentSessionID = "empty-selected"
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.last?.sessionID, "empty-selected")
        XCTAssertEqual(snapshots.last?.blocks, [])
        withExtendedLifetime(subscription) {}
    }

    func testTranscriptIdentityNoOpsWrongSourceRekeyAndStaleCompletionDoNotPublish() {
        let app = AppModel(startImmediately: false)
        app.installTranscriptSession("selected", blocks: [ChatBlock(kind: .assistant, text: "Selected rows")])
        let original = app.transcriptPresentation.snapshot
        let stale = app.transcriptPresentation.beginSessionLoad("selected")
        let current = app.transcriptPresentation.beginSessionLoad("selected")
        var publications = 0
        let subscription = app.objectWillChange.sink { publications += 1 }

        app.currentSessionID = "selected"
        app.rekeyTranscriptSession(to: "selected")
        app.transcriptPresentation.rekeySession(from: "wrong-old-session", to: "unrelated")
        XCTAssertFalse(app.completeTranscriptSessionLoad(
            stale, sessionID: "late", blocks: [ChatBlock(kind: .assistant, text: "Rejected")]
        ))
        XCTAssertEqual(app.transcriptPresentation.snapshot, original)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(app.completeTranscriptSessionLoad(current, sessionID: "selected", blocks: original.blocks))
        XCTAssertEqual(publications, 0, "An accepted same-identity response is not a session transition")
        XCTAssertFalse(app.completeTranscriptSessionLoad(current, sessionID: "duplicate", blocks: []))
        app.installTranscriptSession("selected", blocks: original.blocks)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(app.transcriptPresentation.snapshot, original)
        withExtendedLifetime(subscription) {}
    }

    func testOwnedTranscriptCompletionWithAssignedIdentityPublishesItsInstalledRowsOnce() {
        let app = AppModel(startImmediately: false)
        let ownership = app.beginTranscriptSessionLoad("requested")
        let loaded = ChatBlock(kind: .assistant, text: "Loaded for the assigned identity")
        var snapshots: [TranscriptPresentationSnapshot] = []
        let subscription = app.objectWillChange.sink { snapshots.append(app.transcriptPresentation.snapshot) }

        XCTAssertTrue(app.completeTranscriptSessionLoad(ownership, sessionID: "assigned", blocks: [loaded]))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.sessionID, "assigned")
        XCTAssertEqual(snapshots.first?.blocks, [loaded])
        XCTAssertEqual(app.currentSessionID, "assigned")
        XCTAssertEqual(app.transcriptInputState, .loading,
            "An identity notification does not bypass the separately owned metadata admission gate")
        withExtendedLifetime(subscription) {}
    }

    func testTranscriptLoadAdmissionAndIdentityPublishAtTheirSeparateOwnedBoundaries() {
        let app = AppModel(startImmediately: false)
        let old = ChatBlock(kind: .assistant, text: "Old rows")
        app.installTranscriptSession("old", blocks: [old])
        var snapshots: [TranscriptPresentationSnapshot] = []
        let subscription = app.objectWillChange.sink { snapshots.append(app.transcriptPresentation.snapshot) }

        let ownership = app.beginTranscriptSessionLoad("requested")

        XCTAssertEqual(snapshots.count, 2,
            "One loading-state publication and one successful identity transition have distinct owners")
        XCTAssertEqual(snapshots.first?.sessionID, "old")
        XCTAssertEqual(snapshots.first?.blocks, [old])
        XCTAssertEqual(snapshots.last?.sessionID, "requested")
        XCTAssertEqual(snapshots.last?.blocks, [])
        XCTAssertEqual(app.transcriptInputState, .loading)
        XCTAssertTrue(app.transcriptPresentation.ownsSessionLoad(ownership))
        withExtendedLifetime(subscription) {}
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
