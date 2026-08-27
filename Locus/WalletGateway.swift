import Foundation

struct WalletPolicyTemplate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let accountID: String
    let networkID: String
    let recipient: String
    let maximumTransactionBaseUnits: String
    let maximumSessionBaseUnits: String
    let maximumFeeBaseUnits: String
    let durationMinutes: Int

    func policy() -> WalletSessionPolicy {
        WalletSessionPolicy(
            id: UUID().uuidString.lowercased(), accountID: accountID, networkID: networkID,
            allowedAssetIDs: ["slip44:60"], allowedRecipients: [recipient],
            allowedContractIDs: [], allowedAdapterIDs: ["native-eth-transfer-v1"],
            maximumTransactionBaseUnits: maximumTransactionBaseUnits,
            maximumSessionBaseUnits: maximumSessionBaseUnits,
            maximumFeeBaseUnits: maximumFeeBaseUnits,
            expiresAt: Date().addingTimeInterval(TimeInterval(durationMinutes * 60))
        )
    }
}

struct WalletBrowserOriginGrant: Identifiable, Equatable, Sendable {
    let id: UUID
    let origin: String
}

enum WalletPolicyDecision: Equatable, Sendable {
    case automatic
    case requiresApproval(String)
    case denied(String)
}

/// Decimal-free arithmetic for unsigned chain base units. Security decisions
/// must not round through Decimal, Double, locale formatting, or token decimals.
enum WalletBaseUnits {
    static func normalize(_ value: String) -> String? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = normalize(lhs), let right = normalize(rhs) else { return nil }
        if left.count != right.count {
            return left.count < right.count ? .orderedAscending : .orderedDescending
        }
        if left == right { return .orderedSame }
        return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
    }

    static func add(_ lhs: String, _ rhs: String) -> String? {
        guard let left = normalize(lhs), let right = normalize(rhs) else { return nil }
        var a = left.reversed().map { Int(String($0))! }
        let b = right.reversed().map { Int(String($0))! }
        if a.count < b.count { a.append(contentsOf: repeatElement(0, count: b.count - a.count)) }
        var carry = 0
        for index in 0..<a.count {
            let total = a[index] + (index < b.count ? b[index] : 0) + carry
            a[index] = total % 10
            carry = total / 10
        }
        if carry > 0 { a.append(carry) }
        return a.reversed().map(String.init).joined()
    }

    static func multiply(_ lhs: String, _ rhs: String) -> String? {
        guard let left = normalize(lhs), let right = normalize(rhs) else { return nil }
        if left == "0" || right == "0" { return "0" }
        let a = left.reversed().map { Int(String($0))! }
        let b = right.reversed().map { Int(String($0))! }
        var product = Array(repeating: 0, count: a.count + b.count)
        for (leftIndex, leftDigit) in a.enumerated() {
            for (rightIndex, rightDigit) in b.enumerated() {
                product[leftIndex + rightIndex] += leftDigit * rightDigit
            }
        }
        for index in 0..<(product.count - 1) {
            product[index + 1] += product[index] / 10
            product[index] %= 10
        }
        while product.last == 0 { product.removeLast() }
        return product.reversed().map(String.init).joined()
    }

    static func lessThanOrEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard let result = compare(lhs, rhs) else { return false }
        return result != .orderedDescending
    }
}

enum WalletPolicyEngine {
    static func evaluate(
        transaction: WalletPreparedTransaction,
        policy: WalletSessionPolicy?,
        spentThisSession: String,
        now: Date = Date()
    ) -> WalletPolicyDecision {
        guard transaction.expiresAt > now else { return .denied("The prepared transaction has expired.") }
        guard transaction.simulationSucceeded else { return .denied("The transaction simulation failed.") }
        if transaction.riskFlags.contains(.codeHashMismatch) {
            return .denied("The observed contract code no longer matches the approved registry entry.")
        }
        if transaction.riskFlags.contains(.unlimitedApproval) {
            return .requiresApproval("Unlimited token approvals require an exact confirmation.")
        }
        if transaction.riskFlags.contains(.undecodableCall)
            || transaction.riskFlags.contains(.unknownEffect) {
            return .requiresApproval("The call has effects that are not covered by an autonomous adapter.")
        }
        guard let adapterID = transaction.adapterID else {
            return .requiresApproval("This registered call has no reviewed autonomous effect adapter.")
        }
        guard let policy else {
            return .requiresApproval("No active session policy covers this transaction.")
        }
        guard policy.expiresAt > now else { return .requiresApproval("The wallet policy has expired.") }
        guard policy.accountID == transaction.accountID, policy.networkID == transaction.networkID else {
            return .requiresApproval("The account or network is outside the active policy.")
        }
        guard policy.allowedAdapterIDs.contains(adapterID),
              policy.allowedAssetIDs.contains(transaction.budgetAssetID) else {
            return .requiresApproval("The asset or effect adapter is outside the active policy.")
        }
        if let recipient = transaction.action.recipient,
           !policy.allowedRecipients.contains(recipient) {
            return .requiresApproval("The recipient is outside the active policy.")
        }
        if let contractID = transaction.action.contractID,
           !policy.allowedContractIDs.contains(contractID) {
            return .requiresApproval("The contract is outside the active policy.")
        }
        guard WalletBaseUnits.lessThanOrEqual(
            transaction.spendBaseUnits, policy.maximumTransactionBaseUnits
        ), let total = WalletBaseUnits.add(spentThisSession, transaction.spendBaseUnits),
           WalletBaseUnits.lessThanOrEqual(total, policy.maximumSessionBaseUnits) else {
            return .requiresApproval("The transaction exceeds its base-unit budget.")
        }
        guard WalletBaseUnits.lessThanOrEqual(
            transaction.maximumFeeBaseUnits, policy.maximumFeeBaseUnits
        ), WalletBaseUnits.lessThanOrEqual(
            transaction.feeQuoteBaseUnits, transaction.maximumFeeBaseUnits
        ) else {
            return .requiresApproval("The transaction exceeds its fee ceiling.")
        }
        return .automatic
    }
}

