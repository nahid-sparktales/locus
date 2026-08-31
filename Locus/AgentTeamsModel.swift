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
    @Published var agentProfiles: [AgentProfile] = []
    @Published var agentTeams: [AgentTeam] = []
    @Published private(set) var teamRoutingConsentAccountIDs: Set<UUID> = []

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
        agentTeams = loadedTeams
        if approvalMigration.changed || budgetMigration.changed {
            AgentTeamStore.save(profiles: loadedProfiles, teams: loadedTeams, to: defaults)
        }
        teamRoutingConsentAccountIDs = AgentTeamStore.loadConsent(from: defaults)
        let storedConcurrency = defaults.integer(forKey: AgentTeamStore.globalConcurrencyKey)
        globalAgentConcurrency = storedConcurrency == 0 ? 3 : min(max(storedConcurrency, 1), 8)
        selectedAgentTeamID = loadedTeams.contains(where: { $0.id == loadedSelection })
            ? loadedSelection : nil
    }

    func configure(
        isBusyProvider: @escaping () -> Bool,
        workspacePersistenceRequested: @escaping () -> Void,
        localModelsProvider: @escaping () -> [ModelInfo],
        accountsProvider: @escaping () -> [ProviderAccount],
        accountModelsProvider: @escaping (UUID) -> [String]?,
        toastHandler: @escaping (String) -> Void
    ) {
        self.isBusyProvider = isBusyProvider
        self.workspacePersistenceRequested = workspacePersistenceRequested
        self.localModelsProvider = localModelsProvider
        self.accountsProvider = accountsProvider
        self.accountModelsProvider = accountModelsProvider
        self.toastHandler = toastHandler
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
                      account.isCredentialReady
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
        soloSwarmEnabled = id == nil
        selectedAgentTeamID = id
        toastHandler(id == nil ? "Solo mode" : "Team mode")
    }

    func selectSoloRoute() {
        selectedAgentTeamID = nil
        soloSwarmEnabled = true
        toastHandler("Solo mode")
    }

    func savePrimaryAgentBehavior(_ behavior: AgentBehavior) {
        var updated = behavior
        updated.clamp()
        primaryAgentBehavior = updated
        if persistenceEnabled {
            AgentTeamStore.savePrimaryBehavior(updated)
        }
        toastHandler("Primary agent settings saved — they apply on the next turn")
    }

    func saveAgentProfile(_ profile: AgentProfile) {
        var updated = profile
        updated.clamp()
        guard updated.isConfigured else {
            toastHandler("Give the agent a name and exact model")
            return
        }
        let collision = agentProfiles.contains {
            $0.id != updated.id
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

    func removeAgentProfile(_ profile: AgentProfile) {
        guard !isBusyProvider() else {
            toastHandler("Stop the active run before removing an agent")
            return
        }
        agentProfiles.removeAll { $0.id == profile.id }
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
        AgentTeamStore.save(profiles: agentProfiles, teams: agentTeams)
        defaults.set(
            teamRoutingConsentAccountIDs.map(\.uuidString).sorted(),
            forKey: AgentTeamStore.consentKey
        )
    }
}
