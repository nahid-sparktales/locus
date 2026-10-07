import Foundation

/// Owns agent-team configuration: the primary agent's behavior, saved
/// profiles and teams, routing consent, the concurrency knob, and the
/// selected team with its solo-delegation counterpart. Cross-feature reads
/// (accounts, catalogs, local models) arrive as closures; run manifests and
/// profile connection tests stay with the composition root, which reads this
/// state through the facade. AppModel wires it via configure(...) and
/// bridges its publication; it never retains AppModel.
@MainActor
final class AgentTeamsModel: ObservableObject {
    @Published private(set) var primaryAgentBehavior = AgentBehavior.primaryDefault()
    @Published var agentProfiles: [AgentProfile] = [] {
        didSet { if !isRestoring { profilesChanged() } }
    }
    var profilesChanged: () -> Void = {}
    @Published var agentTeams: [AgentTeam] = []
    @Published private(set) var teamRoutingConsentAccountIDs: Set<UUID> = []
    /// Native display preferences, deliberately separate from execution profiles.
    @Published private(set) var agentAvatarData: [UUID: Data] = [:]
    static let avatarsKey = "Locus.AgentProfiles.avatars.v1"
    @Published private(set) var agentAppearances: [UUID: CompanionAppearance] = [:]
    @Published private(set) var primaryCompanionID: UUID?
    @Published private(set) var companionAnimationsEnabled = true
    static let companionPresentationKey = "Locus.AgentProfiles.companionPresentation.v1"
    private var companionPresentation = AgentCompanionPresentation()

    @Published var globalAgentConcurrency = 3 {
        didSet {
            guard !isRestoring else { return }
            let bounded = min(max(globalAgentConcurrency, 1), 8)
            if bounded != globalAgentConcurrency {
                globalAgentConcurrency = bounded
                return
            }
            if persistenceEnabled {
                defaults.set(bounded, forKey: AgentTeamStore.globalConcurrencyKey)
            }
        }
    }

    @Published var selectedAgentTeamID: UUID? = nil {
        didSet {
            guard !isRestoring else { return }
            if selectedAgentTeamID != nil, soloSwarmEnabled {
                soloSwarmEnabled = false
            }
            guard persistenceEnabled else { return }
            defaults.set(selectedAgentTeamID?.uuidString, forKey: AgentTeamStore.selectionKey)
        }
    }

    /// Compatibility state for profiles written before Solo delegation became
    /// adaptive. Every non-team Solo Work/Plan/Grill turn now enables it.
    @Published var soloSwarmEnabled = true {
        didSet {
            guard !isRestoring else { return }
            guard soloSwarmEnabled != oldValue else { return }
            if soloSwarmEnabled, selectedAgentTeamID != nil {
                selectedAgentTeamID = nil
            }
            workspacePersistenceRequested()
        }
    }

    private var isRestoring = false
    private var persistenceEnabled = false
    private var defaults: UserDefaults = .standard
    private var isBusyProvider: () -> Bool = { false }
    private var workspacePersistenceRequested: () -> Void = {}
    private var localModelsProvider: () -> [ModelInfo] = { [] }
    private var accountsProvider: () -> [ProviderAccount] = { [] }
    private var accountModelsProvider: (UUID) -> [String]? = { _ in nil }
    private var toastHandler: (String) -> Void = { _ in }
    private var executionRouteWillChange: () -> Void = {}
    private let credentialStore: any CredentialStoring

    init(credentialStore: any CredentialStoring = CredentialStore.shared) {
        self.credentialStore = credentialStore
    }

    var selectedAgentTeam: AgentTeam? {
        selectedAgentTeamID.flatMap { id in agentTeams.first(where: { $0.id == id }) }
    }

    var teamModeEnabled: Bool { selectedAgentTeam != nil }