@MainActor
protocol WalletSignerClient: AnyObject {
    var isAvailable: Bool { get }
    var sessionID: String? { get }
    var invalidationHandler: (() -> Void)? { get set }
    func signerStatus() async throws -> WalletSignerStatus
    func beginVaultCreation() async throws -> WalletVaultCreation
    func confirmVaultBackup(_ confirmation: WalletBackupConfirmation) async throws -> WalletSignerStatus
    func cancelVaultCreation() async throws -> WalletSignerStatus
    func deleteVault(confirmation: String) async throws -> WalletSignerStatus
    func authorizeSession() async throws
    func listAccounts() async throws -> [WalletAccount]
    func prepare(
        _ request: WalletPrepareRequest,
        contract: WalletContractRegistryEntry?
    ) async throws -> WalletPreparedTransaction
    func simulate(intentID: String) async throws -> WalletPreparedTransaction
    func confirmExecution(intentID: String) async throws
    func execute(intentID: String) async throws -> [String: Any]
    func activatePolicy(_ policy: WalletSessionPolicy) async throws -> [WalletActivePolicyStatus]
    func listPolicies() async throws -> [WalletActivePolicyStatus]
    func clearPolicies() async throws
    func verifyContract(_ draft: WalletContractRegistryDraft) async throws -> WalletContractRegistryEntry
    func browserRPC(method: String, params: [Any]) async throws -> Any
    func performRead(tool: String, arguments: [String: Any]) async throws -> [String: Any]
    func rpcHealth() async throws -> String
    func configureRPCURL(_ value: String)
    func lock()
}

@MainActor
final class UnavailableWalletSignerClient: WalletSignerClient {
    let isAvailable = false
    let sessionID: String? = nil
    var invalidationHandler: (() -> Void)?
    func signerStatus() async throws -> WalletSignerStatus { throw WalletGateway.Error.signerUnavailable }
    func beginVaultCreation() async throws -> WalletVaultCreation { throw WalletGateway.Error.signerUnavailable }
    func confirmVaultBackup(_ confirmation: WalletBackupConfirmation) async throws -> WalletSignerStatus {
        throw WalletGateway.Error.signerUnavailable
    }
    func cancelVaultCreation() async throws -> WalletSignerStatus { throw WalletGateway.Error.signerUnavailable }
    func deleteVault(confirmation: String) async throws -> WalletSignerStatus {
        throw WalletGateway.Error.signerUnavailable
    }
    func authorizeSession() async throws { throw WalletGateway.Error.signerUnavailable }
    func listAccounts() async throws -> [WalletAccount] { [] }
    func prepare(
        _ request: WalletPrepareRequest,
        contract: WalletContractRegistryEntry?
    ) async throws -> WalletPreparedTransaction {
        throw WalletGateway.Error.signerUnavailable
    }
    func simulate(intentID: String) async throws -> WalletPreparedTransaction {
        throw WalletGateway.Error.signerUnavailable
    }
    func confirmExecution(intentID: String) async throws { throw WalletGateway.Error.signerUnavailable }
    func execute(intentID: String) async throws -> [String: Any] {
        throw WalletGateway.Error.signerUnavailable
    }
    func activatePolicy(_ policy: WalletSessionPolicy) async throws -> [WalletActivePolicyStatus] {
        throw WalletGateway.Error.signerUnavailable
    }
    func listPolicies() async throws -> [WalletActivePolicyStatus] { [] }
    func clearPolicies() async throws { throw WalletGateway.Error.signerUnavailable }
    func verifyContract(_ draft: WalletContractRegistryDraft) async throws -> WalletContractRegistryEntry {
        throw WalletGateway.Error.signerUnavailable
    }
    func browserRPC(method: String, params: [Any]) async throws -> Any {
        throw WalletGateway.Error.signerUnavailable
    }
    func performRead(tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        throw WalletGateway.Error.signerUnavailable
    }
    func rpcHealth() async throws -> String { throw WalletGateway.Error.signerUnavailable }
    func configureRPCURL(_ value: String) {}
    func lock() {}
}

