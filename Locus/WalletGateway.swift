import AppKit
import CryptoKit
import Foundation

enum WalletHubState: Equatable, Sendable {
    case unavailableBuild
    case alphaDisabled
    case setupRequired
    case backupIncomplete
    case rotationRequired
    case locked
    case ready
    case error
}

struct WalletAccountSnapshot: Identifiable, Equatable, Sendable {
    enum Freshness: String, Equatable, Sendable {
        case notLoaded = "not_loaded"
        case current
        case stale
    }

    var id: String { "\(accountID):\(networkID):\(assetID)" }
    let accountID: String
    let chain: WalletChain
    let address: String
    let label: String
    let networkID: String
    let assetID: String
    let symbol: String
    var balanceBaseUnits: String?
    var refreshedAt: Date?
    var freshness: Freshness
}

struct WalletDiagnosticSnapshot: Codable, Equatable, Sendable {
    let appVersion: String
    let buildVersion: String
    let macOSVersion: String
    let signerProtocolVersion: Int
    let signerReachability: String
    let walletBuildAvailable: Bool
    let walletEnabled: Bool
    let browserProviderEnabled: Bool
    let vaultState: String
    let rpcHealthCategory: String
    let submittedActivityCount: Int
    let confirmedActivityCount: Int
    let failedActivityCount: Int
    let uncertainActivityCount: Int

    func text() -> String {
        [
            "Locus \(appVersion) (\(buildVersion))",
            "macOS: \(macOSVersion)",
            "Wallet signer: protocol \(signerProtocolVersion) · \(signerReachability)",
            "Feature access: build=\(walletBuildAvailable) wallet=\(walletEnabled) browser=\(browserProviderEnabled)",
            "Vault: \(vaultState)",
            "RPC health: \(rpcHealthCategory)",
            "Activity: submitted=\(submittedActivityCount) confirmed=\(confirmedActivityCount) failed=\(failedActivityCount) uncertain=\(uncertainActivityCount)",
        ].joined(separator: "\n")
    }
}

enum WalletReceiveURI {
    static func payload(address: String, networkID: String) -> String {
        guard let network = WalletNetworkCatalog.descriptor(id: networkID) else {
            return address
        }
        switch network.identity.kind {
        case .eip155ChainID:
            return "ethereum:\(address)@\(network.identity.value)"
        case .solanaGenesisHash:
            return "solana:\(address)"
        case .suiChainIdentifier:
            // Sui does not define a canonical payment URI. Encoding the raw
            // address avoids inventing a scheme that another wallet may parse
            // with different semantics.
            return address
        }
    }
}

enum WalletExternalConnectorKind: String, Codable, CaseIterable, Sendable {
    case metamask
    case phantom
    case slush
}

enum WalletExternalConnectorState: String, Codable, Sendable {
    case foundationReady = "foundation_ready"
    case enabledAfterAudit = "enabled_after_audit"
}

struct WalletExternalConnectorDescriptor: Identifiable, Equatable, Sendable {
    var id: String { kind.rawValue }
    let kind: WalletExternalConnectorKind
    let name: String
    let supportedTestNetworks: Set<String>
    let transport: String
    let documentationURL: URL
    let state: WalletExternalConnectorState
}

/// Non-secret connector metadata and rollout order. The connector foundations
/// deliberately expose no generic signing primitive and do not enable native
/// mainnet, Solana, or Sui signing.
enum WalletExternalConnectorCatalog {
    static let connectors: [WalletExternalConnectorDescriptor] = [
        WalletExternalConnectorDescriptor(
            kind: .metamask, name: "MetaMask",
            supportedTestNetworks: ["eip155:11155111"],
            transport: "MetaMask Connect · wallet-owned confirmation",
            documentationURL: URL(string: "https://docs.metamask.io/")!,
            state: .foundationReady
        ),
        WalletExternalConnectorDescriptor(
            kind: .phantom, name: "Phantom",
            supportedTestNetworks: ["solana:devnet"],
            transport: "Phantom Connect · encrypted session · signTransaction",
            documentationURL: URL(
                string: "https://docs.phantom.com/phantom-deeplinks/provider-methods/signtransaction"
            )!,
            state: .foundationReady
        ),
        WalletExternalConnectorDescriptor(
            kind: .slush, name: "Slush",
            supportedTestNetworks: ["sui:testnet"],
            transport: "Sui Wallet Standard · wallet-owned confirmation",
            documentationURL: URL(string: "https://docs.sui.io/standards/wallet-standard")!,
            state: .foundationReady
        ),
    ]

    static let nativeSigningNetworks: Set<String> = ["eip155:11155111"]

    static func canUseNativeSigner(on networkID: String) -> Bool {
        nativeSigningNetworks.contains(networkID)
    }
}

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
            allowedAssetIDs: ["\(networkID)/slip44:60"], allowedRecipients: [recipient],
            allowedContractIDs: [], allowedAdapterIDs: ["native-eth-transfer-v1"],
            maximumTransactionBaseUnits: maximumTransactionBaseUnits,
            maximumSessionBaseUnits: maximumSessionBaseUnits,
            maximumFeeBaseUnits: maximumFeeBaseUnits,
            expiresAt: Date().addingTimeInterval(TimeInterval(durationMinutes * 60)),
            allowedActionKinds: [.nativeTransfer]
        )
    }
}

struct WalletBrowserOriginGrant: Identifiable, Equatable, Sendable {
    let id: UUID
    let origin: String
    let networkID: String
}

private struct WalletBrowserOriginNetworkGrant: Hashable, Sendable {
    let origin: String
    let networkID: String
}

enum WalletActivityState: String, Codable, Equatable, Sendable {
    case submitted
    case confirmed
    case failed
    case broadcastUnknown = "broadcast_unknown"
}

enum WalletActivityDirection: String, Codable, Equatable, Sendable {
    case inbound
    case outbound
    case selfTransfer = "self_transfer"
}

enum WalletActivityFinality: String, Codable, Equatable, Sendable {
    case pending
    case confirmed
    case finalized
    case expired
    case replaced
    case uncertain
    case failed
}

struct WalletActivityRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let intentID: String
    let transactionHash: String
    let networkID: String
    let accountID: String
    let summary: String
    let submittedAt: Date
    var state: WalletActivityState
    var blockNumber: String?
    var lastCheckedAt: Date?
    var detail: String?
    var direction: WalletActivityDirection? = nil
    var source: WalletRequestSource? = nil
    var actionKind: WalletActionKind? = nil
    var assetID: String? = nil
    var amountBaseUnits: String? = nil
    var finality: WalletActivityFinality? = nil
    var expiresAt: Date? = nil
    var replacedByTransactionHash: String? = nil
}

enum WalletAmountFormatter {
    /// Parses a human ETH amount without locale, floating point, exponent
    /// notation, signs, or non-ASCII digits. The returned string is canonical
    /// wei and is suitable for policy and signing payloads.
    static func wei(fromEther value: String) -> String? {
        baseUnits(from: value, decimals: 18)
    }