    /// Replicates the launch restore: loads never run for tests, migrations
    /// write back only on a real launch, and no property observer fires —
    /// matching the stored-property initialization the monolith's init did.
    func restore(persistenceEnabled: Bool, defaults: UserDefaults = .standard) {
        self.persistenceEnabled = persistenceEnabled
        self.defaults = defaults
        guard persistenceEnabled else { return }
        isRestoring = true
        defer { isRestoring = false }
        primaryAgentBehavior = AgentTeamStore.loadPrimaryBehavior(from: defaults)
        let loadedProfiles = AgentTeamStore.loadProfiles(from: defaults)
        let storedTeams = AgentTeamStore.loadTeams(from: defaults)
        let approvalMigration = AgentTeamStore.migrateToOneTimeApproval(storedTeams)
        let budgetMigration = AgentTeamStore.migrateLegacyCallBudgets(approvalMigration.teams)
        let loadedTeams = budgetMigration.teams
        let loadedSelection = defaults.string(forKey: AgentTeamStore.selectionKey)
            .flatMap(UUID.init(uuidString:))
        agentProfiles = loadedProfiles
        restoreAgentAvatars()
        agentTeams = loadedTeams
        if approvalMigration.changed || budgetMigration.changed {
            AgentTeamStore.save(profiles: loadedProfiles, teams: loadedTeams, to: defaults)
        }
        teamRoutingConsentAccountIDs = AgentTeamStore.loadConsent(from: defaults)
        let storedConcurrency = defaults.integer(forKey: AgentTeamStore.globalConcurrencyKey)
        globalAgentConcurrency = storedConcurrency == 0 ? 3 : min(max(storedConcurrency, 1), 8)
        selectedAgentTeamID = loadedTeams.contains(where: { $0.id == loadedSelection })
            ? loadedSelection : nil
        restoreCompanionPresentation()
    }

    func configure(
        isBusyProvider: @escaping () -> Bool,
        workspacePersistenceRequested: @escaping () -> Void,
        localModelsProvider: @escaping () -> [ModelInfo],
        accountsProvider: @escaping () -> [ProviderAccount],
        accountModelsProvider: @escaping (UUID) -> [String]?,
        toastHandler: @escaping (String) -> Void,
        executionRouteWillChange: @escaping () -> Void = {}
    ) {
        self.isBusyProvider = isBusyProvider
        self.workspacePersistenceRequested = workspacePersistenceRequested
        self.localModelsProvider = localModelsProvider
        self.accountsProvider = accountsProvider
        self.accountModelsProvider = accountModelsProvider
        self.toastHandler = toastHandler
        self.executionRouteWillChange = executionRouteWillChange
    }

    func suggestedQuickTeamName() -> String {
        QuickTeamFactory.suggestedTeamName(existingTeams: agentTeams)
    }