@MainActor
final class WalletGateway: ObservableObject {
    enum Status: String, Equatable {
        case securityReviewRequired
        case locked
        case unlocked
    }

    enum Error: LocalizedError {
        case signerUnavailable
        case vaultLocked
        case invalidArguments(String)
        case intentNotFound
        case policyDenied(String)
        case approvalRequired(String)

        var errorDescription: String? {
            switch self {
            case .signerUnavailable: "The experimental Locus WalletSigner component is not installed in this build."
            case .vaultLocked: "Locus Vault is locked. Authorize a signing session in Wallet Settings first."
            case .invalidArguments(let message): message
            case .intentNotFound: "The prepared transaction is missing or expired. Prepare it again."
            case .policyDenied(let message): message
            case .approvalRequired(let message): message
            }
        }
    }

    static let protocolVersion = 1
    static let sepoliaNetworkID = "eip155:11155111"
    static let allowedOperations = [
        "wallet_list_accounts", "wallet_get_balance", "wallet_get_activity",
        "wallet_prepare_transaction", "wallet_simulate_transaction",
        "wallet_execute_transaction", "wallet_lock",
    ]

    @Published private(set) var status: Status
    @Published private(set) var accounts: [WalletAccount] = []
    @Published private(set) var activePolicies: [WalletSessionPolicy] = []
    @Published private(set) var pendingConfirmation: WalletPreparedTransaction?
    @Published private(set) var vaultState: WalletVaultState = .missing
    @Published private(set) var vaultCreation: WalletVaultCreation?
    @Published private(set) var rpcHealthText = "Not checked"
    @Published private(set) var lastError: String?
    @Published private(set) var transactionHistory: [[String: String]] = []
    @Published private(set) var activePolicyStatuses: [WalletActivePolicyStatus] = []
    @Published private(set) var contractRegistry: [WalletContractRegistryEntry] = []
    @Published private(set) var savedPolicyTemplates: [WalletPolicyTemplate] = []
    @Published private(set) var pendingBrowserOriginGrant: WalletBrowserOriginGrant?

    private let signer: WalletSignerClient
    private let experimentalEnabled: Bool
    let browserProviderEnabled: Bool
    private var prepared: [String: WalletPreparedTransaction] = [:]
    private var confirmedIntentIDs: Set<String> = []
    private let registryDefaultsKey = "LocusWalletContractRegistryV1"
    private let policyTemplatesDefaultsKey = "LocusWalletPolicyTemplatesV1"
    private var browserOriginGrants: Set<String> = []
    private var browserIntentOrigins: [String: String] = [:]
    private var browserGrantContinuation: CheckedContinuation<Bool, Never>?
    private var confirmationContinuations: [String: CheckedContinuation<Bool, Never>] = [:]
    var onBrowserAuthorizationNeeded: (() -> Void)?
    var onBrowserGrantsRevoked: ((String?) -> Void)?

    init(signer: WalletSignerClient? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        let signer = signer ?? WalletSignerClientFactory.make()
        self.signer = signer
        experimentalEnabled = environment["LOCUS_ENABLE_EXPERIMENTAL_WALLET"] == "1"
        browserProviderEnabled = experimentalEnabled
            && environment["LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER"] == "1"
        status = signer.isAvailable ? .locked : .securityReviewRequired
        if let data = UserDefaults.standard.data(forKey: registryDefaultsKey),
           let registry = try? JSONDecoder().decode([WalletContractRegistryEntry].self, from: data) {
            contractRegistry = registry
        }
        if let data = UserDefaults.standard.data(forKey: policyTemplatesDefaultsKey),
           let templates = try? JSONDecoder().decode([WalletPolicyTemplate].self, from: data) {
            savedPolicyTemplates = templates
        }
        signer.invalidationHandler = { [weak self] in self?.handleSignerInvalidation() }
    }

    var agentToolingAvailable: Bool {
        experimentalEnabled && signer.isAvailable && status == .unlocked && signer.sessionID != nil
    }

    var capability: [String: Any]? {
        guard agentToolingAvailable, let sessionID = signer.sessionID else { return nil }
        return [
            "protocol_version": Self.protocolVersion,
            "signer_state": status.rawValue,
            "session_id": sessionID,
            "supported_chains": [Self.sepoliaNetworkID],
            "allowed_operations": Self.allowedOperations,
        ]
    }

