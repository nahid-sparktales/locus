import AppKit
import XCTest
@testable import Locus

@MainActor
final class CompanionPersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "CompanionPersistenceTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func store(in defaults: UserDefaults? = nil) -> AgentTeamsModel {
        let model = AgentTeamsModel(credentialStore: InMemoryCredentialStore())
        model.restore(persistenceEnabled: true, defaults: defaults ?? self.defaults)
        return model
    }

    private func onboarding(existing: Bool = false, store: AgentTeamsModel? = nil) -> OnboardingModel {
        let model = OnboardingModel()
        model.configure(defaults: defaults, isExistingInstallation: existing, autoPresent: true,
            readiness: { .unknown }, refresh: { XCTFail("Setup must not connect to a model") },
            start: { _, _ in XCTFail("Setup must not start work"); throw CocoaError(.userCancelled) },
            observe: { _ in XCTFail("Setup must not monitor work"); return .running })
        if let store {
            model.configureCompanion(commit: { try store.commitCompanion($0) },
                                     primaryProfileID: { store.primaryCompanionID })
        }
        return model
    }

    func testFreshDraftDefaultsToPitouWithoutCreatingAnAgent() {
        let profiles = store()
        let model = onboarding(store: profiles)
        XCTAssertEqual(model.companion.draft.name, "Pitou")
        XCTAssertEqual(model.companion.draft.appearance.bundledSprite, .pitou)
        XCTAssertTrue(profiles.agentProfiles.isEmpty)
        XCTAssertNil(profiles.primaryCompanionID)
    }

    func testRestoredLocusDraftKeepsItsNameAppearanceAndReservedIdentity() throws {
        let draft = CompanionOnboardingDraft(name: "Locus", appearance: .robot)
        var saved = OnboardingModel.Progress()
        saved.companion = CompanionOnboardingProgress(status: .deferred, step: .name, draft: draft)
        defaults.set(try JSONEncoder().encode(saved), forKey: "Locus.onboarding.v1")
        let model = onboarding(existing: true)
        model.beginCompanionSetup()
        XCTAssertEqual(model.companion.draft, draft)
        XCTAssertEqual(model.companion.step, .name)
        XCTAssertEqual(model.companion.draft.name, "Locus")
        XCTAssertEqual(model.companion.draft.appearance.builtIn, .robot)
    }

    func testFreshOfflineSetupCommitsCanonicalProfileExactlyOnce() throws {
        let profiles = store()
        let model = onboarding(store: profiles)
        let reserved = model.companion.draft.reservedProfileID
        model.presentOnLaunchIfNeeded()
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.companion.status, .inProgress)
        XCTAssertTrue(profiles.agentProfiles.isEmpty)
        model.setCompanionName("  Névé 李  ")
        let appearance = CompanionAppearance(character: .fox, palette: .violet, accessory: .scarf, variationSeed: 17)
        model.selectCompanionAppearance(appearance)
        model.companionNext()
        model.companionNext()
        model.companionNext()
        XCTAssertTrue(profiles.agentProfiles.isEmpty, "Preview and naming cannot create an agent")
        XCTAssertEqual(model.completeCompanion(), reserved)
        XCTAssertEqual(model.completeCompanion(), reserved)
        XCTAssertEqual(profiles.agentProfiles.count, 1)
        XCTAssertEqual(profiles.agentProfiles.first?.name, "Névé 李")
        XCTAssertEqual(profiles.agentProfiles.first?.model, "")
        XCTAssertEqual(profiles.agentProfiles.first?.accessCeiling, .readOnly)
        XCTAssertNil(profiles.agentProfiles.first?.mcpPolicy)
        XCTAssertEqual(profiles.agentAppearances[reserved], appearance)
        XCTAssertEqual(model.companion.status, .completed)
        XCTAssertFalse(model.progress.firstTaskCompleted)
        XCTAssertNil(model.progress.run)
        XCTAssertTrue(profiles.agentTeams.isEmpty)
        XCTAssertTrue(profiles.teamRoutingConsentAccountIDs.isEmpty)
    }

    func testSkipQuitAndManualResumeKeepExactDraftWithoutCreating() throws {
        let profiles = store()
        let first = onboarding(store: profiles)
        first.presentOnLaunchIfNeeded()
        first.companionNext()
        first.setCompanionName("Aster")
        first.selectCompanionAppearance(.surprise(seed: 42))
        let draft = first.companion.draft
        // Reopening after a quit while the sheet is open is not another offer.
        let afterQuit = onboarding(store: profiles)
        afterQuit.presentOnLaunchIfNeeded()
        XCTAssertFalse(afterQuit.isPresented)
        XCTAssertEqual(afterQuit.companion.draft, draft)
        afterQuit.beginCompanionSetup()
        XCTAssertTrue(afterQuit.isPresented)
        afterQuit.dismiss()
        XCTAssertEqual(afterQuit.companion.status, .deferred)
        let afterSkip = onboarding(store: profiles)
        afterSkip.presentOnLaunchIfNeeded()
        XCTAssertFalse(afterSkip.isPresented)
        afterSkip.beginCompanionSetup()
        XCTAssertEqual(afterSkip.companion.draft, draft)
        XCTAssertEqual(afterSkip.companion.step, .appearance)
        XCTAssertTrue(profiles.agentProfiles.isEmpty)
    }

    func testTwoWindowModelsClaimOnlyOneAutomaticPresentation() {
        let first = onboarding()
        let second = onboarding()
        first.presentOnLaunchIfNeeded()
        second.presentOnLaunchIfNeeded()
        XCTAssertTrue(first.isPresented)
        XCTAssertFalse(second.isPresented)
        XCTAssertEqual(second.companion.draft.reservedProfileID, first.companion.draft.reservedProfileID)
    }

    func testTwoWindowStoresConvergeOnFirstCommittedPrimary() throws {
        let first = store()
        let second = store()
        let firstDraft = CompanionOnboardingDraft(name: "One")
        let secondDraft = CompanionOnboardingDraft(name: "Two")
        let id = try first.commitCompanion(firstDraft)
        XCTAssertEqual(try second.commitCompanion(secondDraft), id)
        XCTAssertEqual(AgentTeamStore.loadProfiles(from: defaults).map(\.id), [id])
        XCTAssertEqual(second.agentProfiles.first?.name, "One")
    }

    func testStaleWindowCommitPreservesOtherWindowsProfileTeamAndConsentEdits() throws {
        let first = store()
        let original = AgentProfile(name: "Researcher", model: "old-model")
        first.saveAgentProfile(original)
        let staleWindow = store()
        var edited = original
        edited.model = "new-model"
        edited.instructions = "Changed in the first window"
        edited.behavior?.customInstructions = edited.instructions
        first.saveAgentProfile(edited)
        let additional = AgentProfile(name: "Writer", model: "writer-model")
        first.saveAgentProfile(additional)
        let consentID = UUID()
        first.grantAutomaticRoutingConsent(for: consentID)
        let team = AgentTeam(name: "Existing team", dispatcherID: original.id,
            fallbackDispatcherID: nil, memberIDs: [original.id, additional.id], defaultWriterID: additional.id,
            dispatchApprovalMode: .preview)
        AgentTeamStore.save(profiles: first.agentProfiles, teams: [team], to: defaults)
        let companionID = try staleWindow.commitCompanion(.init(name: "New companion"))
        let restored = store()
        XCTAssertEqual(restored.agentProfiles.first(where: { $0.id == original.id }), edited)
        XCTAssertTrue(restored.agentProfiles.contains(where: { $0.id == additional.id }))
        XCTAssertTrue(restored.agentProfiles.contains(where: { $0.id == companionID }))
        XCTAssertEqual(restored.teamRoutingConsentAccountIDs, [consentID])
        XCTAssertEqual(restored.agentTeams, [team])
    }

    func testExistingInstallDoesNotAutomaticallyShowCompanion() {
        let model = onboarding(existing: true)
        model.presentOnLaunchIfNeeded()
        XCTAssertFalse(model.isPresented)
        XCTAssertFalse(model.showsCompanionSetup)
        XCTAssertEqual(model.companion.status, .deferred)
        model.beginCompanionSetup()
        XCTAssertTrue(model.isPresented)
        XCTAssertTrue(model.showsCompanionSetup)
    }

    func testVersionOneMigrationPreservesGettingStartedAndDoesNotOfferAgain() throws {
        var legacy = OnboardingModel.Progress()
        legacy.version = 1
        legacy.step = .workspace
        legacy.startingPoint = .coding
        legacy.workspace = "/tmp/private-project"
        legacy.failure = "An existing task failed"
        defaults.set(try JSONEncoder().encode(legacy), forKey: "Locus.onboarding.v1")
        let model = onboarding()
        model.presentOnLaunchIfNeeded()
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(model.progress.version, 2)
        XCTAssertEqual(model.progress.step, .workspace)
        XCTAssertEqual(model.progress.startingPoint, .coding)
        XCTAssertEqual(model.progress.workspace, legacy.workspace)
        XCTAssertEqual(model.progress.failure, legacy.failure)
        XCTAssertEqual(model.companion.status, .deferred)
    }

    func testUnreadableStoredProgressIsNotMisclassifiedAsFresh() {
        defaults.set(Data("unsupported stored progress".utf8), forKey: "Locus.onboarding.v1")
        let model = onboarding()
        model.presentOnLaunchIfNeeded()
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(model.companion.status, .deferred)
        model.beginCompanionSetup()
        XCTAssertTrue(model.isPresented)
    }

    func testNameValidationPreservesUnicodeAndRejectsWithoutTruncating() throws {
        XCTAssertEqual(try CompanionValidationError.validatedName("  Zoë 李  "), "Zoë 李")
        XCTAssertEqual(try CompanionValidationError.validatedName(String(repeating: "é", count: 64)).count, 64)
        for invalid in ["", "   ", "A\nB", "A\u{0}B", "\tA", String(repeating: "é", count: 65)] {
            XCTAssertThrowsError(try CompanionValidationError.validatedName(invalid))
        }
        let model = onboarding(store: store())
        let tooLong = String(repeating: "ø", count: 65)
        model.setCompanionName(tooLong)
        XCTAssertNil(model.completeCompanion())
        XCTAssertEqual(model.companion.draft.name, tooLong)
        XCTAssertNotNil(model.error)
    }

    func testRestartRestoresIdentityAndReconcilesOnboardingCommitGap() throws {
        let profiles = store()
        let first = onboarding(store: profiles)
        first.setCompanionName("Pip")
        first.selectCompanionAppearance(.init(character: .frog, palette: .amber, accessory: .glasses))
        let draft = first.companion.draft
        // Simulate a crash after canonical commit but before onboarding completion.
        let id = try profiles.commitCompanion(draft)
        let restoredProfiles = store()
        let restoredOnboarding = onboarding(store: restoredProfiles)
        XCTAssertEqual(restoredOnboarding.companion.status, .completed)
        XCTAssertEqual(restoredOnboarding.companion.completedProfileID, id)
        XCTAssertEqual(restoredOnboarding.completeCompanion(), id)
        XCTAssertEqual(restoredProfiles.agentProfiles.map(\.id), [id])
        XCTAssertEqual(restoredProfiles.agentProfiles.first?.name, "Pip")
        XCTAssertEqual(restoredProfiles.agentAppearances[id], draft.appearance)
    }

    func testJournalReplaysBeforeAndAfterCanonicalSaveWithoutDuplication() throws {
        let profile = AgentProfile(name: "Interrupted")
        let appearance = CompanionAppearance(character: .explorer, palette: .slate)
        let journal = AgentCompanionPresentation(primaryProfileID: profile.id,
            appearances: [profile.id: appearance], pendingCreation: profile)
        for alreadyCreated in [false, true] {
            AgentTeamStore.save(profiles: alreadyCreated ? [profile] : [], teams: [], to: defaults)
            defaults.set(try JSONEncoder().encode(journal), forKey: AgentTeamsModel.companionPresentationKey)
            let model = store()
            XCTAssertEqual(model.agentProfiles, [profile])
            XCTAssertEqual(model.primaryCompanionID, profile.id)
            XCTAssertEqual(model.agentAppearances[profile.id], appearance)
            let data = try XCTUnwrap(defaults.data(forKey: AgentTeamsModel.companionPresentationKey))
            let finished = try JSONDecoder().decode(AgentCompanionPresentation.self, from: data)
            XCTAssertNil(finished.pendingCreation)
            XCTAssertNil(finished.pendingAvatarData)
        }
    }

    func testPortraitJournalRecoveryPreservesOtherAgentsArtwork() throws {
        let existing = AgentProfile(name: "Existing art", model: "local")
        let pending = AgentProfile(name: "Custom companion")
        let oldAppearance = CompanionAppearance(character: .cat, palette: .rose)
        let pixels = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        pixels.bitmapData?.initialize(repeating: 0, count: pixels.bytesPerRow * pixels.pixelsHigh)
        let source = try XCTUnwrap(pixels.representation(using: .png, properties: [:]))
        let image = try AgentAvatarImage.normalized(source)
        AgentTeamStore.save(profiles: [existing], teams: [], to: defaults)
        let journal = AgentCompanionPresentation(primaryProfileID: pending.id,
            appearances: [existing.id: oldAppearance, pending.id: .portrait],
            pendingCreation: pending, pendingAvatarData: image)
        defaults.set(try JSONEncoder().encode(journal), forKey: AgentTeamsModel.companionPresentationKey)
        let recovered = store()
        XCTAssertEqual(recovered.agentAppearances[existing.id], oldAppearance)
        XCTAssertEqual(recovered.agentAppearances[pending.id], .portrait)
        XCTAssertEqual(recovered.agentAvatarData[pending.id], image)
        XCTAssertEqual(recovered.agentProfiles.map(\.id), [existing.id, pending.id])
    }

    func testExplicitExistingLinkPreservesEveryCanonicalAndPresentationField() throws {
        let model = store()
        let profile = AgentProfile(name: "Existing", route: .providerAccount(UUID()), model: "private-model",
            instructions: "Existing instructions", accessCeiling: .readOnly,
            mcpPolicy: MCPAgentPolicy(serverIDs: ["specific-service"]))
        model.saveAgentProfile(profile)
        let appearance = CompanionAppearance(character: .cat, palette: .rose)
        model.setAgentAppearance(appearance, profileID: profile.id)
        let id = try model.commitCompanion(CompanionOnboardingDraft(name: "Should not rename", existingProfileID: profile.id))
        XCTAssertEqual(id, profile.id)
        XCTAssertEqual(model.agentProfiles, [profile])
        XCTAssertEqual(model.agentAppearances[id], appearance)
        XCTAssertTrue(model.teamRoutingConsentAccountIDs.isEmpty)
        XCTAssertNil(model.selectedAgentTeamID)
    }

    func testMissingExplicitProfileNeverRepurposesAnotherAgent() throws {
        let model = store()
        let existing = AgentProfile(name: "Unrelated", model: "local")
        model.saveAgentProfile(existing)
        XCTAssertThrowsError(try model.commitCompanion(.init(existingProfileID: UUID())))
        XCTAssertEqual(model.agentProfiles, [existing])
        XCTAssertNil(model.primaryCompanionID)
    }

    func testDisplayNamesAreNotIdentityKeys() throws {
        let model = store()
        let existing = AgentProfile(name: "Locus", model: "local")
        model.saveAgentProfile(existing)
        let companionID = try model.commitCompanion(.init(name: "Locus"))
        XCTAssertNotEqual(existing.id, companionID)
        XCTAssertEqual(model.agentProfiles.count, 2)
        XCTAssertEqual(model.agentProfiles.first, existing)
        var edited = existing
        edited.model = "updated-model"
        model.saveAgentProfile(edited)
        XCTAssertEqual(model.agentProfiles.first, edited,
                       "A companion with the same display name must not prevent editing the original agent")
    }

    func testAppearanceAndAnimationEditsDoNotMutateExecutionProfiles() throws {
        let model = store()
        let id = try model.commitCompanion(.init(), route: .providerAccount(UUID()), model: "chosen-model")
        let before = model.agentProfiles
        model.setAgentAppearance(.surprise(seed: 808), profileID: id)
        model.setCompanionAnimationsEnabled(false)
        XCTAssertEqual(model.agentProfiles, before)
        let restored = store()
        XCTAssertEqual(restored.agentProfiles, before)
        XCTAssertFalse(restored.companionAnimationsEnabled)
        XCTAssertEqual(restored.agentAppearances[id], .surprise(seed: 808))
    }

    func testInvalidPortraitCannotCreateProfileOrChangeBinding() {
        let model = store()
        let invalid = CompanionOnboardingDraft(appearance: .portrait, avatarData: Data("<svg onload='bad'/>".utf8))
        XCTAssertThrowsError(try model.commitCompanion(invalid))
        XCTAssertTrue(model.agentProfiles.isEmpty)
        XCTAssertNil(model.primaryCompanionID)
    }

    func testEditionAndDevelopmentSuitesRemainIsolated() throws {
        let otherName = "CompanionOtherEdition.\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherName))
        defer { otherDefaults.removePersistentDomain(forName: otherName) }
        let model = store()
        _ = try model.commitCompanion(.init(name: "Locus edition"))
        let other = store(in: otherDefaults)
        XCTAssertNil(other.primaryCompanionID)
        XCTAssertTrue(other.agentProfiles.isEmpty)
        XCTAssertTrue(other.agentAppearances.isEmpty)
    }

    func testExplicitCompanionFolderRestoresThroughCanonicalProfileInIsolatedSuite() throws {
        let profiles = store()
        let id = try profiles.commitCompanion(.init(name: "Pitou"))
        let app = AppModel(startImmediately: false)
        defer { app.toastCenter.cancelPendingDismissal() }
        app.agentTeamsModel.restore(persistenceEnabled: true, defaults: defaults)
        app.selectCompanionWorkspace("/var/tmp")
        let restored = store()
        XCTAssertEqual(restored.primaryCompanionID, id)
        XCTAssertEqual(restored.agentProfiles.first?.workspacePreferences?.defaultProjectPath,
                       SessionSummary.canonicalWorkspacePath("/var/tmp"))
        XCTAssertEqual(restored.agentProfiles.first?.model, "", "Folder choice does not configure execution")
        XCTAssertEqual(restored.agentProfiles.first?.accessCeiling, .readOnly)
        let otherName = "CompanionFolderOtherEdition.\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherName))
        defer { otherDefaults.removePersistentDomain(forName: otherName) }
        let other = store(in: otherDefaults)
        XCTAssertNil(other.primaryCompanionID)
        XCTAssertTrue(other.agentProfiles.isEmpty)
    }

    func testDeletingCompanionDoesNotResurrectItsJournalOnRestart() throws {
        let model = store()
        _ = try model.commitCompanion(.init())
        let profile = try XCTUnwrap(model.agentProfiles.first)
        XCTAssertTrue(model.removeAgentProfile(profile))
        let restored = store()
        XCTAssertTrue(restored.agentProfiles.isEmpty)
        XCTAssertNil(restored.primaryCompanionID)
        XCTAssertTrue(restored.agentAppearances.isEmpty)
    }
}