    func missingQuickTeamRoutingAccounts(for draft: QuickTeamDraft) -> [ProviderAccount] {
        let accounts = accountsProvider()
        return draft.selectedAccountIDs
            .subtracting(teamRoutingConsentAccountIDs)
            .compactMap { id in accounts.first(where: { $0.id == id }) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @discardableResult
    func createAndSelectQuickTeam(
        _ draft: QuickTeamDraft
    ) -> Result<AgentTeam, QuickTeamCreationError> {
        if isBusyProvider() { return quickTeamFailure(.activeRun) }
        if let account = missingQuickTeamRoutingAccounts(for: draft).first {
            return quickTeamFailure(.routingConsentRequired(account.displayName))
        }
        if let availabilityError = quickTeamAvailabilityError(for: draft) {
            return quickTeamFailure(availabilityError)
        }

        do {
            let build = try QuickTeamFactory.build(
                draft: draft,
                existingProfiles: agentProfiles,
                existingTeams: agentTeams
            )
            // Publish only after the complete staged result validates. This
            // prevents a failed quick setup from leaving orphaned profiles.
            executionRouteWillChange()
            agentProfiles = build.profiles
            agentTeams.append(build.team)
            persistAgentTeams()
            soloSwarmEnabled = false
            selectedAgentTeamID = build.team.id
            toastHandler("Created and selected \(build.team.name)")
            return .success(build.team)
        } catch let error as QuickTeamCreationError {
            return quickTeamFailure(error)
        } catch {
            return quickTeamFailure(.invalidTeam(error.localizedDescription))
        }
    }

    private func quickTeamAvailabilityError(
        for draft: QuickTeamDraft
    ) -> QuickTeamCreationError? {
        let localModels = localModelsProvider()
        let accounts = accountsProvider()
        for choice in draft.selectedChoices {
            switch choice.route {
            case .localOllama:
                if !localModels.isEmpty,
                   !localModels.contains(where: {
                       $0.name.caseInsensitiveCompare(choice.model) == .orderedSame
                   })
                {
                    return .unavailableModel(choice.model)
                }
            case .providerAccount(let accountID):
                guard let account = accounts.first(where: { $0.id == accountID }),
                      account.isCredentialReady(in: credentialStore)
                else {
                    return .unavailableProvider(choice.providerName)
                }
                guard let reported = accountModelsProvider(accountID),
                      reported.contains(where: {
                          $0.caseInsensitiveCompare(choice.model) == .orderedSame
                      })
                else {
                    return .unavailableModel(choice.model)
                }
            }
        }
        return nil
    }

    private func quickTeamFailure(
        _ error: QuickTeamCreationError
    ) -> Result<AgentTeam, QuickTeamCreationError> {
        toastHandler(error.localizedDescription)
        return .failure(error)
    }

    func selectAgentTeam(_ id: UUID?) {
        if selectedAgentTeamID != id { executionRouteWillChange() }
        soloSwarmEnabled = id == nil
        selectedAgentTeamID = id
        toastHandler(id == nil ? "Solo mode" : "Team mode")
    }

    func selectSoloRoute() {
        if selectedAgentTeamID != nil { executionRouteWillChange() }
        selectedAgentTeamID = nil
        soloSwarmEnabled = true
        toastHandler("Solo mode")
    }

    func savePrimaryAgentBehavior(_ behavior: AgentBehavior) {
        var updated = behavior
        updated.clamp()
        executionRouteWillChange()
        primaryAgentBehavior = updated
        if persistenceEnabled {
            AgentTeamStore.savePrimaryBehavior(updated, to: defaults)
        }
        toastHandler("Primary agent settings saved — they apply on the next turn")
    }

    func setAgentAvatar(_ data: Data?, profileID: UUID) {
        guard agentProfiles.contains(where: { $0.id == profileID }),
              data.map({ $0.count <= AgentAvatarImage.maximumStoredBytes }) ?? true else { return }
        agentAvatarData[profileID] = data
        persistAgentAvatars()
        if data != nil { setAgentAppearance(.portrait, profileID: profileID) }
    }

    func setAgentAnimationPack(_ data: Data, profileID: UUID) throws {
        guard agentProfiles.contains(where: { $0.id == profileID }) else { throw CompanionValidationError.missingProfile }
        let pack = try CompanionAnimationPack.decode(data)
        let clean = try JSONEncoder().encode(pack)
        agentAvatarData[profileID] = clean
        persistAgentAvatars()
        setAgentAppearance(.importedSprite(assetID: pack.assetID), profileID: profileID)
    }

    func setAgentAppearance(_ appearance: CompanionAppearance?, profileID: UUID) {
        guard agentProfiles.contains(where: { $0.id == profileID }) else { return }
        companionPresentation.appearances[profileID] = appearance?.validated
        agentAppearances = companionPresentation.appearances.mapValues(\.validated)
        persistCompanionPresentation()
    }

    func setCompanionAnimationsEnabled(_ enabled: Bool) {
        companionAnimationsEnabled = enabled
        companionPresentation.animationsEnabled = enabled
        persistCompanionPresentation()
    }

    /// Explicit setup seeds a new identity and its communication defaults. An offline profile
    /// intentionally has no model; execution still requires the normal routing
    /// and readiness checks. Existing-profile selection never edits that profile.
    @discardableResult
    func commitCompanion(
        _ draft: CompanionOnboardingDraft,
        route: AgentRoute = .localOllama,
        model: String = ""
    ) throws -> UUID {
        if persistenceEnabled {
            // MainActor serializes multiple windows. Read the durable winner so
            // even separately constructed models cannot commit a second primary.
            restoreCompanionPresentation()
        }
        if let id = primaryCompanionID,
           agentProfiles.contains(where: { $0.id == id }) { return id }

        if let existingID = draft.existingProfileID {
            guard agentProfiles.contains(where: { $0.id == existingID }) else {
                throw CompanionValidationError.missingProfile
            }
            companionPresentation.primaryProfileID = existingID
            primaryCompanionID = existingID
            persistCompanionPresentation()
            return existingID
        }

        let name = try CompanionValidationError.validatedName(draft.name)
        let appearance = draft.appearance.validated
        var approvedAvatar: Data?
        if appearance.kind == .portrait {
            guard let data = draft.avatarData, data.count <= AgentAvatarImage.maximumStoredBytes,
                  let normalized = try? AgentAvatarImage.normalized(data) else {
                throw CompanionValidationError.invalidPortrait
            }
            approvedAvatar = normalized
        }
        // A reserved UUID, never a name match, reconciles interrupted creation.
        // Presentation can use repeated human names; IDs remain authoritative.
        let profile = agentProfiles.first(where: { $0.id == draft.reservedProfileID })
            ?? AgentProfile(id: draft.reservedProfileID, name: name, route: route, model: model,
                instructions: draft.instructions,
                behavior: AgentBehavior(displayName: name,
                    selfDescription: draft.personality.map { "Your \($0.role.lowercased())." }
                        ?? "A practical companion.",
                    customInstructions: draft.instructions))
        companionPresentation.primaryProfileID = profile.id
        companionPresentation.appearances[profile.id] = appearance
        companionPresentation.pendingCreation = profile
        companionPresentation.pendingAvatarData = approvedAvatar
        persistCompanionPresentation()
        finishPendingCompanionCreation()
        return profile.id
    }

    private func restoreCompanionPresentation() {
        // Saved edits from another window win over this model's stale snapshot.
        // Loading the full arrays also preserves teams when replay saves profiles.
        if persistenceEnabled, defaults.data(forKey: AgentTeamStore.profilesKey) != nil {
            agentProfiles = AgentTeamStore.loadProfiles(from: defaults)
        }
        if persistenceEnabled, defaults.data(forKey: AgentTeamStore.teamsKey) != nil {
            agentTeams = AgentTeamStore.loadTeams(from: defaults)
        }
        if persistenceEnabled {
            teamRoutingConsentAccountIDs = AgentTeamStore.loadConsent(from: defaults)
            restoreAgentAvatars()
        }
        if let data = defaults.data(forKey: Self.companionPresentationKey),
           let saved = try? JSONDecoder().decode(AgentCompanionPresentation.self, from: data),
           saved.version == 1 {
            companionPresentation = saved
        }
        // A complete canonical snapshot exists only in this short-lived intent.
        // Replay is idempotent and is removed as soon as the profile is durable.
        finishPendingCompanionCreation()
        if let id = companionPresentation.primaryProfileID,
           !agentProfiles.contains(where: { $0.id == id }),
           let durable = AgentTeamStore.loadProfiles(from: defaults).first(where: { $0.id == id }) {
            agentProfiles.append(durable)
        }
        primaryCompanionID = companionPresentation.primaryProfileID.flatMap { id in
            agentProfiles.contains(where: { $0.id == id }) ? id : nil
        }
        agentAppearances = companionPresentation.appearances.mapValues(\.validated)
        companionAnimationsEnabled = companionPresentation.animationsEnabled
        restoreAgentAvatars()
    }

    private func finishPendingCompanionCreation() {
        guard let pending = companionPresentation.pendingCreation else { return }
        if !agentProfiles.contains(where: { $0.id == pending.id }) {
            // Preserve other durable agents if this model was mounted earlier
            // than another window's changes.
            if persistenceEnabled {
                for profile in AgentTeamStore.loadProfiles(from: defaults)
                    where !agentProfiles.contains(where: { $0.id == profile.id }) {
                    agentProfiles.append(profile)
                }
            }
            if !agentProfiles.contains(where: { $0.id == pending.id }) { agentProfiles.append(pending) }
        }
        persistAgentTeams()
        if let data = companionPresentation.pendingAvatarData {
            setAgentAvatar(data, profileID: pending.id)
        }
        primaryCompanionID = pending.id
        agentAppearances = companionPresentation.appearances.mapValues(\.validated)
        companionAnimationsEnabled = companionPresentation.animationsEnabled
        companionPresentation.pendingCreation = nil
        companionPresentation.pendingAvatarData = nil
        persistCompanionPresentation()
    }

    private func persistCompanionPresentation() {
        guard persistenceEnabled,
              let data = try? JSONEncoder().encode(companionPresentation) else { return }
        // Like existing profiles, one encoded value is atomically replaced in
        // the injected edition UserDefaults domain; no second profile database.
        defaults.set(data, forKey: Self.companionPresentationKey)
    }

    private func persistAgentAvatars() {
        guard persistenceEnabled else { return }
        defaults.set(Dictionary(uniqueKeysWithValues: agentAvatarData.map { ($0.key.uuidString, $0.value) }),
                     forKey: Self.avatarsKey)
    }

    private func restoreAgentAvatars() {
        guard persistenceEnabled else { return }
        let profileIDs = Set(agentProfiles.map(\.id))
        agentAvatarData = Dictionary(uniqueKeysWithValues:
            (defaults.dictionary(forKey: Self.avatarsKey) ?? [:]).compactMap { key, value in
                guard let id = UUID(uuidString: key), profileIDs.contains(id),
                      let data = value as? Data else { return nil }
                if data.count > AgentAvatarImage.maximumStoredBytes || agentAppearances[id]?.kind == .importedSprite {
                    guard agentAppearances[id]?.kind == .importedSprite,
                          (try? CompanionAnimationPack.decode(data)) != nil else { return nil }
                }
                return (id, data)
            })
    }

    func saveAgentProfile(_ profile: AgentProfile) {
        var updated = profile
        if updated.id == primaryCompanionID {
            do { updated.name = try CompanionValidationError.validatedName(updated.name) }
            catch { toastHandler(error.localizedDescription); return }
        }
        updated.clamp()
        guard updated.isConfigured || (updated.id == primaryCompanionID && !updated.name.isEmpty) else {
            toastHandler("Give the agent a name and exact model")
            return
        }
        let collision = updated.id != primaryCompanionID && agentProfiles.contains {
            $0.id != updated.id
                && $0.id != primaryCompanionID
                && $0.name.caseInsensitiveCompare(updated.name) == .orderedSame
        }
        guard !collision else {
            toastHandler("Agent names must be unique")
            return
        }
        if let index = agentProfiles.firstIndex(where: { $0.id == updated.id }) {
            agentProfiles[index] = updated
        } else {
            agentProfiles.append(updated)
        }
        persistAgentTeams()
        toastHandler("Saved \(updated.name)")
    }

    @discardableResult
    func removeAgentProfile(_ profile: AgentProfile) -> Bool {
        guard !isBusyProvider() else {
            toastHandler("Stop the active run before removing an agent")
            return false
        }
        agentProfiles.removeAll { $0.id == profile.id }
        agentAvatarData[profile.id] = nil
        persistAgentAvatars()
        agentAppearances[profile.id] = nil
        companionPresentation.appearances[profile.id] = nil
        if primaryCompanionID == profile.id {
            primaryCompanionID = nil
            companionPresentation.primaryProfileID = nil
        }
        if companionPresentation.pendingCreation?.id == profile.id {
            companionPresentation.pendingCreation = nil
            companionPresentation.pendingAvatarData = nil
        }
        persistCompanionPresentation()
        agentTeams = agentTeams.compactMap { team in
            var updated = team
            updated.memberIDs.removeAll { $0 == profile.id }
            if updated.dispatcherID == profile.id { updated.dispatcherID = nil }
            if updated.fallbackDispatcherID == profile.id { updated.fallbackDispatcherID = nil }
            if updated.defaultWriterID == profile.id { updated.defaultWriterID = nil }
            return updated
        }
        if selectedAgentTeamID.flatMap({ id in agentTeams.first(where: { $0.id == id }) }) == nil {
            selectedAgentTeamID = nil
        }
        persistAgentTeams()
        return true
    }

    func saveAgentTeam(_ team: AgentTeam) {
        var updated = team
        updated.clamp()
        let errors = AgentTeamValidation.errors(team: updated, profiles: agentProfiles)
        guard errors.isEmpty else {
            toastHandler(errors[0])
            return
        }
        let collision = agentTeams.contains {
            $0.id != updated.id
                && $0.name.caseInsensitiveCompare(updated.name) == .orderedSame
        }
        guard !collision else {
            toastHandler("Team names must be unique")
            return
        }
        if let index = agentTeams.firstIndex(where: { $0.id == updated.id }) {
            agentTeams[index] = updated
        } else {
            agentTeams.append(updated)
        }
        persistAgentTeams()
        toastHandler("Saved \(updated.name)")
    }

    func removeAgentTeam(_ team: AgentTeam) {
        guard !isBusyProvider() else {
            toastHandler("Stop the active run before removing a team")
            return
        }
        agentTeams.removeAll { $0.id == team.id }
        if selectedAgentTeamID == team.id { selectedAgentTeamID = nil }
        persistAgentTeams()
    }

    func grantAutomaticRoutingConsent(for accountID: UUID) {
        teamRoutingConsentAccountIDs.insert(accountID)
        persistAgentTeams()
    }

    func revokeAutomaticRoutingConsent(for accountID: UUID) {
        teamRoutingConsentAccountIDs.remove(accountID)
        persistAgentTeams()
    }

    private func persistAgentTeams() {
        guard persistenceEnabled else { return }
        AgentTeamStore.save(profiles: agentProfiles, teams: agentTeams, to: defaults)
        defaults.set(
            teamRoutingConsentAccountIDs.map(\.uuidString).sorted(),
            forKey: AgentTeamStore.consentKey
        )
    }
}