    var canAuthorizeSession: Bool {
        experimentalEnabled && signer.isAvailable && vaultState == .locked
    }

    var canCreateVault: Bool {
        experimentalEnabled && signer.isAvailable && vaultState == .missing
    }

    var isExperimentalEnabled: Bool { experimentalEnabled }
    var signerAvailable: Bool { signer.isAvailable }

    func refreshStatus() async {
        guard signer.isAvailable else {
            status = .securityReviewRequired
            vaultState = .missing
            return
        }
        do {
            let signerStatus = try await signer.signerStatus()
            vaultState = signerStatus.vaultState
            accounts = signerStatus.accounts
            status = signerStatus.vaultState == .unlocked ? .unlocked : .locked
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func beginVaultCreation() async -> WalletVaultCreation? {
        guard canCreateVault else { return nil }
        do {
            let creation = try await signer.beginVaultCreation()
            vaultCreation = creation
            vaultState = .awaitingBackup
            lastError = nil
            return creation
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func confirmVaultBackup(wordsByIndex: [Int: String]) async -> Bool {
        do {
            let signerStatus = try await signer.confirmVaultBackup(
                WalletBackupConfirmation(wordsByIndex: wordsByIndex)
            )
            vaultCreation = nil
            vaultState = signerStatus.vaultState
            accounts = signerStatus.accounts
            status = .locked
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func cancelVaultCreation() async {
        do {
            let signerStatus = try await signer.cancelVaultCreation()
            vaultCreation = nil
            vaultState = signerStatus.vaultState
            accounts = signerStatus.accounts
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func deleteVault(confirmation: String) async -> Bool {
        do {
            let signerStatus = try await signer.deleteVault(confirmation: confirmation)
            lock()
            vaultState = signerStatus.vaultState
            accounts = signerStatus.accounts
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func checkRPCHealth() async {
        do { rpcHealthText = try await signer.rpcHealth() }
        catch { rpcHealthText = error.localizedDescription }
    }

    var statusText: String {
        if signer.isAvailable && !experimentalEnabled { return "Experimental feature is off" }
        if vaultState == .missing { return "Not created" }
        if vaultState == .awaitingBackup { return "Backup not confirmed" }
        return switch status {
        case .securityReviewRequired: "Experimental signer unavailable"
        case .locked: "Locked"
        case .unlocked: "Unlocked for this Locus session"
        }
    }

    func configureRPCURL(_ value: String) {
        signer.configureRPCURL(value)
    }

    func lock() {
        signer.lock()
        activePolicies.removeAll()
        activePolicyStatuses.removeAll()
        prepared.removeAll()
        confirmedIntentIDs.removeAll()
        pendingConfirmation = nil
        revokeAllBrowserGrants()
        resolveAllConfirmationWaiters(approved: false)
        accounts.removeAll()
        status = signer.isAvailable ? .locked : .securityReviewRequired
        if vaultState == .unlocked { vaultState = .locked }
    }

    private func handleSignerInvalidation() {
        activePolicies.removeAll()
        activePolicyStatuses.removeAll()
        prepared.removeAll()
        confirmedIntentIDs.removeAll()
        pendingConfirmation = nil
        revokeAllBrowserGrants()
        resolveAllConfirmationWaiters(approved: false)
        accounts.removeAll()
        status = signer.isAvailable ? .locked : .securityReviewRequired
        if vaultState == .unlocked { vaultState = .locked }
    }

    @discardableResult
    func authorizeSession() async -> Bool {
        guard experimentalEnabled, signer.isAvailable else { return false }
        do {
            try await signer.authorizeSession()
            accounts = try await signer.listAccounts()
            guard signer.sessionID != nil else { throw Error.vaultLocked }
            status = .unlocked
            vaultState = .unlocked
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            status = .locked
            vaultState = .locked
            return false
        }
    }

    @discardableResult
    func activatePolicy(_ policy: WalletSessionPolicy) async -> Bool {
        guard status == .unlocked else { return false }
        do {
            activePolicyStatuses = try await signer.activatePolicy(policy)
            activePolicies = activePolicyStatuses.map(\.policy)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func clearPolicies() async {
        do {
            try await signer.clearPolicies()
            activePolicies.removeAll()
            activePolicyStatuses.removeAll()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func savePolicyTemplate(_ template: WalletPolicyTemplate) {
        savedPolicyTemplates.removeAll { $0.id == template.id }
        savedPolicyTemplates.append(template)
        savedPolicyTemplates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistPolicyTemplates()
    }

    func removePolicyTemplate(id: String) {
        savedPolicyTemplates.removeAll { $0.id == id }
        persistPolicyTemplates()
    }

    @discardableResult
    func activatePolicyTemplate(id: String) async -> Bool {
        guard let template = savedPolicyTemplates.first(where: { $0.id == id }) else { return false }
        return await activatePolicy(template.policy())
    }

    private func persistPolicyTemplates() {
        if let data = try? JSONEncoder().encode(savedPolicyTemplates) {
            UserDefaults.standard.set(data, forKey: policyTemplatesDefaultsKey)
        }
    }

    @discardableResult
    func addContractRegistryEntry(_ draft: WalletContractRegistryDraft) async -> Bool {
        do {
            let entry = try await signer.verifyContract(draft)
            let changed = contractRegistry.first(where: { $0.id == entry.id }).map { $0 != entry } ?? false
            contractRegistry.removeAll { $0.id == entry.id }
            contractRegistry.append(entry)
            contractRegistry.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            if let data = try? JSONEncoder().encode(contractRegistry) {
                UserDefaults.standard.set(data, forKey: registryDefaultsKey)
            }
            if changed { await clearPolicies() }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func removeContractRegistryEntry(id: String) async {
        contractRegistry.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(contractRegistry) {
            UserDefaults.standard.set(data, forKey: registryDefaultsKey)
        }
        await clearPolicies()
    }

    func confirm(intentID: String) {
        guard let transaction = prepared[intentID], transaction.expiresAt > Date() else { return }
        confirmedIntentIDs.insert(intentID)
        confirmationContinuations.removeValue(forKey: intentID)?.resume(returning: true)
        if pendingConfirmation?.id == intentID { pendingConfirmation = nil }
    }

    func cancelConfirmation(intentID: String) {
        prepared[intentID] = nil
        confirmedIntentIDs.remove(intentID)
        confirmationContinuations.removeValue(forKey: intentID)?.resume(returning: false)
        if pendingConfirmation?.id == intentID { pendingConfirmation = nil }
    }

    func requestBrowserAccounts(origin: String) async -> [String]? {
        guard browserProviderEnabled, agentToolingAvailable,
              let normalized = Self.normalizedWebOrigin(origin) else { return nil }
        if browserOriginGrants.contains(normalized) { return evmAddresses }
        guard pendingBrowserOriginGrant == nil, browserGrantContinuation == nil else { return nil }
        pendingBrowserOriginGrant = WalletBrowserOriginGrant(id: UUID(), origin: normalized)
        onBrowserAuthorizationNeeded?()
        let approved = await withCheckedContinuation { continuation in
            browserGrantContinuation = continuation
        }
        return approved ? evmAddresses : nil
    }

    func browserAccounts(origin: String) -> [String] {
        guard let normalized = Self.normalizedWebOrigin(origin),
              browserOriginGrants.contains(normalized), agentToolingAvailable else { return [] }
        return evmAddresses
    }

    func approveBrowserOrigin() {
        guard let request = pendingBrowserOriginGrant else { return }
        browserOriginGrants.insert(request.origin)
        pendingBrowserOriginGrant = nil
        browserGrantContinuation?.resume(returning: true)
        browserGrantContinuation = nil
    }

    func denyBrowserOrigin() {
        pendingBrowserOriginGrant = nil
        browserGrantContinuation?.resume(returning: false)
        browserGrantContinuation = nil
    }

    func revokeBrowserOrigin(_ origin: String) {
        guard let normalized = Self.normalizedWebOrigin(origin) else { return }
        browserOriginGrants.remove(normalized)
        if pendingBrowserOriginGrant?.origin == normalized { denyBrowserOrigin() }
        for intentID in browserIntentOrigins.compactMap({ $0.value == normalized ? $0.key : nil }) {
            cancelConfirmation(intentID: intentID)
            browserIntentOrigins[intentID] = nil
        }
        onBrowserGrantsRevoked?(normalized)
    }

    func browserReadRPC(origin: String, method: String, params: [Any]) async throws -> Any {
        guard !browserAccounts(origin: origin).isEmpty else {
            throw Error.approvalRequired("This website is not connected to Locus Vault.")
        }
        return try await signer.browserRPC(method: method, params: params)
    }

    func browserSendTransaction(origin: String, transaction: [String: Any]) async throws -> String {
        let rawValue = nonempty(transaction["value"]) ?? "0x0"
        let rawData = nonempty(transaction["data"]) ?? "0x"
        guard let normalizedOrigin = Self.normalizedWebOrigin(origin),
              let account = browserAccounts(origin: normalizedOrigin).first,
              let from = nonempty(transaction["from"]),
              from.caseInsensitiveCompare(account) == .orderedSame,
              let recipient = nonempty(transaction["to"]),
              let value = WalletEthereumQuantity.hexToDecimal(rawValue),
              rawData.lowercased() == "0x" else {
            throw Error.invalidArguments(
                "The experimental browser provider accepts Sepolia native transfers only; contract calldata and signing methods are disabled."
            )
        }
        let preparedResult = await perform(tool: "wallet_prepare_transaction", arguments: [
            "network_id": Self.sepoliaNetworkID,
            "account_id": accounts.first(where: { $0.chain == .evm })?.id ?? "",
            "action": [
                "type": "native_transfer", "recipient": recipient,
                "amount_base_units": value,
            ],
            // Testnet-only ceiling. The exact native sheet still displays and
            // approves the authoritative simulated fee before execution.
            "maximum_fee_base_units": "10000000000000000",
        ])
        if let message = preparedResult["error"] as? String { throw Error.policyDenied(message) }
        guard let intentID = preparedResult["intent_id"] as? String else {
            throw Error.invalidArguments("The wallet did not return a transaction intent.")
        }
        browserIntentOrigins[intentID] = normalizedOrigin
        defer { browserIntentOrigins[intentID] = nil }
        if pendingConfirmation?.id == intentID {
            onBrowserAuthorizationNeeded?()
            guard await waitForConfirmation(intentID: intentID) else {
                throw Error.approvalRequired("The website transaction was rejected or expired.")
            }
        }
        guard !browserAccounts(origin: normalizedOrigin).isEmpty else {
            cancelConfirmation(intentID: intentID)
            throw Error.approvalRequired("The website grant was revoked before signing.")
        }
        let result = await perform(tool: "wallet_execute_transaction", arguments: ["intent_id": intentID])
        if let message = result["error"] as? String { throw Error.policyDenied(message) }
        guard let hash = result["transaction_hash"] as? String else {
            throw Error.invalidArguments("The Sepolia RPC did not return a transaction hash.")
        }
        return hash
    }

    private var evmAddresses: [String] {
        accounts.filter { $0.chain == .evm }.map(\.address)
    }

    private func waitForConfirmation(intentID: String) async -> Bool {
        if confirmedIntentIDs.contains(intentID) { return true }
        guard (prepared[intentID]?.expiresAt ?? .distantPast) > Date(),
              confirmationContinuations[intentID] == nil else { return false }
        return await withCheckedContinuation { continuation in
            confirmationContinuations[intentID] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(125))
                guard self?.confirmationContinuations[intentID] != nil else { return }
                self?.cancelConfirmation(intentID: intentID)
            }
        }
    }

    private func revokeAllBrowserGrants() {
        let hadGrants = !browserOriginGrants.isEmpty || pendingBrowserOriginGrant != nil
        browserOriginGrants.removeAll()
        for intentID in browserIntentOrigins.keys { cancelConfirmation(intentID: intentID) }
        browserIntentOrigins.removeAll()
        pendingBrowserOriginGrant = nil
        browserGrantContinuation?.resume(returning: false)
        browserGrantContinuation = nil
        if hadGrants { onBrowserGrantsRevoked?(nil) }
    }

    private func resolveAllConfirmationWaiters(approved: Bool) {
        let waiters = Array(confirmationContinuations.values)
        confirmationContinuations.removeAll()
        waiters.forEach { $0.resume(returning: approved) }
    }

    private static func normalizedWebOrigin(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let isStandardPort = (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        let port = components.port.map { isStandardPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    func perform(tool: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            if tool == "wallet_lock" {
                lock()
                return ["text": "Locus Vault locked; intents, policies, and budgets were cleared."]
            }
            guard agentToolingAvailable else {
                throw signer.isAvailable ? Error.vaultLocked : Error.signerUnavailable
            }
            switch tool {
            case "wallet_list_accounts":
                accounts = try await signer.listAccounts()
                let text = accounts.isEmpty ? "No Locus Vault accounts are available." : accounts
                    .map { "\($0.label) · \($0.chain.rawValue) · \($0.address)" }
                    .joined(separator: "\n")
                return ["text": text, "accounts": try dictionary(accounts)]
            case "wallet_get_balance", "wallet_get_activity":
                return try await signer.performRead(tool: tool, arguments: arguments)
            case "wallet_simulate_transaction": return try await simulate(arguments)
            case "wallet_prepare_transaction": return response(for: try await prepare(arguments))
            case "wallet_execute_transaction": return try await execute(arguments)
            default: throw Error.invalidArguments("Unknown wallet tool \(tool).")
            }
        } catch {
            return ["error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription]
        }
    }

    private func prepare(_ arguments: [String: Any]) async throws -> WalletPreparedTransaction {
        let request = try parsePrepareRequest(arguments)
        let contract: WalletContractRegistryEntry?
        if request.action.type == .contractCall {
            guard let contractID = request.action.contractID,
                  let registered = contractRegistry.first(where: { $0.id == contractID }),
                  registered.networkID == request.networkID,
                  let function = request.action.function,
                  registered.permittedFunctions.contains(function) else {
                throw Error.invalidArguments(
                    "The contract and canonical function must be present in the verified registry."
                )
            }
            contract = registered
        } else {
            contract = nil
        }
        let transaction = try await signer.prepare(request, contract: contract)
        guard transaction.networkID == request.networkID,
              transaction.accountID == request.accountID,
              transaction.action == request.action,
              transaction.maximumFeeBaseUnits == request.maximumFeeBaseUnits,
              transaction.expiresAt.timeIntervalSince(transaction.createdAt) <= 120.5 else {
            throw Error.invalidArguments("WalletSigner returned a preparation for a different semantic request.")
        }
        if transaction.policyDecision != "allowed_by_session_policy" {
            pendingConfirmation = transaction
        } else if transaction.policyID == nil {
            throw Error.policyDenied("WalletSigner returned an autonomous decision without a policy ID.")
        }
        prepared[transaction.id] = transaction
        return transaction
    }

    private func parsePrepareRequest(_ arguments: [String: Any]) throws -> WalletPrepareRequest {
        guard let networkID = nonempty(arguments["network_id"]),
              networkID == Self.sepoliaNetworkID,
              let accountID = nonempty(arguments["account_id"]),
              let maximumFee = WalletBaseUnits.normalize(nonempty(arguments["maximum_fee_base_units"]) ?? ""),
              let actionObject = arguments["action"] as? [String: Any],
              let rawType = nonempty(actionObject["type"]),
              let kind = WalletActionKind(rawValue: rawType) else {
            throw Error.invalidArguments("network_id, account_id, semantic action, and an unsigned base-unit fee ceiling are required.")
        }
        let action: WalletSemanticAction
        switch kind {
        case .nativeTransfer:
            guard let recipient = nonempty(actionObject["recipient"]),
                  let amount = WalletBaseUnits.normalize(nonempty(actionObject["amount_base_units"]) ?? "") else {
                throw Error.invalidArguments("A native transfer requires recipient and amount_base_units.")
            }
            action = .nativeTransfer(recipient: recipient, amountBaseUnits: amount)
        case .contractCall:
            guard let contractID = nonempty(actionObject["contract_id"]),
                  let function = nonempty(actionObject["function"]),
                  !function.lowercased().hasPrefix("0x"), actionObject["calldata"] == nil else {
                throw Error.invalidArguments("A contract call requires a registry ID and canonical function signature; raw calldata is forbidden.")
            }
            let rawArguments = actionObject["arguments"] as? [[String: Any]] ?? []
            guard rawArguments.count <= 64 else {
                throw Error.invalidArguments("A contract call can contain at most 64 typed arguments.")
            }
            let typedArguments = try rawArguments.map { item -> WalletTypedArgument in
                guard let type = nonempty(item["type"]), let value = nonempty(item["value"]) else {
                    throw Error.invalidArguments("Every contract argument requires an ABI type and canonical string value.")
                }
                guard type.count <= 256, value.utf8.count <= 8_192 else {
                    throw Error.invalidArguments("A contract argument exceeds the native encoding limit.")
                }
                return WalletTypedArgument(type: type, value: value)
            }
            guard let value = WalletBaseUnits.normalize(nonempty(actionObject["value_base_units"]) ?? "0") else {
                throw Error.invalidArguments("value_base_units must be an unsigned integer string.")
            }
            action = .contractCall(contractID: contractID, function: function,
                                   arguments: typedArguments, valueBaseUnits: value)
        }
        return WalletPrepareRequest(networkID: networkID, accountID: accountID,
                                    action: action, maximumFeeBaseUnits: maximumFee)
    }

    private func simulate(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let intentID = nonempty(arguments["intent_id"]),
              let known = prepared[intentID], known.expiresAt > Date() else { throw Error.intentNotFound }
        let transaction = try await signer.simulate(intentID: intentID)
        guard transaction.id == known.id, transaction.digest == known.digest else {
            throw Error.policyDenied("The signer returned a different transaction during re-simulation.")
        }
        prepared[intentID] = transaction
        return response(for: transaction)
    }

    private func execute(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let intentID = nonempty(arguments["intent_id"]),
              let transaction = prepared[intentID], transaction.expiresAt > Date() else {
            throw Error.intentNotFound
        }
        if transaction.policyDecision != "allowed_by_session_policy" {
            guard confirmedIntentIDs.remove(intentID) != nil else {
                pendingConfirmation = transaction
                throw Error.approvalRequired(transaction.policyDecision)
            }
            try await signer.confirmExecution(intentID: intentID)
        }
        // The signer owns the bytes; execution accepts the opaque ID only.
        let result = try await signer.execute(intentID: intentID)
        activePolicyStatuses = (try? await signer.listPolicies()) ?? activePolicyStatuses
        activePolicies = activePolicyStatuses.map(\.policy)
        prepared[intentID] = nil
        pendingConfirmation = nil
        if let hash = result["transaction_hash"] as? String {
            transactionHistory.insert([
                "hash": hash,
                "summary": transaction.summary,
                "status": result["status"] as? String ?? "submitted",
                "date": ISO8601DateFormatter().string(from: Date()),
            ], at: 0)
        }
        return result
    }

    private func response(for transaction: WalletPreparedTransaction) -> [String: Any] {
        var result: [String: Any] = [
            "text": "Prepared \(transaction.id)\nDigest: \(transaction.digest)\n\(transaction.summary)\nSimulation: \(transaction.simulation)",
            "intent_id": transaction.id,
            "digest": transaction.digest,
            "network_id": transaction.networkID,
            "account_id": transaction.accountID,
            "decoded_effects": (try? dictionary(transaction.effects)) ?? [],
            "risk_flags": transaction.riskFlags.map(\.rawValue),
            "maximum_fee_base_units": transaction.maximumFeeBaseUnits,
            "fee_quote_base_units": transaction.feeQuoteBaseUnits,
            "simulation": transaction.simulation,
            "simulation_succeeded": transaction.simulationSucceeded,
            "policy_decision": transaction.policyDecision,
            "nonce": transaction.nonce,
            "expires_at": transaction.expiresAt.timeIntervalSince1970,
        ]
        if let contract = transaction.contract { result["contract"] = try? dictionary(contract) }
        return result
    }

    private func nonempty(_ value: Any?) -> String? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private func dictionary<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}

enum LocusWalletProviderScript {
    /// Page-world EIP-1193/EIP-6963 facade. It has no authority of its own:
    /// native code derives the origin from WKFrameInfo, grants accounts only
    /// for the current session, and routes sends through WalletGateway.
    static let evmBootstrap = #"""
    (() => {
      if (globalThis.locusVault) return;
      const pending = new Map();
      const listeners = new Map();
      let sequence = 0;

      const emit = (event, value) => {
        for (const callback of listeners.get(event) || []) {
          try { callback(value); } catch (_) {}
        }
      };

      const request = ({ method, params = [] } = {}) => {
        if (typeof method !== 'string' || !method) {
          return Promise.reject(Object.assign(new Error('A wallet method is required.'), { code: -32602 }));
        }
        if (pending.size >= 32) {
          return Promise.reject(Object.assign(new Error('Too many wallet requests are pending.'), { code: -32005 }));
        }
        const id = `${Date.now().toString(36)}-${(++sequence).toString(36)}`;
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject });
          try {
            globalThis.webkit.messageHandlers.locusWalletProvider.postMessage({ id, method, params });
          } catch (_) {
            pending.delete(id);
            reject(Object.assign(new Error('Locus Vault is unavailable.'), { code: 4900 }));
          }
        });
      };

      const provider = Object.freeze({
        request,
        on(event, callback) {
          if (typeof callback !== 'function') return provider;
          const values = listeners.get(event) || new Set();
          values.add(callback); listeners.set(event, values); return provider;
        },
        removeListener(event, callback) {
          listeners.get(event)?.delete(callback); return provider;
        },
        isLocusVault: true,
      });

      Object.defineProperty(globalThis, '__locusWalletReceive', {
        configurable: false, enumerable: false,
        value(id, payload) {
          const item = pending.get(id); if (!item) return;
          pending.delete(id);
          if (payload && payload.error) {
            item.reject(Object.assign(new Error(payload.error.message || 'Wallet request failed.'), {
              code: payload.error.code ?? -32603,
            }));
          } else { item.resolve(payload ? payload.result : null); }
        },
      });
      Object.defineProperty(globalThis, '__locusWalletEvent', {
        configurable: false, enumerable: false,
        value: emit,
      });
      globalThis.locusVault = provider;
      const detail = Object.freeze({
        info: Object.freeze({
          uuid: '535b3a6d-22e8-4f91-8a6f-bc9c6b2cafe1',
          name: 'Locus Vault',
          icon: 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"%3E%3Crect width="32" height="32" rx="8" fill="%236d5dfc"/%3E%3Cpath d="M9 8v16h14v-3H13V8z" fill="white"/%3E%3C/svg%3E',
          rdns: 'io.sparktales.locus'
        }),
        provider
      });
      addEventListener('eip6963:requestProvider', () => dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail })));
      dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail }));
      if (typeof globalThis.ethereum === 'undefined') {
        try { Object.defineProperty(globalThis, 'ethereum', { value: provider, configurable: true }); }
        catch (_) {}
      }
    })();
    """#
}