    static func baseUnits(from value: String, decimals: Int) -> String? {
        guard (0...255).contains(decimals),
              !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else {
            return nil
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2 else { return nil }
        let whole = String(components[0])
        let fraction = components.count == 2 ? String(components[1]) : ""
        guard !whole.isEmpty || !fraction.isEmpty,
              whole.utf8.allSatisfy({ (48...57).contains($0) }),
              fraction.utf8.allSatisfy({ (48...57).contains($0) }),
              fraction.count <= decimals else { return nil }
        let paddedFraction = fraction + String(repeating: "0", count: decimals - fraction.count)
        return WalletBaseUnits.normalize((whole.isEmpty ? "0" : whole) + paddedFraction)
    }

    static func ether(wei: String) -> String? {
        asset(baseUnits: wei, decimals: 18, symbol: "ETH")
    }

    static func asset(baseUnits: String, decimals: Int, symbol: String) -> String? {
        guard (0...255).contains(decimals), let normalized = WalletBaseUnits.normalize(baseUnits)
        else { return nil }
        guard decimals > 0 else { return "\(normalized) \(symbol)" }
        let padded = String(repeating: "0", count: max(0, decimals + 1 - normalized.count))
            + normalized
        let split = padded.index(padded.endIndex, offsetBy: -decimals)
        let whole = String(padded[..<split])
        let fraction = String(padded[split...]).replacingOccurrences(
            of: "0+$", with: "", options: .regularExpression
        )
        return fraction.isEmpty ? "\(whole) \(symbol)" : "\(whole).\(fraction) \(symbol)"
    }
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
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
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
        guard transaction.source.kind == .agent else {
            return .requiresApproval("Browser transactions require an exact confirmation.")
        }
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
        if let allowedActionKinds = policy.allowedActionKinds,
           !allowedActionKinds.contains(transaction.action.type) {
            return .requiresApproval("The semantic action is outside the active policy.")
        }
        guard policy.allowedAdapterIDs.contains(adapterID),
              policy.allowedAssetIDs.contains(transaction.budgetAssetID) else {
            return .requiresApproval("The asset or effect adapter is outside the active policy.")
        }
        let counterparties: [String]
        switch adapterID {
        case "native-eth-transfer-v1":
            counterparties = transaction.action.recipient.map { [$0] } ?? []
        case WalletReviewedAdapters.erc20:
            counterparties = transaction.effects.compactMap { effect in
                if effect.kind == "token_transfer" { return effect.to }
                if effect.kind == "approval" || effect.kind == "approval_revoke" {
                    return effect.spender
                }
                return nil
            }
        case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn:
            counterparties = transaction.effects.filter {
                $0.kind == "minimum_receive"
            }.compactMap(\.to)
            guard transaction.action.arguments.count == 3,
                  let deadline = UInt64(transaction.action.arguments[2].value),
                  deadline >= UInt64(max(0, now.timeIntervalSince1970.rounded(.down))) else {
                return .requiresApproval("The swap quote is stale.")
            }
            if let minimum = policy.minimumOutputBaseUnits {
                let outputs = transaction.effects.filter { $0.kind == "minimum_receive" }
                guard outputs.count == 1,
                      WalletBaseUnits.lessThanOrEqual(minimum, outputs[0].amountBaseUnits) else {
                    return .requiresApproval("The swap minimum output is below the policy floor.")
                }
            }
        default:
            counterparties = []
        }
        guard !counterparties.isEmpty,
              counterparties.allSatisfy({ counterparty in
                  policy.allowedRecipients.contains(where: {
                      $0.caseInsensitiveCompare(counterparty) == .orderedSame
                  })
              }) else {
            return .requiresApproval("A transaction counterparty is outside the active policy.")
        }
        if let contractID = transaction.action.contractID,
           !policy.allowedContractIDs.contains(contractID) {
            return .requiresApproval("The contract is outside the active policy.")
        }
        guard WalletBaseUnits.lessThanOrEqual(
            transaction.spendBaseUnits, policy.maximumTransactionBaseUnits
        ), let total = WalletBaseUnits.add(spentThisSession, transaction.spendBaseUnits),
           WalletBaseUnits.lessThanOrEqual(total, policy.maximumSessionBaseUnits) else {
            return .requiresApproval("The transaction exceeds its base-unit spending rule.")
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
    func beginRecoveryCeremony(
        mode: WalletRecoveryCeremonyMode
    ) async throws -> WalletRecoveryCeremonyLaunch
    func cancelRecoveryCeremony(id: String) async throws -> WalletSignerStatus
    func deleteVault(confirmation: String) async throws -> WalletSignerStatus
    func deleteRecoveryVault(confirmation: String) async throws -> WalletSignerStatus
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
    func browserRPC(networkID: String, method: String, params: [Any]) async throws -> Any
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
    func beginRecoveryCeremony(
        mode: WalletRecoveryCeremonyMode
    ) async throws -> WalletRecoveryCeremonyLaunch {
        throw WalletGateway.Error.signerUnavailable
    }
    func cancelRecoveryCeremony(id: String) async throws -> WalletSignerStatus {
        throw WalletGateway.Error.signerUnavailable
    }
    func deleteVault(confirmation: String) async throws -> WalletSignerStatus {
        throw WalletGateway.Error.signerUnavailable
    }
    func deleteRecoveryVault(confirmation: String) async throws -> WalletSignerStatus {
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
    func browserRPC(networkID: String, method: String, params: [Any]) async throws -> Any {
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
        case broadcastUnknown(transactionHash: String, message: String)

        var errorDescription: String? {
            switch self {
            case .signerUnavailable: "The experimental Locus WalletSigner component is not installed in this build."
            case .vaultLocked: "Locus Vault is locked. Authorize a signing session in Wallet Settings first."
            case .invalidArguments(let message): message
            case .intentNotFound: "The prepared transaction is missing or expired. Prepare it again."
            case .policyDenied(let message): message
            case .approvalRequired(let message): message
            case .broadcastUnknown(let transactionHash, let message):
                "The signed transaction \(transactionHash) has an uncertain broadcast state: \(message)"
            }
        }
    }

    static let protocolVersion = 2
    static let ethereumMainnetNetworkID = "eip155:1"
    static let sepoliaNetworkID = "eip155:11155111"
    static let solanaMainnetNetworkID = "solana:mainnet-beta"
    static let suiMainnetNetworkID = "sui:mainnet"
    private static let maximumPreparedIntents = 32
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
    @Published private(set) var recoveryCeremonyActive = false
    @Published private(set) var rpcHealthText = "Not checked"
    @Published private(set) var lastError: String?
    @Published private(set) var transactionHistory: [WalletActivityRecord] = []
    @Published private(set) var activePolicyStatuses: [WalletActivePolicyStatus] = []
    @Published private(set) var contractRegistry: [WalletContractRegistryEntry] = []
    @Published private(set) var savedPolicyTemplates: [WalletPolicyTemplate] = []
    @Published private(set) var pendingBrowserOriginGrant: WalletBrowserOriginGrant?
    @Published private(set) var accountSnapshots: [WalletAccountSnapshot] = []
    @Published private(set) var approvedBrowserOrigins: [String] = []
    @Published private(set) var walletEnabled: Bool
    @Published private(set) var browserProviderEnabled: Bool
    @Published private(set) var idleLockMinutes: Int
    @Published private(set) var recoveryOnlyVaultAvailable = false
    @Published private(set) var contacts: [WalletContact] = []
    @Published private(set) var assets: [WalletAsset] = []
    @Published private(set) var connections: [WalletConnectionRecord] = []

    private let signer: WalletSignerClient
    private let recoveryView: WalletRecoveryViewClient
    private let userDefaults: UserDefaults
    private let publicStore: WalletPublicStore?
    private let launchGate: WalletLaunchGate
    private let regionCode: String
    let buildSupportsWalletAlpha: Bool
    private var prepared: [String: WalletPreparedTransaction] = [:]
    private var confirmedIntentIDs: Set<String> = []
    private let registryDefaultsKey = "LocusWalletContractRegistryV1"
    private let policyTemplatesDefaultsKey = "LocusWalletPolicyTemplatesV1"
    private let activityDefaultsKey = "LocusWalletActivityV1"
    private let idleLockDefaultsKey = "LocusWalletIdleLockMinutesV2"
    private var browserOriginGrants: Set<WalletBrowserOriginNetworkGrant> = []
    private var browserIntentOrigins: [String: String] = [:]
    private var browserGrantContinuation: CheckedContinuation<Bool, Never>?
    private var confirmationContinuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var uiFixtureHubState: WalletHubState?
    private var idleLockTimer: Timer?
    private var localActivityMonitor: Any?
    private var activeRecoveryCeremonyID: String?
    var onBrowserAuthorizationNeeded: (() -> Void)?
    var onBrowserGrantsRevoked: ((String?) -> Void)?

    init(signer: WalletSignerClient? = nil,
         recoveryView: WalletRecoveryViewClient? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         userDefaults: UserDefaults = .standard,
         publicStore: WalletPublicStore? = nil,
         launchGate: WalletLaunchGate? = nil,
         regionCode: String = Locale.current.region?.identifier ?? "ZZ",
         buildSupportsWalletAlpha: Bool = AppSettings.walletAlphaSupportedByCurrentBuild) {
        let signer = signer ?? WalletSignerClientFactory.make()
        self.signer = signer
        self.recoveryView = recoveryView ?? WalletRecoveryViewClientFactory.make()
        self.userDefaults = userDefaults
        self.publicStore = publicStore ?? Self.makeDefaultPublicStore(
            environment: environment,
            buildSupportsWallet: buildSupportsWalletAlpha
        )
        self.launchGate = launchGate
            ?? Self.loadBundledLaunchGate()
            ?? (try! WalletLaunchGate())
        self.regionCode = regionCode.uppercased()
        self.buildSupportsWalletAlpha = buildSupportsWalletAlpha
        let legacyWalletEnabled = buildSupportsWalletAlpha
            && environment["LOCUS_ENABLE_EXPERIMENTAL_WALLET"] == "1"
        walletEnabled = legacyWalletEnabled
        browserProviderEnabled = legacyWalletEnabled
            && environment["LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER"] == "1"
        idleLockMinutes = min(30, max(5, userDefaults.integer(forKey: idleLockDefaultsKey)))
        if userDefaults.object(forKey: idleLockDefaultsKey) == nil { idleLockMinutes = 5 }
        status = signer.isAvailable ? .locked : .securityReviewRequired
        if let data = userDefaults.data(forKey: registryDefaultsKey),
           let registry = try? JSONDecoder().decode([WalletContractRegistryEntry].self, from: data) {
            contractRegistry = registry.map(Self.sanitizedRegistryEntry)
            if contractRegistry != registry,
               let upgraded = try? JSONEncoder().encode(contractRegistry) {
                userDefaults.set(upgraded, forKey: registryDefaultsKey)
            }
        }
        if let data = userDefaults.data(forKey: policyTemplatesDefaultsKey),
           let templates = try? JSONDecoder().decode([WalletPolicyTemplate].self, from: data) {
            savedPolicyTemplates = templates
        }
        let legacyActivity = userDefaults.data(forKey: activityDefaultsKey).flatMap {
            try? JSONDecoder().decode([WalletActivityRecord].self, from: $0)
        } ?? []
        if let publicStore = self.publicStore {
            let stored = (try? publicStore.loadActivities(limit: 500)) ?? []
            if stored.isEmpty, !legacyActivity.isEmpty,
               (try? publicStore.migrateLegacyActivities(legacyActivity)) != nil {
                transactionHistory = Array(legacyActivity.prefix(500))
                userDefaults.removeObject(forKey: activityDefaultsKey)
            } else {
                transactionHistory = stored
            }
        } else {
            transactionHistory = Array(legacyActivity.prefix(250))
        }
        if let publicStore = self.publicStore {
            contacts = (try? publicStore.loadContacts()) ?? []
            assets = (try? publicStore.loadAssets()) ?? []
            connections = (try? publicStore.loadConnections()) ?? []
        }
        signer.invalidationHandler = { [weak self] in self?.handleSignerInvalidation() }
        self.recoveryView.invalidationHandler = { [weak self] in
            self?.handleRecoveryInvalidation()
        }
        if buildSupportsWalletAlpha, environment["XCTestConfigurationFilePath"] == nil {
            localActivityMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                           .scrollWheel, .mouseMoved]
            ) { [weak self] event in
                self?.noteUserActivity()
                return event
            }
        }
        #if DEBUG
        configureUIFixture(environment: environment)
        #endif
    }

    deinit {
        idleLockTimer?.invalidate()
        if let localActivityMonitor { NSEvent.removeMonitor(localActivityMonitor) }
    }

    private static func makeDefaultPublicStore(
        environment: [String: String],
        buildSupportsWallet: Bool
    ) -> WalletPublicStore? {
        guard buildSupportsWallet,
              environment["XCTestConfigurationFilePath"] == nil,
              environment["LOCUS_UI_TESTING"] != "1",
              let url = try? WalletPublicStore.defaultURL() else { return nil }
        return try? WalletPublicStore(url: url)
    }

    private static func loadBundledLaunchGate(bundle: Bundle = .main) -> WalletLaunchGate? {
        let signerURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("WalletSigner.xpc", isDirectory: true)
        guard let signerBundle = Bundle(url: signerURL),
              let publicKeyText = signerBundle.object(
                  forInfoDictionaryKey: "LocusWalletCapabilityPublicKey"
              ) as? String,
              let publicKeyData = Data(base64Encoded: publicKeyText),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              let manifestText = signerBundle.object(
                  forInfoDictionaryKey: "LocusWalletCapabilityManifestBase64"
              ) as? String,
              let manifestData = Data(base64Encoded: manifestText) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let signed = try? decoder.decode(
            WalletSignedCapabilityManifest.self, from: manifestData
        ) else { return nil }
        return try? WalletLaunchGate(signedManifest: signed, publicKey: publicKey)
    }

    private static func sanitizedRegistryEntry(
        _ entry: WalletContractRegistryEntry
    ) -> WalletContractRegistryEntry {
        let reviewedAdapterID = WalletReviewedAdapters.classify(
            normalizedABI: entry.normalizedABI,
            permittedFunctions: entry.permittedFunctions
        )
        guard entry.reviewedAdapterID != reviewedAdapterID else { return entry }
        return WalletContractRegistryEntry(
            id: entry.id, networkID: entry.networkID,
            checksumAddress: entry.checksumAddress, label: entry.label,
            normalizedABI: entry.normalizedABI, abiDigest: entry.abiDigest,
            runtimeCodeHash: entry.runtimeCodeHash,
            permittedFunctions: entry.permittedFunctions,
            permittedSelectors: entry.permittedSelectors,
            reviewedAdapterID: reviewedAdapterID, verifiedAt: entry.verifiedAt
        )
    }

    var agentToolingAvailable: Bool {
        walletEnabled && signer.isAvailable && status == .unlocked && signer.sessionID != nil
    }

    var capability: [String: Any]? {
        guard agentToolingAvailable, let sessionID = signer.sessionID else { return nil }
        var supportedChains = [Self.sepoliaNetworkID]
        if (try? launchGate.authorize(
            networkID: Self.ethereumMainnetNetworkID,
            capability: .nativeTransfer,
            regionCode: regionCode
        )) != nil {
            supportedChains.append(Self.ethereumMainnetNetworkID)
        }
        return [
            "protocol_version": Self.protocolVersion,
            "signer_state": status.rawValue,
            "session_id": sessionID,
            "supported_chains": supportedChains,
            "allowed_operations": Self.allowedOperations,
        ]
    }

    var canAuthorizeSession: Bool {
        walletEnabled && signer.isAvailable && vaultState == .locked
    }

    var canCreateVault: Bool {
        walletEnabled && signer.isAvailable && recoveryView.isAvailable
            && vaultState == .missing && !recoveryCeremonyActive
    }

    var canRotateForMainnet: Bool {
        walletEnabled && signer.isAvailable && recoveryView.isAvailable
            && vaultState == .rotationRequired && !recoveryCeremonyActive
    }

    var isExperimentalEnabled: Bool { walletEnabled }
    var signerAvailable: Bool { signer.isAvailable }

    var hubState: WalletHubState {
        if let uiFixtureHubState { return uiFixtureHubState }
        guard buildSupportsWalletAlpha else { return .unavailableBuild }
        guard walletEnabled else { return .alphaDisabled }
        guard signer.isAvailable else { return .error }
        return switch vaultState {
        case .missing: .setupRequired
        case .awaitingBackup: .backupIncomplete
        case .rotationRequired: .rotationRequired
        case .locked: .locked
        case .unlocked: status == .unlocked ? .ready : .locked
        }
    }

    func refreshStatus() async {
        guard uiFixtureHubState == nil else { return }
        guard buildSupportsWalletAlpha, walletEnabled else {
            status = signer.isAvailable ? .locked : .securityReviewRequired
            return
        }
        guard signer.isAvailable else {
            status = .securityReviewRequired
            vaultState = .missing
            return
        }
        do {
            let signerStatus = try await signer.signerStatus()
            vaultState = signerStatus.vaultState
            recoveryOnlyVaultAvailable = signerStatus.recoveryOnlyVaultAvailable
            accounts = signerStatus.accounts
            synchronizeAccountSnapshots(with: signerStatus.accounts)
            status = signerStatus.vaultState == .unlocked ? .unlocked : .locked
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func beginVaultCreation() async -> Bool {
        guard canCreateVault else { return false }
        return await runRecoveryCeremony(mode: .create)
    }

    @discardableResult
    func beginMainnetRotation() async -> Bool {
        guard canRotateForMainnet else { return false }
        return await runRecoveryCeremony(mode: .rotateForMainnet)
    }

    @discardableResult
    func beginVaultRestoration() async -> Bool {
        guard canCreateVault else { return false }
        return await runRecoveryCeremony(mode: .restore)
    }

    private func runRecoveryCeremony(mode: WalletRecoveryCeremonyMode) async -> Bool {
        guard !recoveryCeremonyActive, recoveryView.isAvailable else {
            lastError = "The isolated recovery window is unavailable in this build."
            return false
        }
        do {
            let launch = try await signer.beginRecoveryCeremony(mode: mode)
            activeRecoveryCeremonyID = launch.handle.id
            recoveryCeremonyActive = true
            if mode != .restore { vaultState = .awaitingBackup }
            let result = try await recoveryView.present(launch: launch)
            activeRecoveryCeremonyID = nil
            recoveryCeremonyActive = false
            switch result.outcome {
            case .completed:
                guard let signerStatus = result.signerStatus else {
                    throw Error.signerUnavailable
                }
                applyRecoveryStatus(signerStatus)
                lastError = nil
                return true
            case .canceled:
                await refreshStatus()
                return false
            case .failed:
                lastError = result.error ?? "The recovery ceremony failed."
                await refreshStatus()
                return false
            }
        } catch {
            if let ceremonyID = activeRecoveryCeremonyID {
                _ = try? await signer.cancelRecoveryCeremony(id: ceremonyID)
            }
            activeRecoveryCeremonyID = nil
            recoveryCeremonyActive = false
            lastError = error.localizedDescription
            return false
        }
    }

    private func applyRecoveryStatus(_ signerStatus: WalletSignerStatus) {
        vaultState = signerStatus.vaultState
        recoveryOnlyVaultAvailable = signerStatus.recoveryOnlyVaultAvailable
        accounts = signerStatus.accounts
        synchronizeAccountSnapshots(with: signerStatus.accounts)
        status = .locked
    }

    @discardableResult
    func deleteVault(confirmation: String) async -> Bool {
        do {
            let signerStatus = try await signer.deleteVault(confirmation: confirmation)
            lock()
            vaultState = signerStatus.vaultState
            recoveryOnlyVaultAvailable = signerStatus.recoveryOnlyVaultAvailable
            accounts = signerStatus.accounts
            synchronizeAccountSnapshots(with: signerStatus.accounts)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteRecoveryVault(confirmation: String) async -> Bool {
        do {
            let signerStatus = try await signer.deleteRecoveryVault(confirmation: confirmation)
            vaultState = signerStatus.vaultState
            recoveryOnlyVaultAvailable = signerStatus.recoveryOnlyVaultAvailable
            accounts = signerStatus.accounts
            synchronizeAccountSnapshots(with: signerStatus.accounts)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveContact(
        name: String,
        networkID: String,
        rawAddress: String,
        resolvedName: String? = nil,
        resolutionProof: String? = nil
    ) -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAddress = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let descriptor = WalletNetworkCatalog.descriptor(id: networkID),
              !cleanName.isEmpty, cleanName.count <= 128,
              Self.validAddress(cleanAddress, chain: descriptor.chain),
              resolvedName == nil || (resolutionProof?.isEmpty == false) else {
            lastError = "Enter a valid chain-scoped raw address. Resolved names require a verified forward-resolution proof."
            return false
        }
        let now = Date()
        let existing = contacts.first { contact in
            contact.networkID == networkID
                && contact.rawAddress.caseInsensitiveCompare(cleanAddress) == .orderedSame
        }
        let contact = WalletContact(
            id: existing?.id ?? UUID().uuidString.lowercased(),
            networkID: networkID,
            chain: descriptor.chain,
            name: cleanName,
            rawAddress: cleanAddress,
            resolvedName: resolvedName,
            resolutionProof: resolutionProof,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        do {
            try publicStore?.upsertContact(contact)
            contacts.removeAll { $0.id == contact.id }
            contacts.append(contact)
            contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func trustQuarantinedAsset(id: String) {
        guard let asset = assets.first(where: { $0.id == id }), asset.trust == .quarantined else {
            return
        }
        let trusted = WalletAsset(
            canonicalID: asset.canonicalID, networkID: asset.networkID,
            chain: asset.chain, kind: asset.kind, reference: asset.reference,
            name: asset.name, symbol: asset.symbol, decimals: asset.decimals,
            trust: .userTrusted, manifestRevision: asset.manifestRevision
        )
        do {
            try publicStore?.upsertAsset(trusted)
            assets.removeAll { $0.id == trusted.id }
            assets.append(trusted)
            synchronizeAccountSnapshots(with: accounts)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func validAddress(_ value: String, chain: WalletChain) -> Bool {
        switch chain {
        case .evm:
            value.count == 42 && value.hasPrefix("0x")
                && value.dropFirst(2).allSatisfy(\.isHexDigit)
        case .solana:
            (32...44).contains(value.count)
                && value.allSatisfy { "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0) }
        case .sui:
            value.count == 66 && value.hasPrefix("0x")
                && value.dropFirst(2).allSatisfy(\.isHexDigit)
        }
    }

    func checkRPCHealth() async {
        guard uiFixtureHubState == nil else { return }
        do { rpcHealthText = try await signer.rpcHealth() }
        catch { rpcHealthText = error.localizedDescription }
    }

    func refreshTransactionHistory() async {
        guard uiFixtureHubState == nil else { return }
        guard signer.isAvailable else { return }
        var changed = false
        let recordIDs = transactionHistory.filter {
            $0.state == .submitted || $0.state == .broadcastUnknown
        }.map(\.id)
        for recordID in recordIDs {
            guard let original = transactionHistory.first(where: { $0.id == recordID }) else {
                continue
            }
            do {
                let result = try await signer.browserRPC(
                    networkID: original.networkID,
                    method: "eth_getTransactionReceipt",
                    params: [original.transactionHash]
                )
                guard let index = transactionHistory.firstIndex(where: { $0.id == recordID }) else {
                    continue
                }
                transactionHistory[index].lastCheckedAt = Date()
                if result is NSNull {
                    changed = true
                    continue
                }
                guard let receipt = result as? [String: Any],
                      let status = receipt["status"] as? String else { continue }
                transactionHistory[index].state = status.lowercased() == "0x1" ? .confirmed : .failed
                transactionHistory[index].finality = status.lowercased() == "0x1" ? .confirmed : .failed
                transactionHistory[index].blockNumber = receipt["blockNumber"] as? String
                transactionHistory[index].detail = nil
                changed = true
            } catch {
                guard let index = transactionHistory.firstIndex(where: { $0.id == recordID }) else {
                    continue
                }
                transactionHistory[index].lastCheckedAt = Date()
                transactionHistory[index].detail = String(error.localizedDescription.prefix(512))
                changed = true
            }
        }
        if changed { persistActivity() }
    }

    var statusText: String {
        if !buildSupportsWalletAlpha { return "Direct download required" }
        if signer.isAvailable && !walletEnabled { return "Wallet is off" }
        if vaultState == .missing { return "Not created" }
        if vaultState == .awaitingBackup { return "Backup not confirmed" }
        if vaultState == .rotationRequired { return "Rotate for Mainnet" }
        return switch status {
        case .securityReviewRequired: "Signer unavailable"
        case .locked: "Locked"
        case .unlocked: "Unlocked for this Locus session"
        }
    }

    func configureRPCURL(_ value: String) {
        signer.configureRPCURL(value)
    }

    func applyFeatureAccess(walletEnabled: Bool, browserEnabled: Bool) {
        let effective = AppSettings.effectiveWalletFeatureAccess(
            walletEnabled: walletEnabled,
            browserEnabled: browserEnabled,
            isDirectDownload: buildSupportsWalletAlpha
        )
        let walletWasEnabled = self.walletEnabled
        let browserWasEnabled = browserProviderEnabled
        self.walletEnabled = effective.walletEnabled
        browserProviderEnabled = effective.browserEnabled

        if walletWasEnabled && !effective.walletEnabled {
            lock()
        } else if browserWasEnabled && !effective.browserEnabled {
            revokeAllBrowserGrants()
        }

        guard effective.walletEnabled else { return }
        Task { @MainActor [weak self] in
            await self?.refreshStatus()
            await self?.refreshAccountSnapshots()
        }
    }

    func refreshAccountSnapshots() async {
        guard uiFixtureHubState == nil else { return }
        guard buildSupportsWalletAlpha, walletEnabled, signer.isAvailable else { return }
        do {
            let publicAccounts = try await signer.listAccounts()
            accounts = publicAccounts
            synchronizeAccountSnapshots(with: publicAccounts)
            for snapshot in accountSnapshots where snapshot.chain == .evm {
                do {
                    let result = try await signer.performRead(
                        tool: "wallet_get_balance",
                        arguments: [
                            "account_id": snapshot.accountID,
                            "network_id": snapshot.networkID,
                            "asset_id": snapshot.assetID,
                        ]
                    )
                    guard let balance = result["balance_base_units"] as? String,
                          WalletBaseUnits.normalize(balance) != nil,
                          let index = accountSnapshots.firstIndex(where: {
                              $0.id == snapshot.id
                          }) else { continue }
                    accountSnapshots[index].balanceBaseUnits = WalletBaseUnits.normalize(balance)
                    accountSnapshots[index].refreshedAt = Date()
                    accountSnapshots[index].freshness = .current
                } catch {
                    guard let index = accountSnapshots.firstIndex(where: {
                        $0.id == snapshot.id
                    }) else { continue }
                    accountSnapshots[index].freshness = accountSnapshots[index].balanceBaseUnits == nil
                        ? .notLoaded : .stale
                }
            }
        } catch {
            accountSnapshots = accountSnapshots.map { snapshot in
                var stale = snapshot
                if stale.balanceBaseUnits != nil { stale.freshness = .stale }
                return stale
            }
        }
    }

    func diagnosticSnapshot(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> WalletDiagnosticSnapshot {
        let category: String
        let normalizedHealth = rpcHealthText.lowercased()
        if normalizedHealth.contains("healthy") {
            category = "healthy"
        } else if normalizedHealth == "not checked" {
            category = "not_checked"
        } else {
            category = "unavailable"
        }
        return WalletDiagnosticSnapshot(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            macOSVersion: processInfo.operatingSystemVersionString,
            signerProtocolVersion: Self.protocolVersion,
            signerReachability: signer.isAvailable ? "reachable" : "unavailable",
            walletBuildAvailable: buildSupportsWalletAlpha,
            walletEnabled: walletEnabled,
            browserProviderEnabled: browserProviderEnabled,
            vaultState: vaultState.rawValue,
            rpcHealthCategory: category,
            submittedActivityCount: transactionHistory.count { $0.state == .submitted },
            confirmedActivityCount: transactionHistory.count { $0.state == .confirmed },
            failedActivityCount: transactionHistory.count { $0.state == .failed },
            uncertainActivityCount: transactionHistory.count { $0.state == .broadcastUnknown }
        )
    }

    private func synchronizeAccountSnapshots(with publicAccounts: [WalletAccount]) {
        let previous = Dictionary(uniqueKeysWithValues: accountSnapshots.map { ($0.id, $0) })
        accountSnapshots = publicAccounts.flatMap { account -> [WalletAccountSnapshot] in
            let networkID: String
            let assetID: String
            let symbol: String
            switch account.chain {
            case .evm:
                networkID = account.networkIDs.first(where: {
                    WalletNetworkCatalog.descriptor(id: $0)?.environment == .mainnet
                }) ?? account.networkIDs.first ?? Self.sepoliaNetworkID
                let descriptor = WalletNetworkCatalog.descriptor(id: networkID)
                assetID = descriptor?.nativeAssetID ?? "\(networkID)/slip44:60"
                symbol = descriptor?.nativeSymbol ?? "ETH"
            case .solana:
                networkID = account.networkIDs.first(where: {
                    WalletNetworkCatalog.descriptor(id: $0)?.environment == .mainnet
                }) ?? account.networkIDs.first ?? "solana:devnet"
                let descriptor = WalletNetworkCatalog.descriptor(id: networkID)
                assetID = descriptor?.nativeAssetID ?? "\(networkID)/slip44:501"
                symbol = descriptor?.nativeSymbol ?? "SOL"
            case .sui:
                networkID = account.networkIDs.first(where: {
                    WalletNetworkCatalog.descriptor(id: $0)?.environment == .mainnet
                }) ?? account.networkIDs.first ?? "sui:testnet"
                let descriptor = WalletNetworkCatalog.descriptor(id: networkID)
                assetID = descriptor?.nativeAssetID ?? "\(networkID)/coin:0x2::sui::SUI"
                symbol = descriptor?.nativeSymbol ?? "SUI"
            }
            let id = "\(account.id):\(networkID):\(assetID)"
            let cached = previous[id]
            let native = WalletAccountSnapshot(
                accountID: account.id,
                chain: account.chain,
                address: account.address,
                label: account.label,
                networkID: networkID,
                assetID: assetID,
                symbol: symbol,
                balanceBaseUnits: cached?.balanceBaseUnits,
                refreshedAt: cached?.refreshedAt,
                freshness: cached?.freshness ?? .notLoaded
            )
            let additional = assets.filter {
                $0.networkID == networkID && $0.chain == account.chain
                    && $0.isVisibleByDefault && $0.id != assetID
            }.sorted {
                $0.symbol.localizedCaseInsensitiveCompare($1.symbol) == .orderedAscending
            }.map { asset -> WalletAccountSnapshot in
                let cached = previous["\(account.id):\(networkID):\(asset.id)"]
                return WalletAccountSnapshot(
                    accountID: account.id, chain: account.chain,
                    address: account.address, label: account.label,
                    networkID: networkID, assetID: asset.id,
                    symbol: asset.symbol,
                    balanceBaseUnits: cached?.balanceBaseUnits,
                    refreshedAt: cached?.refreshedAt,
                    freshness: cached?.freshness ?? .notLoaded
                )
            }
            return [native] + additional
        }
    }

    #if DEBUG
    /// Deterministic, secret-free states for UI coverage. Production builds do
    /// not compile this path, and it is accepted only in the UI-test process.
    private func configureUIFixture(environment: [String: String]) {
        guard environment["LOCUS_UI_TESTING"] == "1",
              let fixture = environment["LOCUS_UI_TESTING_WALLET_FIXTURE"] else { return }

        let evmAddress = "0x8Ba1f109551bD432803012645Ac136ddd64DBA72"
        let evm = WalletAccount(
            id: "wallet-fixture-evm", chain: .evm, address: evmAddress,
            label: "Sepolia account", networkIDs: [Self.sepoliaNetworkID]
        )
        let solana = WalletAccount(
            id: "wallet-fixture-solana", chain: .solana,
            address: "9xQeWvG816bUx9EPfEzphDFTeGmQqoZ8VjPzM8YjWm7k",
            label: "Solana address", networkIDs: ["solana:devnet"]
        )
        let sui = WalletAccount(
            id: "wallet-fixture-sui", chain: .sui,
            address: "0x1111111111111111111111111111111111111111111111111111111111111111",
            label: "Sui address", networkIDs: ["sui:testnet"]
        )

        switch fixture {
        case "disabled":
            uiFixtureHubState = .alphaDisabled
            return
        case "setup":
            uiFixtureHubState = .setupRequired
            vaultState = .missing
            status = .locked
            return
        case "backup":
            uiFixtureHubState = .backupIncomplete
            vaultState = .awaitingBackup
            status = .locked
            return
        case "error":
            uiFixtureHubState = .error
            lastError = "The UI fixture is showing the recoverable wallet error state."
            return
        case "locked":
            uiFixtureHubState = .locked
            vaultState = .locked
            status = .locked
        case "ready", "activity", "origin", "transaction":
            uiFixtureHubState = .ready
            vaultState = .unlocked
            status = .unlocked
        default:
            return
        }

        accounts = [evm, solana, sui]
        synchronizeAccountSnapshots(with: accounts)
        if let index = accountSnapshots.firstIndex(where: { $0.chain == .evm }) {
            accountSnapshots[index].balanceBaseUnits = "12500000000000000"
            accountSnapshots[index].refreshedAt = Date().addingTimeInterval(-45)
            accountSnapshots[index].freshness = .current
        }
        rpcHealthText = "Sepolia · healthy"

        if fixture == "ready" || fixture == "activity" {
            let policy = WalletSessionPolicy(
                id: "wallet-fixture-policy", accountID: evm.id,
                networkID: Self.sepoliaNetworkID,
                allowedAssetIDs: ["slip44:60"],
                allowedRecipients: ["0x1111111111111111111111111111111111111111"],
                allowedContractIDs: [], allowedAdapterIDs: ["native-eth-transfer-v1"],
                maximumTransactionBaseUnits: "5000000000000000",
                maximumSessionBaseUnits: "10000000000000000",
                maximumFeeBaseUnits: "1000000000000000",
                expiresAt: Date().addingTimeInterval(1_800)
            )
            activePolicies = [policy]
            activePolicyStatuses = [WalletActivePolicyStatus(
                policy: policy, spentBaseUnits: "2500000000000000"
            )]
        }

        if fixture == "activity" {
            transactionHistory = [
                WalletActivityRecord(
                    id: "wallet-fixture-activity-confirmed", intentID: "fixture-intent-1",
                    transactionHash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    networkID: Self.sepoliaNetworkID, accountID: evm.id,
                    summary: "Sent 0.002 Sepolia ETH", submittedAt: Date().addingTimeInterval(-420),
                    state: .confirmed, blockNumber: "0x53a10", lastCheckedAt: Date(), detail: nil
                ),
                WalletActivityRecord(
                    id: "wallet-fixture-activity-pending", intentID: "fixture-intent-2",
                    transactionHash: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    networkID: Self.sepoliaNetworkID, accountID: evm.id,
                    summary: "Sent 0.001 Sepolia ETH", submittedAt: Date().addingTimeInterval(-75),
                    state: .submitted, blockNumber: nil, lastCheckedAt: Date(), detail: nil
                ),
            ]
        } else if fixture == "origin" {
            pendingBrowserOriginGrant = WalletBrowserOriginGrant(
                id: UUID(), origin: "https://pay.example.com",
                networkID: Self.sepoliaNetworkID
            )
        } else if fixture == "transaction" {
            pendingConfirmation = WalletPreparedTransaction(
                id: "wallet-fixture-confirmation", digest: "0xfixture-digest",
                networkID: Self.sepoliaNetworkID, accountID: evm.id,
                source: .browser(origin: "https://pay.example.com"),
                action: .nativeTransfer(
                    recipient: "0x1111111111111111111111111111111111111111",
                    amountBaseUnits: "10000000000000000"
                ),
                summary: "Send 0.01 Sepolia ETH",
                effects: [WalletDecodedEffect(
                    id: "wallet-fixture-effect", kind: "native_transfer",
                    assetID: "slip44:60", amountBaseUnits: "10000000000000000",
                    from: evmAddress, to: "0x1111111111111111111111111111111111111111",
                    spender: nil
                )],
                riskFlags: [], contract: nil, adapterID: "native-eth-transfer-v1",
                budgetAssetID: "slip44:60", spendBaseUnits: "10000000000000000",
                maximumFeeBaseUnits: "1000000000000000",
                feeQuoteBaseUnits: "42000000000000", simulation: "Transfer succeeds",
                simulationSucceeded: true, nonce: "7", createdAt: Date(),
                expiresAt: Date().addingTimeInterval(120),
                policyDecision: "Browser transactions require exact confirmation.", policyID: nil
            )
        }
    }
    #endif

    func lock() {
        cancelActiveRecoveryCeremony()
        idleLockTimer?.invalidate()
        idleLockTimer = nil
        signer.lock()
        activePolicies.removeAll()
        activePolicyStatuses.removeAll()
        prepared.removeAll()
        confirmedIntentIDs.removeAll()
        pendingConfirmation = nil
        revokeAllBrowserGrants()
        resolveAllConfirmationWaiters(approved: false)
        status = signer.isAvailable ? .locked : .securityReviewRequired
        if vaultState == .unlocked { vaultState = .locked }
    }

    private func handleSignerInvalidation() {
        recoveryView.cancel()
        activeRecoveryCeremonyID = nil
        recoveryCeremonyActive = false
        idleLockTimer?.invalidate()
        idleLockTimer = nil
        activePolicies.removeAll()
        activePolicyStatuses.removeAll()
        prepared.removeAll()
        confirmedIntentIDs.removeAll()
        pendingConfirmation = nil
        revokeAllBrowserGrants()
        resolveAllConfirmationWaiters(approved: false)
        status = signer.isAvailable ? .locked : .securityReviewRequired
        if vaultState == .unlocked { vaultState = .locked }
    }

    private func handleRecoveryInvalidation() {
        guard let ceremonyID = activeRecoveryCeremonyID else { return }
        activeRecoveryCeremonyID = nil
        recoveryCeremonyActive = false
        signer.lock()
        Task { _ = try? await signer.cancelRecoveryCeremony(id: ceremonyID) }
        status = signer.isAvailable ? .locked : .securityReviewRequired
        lastError = "The isolated recovery window was interrupted. The vault is locked."
    }

    private func cancelActiveRecoveryCeremony() {
        guard let ceremonyID = activeRecoveryCeremonyID else { return }
        activeRecoveryCeremonyID = nil
        recoveryCeremonyActive = false
        recoveryView.cancel()
        Task { _ = try? await signer.cancelRecoveryCeremony(id: ceremonyID) }
    }

    @discardableResult
    func authorizeSession() async -> Bool {
        guard walletEnabled, signer.isAvailable else { return false }
        do {
            try await signer.authorizeSession()
            accounts = try await signer.listAccounts()
            synchronizeAccountSnapshots(with: accounts)
            guard signer.sessionID != nil else { throw Error.vaultLocked }
            status = .unlocked
            noteUserActivity()
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

    func configureIdleLock(minutes: Int) {
        idleLockMinutes = min(30, max(5, minutes))
        userDefaults.set(idleLockMinutes, forKey: idleLockDefaultsKey)
        noteUserActivity()
    }

    func noteUserActivity() {
        guard status == .unlocked, signer.sessionID != nil else { return }
        idleLockTimer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(idleLockMinutes * 60), repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
        timer.tolerance = min(15, TimeInterval(idleLockMinutes * 6))
        RunLoop.main.add(timer, forMode: .common)
        idleLockTimer = timer
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
            userDefaults.set(data, forKey: policyTemplatesDefaultsKey)
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
                userDefaults.set(data, forKey: registryDefaultsKey)
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
            userDefaults.set(data, forKey: registryDefaultsKey)
        }
        await clearPolicies()
    }

    func isTransactionConfirmable(_ transaction: WalletPreparedTransaction) -> Bool {
        transaction.expiresAt > Date()
            && transaction.simulationSucceeded
            && !transaction.riskFlags.contains(.codeHashMismatch)
            && !transaction.policyDecision.lowercased().contains("denied")
    }

    @discardableResult
    func prepareHumanNativeTransfer(
        networkID: String,
        accountID: String,
        recipient: String,
        amountBaseUnits: String,
        maximumFeeBaseUnits: String
    ) async -> Bool {
        guard status == .unlocked else {
            lastError = Error.vaultLocked.localizedDescription
            return false
        }
        do {
            _ = try await prepare([
                "network_id": networkID,
                "account_id": accountID,
                "maximum_fee_base_units": maximumFeeBaseUnits,
                "action": [
                    "type": WalletActionKind.nativeTransfer.rawValue,
                    "recipient": recipient,
                    "amount_base_units": amountBaseUnits,
                ],
            ], source: .human)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func prepareHumanFungibleTransfer(
        networkID: String,
        accountID: String,
        assetID: String,
        recipient: String,
        amountBaseUnits: String,
        maximumFeeBaseUnits: String
    ) async -> Bool {
        guard status == .unlocked else {
            lastError = Error.vaultLocked.localizedDescription
            return false
        }
        do {
            _ = try await prepare([
                "network_id": networkID,
                "account_id": accountID,
                "maximum_fee_base_units": maximumFeeBaseUnits,
                "action": [
                    "type": WalletActionKind.fungibleTokenTransfer.rawValue,
                    "asset_id": assetID,
                    "recipient": recipient,
                    "amount_base_units": amountBaseUnits,
                ],
            ], source: .human)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func prepareHumanNFTTransfer(
        networkID: String,
        accountID: String,
        assetID: String,
        tokenID: String,
        recipient: String,
        maximumFeeBaseUnits: String
    ) async -> Bool {
        guard status == .unlocked else {
            lastError = Error.vaultLocked.localizedDescription
            return false
        }
        do {
            _ = try await prepare([
                "network_id": networkID,
                "account_id": accountID,
                "maximum_fee_base_units": maximumFeeBaseUnits,
                "action": [
                    "type": WalletActionKind.nftTransfer.rawValue,
                    "asset_id": assetID,
                    "token_id": tokenID,
                    "recipient": recipient,
                ],
            ], source: .human)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func confirmAndExecuteHumanIntent(intentID: String) async -> Bool {
        guard prepared[intentID]?.source.kind == .humanUI else { return false }
        confirm(intentID: intentID)
        do {
            _ = try await execute(["intent_id": intentID], source: .human)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func confirm(intentID: String) {
        guard let transaction = prepared[intentID],
              isTransactionConfirmable(transaction) else { return }
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

    func requestBrowserAccounts(
        origin: String, networkID: String = "eip155:11155111"
    ) async -> [String]? {
        guard browserProviderEnabled, agentToolingAvailable,
              let normalized = Self.normalizedWebOrigin(origin),
              canUseBrowserNetwork(networkID) else { return nil }
        let grant = WalletBrowserOriginNetworkGrant(origin: normalized, networkID: networkID)
        if browserOriginGrants.contains(grant) { return evmAddresses }
        guard pendingBrowserOriginGrant == nil, browserGrantContinuation == nil else { return nil }
        pendingBrowserOriginGrant = WalletBrowserOriginGrant(
            id: UUID(), origin: normalized, networkID: networkID
        )
        onBrowserAuthorizationNeeded?()
        let approved = await withCheckedContinuation { continuation in
            browserGrantContinuation = continuation
        }
        return approved ? evmAddresses : nil
    }

    func browserAccounts(
        origin: String, networkID: String = "eip155:11155111"
    ) -> [String] {
        guard let normalized = Self.normalizedWebOrigin(origin),
              browserOriginGrants.contains(.init(origin: normalized, networkID: networkID)),
              agentToolingAvailable else { return [] }
        return evmAddresses
    }

    func approveBrowserOrigin() {
        guard let request = pendingBrowserOriginGrant else { return }
        browserOriginGrants.insert(.init(origin: request.origin, networkID: request.networkID))
        approvedBrowserOrigins = Set(browserOriginGrants.map(\.origin)).sorted()
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
        browserOriginGrants = Set(browserOriginGrants.filter { $0.origin != normalized })
        approvedBrowserOrigins = Set(browserOriginGrants.map(\.origin)).sorted()
        if pendingBrowserOriginGrant?.origin == normalized { denyBrowserOrigin() }
        for intentID in browserIntentOrigins.compactMap({ $0.value == normalized ? $0.key : nil }) {
            cancelConfirmation(intentID: intentID)
            browserIntentOrigins[intentID] = nil
        }
        onBrowserGrantsRevoked?(normalized)
    }

    func browserReadRPC(
        origin: String, networkID: String = "eip155:11155111",
        method: String, params: [Any]
    ) async throws -> Any {
        guard !browserAccounts(origin: origin, networkID: networkID).isEmpty else {
            throw Error.approvalRequired("This website is not connected to Locus Vault.")
        }
        guard canUseBrowserNetwork(networkID) else {
            throw Error.policyDenied("That browser network has not passed its signed release gate.")
        }
        return try await signer.browserRPC(networkID: networkID, method: method, params: params)
    }

    func browserSendTransaction(
        origin: String, networkID: String = "eip155:11155111",
        transaction: [String: Any]
    ) async throws -> String {
        let rawValue = nonempty(transaction["value"]) ?? "0x0"
        let rawData = nonempty(transaction["data"]) ?? "0x"
        guard let normalizedOrigin = Self.normalizedWebOrigin(origin),
              let account = browserAccounts(origin: normalizedOrigin, networkID: networkID).first,
              let from = nonempty(transaction["from"]),
              from.caseInsensitiveCompare(account) == .orderedSame,
              let recipient = nonempty(transaction["to"]),
              let value = WalletEthereumQuantity.hexToDecimal(rawValue),
              rawData.lowercased() == "0x",
              canUseBrowserNetwork(networkID) else {
            throw Error.invalidArguments(
                "The browser provider accepts reviewed native transfers only; opaque calldata and signing methods are disabled."
            )
        }
        let browserSource = WalletRequestSource.browser(origin: normalizedOrigin)
        let preparedResult = await perform(tool: "wallet_prepare_transaction", arguments: [
            "network_id": networkID,
            "account_id": accounts.first(where: { $0.chain == .evm })?.id ?? "",
            "action": [
                "type": "native_transfer", "recipient": recipient,
                "amount_base_units": value,
            ],
            // Testnet-only ceiling. The exact native sheet still displays and
            // approves the authoritative simulated fee before execution.
            "maximum_fee_base_units": "10000000000000000",
        ], source: browserSource)
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
        guard !browserAccounts(origin: normalizedOrigin, networkID: networkID).isEmpty else {
            cancelConfirmation(intentID: intentID)
            throw Error.approvalRequired("The website grant was revoked before signing.")
        }
        let result = await perform(
            tool: "wallet_execute_transaction",
            arguments: ["intent_id": intentID],
            source: browserSource
        )
        if let message = result["error"] as? String { throw Error.policyDenied(message) }
        guard let hash = result["transaction_hash"] as? String else {
            throw Error.invalidArguments("The network provider did not return a transaction hash.")
        }
        return hash
    }

    func canUseBrowserNetwork(_ networkID: String) -> Bool {
        if networkID == Self.sepoliaNetworkID { return true }
        guard networkID == Self.ethereumMainnetNetworkID else { return false }
        return (try? launchGate.authorize(
            networkID: networkID,
            capability: .embeddedBrowser,
            regionCode: regionCode
        )) != nil
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
        approvedBrowserOrigins = []
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

    func perform(
        tool: String,
        arguments: [String: Any],
        source: WalletRequestSource = .agent
    ) async -> [String: Any] {
        do {
            if tool == "wallet_lock" {
                lock()
                return ["text": "Locus Vault locked; intents, policies, and spending rules were cleared."]
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
            case "wallet_simulate_transaction": return try await simulate(arguments, source: source)
            case "wallet_prepare_transaction": return response(for: try await prepare(arguments, source: source))
            case "wallet_execute_transaction": return try await execute(arguments, source: source)
            default: throw Error.invalidArguments("Unknown wallet tool \(tool).")
            }
        } catch {
            return ["error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription]
        }
    }

    private func prepare(
        _ arguments: [String: Any],
        source: WalletRequestSource
    ) async throws -> WalletPreparedTransaction {
        let now = Date()
        prepared = prepared.filter { $0.value.expiresAt > now }
        confirmedIntentIDs = confirmedIntentIDs.intersection(Set(prepared.keys))
        if let pendingConfirmation, pendingConfirmation.expiresAt <= now {
            self.pendingConfirmation = nil
        }
        guard prepared.count < Self.maximumPreparedIntents else {
            throw Error.policyDenied("Too many wallet intents are pending for this session.")
        }
        let request = try parsePrepareRequest(arguments, source: source)
        let contract: WalletContractRegistryEntry?
        switch request.action.type {
        case .contractCall:
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
        case .fungibleTokenTransfer, .nftTransfer:
            contract = try reviewedAssetContract(
                for: request.action, networkID: request.networkID
            )
        default:
            contract = nil
        }
        let transaction = try await signer.prepare(request, contract: contract)
        guard transaction.networkID == request.networkID,
              transaction.accountID == request.accountID,
              transaction.source == request.source,
              transaction.action == request.action,
              transaction.maximumFeeBaseUnits == request.maximumFeeBaseUnits,
              transaction.expiresAt.timeIntervalSince(transaction.createdAt) <= 120.5 else {
            throw Error.invalidArguments("WalletSigner returned a preparation for a different semantic request.")
        }
        if request.source.kind != .agent,
           transaction.policyDecision == "allowed_by_session_policy" {
            throw Error.policyDenied("Human and connected-wallet requests require exact confirmation.")
        }
        if transaction.policyDecision != "allowed_by_session_policy" {
            pendingConfirmation = transaction
        } else if transaction.policyID == nil {
            throw Error.policyDenied("WalletSigner returned an autonomous decision without a policy ID.")
        }
        prepared[transaction.id] = transaction
        return transaction
    }

    private func reviewedAssetContract(
        for action: WalletSemanticAction,
        networkID: String
    ) throws -> WalletContractRegistryEntry {
        guard let assetID = action.assetID,
              let asset = assets.first(where: { $0.id == assetID }),
              asset.networkID == networkID, asset.chain == .evm,
              asset.isVisibleByDefault,
              let identity = WalletEVMAssetIdentity.parse(assetID),
              identity.networkID == networkID,
              asset.reference?.caseInsensitiveCompare(identity.contractAddress) == .orderedSame,
              let entry = contractRegistry.first(where: {
                  $0.networkID == networkID
                      && $0.checksumAddress.caseInsensitiveCompare(
                          identity.contractAddress
                      ) == .orderedSame
              }),
              let adapterID = WalletReviewedAdapters.validatedID(for: entry) else {
            throw Error.invalidArguments(
                "The selected asset is not trusted with a verified standard contract adapter."
            )
        }
        let expectedAdapter: String
        switch (action.type, identity.standard) {
        case (.fungibleTokenTransfer, .erc20):
            expectedAdapter = WalletReviewedAdapters.erc20
        case (.nftTransfer, .erc721):
            expectedAdapter = WalletReviewedAdapters.erc721SafeTransfer
        case (.nftTransfer, .erc1155):
            expectedAdapter = WalletReviewedAdapters.erc1155SafeTransfer
        default:
            throw Error.invalidArguments("The asset standard does not match the requested action.")
        }
        guard adapterID == expectedAdapter else {
            throw Error.invalidArguments("The verified contract adapter does not match the asset standard.")
        }
        return entry
    }

    private func parsePrepareRequest(
        _ arguments: [String: Any],
        source: WalletRequestSource
    ) throws -> WalletPrepareRequest {
        guard let networkID = nonempty(arguments["network_id"]),
              let descriptor = WalletNetworkCatalog.descriptor(id: networkID),
              descriptor.chain == .evm,
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
        case .fungibleTokenTransfer:
            guard let assetID = nonempty(actionObject["asset_id"]),
                  let recipient = nonempty(actionObject["recipient"]),
                  Self.validAddress(recipient, chain: .evm),
                  let amount = WalletBaseUnits.normalize(
                      nonempty(actionObject["amount_base_units"]) ?? ""
                  ), amount != "0", actionObject["calldata"] == nil else {
                throw Error.invalidArguments(
                    "A token transfer requires a canonical asset ID, raw recipient, and positive base-unit amount."
                )
            }
            action = .fungibleTokenTransfer(
                assetID: assetID, recipient: recipient, amountBaseUnits: amount
            )
        case .nftTransfer:
            guard let assetID = nonempty(actionObject["asset_id"]),
                  let tokenID = WalletBaseUnits.normalize(
                      nonempty(actionObject["token_id"]) ?? ""
                  ),
                  let recipient = nonempty(actionObject["recipient"]),
                  Self.validAddress(recipient, chain: .evm),
                  actionObject["calldata"] == nil else {
                throw Error.invalidArguments(
                    "An NFT transfer requires a canonical asset ID, uint256 token ID, and raw recipient."
                )
            }
            action = .nftTransfer(
                assetID: assetID, tokenID: tokenID, recipient: recipient
            )
        case .exactInputSwap, .reviewedCall, .standardizedSignIn,
             .reviewedTypedAuthorization:
            throw Error.invalidArguments(
                "That operation requires a reviewed chain adapter that is not active."
            )
        }
        if descriptor.environment == .mainnet {
            let capability: WalletNetworkCapability = switch kind {
            case .nativeTransfer: .nativeTransfer
            case .contractCall, .reviewedCall: .reviewedCall
            case .fungibleTokenTransfer: .fungibleTokenTransfer
            case .nftTransfer: .nftTransfer
            case .exactInputSwap: .exactInputSwap
            case .standardizedSignIn, .reviewedTypedAuthorization: .embeddedBrowser
            }
            do {
                try launchGate.authorize(
                    networkID: networkID, capability: capability,
                    regionCode: regionCode
                )
            } catch {
                throw Error.policyDenied(error.localizedDescription)
            }
        }
        return WalletPrepareRequest(
            networkID: networkID,
            accountID: accountID,
            source: source,
            action: action,
            maximumFeeBaseUnits: maximumFee
        )
    }

    private func simulate(
        _ arguments: [String: Any],
        source: WalletRequestSource
    ) async throws -> [String: Any] {
        guard let intentID = nonempty(arguments["intent_id"]),
              let known = prepared[intentID], known.expiresAt > Date(),
              known.source == source else { throw Error.intentNotFound }
        let transaction = try await signer.simulate(intentID: intentID)
        guard transaction.id == known.id, transaction.digest == known.digest else {
            throw Error.policyDenied("The signer returned a different transaction during re-simulation.")
        }
        prepared[intentID] = transaction
        return response(for: transaction)
    }

    private func execute(
        _ arguments: [String: Any],
        source: WalletRequestSource
    ) async throws -> [String: Any] {
        guard let intentID = nonempty(arguments["intent_id"]),
              let transaction = prepared[intentID], transaction.expiresAt > Date(),
              transaction.source == source else {
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
        let result: [String: Any]
        do {
            result = try await signer.execute(intentID: intentID)
        } catch let Error.broadcastUnknown(transactionHash, message) {
            recordActivity(
                transaction: transaction,
                transactionHash: transactionHash,
                state: .broadcastUnknown,
                detail: message
            )
            prepared[intentID] = nil
            pendingConfirmation = nil
            throw Error.broadcastUnknown(transactionHash: transactionHash, message: message)
        }
        activePolicyStatuses = (try? await signer.listPolicies()) ?? activePolicyStatuses
        activePolicies = activePolicyStatuses.map(\.policy)
        prepared[intentID] = nil
        pendingConfirmation = nil
        if let hash = result["transaction_hash"] as? String {
            recordActivity(
                transaction: transaction,
                transactionHash: hash,
                state: .submitted,
                detail: nil
            )
        }
        return result
    }

    private func recordActivity(
        transaction: WalletPreparedTransaction,
        transactionHash: String,
        state: WalletActivityState,
        detail: String?
    ) {
        let record = WalletActivityRecord(
            id: transactionHash.lowercased(),
            intentID: transaction.id,
            transactionHash: transactionHash,
            networkID: transaction.networkID,
            accountID: transaction.accountID,
            summary: transaction.summary,
            submittedAt: Date(),
            state: state,
            blockNumber: nil,
            lastCheckedAt: nil,
            detail: detail.map { String($0.prefix(512)) },
            direction: .outbound,
            source: transaction.source,
            actionKind: transaction.action.type,
            assetID: transaction.budgetAssetID,
            amountBaseUnits: transaction.spendBaseUnits,
            finality: state == .broadcastUnknown ? .uncertain : .pending,
            expiresAt: transaction.expiresAt
        )
        transactionHistory.removeAll { $0.id == record.id }
        transactionHistory.insert(record, at: 0)
        if transactionHistory.count > 250 { transactionHistory.removeLast(transactionHistory.count - 250) }
        persistActivity()
    }

    private func persistActivity() {
        if let publicStore {
            for record in transactionHistory { try? publicStore.upsertActivity(record) }
        } else if let data = try? JSONEncoder().encode(transactionHistory) {
            userDefaults.set(data, forKey: activityDefaultsKey)
        }
    }

    private func response(for transaction: WalletPreparedTransaction) -> [String: Any] {
        var result: [String: Any] = [
            "text": "Prepared \(transaction.id)\nDigest: \(transaction.digest)\n\(transaction.summary)\nSimulation: \(transaction.simulation)",
            "intent_id": transaction.id,
            "digest": transaction.digest,
            "network_id": transaction.networkID,
            "account_id": transaction.accountID,
            "request_source": transaction.source.kind.rawValue,
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
        if let origin = transaction.source.origin { result["request_origin"] = origin }
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
      const providerUUID = globalThis.crypto?.randomUUID?.() ||
        'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, character => {
          const random = Math.floor(Math.random() * 16);
          return (character === 'x' ? random : (random & 0x3) | 0x8).toString(16);
        });

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
      Object.defineProperty(globalThis, 'locusVault', {
        configurable: false, enumerable: false, writable: false, value: provider,
      });
      const detail = Object.freeze({
        info: Object.freeze({
          uuid: providerUUID,
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
