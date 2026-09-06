import AppKit
import CryptoKit
import Foundation

/// UI eligibility is not signing authority. The signer independently validates
/// every policy; these filters keep unrelated and externally owned accounts out
/// of the rule editors before the user authorizes anything.
enum WalletPolicyAccountEligibility {
    static func contractCapability(_ entry: WalletContractRegistryEntry) -> WalletNetworkCapability? {
        switch entry.reviewedAdapterID {
        case WalletReviewedAdapters.erc20: .fungibleTokenTransfer
        case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
             WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn: .exactInputSwap
        default: nil
        }
    }

    static func accounts(_ accounts: [WalletAccount], networkID: String) -> [WalletAccount] {
        guard let network = WalletNetworkCatalog.descriptor(id: networkID),
              network.chain == .evm || network.chain == .solana,
              network.staticallyReviewedCapabilities.contains(.autonomousPolicy) else { return [] }
        return accounts.filter {
            $0.ownership == .locusVault && $0.chain == network.chain
                && $0.networkIDs.contains(networkID)
        }
    }

    static func contractAssetID(entry: WalletContractRegistryEntry, address: String) -> String? {
        guard WalletNetworkCatalog.descriptor(id: entry.networkID)?.chain == .evm,
              address.count == 42, address.hasPrefix("0x"),
              address.dropFirst(2).allSatisfy(\.isHexDigit) else { return nil }
        return "\(entry.networkID)/erc20:\(address.lowercased())"
    }

    static func contractPolicy(
        entry: WalletContractRegistryEntry, account: WalletAccount, inputToken: String,
        recipient: String, perTransaction: String, sessionCap: String, feeCap: String,
        durationMinutes: String, maximumSlippageBPS: String, minimumOutput: String,
        now: Date = Date()
    ) -> WalletSessionPolicy? {
        guard let capability = contractCapability(entry), let adapter = entry.reviewedAdapterID,
              accounts([account], networkID: entry.networkID).count == 1,
              let minutes = Int(durationMinutes), (1...480).contains(minutes),
              WalletBaseUnits.normalize(perTransaction) == perTransaction, perTransaction != "0",
              WalletBaseUnits.normalize(sessionCap) == sessionCap,
              WalletBaseUnits.normalize(feeCap) == feeCap,
              WalletBaseUnits.lessThanOrEqual(perTransaction, sessionCap) else { return nil }
        let isSwap = capability == .exactInputSwap
        guard let asset = contractAssetID(entry: entry,
            address: isSwap ? inputToken : entry.checksumAddress) else { return nil }
        let counterparty = isSwap ? account.address : recipient
        guard contractAssetID(entry: entry, address: counterparty) != nil else { return nil }
        let slippage: Int?
        let floor: String?
        if isSwap {
            guard let value = Int(maximumSlippageBPS), (0...500).contains(value),
                  WalletBaseUnits.normalize(minimumOutput) == minimumOutput, minimumOutput != "0" else { return nil }
            slippage = value
            floor = minimumOutput
        } else {
            slippage = nil
            floor = nil
        }
        return WalletSessionPolicy(id: UUID().uuidString.lowercased(), accountID: account.id,
            networkID: entry.networkID, allowedAssetIDs: [asset], allowedRecipients: [counterparty],
            allowedContractIDs: [entry.id], allowedAdapterIDs: [adapter],
            maximumTransactionBaseUnits: perTransaction, maximumSessionBaseUnits: sessionCap,
            maximumFeeBaseUnits: feeCap, expiresAt: now.addingTimeInterval(TimeInterval(minutes * 60)),
            allowedActionKinds: isSwap ? [.exactInputSwap] : [.fungibleTokenTransfer],
            maximumSlippageBPS: slippage, minimumOutputBaseUnits: floor)
    }
}

#if LOCUS_DIRECT_DOWNLOAD
#if DEBUG
/// Explicit in-process XCTest injection only; no preference, environment,
/// public bridge, Release, or App Store activation override exists.
struct WalletExperimentalActivationTestConfiguration {
    let key: Curve25519.Signing.PublicKey
    let ceiling: WalletSignedReviewCeiling
    let identity: WalletInstalledReleaseIdentity
}
#endif

struct WalletExperimentalMainnetActivationPreview: Identifiable, Equatable {
    let id: UUID
    let revision: Int
    let expiresAt: Date
    let networkGrants: [WalletNetworkCapabilityGrant]
}

enum WalletExperimentalActivationImport {
    static let maximumBytes = 1_048_576

    static func decode(_ data: Data) throws -> WalletReleaseHistoryRequest {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw WalletReleaseActivationError.malformed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request = try decoder.decode(WalletReleaseHistoryRequest.self, from: data)
        guard request.schemaVersion == 1, request.admission == nil,
              !request.transitions.isEmpty,
              request.transitions.count <= WalletReleaseHistoryVerifier.maximumTransitions,
              request.transitions.allSatisfy({
                  $0.envelope.releaseStage == .experimentalMainnet
                      && $0.envelope.purpose == .experimentalMainnet
              }) else { throw WalletReleaseActivationError.malformed }
        return request
    }

    static func containsExperimentalAuthority(_ request: WalletReleaseHistoryRequest) -> Bool {
        request.transitions.contains {
            $0.envelope.releaseStage == .experimentalMainnet
                || $0.envelope.purpose == .experimentalMainnet
        }
    }
}
#endif

enum WalletHubState: Equatable, Sendable {
    case unavailableBuild
    case alphaDisabled
    case recoveryUnavailable
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
    var ownership: WalletAccountOwnership = .locusVault
}

struct WalletDiagnosticSnapshot: Codable, Equatable, Sendable {
    let appVersion: String
    let buildVersion: String
    let macOSVersion: String
    let signerProtocolVersion: Int
    let signerReachability: String
    let recoveryHelperAvailable: Bool
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
            "Recovery helper: \(recoveryHelperAvailable ? "available" : "unavailable")",
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

enum WalletExternalConnectorState: String, Codable, Sendable {
    case foundationReady = "foundation_ready"
    case enabledAfterAudit = "enabled_after_audit"
}

struct WalletExternalConnectorDescriptor: Identifiable, Equatable, Sendable {
    var id: String { kind.rawValue }
    let kind: WalletExternalConnectorID
    let name: String
    let supportedNetworks: Set<String>
    let transport: String
    let documentationURL: URL
    let state: WalletExternalConnectorState
}

/// Non-secret connector metadata and rollout order. The connector foundations
/// deliberately expose no generic signing primitive. Runtime availability is
/// always the intersection of this ceiling, the signed launch grant, and the
/// signed connector review identity.
enum WalletExternalConnectorCatalog {
    static let connectors: [WalletExternalConnectorDescriptor] = [
        WalletExternalConnectorDescriptor(
            kind: .metamask, name: "MetaMask",
            supportedNetworks: ["eip155:1", "eip155:11155111"],
            transport: "MetaMask Connect · wallet-owned confirmation",
            documentationURL: URL(string: "https://docs.metamask.io/")!,
            state: .foundationReady
        ),
        WalletExternalConnectorDescriptor(
            kind: .phantom, name: "Phantom",
            supportedNetworks: ["solana:mainnet-beta", "solana:devnet"],
            transport: "Phantom embedded user wallet · exact Locus review",
            documentationURL: URL(
                string: "https://docs.phantom.com/sdks/browser-sdk"
            )!,
            state: .foundationReady
        ),
        WalletExternalConnectorDescriptor(
            kind: .slush, name: "Slush",
            supportedNetworks: ["sui:mainnet", "sui:testnet"],
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
        let descriptor = WalletNetworkCatalog.descriptor(id: networkID)
        let assetID = descriptor?.nativeAssetID ?? "\(networkID)/slip44:60"
        let adapterID = descriptor?.chain == .solana
            ? WalletReviewedAdapters.solanaNativeTransfer
            : WalletReviewedAdapters.ethereumNativeTransfer
        return WalletSessionPolicy(
            id: UUID().uuidString.lowercased(), accountID: accountID, networkID: networkID,
            allowedAssetIDs: [assetID], allowedRecipients: [recipient],
            allowedContractIDs: [], allowedAdapterIDs: [adapterID],
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

enum WalletUniswapAllowanceState: Equatable, Sendable {
    case unchecked
    case sufficient
    case needsERC20Approval(
        tokenAddress: String, permit2Address: String,
        amountBaseUnits: String, requiresZeroFirst: Bool
    )
    case needsPermit2Approval(
        tokenAddress: String, routerAddress: String,
        amountBaseUnits: String, expirationUnixSeconds: String
    )
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
    /// Present only for connector-submitted activity. This is public semantic
    /// metadata (never transaction bytes) used to prove the finalized chain
    /// effects still match the exact action the user reviewed.
    var expectedAction: WalletSemanticAction? = nil
    var semanticDigest: String? = nil
    var expectedContractAddress: String? = nil
    var expectedEVMTransactionDigest: String? = nil
    var expectedEVMMaximumFeeBaseUnits: String? = nil
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

    static func subtract(_ lhs: String, _ rhs: String) -> String? {
        guard let left = normalize(lhs), let right = normalize(rhs),
              compare(left, right) != .orderedAscending else { return nil }
        var a = left.reversed().map { Int(String($0))! }
        let b = right.reversed().map { Int(String($0))! }
        var borrow = 0
        for index in 0..<a.count {
            var digit = a[index] - borrow - (index < b.count ? b[index] : 0)
            if digit < 0 {
                digit += 10
                borrow = 1
            } else {
                borrow = 0
            }
            a[index] = digit
        }
        guard borrow == 0 else { return nil }
        while a.count > 1, a.last == 0 { a.removeLast() }
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

    /// Exact long division for bounded unsigned base-unit values. Both parts
    /// remain decimal strings so quote safety never passes through floating
    /// point or locale-sensitive arithmetic.
    static func divide(
        _ dividend: String,
        by divisor: String
    ) -> (quotient: String, remainder: String)? {
        guard let dividend = normalize(dividend),
              let divisor = normalize(divisor), divisor != "0",
              dividend.count <= 256, divisor.count <= 256 else { return nil }
        var remainder = "0"
        var quotient = ""
        for digit in dividend {
            guard let shifted = multiply(remainder, "10"),
                  let nextRemainder = add(shifted, String(digit)) else { return nil }
            remainder = nextRemainder
            var quotientDigit = 0
            for candidate in stride(from: 9, through: 1, by: -1) {
                guard let product = multiply(divisor, String(candidate)) else {
                    return nil
                }
                if lessThanOrEqual(product, remainder) {
                    quotientDigit = candidate
                    remainder = subtract(remainder, product) ?? "0"
                    break
                }
            }
            if !quotient.isEmpty || quotientDigit != 0 {
                quotient.append(String(quotientDigit))
            }
        }
        return (quotient.isEmpty ? "0" : quotient, remainder)
    }

    static func applyingBasisPointFloor(_ value: String, bpsToKeep: Int) -> String? {
        guard (0...10_000).contains(bpsToKeep),
              let scaled = multiply(value, String(bpsToKeep)) else { return nil }
        return divide(scaled, by: "10000")?.quotient
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
        guard transaction.action.type != .swapAllowanceSetup else {
            return .requiresApproval("Allowance setup always requires exact confirmation.")
        }
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
        case WalletReviewedAdapters.ethereumNativeTransfer,
             WalletReviewedAdapters.solanaNativeTransfer,
             WalletReviewedAdapters.solanaSPLTransferChecked,
             WalletReviewedAdapters.solanaToken2022TransferChecked:
            counterparties = transaction.action.recipient.map { [$0] } ?? []
        case WalletReviewedAdapters.erc20:
            counterparties = transaction.effects.compactMap { effect in
                if effect.kind == "token_transfer" { return effect.to }
                if effect.kind == "approval" || effect.kind == "approval_revoke" {
                    return effect.spender
                }
                return nil
            }
        case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
             WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn:
            counterparties = transaction.effects.filter {
                $0.kind == "minimum_receive"
            }.compactMap(\.to)
            guard transaction.action.type == .exactInputSwap,
                  let route = transaction.action.swapRoute,
                  let deadline = UInt64(route.deadlineUnixSeconds),
                  deadline >= UInt64(max(0, now.timeIntervalSince1970.rounded(.down))) else {
                return .requiresApproval("The swap quote is stale.")
            }
            guard let maximumSlippage = policy.maximumSlippageBPS,
                  (0...5_000).contains(maximumSlippage),
                  route.slippageBPS <= maximumSlippage else {
                return .requiresApproval("The swap slippage exceeds the policy limit.")
            }
            let outputs = transaction.effects.filter { $0.kind == "minimum_receive" }
            guard let minimum = policy.minimumOutputBaseUnits,
                  outputs.count == 1,
                  WalletBaseUnits.lessThanOrEqual(
                    minimum, outputs[0].amountBaseUnits
                  ) else {
                return .requiresApproval("The swap minimum output is below the policy floor.")
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
    #if LOCUS_DIRECT_DOWNLOAD
    func applyReleaseActivation(
        _ envelope: WalletSignedReleaseActivationEnvelope
    ) async throws -> WalletReleaseActivationStatus
    func releaseAuthorityStatus() async throws -> WalletReleaseAuthorityStatus
    func applyReleaseHistory(_ history: WalletReleaseHistoryRequest) async throws -> WalletReleaseAuthorityStatus
    #endif
    func deleteVault(confirmation: String) async throws -> WalletSignerStatus
    func deleteRecoveryVault(confirmation: String) async throws -> WalletSignerStatus
    func authorizeSession() async throws
    func listAccounts() async throws -> [WalletAccount]
    func signStructuredAuthorization(
        _ request: WalletStructuredAuthorizationRequest,
        source: WalletRequestSource
    ) async throws -> WalletStructuredAuthorizationResult
    func prepare(
        _ request: WalletPrepareRequest,
        contract: WalletContractRegistryEntry?
    ) async throws -> WalletPreparedTransaction
    func simulate(intentID: String) async throws -> WalletPreparedTransaction
    func confirmExecution(intentID: String) async throws
    func cancelPreparation(intentID: String)
    func execute(intentID: String) async throws -> [String: Any]
    func activatePolicy(_ policy: WalletSessionPolicy) async throws -> [WalletActivePolicyStatus]
    func listPolicies() async throws -> [WalletActivePolicyStatus]
    func clearPolicies() async throws
    func verifyContract(_ draft: WalletContractRegistryDraft) async throws -> WalletContractRegistryEntry
    func browserRPC(networkID: String, method: String, params: [Any]) async throws -> Any
    func quoteUniswap(
        request: WalletUniswapQuoteRequest,
        configuration: WalletReviewedUniswapConfiguration
    ) async throws -> WalletUniswapQuote
    func performRead(tool: String, arguments: [String: Any]) async throws -> [String: Any]
    func rpcHealth() async throws -> String
    func configureRPCURL(_ value: String)
    func lock()
}

extension WalletSignerClient {
    #if LOCUS_DIRECT_DOWNLOAD
    func releaseAuthorityStatus() async throws -> WalletReleaseAuthorityStatus {
        throw WalletGateway.Error.signerUnavailable
    }
    func applyReleaseHistory(_ history: WalletReleaseHistoryRequest) async throws -> WalletReleaseAuthorityStatus {
        throw WalletGateway.Error.signerUnavailable
    }
    #endif
    func cancelPreparation(intentID: String) {}

    func quoteUniswap(
        request: WalletUniswapQuoteRequest,
        configuration: WalletReviewedUniswapConfiguration
    ) async throws -> WalletUniswapQuote {
        throw WalletGateway.Error.signerUnavailable
    }
}

@MainActor
final class UnavailableWalletSignerClient: WalletSignerClient {
    let isAvailable = false
    let sessionID: String? = nil
    var invalidationHandler: (() -> Void)?
    func signerStatus() async throws -> WalletSignerStatus { throw WalletGateway.Error.signerUnavailable }
    #if LOCUS_DIRECT_DOWNLOAD
    func applyReleaseActivation(
        _ envelope: WalletSignedReleaseActivationEnvelope
    ) async throws -> WalletReleaseActivationStatus {
        _ = envelope
        throw WalletGateway.Error.signerUnavailable
    }
    #endif
    func deleteVault(confirmation: String) async throws -> WalletSignerStatus {
        throw WalletGateway.Error.signerUnavailable
    }
    func deleteRecoveryVault(confirmation: String) async throws -> WalletSignerStatus {
        throw WalletGateway.Error.signerUnavailable
    }
    func authorizeSession() async throws { throw WalletGateway.Error.signerUnavailable }
    func listAccounts() async throws -> [WalletAccount] { [] }
    func signStructuredAuthorization(
        _ request: WalletStructuredAuthorizationRequest,
        source: WalletRequestSource
    ) async throws -> WalletStructuredAuthorizationResult {
        throw WalletGateway.Error.signerUnavailable
    }
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
        case connectionHelperUnavailable
        case externalWallet(String)
        case vaultLocked
        case invalidArguments(String)
        case intentNotFound
        case policyDenied(String)
        case approvalRequired(String)
        case needsAllowance(WalletUniswapAllowanceState)
        case broadcastUnknown(transactionHash: String, message: String)

        var errorDescription: String? {
            switch self {
            case .signerUnavailable: "The experimental Locus WalletSigner component is not installed in this build."
            case .connectionHelperUnavailable:
                "The Direct wallet connector runtime is unavailable in this build."
            case .externalWallet(let message): message
            case .vaultLocked: "Locus Vault is locked. Authorize a signing session in Wallet Settings first."
            case .invalidArguments(let message): message
            case .intentNotFound: "The prepared transaction is missing or expired. Prepare it again."
            case .policyDenied(let message): message
            case .approvalRequired(let message): message
            case .needsAllowance:
                "needsAllowance: set up the reviewed finite token allowances in Locus, then request the swap again."
            case .broadcastUnknown(let transactionHash, let message):
                "The signed transaction \(transactionHash) has an uncertain broadcast state: \(message)"
            }
        }
    }

    static let protocolVersion = 3
    static let ethereumMainnetNetworkID = "eip155:1"
    static let sepoliaNetworkID = "eip155:11155111"
    static let solanaMainnetNetworkID = "solana:mainnet-beta"
    static let suiMainnetNetworkID = "sui:mainnet"
    private static let maximumPreparedIntents = 32
    static let allowedOperations = [
        "wallet_list_accounts", "wallet_get_balance", "wallet_get_assets",
        "wallet_get_activity",
        "wallet_prepare_transaction", "wallet_simulate_transaction",
        "wallet_execute_transaction", "wallet_execute_external_transaction",
        "wallet_quote_swap", "wallet_prepare_swap_allowance",
        "wallet_authorize_sign_in",
        "wallet_lock",
    ]

    @Published private(set) var status: Status
    @Published private(set) var accounts: [WalletAccount] = []
    @Published private(set) var activePolicies: [WalletSessionPolicy] = []
    @Published private(set) var pendingConfirmation: WalletPreparedTransaction?
    @Published private(set) var vaultState: WalletVaultState = .missing
    @Published private(set) var recoveryCeremonyActive = false
    @Published private(set) var recoveryPresentationState = WalletRecoveryPresentationState.idle
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
    @Published private(set) var pendingConnectionProposal: WalletConnectionProposalReview?
    @Published private(set) var currentSwapQuote: WalletUniswapQuote?
    @Published private(set) var currentSwapAllowance: WalletUniswapAllowanceState = .unchecked
    @Published private(set) var swapQuoteInProgress = false

    private let signer: WalletSignerClient
    private let connectionsClient: WalletConnectionsClient
    private let recoveryView: WalletRecoveryViewClient
    private let userDefaults: UserDefaults
    private let publicStore: WalletPublicStore?
    private var launchGate: WalletLaunchGate
    private var reviewRegistry: WalletReviewRegistry?
    #if LOCUS_DIRECT_DOWNLOAD
    private let bundledReviewCeiling: WalletReviewRegistry?
    private let immutableReviewCeiling: WalletSignedReviewCeiling?
    private var verifiedReleaseAuthority: WalletVerifiedReleaseAuthority? {
        didSet { NotificationCenter.default.post(name: WalletCandidateUpdateAuthority.changed, object: nil) }
    }
    @Published private(set) var canaryInstallationID: String?
    @Published private(set) var experimentalMainnetActivationPreview: WalletExperimentalMainnetActivationPreview?
    private var stagedExperimentalActivation: (request: WalletReleaseHistoryRequest,
        signerStatus: WalletReleaseAuthorityStatus, checkpoint: WalletReleaseAuthorityCheckpoint)?
    private var experimentalActivationReviewGeneration = UUID()
    private var experimentalActivationConsentGeneration = UUID()
    #if DEBUG
    private var experimentalActivationTestConfiguration: WalletExperimentalActivationTestConfiguration?
    func configureExperimentalActivationForTesting(_ configuration: WalletExperimentalActivationTestConfiguration) {
        precondition(NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil,
            "Activation fixtures require XCTest")
        experimentalActivationTestConfiguration = configuration
    }
    #endif
    private let activationPublicKey: Curve25519.Signing.PublicKey?
    private let installedReleaseIdentity: WalletInstalledReleaseIdentity?
    private let releaseActivationURL: URL?
    private let usesBundledReleaseActivation: Bool
    private var appliedActivationDigest: String?
    private var activationExpiryTask: Task<Void, Never>?
    private var activationRefreshTask: Task<Void, Never>?
    private var activationRefreshTimer: Timer?
    private var activationWakeObserver: NSObjectProtocol?
    private var activationForegroundObserver: NSObjectProtocol?
    private var appliedActivationRevision = 0
    #endif
    private let regionCode: String
    let buildSupportsWalletAlpha: Bool
    private var prepared: [String: WalletPreparedTransaction] = [:]
    private var confirmedIntentIDs: Set<String> = []
    private var connectionIntentBindings: [String: WalletConnectionRequestBinding] = [:]
    private var executingIntentIDs: Set<String> = []
    private let registryDefaultsKey = "LocusWalletContractRegistryV1"
    private let policyTemplatesDefaultsKey = "LocusWalletPolicyTemplatesV1"
    private let activityDefaultsKey = "LocusWalletActivityV1"
    private let idleLockDefaultsKey = "LocusWalletIdleLockMinutesV2"
    private var browserOriginGrants: Set<WalletBrowserOriginNetworkGrant> = []
    private let requestRouter = WalletDappRequestRouter()
    private var browserIntentOrigins: [String: String] = [:]
    private var browserGrantContinuation: CheckedContinuation<Bool, Never>?
    private var connectionProposalContinuation: CheckedContinuation<Bool, Never>?
    private var confirmationContinuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var consumedPairingDigests: [String: Date] = [:]
    private var uiFixtureHubState: WalletHubState?
    private var activeSwapQuoteAccountID: String?
    private var idleLockTimer: Timer?
    private var localActivityMonitor: Any?
    var onBrowserAuthorizationNeeded: (() -> Void)?
    var onBrowserGrantsRevoked: ((String?) -> Void)?

    init(signer: WalletSignerClient? = nil,
         connectionsClient: WalletConnectionsClient? = nil,
         recoveryView: WalletRecoveryViewClient? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         userDefaults: UserDefaults = .standard,
         publicStore: WalletPublicStore? = nil,
         launchGate: WalletLaunchGate? = nil,
         reviewRegistry: WalletReviewRegistry? = nil,
         regionCode: String = Locale.current.region?.identifier ?? "ZZ",
         buildSupportsWalletAlpha: Bool = AppSettings.walletAlphaSupportedByCurrentBuild) {
        let signer = signer ?? WalletSignerClientFactory.make()
        self.signer = signer
        self.connectionsClient = connectionsClient ?? WalletConnectionsClientFactory.make()
        self.recoveryView = recoveryView ?? WalletRecoveryViewClientFactory.make()
        self.userDefaults = userDefaults
        self.publicStore = publicStore ?? Self.makeDefaultPublicStore(
            environment: environment,
            buildSupportsWallet: buildSupportsWalletAlpha
        )
        let bundledReview = reviewRegistry ?? Self.loadBundledReviewRegistry()
        self.launchGate = launchGate ?? (try! WalletLaunchGate())
        self.reviewRegistry = bundledReview
        #if LOCUS_DIRECT_DOWNLOAD
        bundledReviewCeiling = bundledReview
        immutableReviewCeiling = WalletSignedReviewCeiling.loadBundled()
        activationPublicKey = Self.loadBundledActivationPublicKey()
        installedReleaseIdentity = WalletInstalledReleaseIdentity.current()
        releaseActivationURL = WalletReleaseActivationSource.endpoint()
        usesBundledReleaseActivation = launchGate == nil && reviewRegistry == nil
        #endif
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
            let local = registry.map(Self.sanitizedRegistryEntry)
            contractRegistry = Self.mergeReviewedContracts(
                signed: self.reviewRegistry?.evmContracts ?? [], local: local
            )
            if local != registry,
               let upgraded = try? JSONEncoder().encode(local) {
                userDefaults.set(upgraded, forKey: registryDefaultsKey)
            }
        } else {
            contractRegistry = self.reviewRegistry?.evmContracts ?? []
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
            let storedAssets = (try? publicStore.loadAssets()) ?? []
            assets = Self.mergeReviewedAssets(
                signed: self.reviewRegistry?.assets ?? [], stored: storedAssets
            )
            let storedConnections = (try? publicStore.loadConnections()) ?? []
            connections = storedConnections.map { connection in
                guard connection.connector == .phantom,
                      connection.accountOwnership == .external(connectorID: .phantom),
                      !connection.state.isTerminal else { return connection }
                return connection.transitioning(to: .revoked) ?? connection
            }
            for connection in connections where !storedConnections.contains(connection) {
                try? publicStore.upsertConnection(connection)
            }
        } else {
            assets = self.reviewRegistry?.assets ?? []
        }
        signer.invalidationHandler = { [weak self] in self?.handleSignerInvalidation() }
        self.connectionsClient.invalidationHandler = { [weak self] in
            self?.handleConnectionsInvalidation()
        }
        self.connectionsClient.statusChangeHandler = { [weak self] status in
            self?.applyConnectionStatus(status)
        }
        self.connectionsClient.proposalApprovalHandler = { [weak self] proposal in
            guard let self else { return false }
            return await self.reviewConnectionProposal(proposal)
        }
        self.connectionsClient.dappRequestHandler = { [weak self] request in
            guard let self else { throw Error.connectionHelperUnavailable }
            return try await self.handleConnectorDappRequest(request)
        }
        self.recoveryView.invalidationHandler = { [weak self] in
            self?.handleRecoveryInvalidation()
        }
        self.recoveryView.presentationStateHandler = { [weak self] state in
            self?.recoveryPresentationState = state
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
        #if LOCUS_DIRECT_DOWNLOAD
        if usesBundledReleaseActivation {
            WalletCandidateUpdateAuthority.source = { [weak self] in
                guard let self, let authority = self.verifiedReleaseAuthority,
                      let installation = self.canaryInstallationID else { return nil }
                return (authority, installation)
            }
        }
        if buildSupportsWalletAlpha, usesBundledReleaseActivation,
           activationPublicKey != nil, immutableReviewCeiling != nil,
           environment["XCTestConfigurationFilePath"] == nil,
           environment["LOCUS_UI_TESTING"] != "1" {
            activationRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
                [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshReleaseActivation() }
            }
            activationWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshReleaseActivation() }
            }
            activationForegroundObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshReleaseActivation() }
            }
            Task { @MainActor [weak self] in await self?.refreshReleaseActivation() }
        }
        #endif
    }

    deinit {
        idleLockTimer?.invalidate()
        #if LOCUS_DIRECT_DOWNLOAD
        activationRefreshTimer?.invalidate()
        activationRefreshTask?.cancel()
        activationExpiryTask?.cancel()
        if let activationWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationWakeObserver)
        }
        if let activationForegroundObserver {
            NotificationCenter.default.removeObserver(activationForegroundObserver)
        }
        #endif
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

    #if LOCUS_DIRECT_DOWNLOAD
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
    #endif

    private static func loadBundledReviewRegistry(
        bundle: Bundle = .main
    ) -> WalletReviewRegistry? {
        #if LOCUS_DIRECT_DOWNLOAD
        let signerURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("WalletSigner.xpc", isDirectory: true)
        guard let signerBundle = Bundle(url: signerURL),
              let publicKeyText = signerBundle.object(
                  forInfoDictionaryKey: "LocusWalletCapabilityPublicKey"
              ) as? String,
              let publicKeyData = Data(base64Encoded: publicKeyText),
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyData
              ),
              let manifestText = signerBundle.object(
                  forInfoDictionaryKey: "LocusWalletReviewManifestBase64"
              ) as? String,
              let manifestData = Data(base64Encoded: manifestText) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let signed = try? decoder.decode(
            WalletSignedReviewManifest.self, from: manifestData
        ) else { return nil }
        return try? WalletReviewRegistry(signedManifest: signed, publicKey: publicKey)
        #else
        // The App Store target has no signer, review configuration or activation.
        return nil
        #endif
    }

    #if LOCUS_DIRECT_DOWNLOAD
    private static func loadBundledActivationPublicKey(
        bundle: Bundle = .main
    ) -> Curve25519.Signing.PublicKey? {
        let signerURL = bundle.bundleURL
            .appendingPathComponent("Contents/XPCServices/WalletSigner.xpc")
        guard let signerBundle = Bundle(url: signerURL),
              let text = signerBundle.object(
                forInfoDictionaryKey: "LocusWalletCapabilityPublicKey"
              ) as? String,
              let data = Data(base64Encoded: text) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
    #endif

    private static func mergeReviewedAssets(
        signed: [WalletAsset], stored: [WalletAsset]
    ) -> [WalletAsset] {
        let signedIDs = Set(signed.map(\.id))
        let userControlled = stored.filter {
            $0.trust != .curated && !signedIDs.contains($0.id)
        }
        return signed + userControlled
    }

    private static func mergeReviewedContracts(
        signed: [WalletContractRegistryEntry],
        local: [WalletContractRegistryEntry]
    ) -> [WalletContractRegistryEntry] {
        let signedIDs = Set(signed.map(\.id))
        let signedAddresses = Set(signed.map {
            "\($0.networkID):\($0.checksumAddress.lowercased())"
        })
        return signed + local.filter {
            !signedIDs.contains($0.id)
                && !signedAddresses.contains("\($0.networkID):\($0.checksumAddress.lowercased())")
        }
    }

    private static func sanitizedRegistryEntry(
        _ entry: WalletContractRegistryEntry
    ) -> WalletContractRegistryEntry {
        if WalletReviewedAdapters.validatedID(for: entry) != nil {
            return entry
        }
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
        var supportedChains = [
            Self.sepoliaNetworkID,
            WalletNetworkCatalog.solanaDevnet.id,
            WalletNetworkCatalog.suiTestnet.id,
        ]
        if (try? launchGate.authorize(
            networkID: Self.ethereumMainnetNetworkID,
            capability: .nativeTransfer,
            regionCode: regionCode
        )) != nil {
            supportedChains.append(Self.ethereumMainnetNetworkID)
        }
        if (try? launchGate.authorize(
            networkID: Self.solanaMainnetNetworkID,
            capability: .nativeTransfer,
            regionCode: regionCode
        )) != nil {
            supportedChains.append(Self.solanaMainnetNetworkID)
        }
        if (try? launchGate.authorize(
            networkID: Self.suiMainnetNetworkID,
            capability: .nativeTransfer,
            regionCode: regionCode
        )) != nil {
            supportedChains.append(Self.suiMainnetNetworkID)
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
    var connectionHelperAvailable: Bool { connectionsClient.isAvailable }

    func reportConnectionIntakeError(_ error: Swift.Error) {
        lastError = error.localizedDescription
    }

    var hubState: WalletHubState {
        if let uiFixtureHubState { return uiFixtureHubState }
        guard buildSupportsWalletAlpha else { return .unavailableBuild }
        guard walletEnabled else { return .alphaDisabled }
        guard signer.isAvailable else { return .error }
        return switch vaultState {
        case .missing: recoveryView.isAvailable ? .setupRequired : .recoveryUnavailable
        case .awaitingBackup: recoveryView.isAvailable ? .backupIncomplete : .recoveryUnavailable
        case .rotationRequired: recoveryView.isAvailable ? .rotationRequired : .recoveryUnavailable
        case .locked: .locked
        case .unlocked: status == .unlocked ? .ready : .locked
        }
    }

    func refreshStatus() async {
        #if LOCUS_DIRECT_DOWNLOAD
        await refreshReleaseActivation()
        #endif
        await refreshStatus(clearErrorOnSuccess: true)
        await refreshConnections(clearErrorOnSuccess: false)
    }

    #if LOCUS_DIRECT_DOWNLOAD
    private func refreshReleaseActivation() async {
        if let activationRefreshTask {
            await activationRefreshTask.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performReleaseActivationRefresh()
        }
        activationRefreshTask = task
        await task.value
        activationRefreshTask = nil
    }

    private func performReleaseActivationRefresh() async {
        guard usesBundledReleaseActivation || isExperimentalActivationTestFixture,
              let inputs = activationVerificationInputs else { return }
        let (publicKey, ceiling, identity) = inputs
        let consentGeneration = experimentalActivationConsentGeneration
        guard let authorityStatus = try? await signer.releaseAuthorityStatus() else {
            launchGate = try! WalletLaunchGate()
            verifiedReleaseAuthority = nil
            await cancelAuthorityAffectedByActivation()
            return
        }
        canaryInstallationID = authorityStatus.installationID
        var candidates: [WalletReleaseHistoryRequest] = []
        if !isExperimentalActivationTestFixture, let url = releaseActivationURL,
           let remote = try? await WalletReleaseHistorySource.fetch(from: url, checkpoint: authorityStatus.checkpoint),
           !WalletExperimentalActivationImport.containsExperimentalAuthority(remote) {
            candidates.append(remote)
        }
        if let checkpoint = authorityStatus.checkpoint {
            candidates.append(.init(schemaVersion: 1, transitions: [checkpoint.signedTransition], admission: checkpoint.admission))
        }
        for history in candidates {
            do {
                let verified = try WalletReleaseHistoryVerifier.verify(history, ceiling: ceiling,
                    key: publicKey, identity: identity, previous: authorityStatus.checkpoint,
                    installationID: authorityStatus.installationID,
                    allowExperimentalMainnet: experimentalMainnetBuildEnabled)
                // Reapply even the stored checkpoint: after process restart
                // the signer must rehydrate independently verified authority.
                let signerStatus = try await signer.applyReleaseHistory(history)
                guard signerStatus.installationID == authorityStatus.installationID,
                      signerStatus.checkpoint == verified.checkpoint else {
                    throw WalletReleaseActivationError.identityMismatch
                }
                guard consentGeneration == experimentalActivationConsentGeneration else { return }
                let checkpoint = verified.checkpoint
                let admitted = (try? verified.requireAdmission(installationID: authorityStatus.installationID)) != nil
                let isNewAuthority = checkpoint != verifiedReleaseAuthority?.checkpoint
                verifiedReleaseAuthority = verified
                launchGate = admitted ? verified.launchGate : try! WalletLaunchGate()
                reviewRegistry = verified.reviewRegistry
                appliedActivationRevision = checkpoint.revision
                appliedActivationDigest = checkpoint.digest
                if isNewAuthority {
                    activationExpiryTask?.cancel()
                    let expiresAt = verified.authorityExpiresAt
                    activationExpiryTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
                        } catch { return }
                        guard let self,
                              self.appliedActivationDigest == checkpoint.digest else { return }
                        self.launchGate = try! WalletLaunchGate()
                        self.reviewRegistry = self.bundledReviewCeiling
                        self.verifiedReleaseAuthority = nil
                        WalletReleaseActivationCache.remove()
                        await self.cancelAuthorityAffectedByActivation()
                    }
                    await cancelAuthorityAffectedByActivation()
                    if let current = try? await signer.signerStatus() {
                        applyRecoveryStatus(current)
                        status = current.vaultState == .unlocked ? .unlocked : .locked
                    }
                }
                // Persistence is a best-effort optimization, never a condition
                // for enforcing authority already accepted by both processes.
                let cached = WalletReleaseHistoryRequest(schemaVersion: 1,
                    transitions: [checkpoint.signedTransition], admission: checkpoint.admission)
                if !isExperimentalActivationTestFixture {
                    try? WalletReleaseActivationCache.store(WalletAuthorityEncoding.encode(cached))
                }
                return
            } catch {
                continue
            }
        }
        if let expiry = launchGate.effectiveManifest?.expiresAt, expiry <= Date() {
            launchGate = try! WalletLaunchGate()
            reviewRegistry = bundledReviewCeiling
            verifiedReleaseAuthority = nil
            WalletReleaseActivationCache.remove()
            await cancelAuthorityAffectedByActivation()
        }
    }

    private func requireCurrentReleaseAuthority(networkID: String) async throws {
        guard WalletNetworkCatalog.descriptor(id: networkID)?.environment == .mainnet else { return }
        guard let authority = verifiedReleaseAuthority,
              authority.checkpoint.signedTransition.envelope.expiresAt > Date() else {
            throw WalletReleaseActivationError.expired
        }
        let current = try await signer.releaseAuthorityStatus()
        guard current.checkpoint == authority.checkpoint else {
            await refreshReleaseActivation()
            throw WalletReleaseActivationError.rollback
        }
        try authority.requireAdmission(installationID: current.installationID)
    }

    var canaryAccessDescription: String {
        guard let authority = verifiedReleaseAuthority else {
            return "Mainnet is dormant. A verified release activation and invitation are required."
        }
        if authority.checkpoint.signedTransition.envelope.releaseStage == .generalAvailability {
            return "This exact release is approved for general availability."
        }
        if authority.checkpoint.signedTransition.envelope.releaseStage == .experimentalMainnet {
            return "Experimental Mainnet is enabled for this installation. This is not an audited canary or public release. No spending rule is enabled automatically."
        }
        guard let installation = canaryInstallationID,
              (try? authority.requireAdmission(installationID: installation)) != nil else {
            return "An invitation for this installation is required. Import the signed file supplied by the release team."
        }
        return "Invited canary access is active. Every transaction still requires its normal approval and signed spending limits."
    }

    func importCanaryAdmission(_ data: Data) async throws {
        guard data.count <= 1_048_576, let ceiling = immutableReviewCeiling,
              let key = activationPublicKey, let identity = installedReleaseIdentity else {
            throw WalletReleaseActivationError.admissionRequired
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let signed = try decoder.decode(WalletSignedCanaryAdmission.self, from: data)
        let current = try await signer.releaseAuthorityStatus()
        guard let checkpoint = current.checkpoint else { throw WalletReleaseActivationError.historyRequired }
        let request = WalletReleaseHistoryRequest(schemaVersion: 1,
            transitions: [checkpoint.signedTransition], admission: signed)
        let verified = try WalletReleaseHistoryVerifier.verify(request, ceiling: ceiling,
            key: key, identity: identity, previous: checkpoint, installationID: current.installationID,
            allowExperimentalMainnet: experimentalMainnetBuildEnabled)
        try verified.requireAdmission(installationID: current.installationID)
        let applied = try await signer.applyReleaseHistory(request)
        guard applied.checkpoint == verified.checkpoint, applied.installationID == current.installationID else {
            throw WalletReleaseActivationError.identityMismatch
        }
        await refreshReleaseActivation()
    }

    var experimentalMainnetBuildEnabled: Bool {
        isExperimentalActivationTestFixture || WalletExperimentalMainnetBuild.isEnabled()
    }

    private var isExperimentalActivationTestFixture: Bool {
        #if DEBUG
        return experimentalActivationTestConfiguration != nil
        #else
        return false
        #endif
    }

    private var activationVerificationInputs: (Curve25519.Signing.PublicKey,
        WalletSignedReviewCeiling, WalletInstalledReleaseIdentity)? {
        #if DEBUG
        if let fixture = experimentalActivationTestConfiguration {
            return (fixture.key, fixture.ceiling, fixture.identity)
        }
        #endif
        guard let key = activationPublicKey, let ceiling = immutableReviewCeiling,
              let identity = installedReleaseIdentity else { return nil }
        return (key, ceiling, identity)
    }

    var experimentalMainnetActive: Bool {
        walletEnabled && experimentalMainnetBuildEnabled
            && verifiedReleaseAuthority?.checkpoint.signedTransition.envelope.releaseStage == .experimentalMainnet
            && (verifiedReleaseAuthority?.authorityExpiresAt ?? .distantPast) > Date()
    }

    var experimentalMainnetExpiresAt: Date? {
        experimentalMainnetActive ? verifiedReleaseAuthority?.authorityExpiresAt : nil
    }

    func cancelExperimentalMainnetActivationReview() {
        experimentalActivationConsentGeneration = UUID()
        discardExperimentalMainnetActivationPreview()
    }

    private func discardExperimentalMainnetActivationPreview() {
        experimentalActivationReviewGeneration = UUID()
        stagedExperimentalActivation = nil
        experimentalMainnetActivationPreview = nil
    }

    /// Preview is independently verified but grants no authority and never
    /// calls applyReleaseHistory. The file is retained only in native memory.
    func previewExperimentalMainnetActivation(_ data: Data) async throws {
        cancelExperimentalMainnetActivationReview()
        let generation = experimentalActivationReviewGeneration
        guard walletEnabled, experimentalMainnetBuildEnabled,
              let inputs = activationVerificationInputs else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        let (key, ceiling, identity) = inputs
        let request = try WalletExperimentalActivationImport.decode(data)
        let current = try await signer.releaseAuthorityStatus()
        guard walletEnabled, generation == experimentalActivationReviewGeneration else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        let verified = try WalletReleaseHistoryVerifier.verify(request, ceiling: ceiling,
            key: key, identity: identity, previous: current.checkpoint,
            installationID: current.installationID,
            allowExperimentalMainnet: experimentalMainnetBuildEnabled)
        stagedExperimentalActivation = (request, current, verified.checkpoint)
        experimentalMainnetActivationPreview = .init(id: UUID(), revision: verified.checkpoint.revision,
            expiresAt: verified.authorityExpiresAt,
            networkGrants: verified.launchGate.effectiveManifest?.networkGrants.sorted {
                $0.networkID < $1.networkID
            } ?? [])
    }

    /// Only the explicit Enable Mainnet button consumes this one-use review.
    /// Re-read the authenticated signer checkpoint so a stale preview cannot
    /// approve changed history or a different installation.
    func enableExperimentalMainnetActivation(previewID: UUID) async throws {
        guard walletEnabled, experimentalMainnetBuildEnabled,
              experimentalMainnetActivationPreview?.id == previewID,
              let staged = stagedExperimentalActivation,
              let inputs = activationVerificationInputs else {
            throw WalletReleaseActivationError.stateUnavailable
        }
        let (key, ceiling, identity) = inputs
        cancelExperimentalMainnetActivationReview()
        let generation = experimentalActivationReviewGeneration
        let consentGeneration = experimentalActivationConsentGeneration
        let current = try await signer.releaseAuthorityStatus()
        guard walletEnabled, generation == experimentalActivationReviewGeneration,
              current == staged.signerStatus else { throw WalletReleaseActivationError.stateUnavailable }
        let verified = try WalletReleaseHistoryVerifier.verify(staged.request, ceiling: ceiling,
            key: key, identity: identity, previous: current.checkpoint,
            installationID: current.installationID,
            allowExperimentalMainnet: experimentalMainnetBuildEnabled)
        guard verified.checkpoint == staged.checkpoint else {
            throw WalletReleaseActivationError.identityMismatch
        }
        let applied = try await signer.applyReleaseHistory(staged.request)
        guard applied.installationID == current.installationID,
              applied.checkpoint == verified.checkpoint else {
            throw WalletReleaseActivationError.identityMismatch
        }
        guard walletEnabled, generation == experimentalActivationReviewGeneration else {
            // The signer may already have durably accepted the checkpoint.
            // Do not undo its history, revive a canceled review, or publish
            // success after lock, disablement, or a replacement review.
            throw WalletReleaseActivationError.stateUnavailable
        }
        await refreshReleaseActivation()
        guard walletEnabled, consentGeneration == experimentalActivationConsentGeneration,
              verifiedReleaseAuthority?.checkpoint == verified.checkpoint else {
            throw WalletReleaseActivationError.stateUnavailable
        }
    }

    private func cancelAuthorityAffectedByActivation() async {
        // Publishing accepted authority invalidates stale previews, but is not
        // itself user cancellation of the explicit enable operation. Lock,
        // navigation, disablement and replacement review have a separate epoch.
        discardExperimentalMainnetActivationPreview()
        requestRouter.cancel(reason: .walletDisabled)
        for intentID in Array(confirmationContinuations.keys) {
            cancelConfirmation(intentID: intentID)
        }
        prepared.removeAll(keepingCapacity: false)
        confirmedIntentIDs.removeAll(keepingCapacity: false)
        pendingConfirmation = nil
        currentSwapQuote = nil
        currentSwapAllowance = .unchecked
        activePolicies = []
        activePolicyStatuses = []

        let activeConnections = connections.filter { !$0.state.isTerminal }
        for connection in activeConnections {
            let authorized = connection.networkIDs.allSatisfy { networkID in
                (try? authorizeProviderBindings(networkID: networkID)) != nil
                    && connection.approvedMethods.allSatisfy { method in
                    (try? launchGate.authorizeConnection(
                        networkID: networkID,
                        connector: connection.connector,
                        direction: connection.direction,
                        method: method,
                        regionCode: regionCode
                    )) != nil
                        && reviewRegistry?.containsConnector(
                            connection.connector,
                            direction: connection.direction,
                            method: method
                        ) == true
                }
            }
            guard !authorized else { continue }
            if connection.connector == .embeddedBrowser,
               let origin = connection.peerURL {
                revokeBrowserOrigin(origin, reason: .walletDisabled)
            } else {
                await disconnectWalletConnection(id: connection.id)
            }
        }

        if let publicStore {
            let storedAssets = (try? publicStore.loadAssets()) ?? []
            assets = Self.mergeReviewedAssets(
                signed: reviewRegistry?.assets ?? [], stored: storedAssets
            )
        }
        let retainedLocalContracts = contractRegistry.filter {
            WalletReviewedAdapters.validatedID(for: $0) == nil
        }
        contractRegistry = Self.mergeReviewedContracts(
            signed: reviewRegistry?.evmContracts ?? [], local: retainedLocalContracts
        )
    }
    #endif

    private func authorizeProviderBindings(networkID: String) throws {
        #if LOCUS_DIRECT_DOWNLOAD
        guard usesBundledReleaseActivation,
              let network = WalletNetworkCatalog.descriptor(id: networkID),
              network.environment == .mainnet else { return }
        guard let authority = verifiedReleaseAuthority, let installation = canaryInstallationID,
              authority.checkpoint.signedTransition.envelope.expiresAt > Date() else {
            throw WalletReleaseActivationError.expired
        }
        try authority.requireAdmission(installationID: installation)
        guard let reviewRegistry, reviewRegistry.manifest.expiresAt > Date() else {
            throw Error.policyDenied("This network has no current provider review.")
        }
        let endpoints: [WalletProviderEndpoint]
        switch network.chain {
        case .evm:
            guard let config = WalletBundledProviderConfiguration.ethereum(network: network, reviewRegistry: reviewRegistry)
            else { throw Error.policyDenied("Reviewed Ethereum providers are unavailable.") }
            endpoints = [config.primary, config.fallback].compactMap { $0 }
        case .solana:
            guard let config = WalletSolanaProviderConfiguration.bundled(network: network, reviewRegistry: reviewRegistry)
            else { throw Error.policyDenied("Reviewed Solana providers are unavailable.") }
            endpoints = [config.primary, config.fallback].compactMap { $0 }
        case .sui:
            guard let config = WalletSuiProviderConfiguration.bundled(network: network, reviewRegistry: reviewRegistry)
            else { throw Error.policyDenied("Reviewed Sui providers are unavailable.") }
            endpoints = [config.primary, config.fallback].compactMap { $0 }
        }
        guard endpoints.count == 2, endpoints.allSatisfy(reviewRegistry.containsProvider) else {
            throw Error.policyDenied("The active release no longer approves this network's configured providers.")
        }
        #else
        throw Error.signerUnavailable
        #endif
    }

    func policyAccounts(networkID: String, capability: WalletNetworkCapability) -> [WalletAccount] {
        guard walletEnabled, status == .unlocked, signer.isAvailable,
              let network = WalletNetworkCatalog.descriptor(id: networkID),
              network.staticallyReviewedCapabilities.contains(capability) else { return [] }
        // Keep ordinary testnet policies available, matching the signing
        // pipeline. Mainnet additionally requires active release authority.
        if network.environment == .mainnet {
            guard (try? launchGate.authorize(networkID: networkID, capability: .autonomousPolicy,
                      regionCode: regionCode)) != nil,
                  (try? launchGate.authorize(networkID: networkID, capability: capability,
                      regionCode: regionCode)) != nil,
                  (try? authorizeProviderBindings(networkID: networkID)) != nil else { return [] }
        }
        return WalletPolicyAccountEligibility.accounts(accounts, networkID: networkID)
    }

    func canAuthorizeTokenPolicy(for snapshot: WalletAccountSnapshot) -> Bool {
        guard snapshot.ownership == .locusVault,
              WalletSolanaAssetIdentity.parse(snapshot.assetID)?.program == .spl,
              assets.contains(where: {
                  $0.id == snapshot.assetID && $0.networkID == snapshot.networkID
                      && $0.kind == .fungibleToken && $0.isVisibleByDefault
              }) else { return false }
        return policyAccounts(networkID: snapshot.networkID, capability: .fungibleTokenTransfer)
            .contains { $0.id == snapshot.accountID }
    }

    var canAuthorizeNativePolicy: Bool {
        WalletNetworkCatalog.all.contains {
            !policyAccounts(networkID: $0.id, capability: .nativeTransfer).isEmpty
        }
    }

    private func refreshStatus(clearErrorOnSuccess: Bool) async {
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
            replaceVaultAccounts(signerStatus.accounts)
            synchronizeAccountSnapshots(with: accounts)
            status = signerStatus.vaultState == .unlocked ? .unlocked : .locked
            if clearErrorOnSuccess { lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshConnections() async {
        await refreshConnections(clearErrorOnSuccess: true)
    }

    private func refreshConnections(clearErrorOnSuccess: Bool) async {
        guard uiFixtureHubState == nil else { return }
        guard buildSupportsWalletAlpha, walletEnabled, connectionsClient.isAvailable else {
            return
        }
        do {
            applyConnectionStatus(try await connectionsClient.status())
            if clearErrorOnSuccess { lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func availableExternalConnectionNetworks(
        for connector: WalletExternalConnectorID
    ) -> [WalletNetworkDescriptor] {
        guard let descriptor = WalletExternalConnectorCatalog.connectors.first(
            where: { $0.kind == connector }
        ) else { return [] }
        let connectionConnector = WalletConnectionConnector(rawValue: connector.rawValue)!
        return descriptor.supportedNetworks.compactMap(WalletNetworkCatalog.descriptor(id:))
            .filter { network in
                externalConnectionMethods(
                    connector: connectionConnector, networkID: network.id
                ).contains(.sendTransaction)
            }
            .sorted { lhs, rhs in
                if lhs.environment != rhs.environment {
                    return lhs.environment == .testnet
                }
                return lhs.displayName < rhs.displayName
            }
    }

    func externalConnectionMethods(
        connector: WalletConnectionConnector,
        networkID: String
    ) -> Set<WalletConnectionMethod> {
        let candidates: Set<WalletConnectionMethod> = switch connector {
        case .metamask:
            [.listAccounts, .switchNetwork, .sendTransaction, .signInWithEthereum]
        case .phantom:
            [.listAccounts, .switchNetwork, .sendTransaction, .signInWithSolana]
        case .slush:
            [.listAccounts, .switchNetwork, .sendTransaction]
        case .embeddedBrowser, .walletConnect:
            []
        }
        return Set(candidates.filter { method in
            Self.method(method, appliesTo: networkID, connector: connector)
                && (try? launchGate.authorizeConnection(
                    networkID: networkID,
                    connector: connector,
                    direction: .externalAccountToLocus,
                    method: method,
                    regionCode: regionCode
                )) != nil
                && reviewRegistry?.containsConnector(
                    connector,
                    direction: .externalAccountToLocus,
                    method: method
                ) == true
        })
    }

    @discardableResult
    func beginExternalWalletConnection(
        _ connector: WalletExternalConnectorID,
        networkID: String,
        methods requestedMethods: Set<WalletConnectionMethod>
    ) async -> Bool {
        guard walletEnabled, connectionsClient.isAvailable,
              let descriptor = WalletExternalConnectorCatalog.connectors.first(
                where: { $0.kind == connector }
              ), descriptor.supportedNetworks.contains(networkID) else {
            lastError = Error.connectionHelperUnavailable.localizedDescription
            return false
        }
        let connectionConnector = WalletConnectionConnector(rawValue: connector.rawValue)!
        let allowedMethods = externalConnectionMethods(
            connector: connectionConnector, networkID: networkID
        )
        guard !requestedMethods.isEmpty,
              requestedMethods.isSubset(of: allowedMethods),
              requestedMethods.contains(.listAccounts),
              requestedMethods.contains(.sendTransaction) else {
            lastError = WalletLaunchGateError.connectorNotReviewed.localizedDescription
            return false
        }
        let request = WalletConnectorPairingRequest(
            requestID: UUID().uuidString.lowercased(),
            connector: connectionConnector,
            direction: .externalAccountToLocus,
            requestedNetworkIDs: [networkID],
            requestedMethods: requestedMethods,
            expiresAt: Date().addingTimeInterval(10 * 60)
        )
        do {
            try authorizeConnectionRequest(request)
            applyConnectionStatus(try await connectionsClient.beginPairing(request))
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            await refreshConnections(clearErrorOnSuccess: false)
            return false
        }
    }

    @discardableResult
    func beginWalletConnectPairing(uri: String) async -> Bool {
        #if LOCUS_DIRECT_DOWNLOAD
        let pairingURI: String
        let pairingDigest: String
        do {
            pairingURI = try WalletPairingURIIntake.validated(uri)
            pairingDigest = WalletPairingURIIntake.digest(pairingURI)
            let now = Date()
            consumedPairingDigests = consumedPairingDigests.filter { $0.value > now }
            guard consumedPairingDigests[pairingDigest] == nil else {
                throw WalletConnectorRuntimeError.duplicateRequest
            }
            consumedPairingDigests[pairingDigest] = now.addingTimeInterval(7 * 24 * 60 * 60)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        #else
        let pairingURI = uri
        lastError = Error.connectionHelperUnavailable.localizedDescription
        return false
        #endif
        let candidates = accounts.filter {
            $0.ownership == .locusVault && !$0.networkIDs.isEmpty
        }
        let methods: Set<WalletConnectionMethod> = [
            .listAccounts, .sendTransaction, .signInWithEthereum,
            .signInWithSolana,
        ]
        let networkIDs = Set(Set(candidates.flatMap(\.networkIDs)).filter { networkID in
            methods.filter {
                Self.method($0, appliesTo: networkID, connector: .walletConnect)
            }.allSatisfy { method in
                (try? launchGate.authorizeConnection(
                    networkID: networkID,
                    connector: .walletConnect,
                    direction: .locusVaultToDapp,
                    method: method,
                    regionCode: regionCode
                )) != nil && reviewRegistry?.containsConnector(
                    .walletConnect,
                    direction: .locusVaultToDapp,
                    method: method
                ) == true
            }
        })
        let offered = candidates.compactMap { account -> WalletAccount? in
            let approvedNetworks = account.networkIDs.filter(networkIDs.contains)
            guard !approvedNetworks.isEmpty else { return nil }
            return WalletAccount(
                id: account.id, chain: account.chain, address: account.address,
                label: account.label, networkIDs: approvedNetworks,
                ownership: account.ownership
            )
        }
        guard walletEnabled, connectionsClient.isAvailable,
              !networkIDs.isEmpty, !offered.isEmpty else {
            lastError = Error.connectionHelperUnavailable.localizedDescription
            return false
        }
        let request = WalletConnectorPairingRequest(
            requestID: UUID().uuidString.lowercased(),
            connector: .walletConnect,
            direction: .locusVaultToDapp,
            requestedNetworkIDs: networkIDs,
            requestedMethods: methods,
            expiresAt: Date().addingTimeInterval(10 * 60),
            pairingURI: pairingURI,
            offeredAccounts: offered
        )
        do {
            try authorizeConnectionRequest(request)
            applyConnectionStatus(try await connectionsClient.beginPairing(request))
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            await refreshConnections(clearErrorOnSuccess: false)
            return false
        }
    }

    @discardableResult
    func beginWalletConnectPairing(deepLink: URL) async -> Bool {
        #if LOCUS_DIRECT_DOWNLOAD
        do {
            return await beginWalletConnectPairing(
                uri: try WalletPairingURIIntake.pairingURI(fromDeepLink: deepLink)
            )
        } catch {
            lastError = error.localizedDescription
            return false
        }
        #else
        _ = deepLink
        return false
        #endif
    }

    func resolveConnectionProposal(approved: Bool) {
        pendingConnectionProposal = nil
        let continuation = connectionProposalContinuation
        connectionProposalContinuation = nil
        continuation?.resume(returning: approved)
    }

    private func reviewConnectionProposal(
        _ proposal: WalletConnectionProposalReview
    ) async -> Bool {
        guard proposal.expiresAt > Date(), pendingConnectionProposal == nil,
              connectionProposalContinuation == nil else { return false }
        pendingConnectionProposal = proposal
        return await withCheckedContinuation { continuation in
            connectionProposalContinuation = continuation
        }
    }

    private func authorizeConnectionRequest(
        _ request: WalletConnectorPairingRequest
    ) throws {
        for networkID in request.requestedNetworkIDs {
            for method in request.requestedMethods
            where Self.method(
                method, appliesTo: networkID, connector: request.connector
            ) {
                try launchGate.authorizeConnection(
                    networkID: networkID,
                    connector: request.connector,
                    direction: request.direction,
                    method: method,
                    regionCode: regionCode
                )
                guard reviewRegistry?.containsConnector(
                    request.connector,
                    direction: request.direction,
                    method: method
                ) == true else {
                    throw WalletLaunchGateError.connectorNotReviewed
                }
            }
        }
    }

    private static func method(
        _ method: WalletConnectionMethod,
        appliesTo networkID: String,
        connector: WalletConnectionConnector
    ) -> Bool {
        guard let chain = WalletNetworkCatalog.descriptor(id: networkID)?.chain else {
            return false
        }
        switch method {
        case .signInWithEthereum: return chain == .evm
        case .signInWithSolana: return chain == .solana
        case .listAccounts:
            return connector != .walletConnect || chain != .evm
        case .switchNetwork:
            return connector != .walletConnect
        case .sendTransaction:
            return true
        }
    }

    func cancelConnectionPairing(id: String) async {
        do {
            applyConnectionStatus(try await connectionsClient.cancelPairing(requestID: id))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnectWalletConnection(id: String) async {
        cancelConnectionAuthority(connectionID: id, reason: .disconnected)
        if let index = connections.firstIndex(where: { $0.id == id }),
           let revoked = connections[index].transitioning(to: .revoked) {
            connections[index] = revoked
            try? publicStore?.upsertConnection(revoked)
        }
        do {
            applyConnectionStatus(try await connectionsClient.disconnect(connectionID: id))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func beginVaultCreation() async -> Bool {
        guard canCreateVault else {
            lastError = recoveryActionUnavailableMessage
            return false
        }
        return await runRecoveryCeremony(mode: .create)
    }

    @discardableResult
    func beginMainnetRotation() async -> Bool {
        guard canRotateForMainnet else {
            lastError = recoveryActionUnavailableMessage
            return false
        }
        return await runRecoveryCeremony(mode: .rotateForMainnet)
    }

    @discardableResult
    func beginVaultRestoration() async -> Bool {
        guard canCreateVault else {
            lastError = recoveryActionUnavailableMessage
            return false
        }
        return await runRecoveryCeremony(mode: .restore)
    }

    private func runRecoveryCeremony(mode: WalletRecoveryCeremonyMode) async -> Bool {
        guard !recoveryCeremonyActive, recoveryView.isAvailable else {
            lastError = recoveryActionUnavailableMessage
            return false
        }
        recoveryCeremonyActive = true
        recoveryPresentationState = .launching
        do {
            let result = try await recoveryView.present(mode: mode)
            recoveryCeremonyActive = false
            recoveryPresentationState = .idle
            switch result.outcome {
            case .completed:
                guard let signerStatus = result.signerStatus else {
                    throw Error.signerUnavailable
                }
                applyRecoveryStatus(signerStatus)
                lastError = nil
                return true
            case .canceled:
                await refreshStatus(clearErrorOnSuccess: false)
                lastError = nil
                return false
            case .failed:
                let recoveryError = result.error ?? "The recovery ceremony failed."
                await refreshStatus(clearErrorOnSuccess: false)
                lastError = recoveryError
                return false
            }
        } catch {
            recoveryCeremonyActive = false
            recoveryPresentationState = .idle
            let recoveryError = error.localizedDescription
            await refreshStatus(clearErrorOnSuccess: false)
            lastError = recoveryError
            return false
        }
    }

    var recoveryActionUnavailableMessage: String {
        if !recoveryView.isAvailable {
            return "The signed recovery helper is unavailable. Reinstall this direct-download build of Locus."
        }
        if recoveryCeremonyActive { return "A recovery window is already active." }
        return "Recovery is not available for the vault's current state."
    }

    func cancelRecoveryCeremony() {
        guard recoveryCeremonyActive else { return }
        recoveryView.cancel()
    }

    func bringRecoveryToFront() {
        guard recoveryCeremonyActive else { return }
        recoveryView.bringToFront()
    }

    func clearIncompleteRecovery() async {
        recoveryView.cancel()
        signer.lock()
        recoveryCeremonyActive = false
        recoveryPresentationState = .idle
        await refreshStatus(clearErrorOnSuccess: false)
    }

    private func applyRecoveryStatus(_ signerStatus: WalletSignerStatus) {
        vaultState = signerStatus.vaultState
        recoveryOnlyVaultAvailable = signerStatus.recoveryOnlyVaultAvailable
        replaceVaultAccounts(signerStatus.accounts)
        synchronizeAccountSnapshots(with: accounts)
        status = .locked
    }

    @discardableResult
    func deleteVault(confirmation: String) async -> Bool {
        do {
            let signerStatus = try await signer.deleteVault(confirmation: confirmation)
            lock()
            vaultState = signerStatus.vaultState
            recoveryOnlyVaultAvailable = signerStatus.recoveryOnlyVaultAvailable
            replaceVaultAccounts(signerStatus.accounts)
            synchronizeAccountSnapshots(with: accounts)
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
            replaceVaultAccounts(signerStatus.accounts)
            synchronizeAccountSnapshots(with: accounts)
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
            WalletSolanaBase58.decode(value, exactLength: 32) != nil
        case .sui:
            WalletSuiAddress.isCanonical(value)
        }
    }

    func checkRPCHealth() async {
        guard uiFixtureHubState == nil else { return }
        do { rpcHealthText = try await signer.rpcHealth() }
        catch { rpcHealthText = error.localizedDescription }
    }

    func refreshTransactionHistory() async {
        guard uiFixtureHubState == nil else { return }
        var changed = false
        var attemptedHeadNetworks: Set<String> = []
        var headBlocks: [String: UInt64] = [:]
        let recordIDs = transactionHistory.filter {
            $0.state == .submitted || $0.state == .broadcastUnknown
        }.map(\.id)
        for recordID in recordIDs {
            guard let original = transactionHistory.first(where: { $0.id == recordID }) else {
                continue
            }
            do {
                guard let chain = WalletNetworkCatalog.descriptor(
                    id: original.networkID
                )?.chain else { continue }
                #if LOCUS_DIRECT_DOWNLOAD
                if let action = original.expectedAction,
                   let semanticDigest = original.semanticDigest,
                   let account = accounts.first(where: {
                       $0.id == original.accountID
                           && $0.ownership.connectorID != nil
                           && $0.networkIDs.contains(original.networkID)
                   }) {
                    let reconciliation = try await WalletSubmittedTransactionReconciler.reconcile(
                        transactionID: original.transactionHash,
                        networkID: original.networkID,
                        account: account,
                        expectedAction: action,
                        expectedSemanticDigest: semanticDigest,
                        expectedContractAddress: original.expectedContractAddress,
                        expectedEVMTransactionDigest: original.expectedEVMTransactionDigest,
                        expectedEVMMaximumFeeBaseUnits: original.expectedEVMMaximumFeeBaseUnits,
                        reviewRegistry: reviewRegistry
                    )
                    guard let index = transactionHistory.firstIndex(where: {
                        $0.id == recordID
                    }) else { continue }
                    transactionHistory[index].lastCheckedAt = Date()
                    switch reconciliation {
                    case .pending:
                        transactionHistory[index].state = .submitted
                        transactionHistory[index].finality = .pending
                    case .confirmed(let blockNumber, let finalized):
                        transactionHistory[index].state = .confirmed
                        transactionHistory[index].blockNumber = blockNumber
                        transactionHistory[index].finality = finalized ? .finalized : .confirmed
                        transactionHistory[index].detail = nil
                    case .failed(let detail):
                        transactionHistory[index].state = .failed
                        transactionHistory[index].finality = .failed
                        transactionHistory[index].detail = String(detail.prefix(512))
                    }
                    changed = true
                    continue
                }
                #endif
                guard signer.isAvailable else { continue }
                let result: Any
                switch chain {
                case .evm:
                    result = try await signer.browserRPC(
                        networkID: original.networkID,
                        method: "eth_getTransactionReceipt",
                        params: [original.transactionHash]
                    )
                case .solana:
                    result = try await signer.browserRPC(
                        networkID: original.networkID,
                        method: "getSignatureStatuses",
                        params: [
                            [original.transactionHash],
                            ["searchTransactionHistory": true],
                        ]
                    )
                case .sui:
                    continue
                }
                guard let index = transactionHistory.firstIndex(where: { $0.id == recordID }) else {
                    continue
                }
                transactionHistory[index].lastCheckedAt = Date()
                if chain == .solana {
                    guard let envelope = result as? [String: Any],
                          let values = envelope["value"] as? [Any],
                          values.count == 1 else { continue }
                    if values[0] is NSNull {
                        changed = true
                        continue
                    }
                    guard let status = values[0] as? [String: Any],
                          let confirmation = status["confirmationStatus"] as? String,
                          ["processed", "confirmed", "finalized"].contains(
                              confirmation
                          ) else { continue }
                    if let error = status["err"], !(error is NSNull) {
                        transactionHistory[index].state = .failed
                        transactionHistory[index].finality = .failed
                        transactionHistory[index].detail = "Solana execution failed."
                    } else {
                        transactionHistory[index].state = confirmation == "processed"
                            ? .submitted : .confirmed
                        transactionHistory[index].finality = confirmation == "finalized"
                            ? .finalized : (confirmation == "confirmed" ? .confirmed : .pending)
                        transactionHistory[index].detail = nil
                    }
                    if let slot = status["slot"] as? NSNumber,
                       CFGetTypeID(slot) != CFBooleanGetTypeID(),
                       slot.decimalValue >= 0,
                       slot.decimalValue == Decimal(slot.uint64Value) {
                        transactionHistory[index].blockNumber = String(slot.uint64Value)
                    }
                    changed = true
                    continue
                }
                if result is NSNull {
                    changed = true
                    continue
                }
                guard let receipt = result as? [String: Any],
                      let status = receipt["status"] as? String else { continue }
                transactionHistory[index].state = status.lowercased() == "0x1" ? .confirmed : .failed
                transactionHistory[index].blockNumber = receipt["blockNumber"] as? String
                if status.lowercased() == "0x1" {
                    if !attemptedHeadNetworks.contains(original.networkID) {
                        attemptedHeadNetworks.insert(original.networkID)
                        let headResponse = try? await signer.browserRPC(
                            networkID: original.networkID,
                            method: "eth_blockNumber", params: []
                        )
                        if let head = headResponse as? String,
                           let value = WalletEthereumQuantity.hexToUInt64(head) {
                            headBlocks[original.networkID] = value
                        }
                    }
                    transactionHistory[index].finality = Self.evmFinality(
                        block: receipt["blockNumber"] as? String,
                        head: headBlocks[original.networkID]
                    )
                } else {
                    transactionHistory[index].finality = .failed
                }
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
        if !signer.isAvailable {
            if changed { persistActivity() }
            return
        }
        let evmNetworks = accounts.filter { $0.chain == .evm }.flatMap { account in
            account.networkIDs.compactMap { networkID -> (WalletAccount, String)? in
                WalletNetworkCatalog.descriptor(id: networkID)?.chain == .evm
                    ? (account, networkID) : nil
            }
        }
        for (account, networkID) in evmNetworks {
            do {
                let result = try await signer.performRead(
                    tool: "wallet_get_activity",
                    arguments: ["account_id": account.id, "network_id": networkID]
                )
                guard let rows = result["activity"] as? [[String: Any]], rows.count <= 500 else {
                    continue
                }
                let indexedHead = (result["head_block_number"] as? String).flatMap(UInt64.init)
                let existingByHash = Dictionary(
                    grouping: transactionHistory, by: { $0.transactionHash.lowercased() }
                )
                var seenIndexedIDs: Set<String> = []
                let indexed = rows.compactMap {
                    indexedActivityRecord(
                        $0, account: account, networkID: networkID,
                        headBlock: indexedHead, existingByHash: existingByHash
                    )
                }.filter {
                    seenIndexedIDs.insert($0.id).inserted
                }
                guard !indexed.isEmpty else { continue }
                let indexedHashes = Set(indexed.map { $0.transactionHash.lowercased() })
                let replacedIDs = transactionHistory.filter {
                    $0.networkID == networkID && $0.accountID == account.id
                        && indexedHashes.contains($0.transactionHash.lowercased())
                }.map(\.id)
                transactionHistory.removeAll {
                    $0.networkID == networkID && $0.accountID == account.id
                        && indexedHashes.contains($0.transactionHash.lowercased())
                }
                for id in replacedIDs { try? publicStore?.deleteActivity(id: id) }
                transactionHistory.append(contentsOf: indexed)
                quarantineDiscoveredAssets(from: rows, networkID: networkID)
                changed = true
            } catch {
                continue
            }
        }
        let solanaNetworks = accounts.filter { $0.chain == .solana }.flatMap { account in
            account.networkIDs.compactMap { networkID -> (WalletAccount, String)? in
                WalletNetworkCatalog.descriptor(id: networkID)?.chain == .solana
                    ? (account, networkID) : nil
            }
        }
        for (account, networkID) in solanaNetworks {
            do {
                let result = try await signer.performRead(
                    tool: "wallet_get_activity",
                    arguments: ["account_id": account.id, "network_id": networkID]
                )
                guard let rows = result["activity"] as? [[String: Any]],
                      rows.count <= 500 else { continue }
                let existingByHash = Dictionary(
                    grouping: transactionHistory, by: \.transactionHash
                )
                var seenIDs: Set<String> = []
                var indexed: [WalletActivityRecord] = []
                var validBatch = true
                for row in rows {
                    guard let record = indexedSolanaActivityRecord(
                        row, account: account, networkID: networkID,
                        existingByHash: existingByHash
                    ), seenIDs.insert(record.id).inserted else {
                        validBatch = false
                        break
                    }
                    indexed.append(record)
                }
                guard validBatch, !indexed.isEmpty else { continue }
                let hashes = Set(indexed.map(\.transactionHash))
                let replacedIDs = transactionHistory.filter {
                    $0.networkID == networkID && $0.accountID == account.id
                        && hashes.contains($0.transactionHash)
                }.map(\.id)
                transactionHistory.removeAll {
                    $0.networkID == networkID && $0.accountID == account.id
                        && hashes.contains($0.transactionHash)
                }
                for id in replacedIDs { try? publicStore?.deleteActivity(id: id) }
                transactionHistory.append(contentsOf: indexed)
                quarantineSolanaActivityAssets(from: rows, networkID: networkID)
                changed = true
            } catch {
                continue
            }
        }
        let suiNetworks = accounts.filter { $0.chain == .sui }.flatMap { account in
            account.networkIDs.compactMap { networkID -> (WalletAccount, String)? in
                WalletNetworkCatalog.descriptor(id: networkID)?.chain == .sui
                    ? (account, networkID) : nil
            }
        }
        for (account, networkID) in suiNetworks {
            do {
                let result = try await signer.performRead(
                    tool: "wallet_get_activity",
                    arguments: ["account_id": account.id, "network_id": networkID]
                )
                guard let rows = result["activity"] as? [[String: Any]],
                      rows.count <= 50_500 else { continue }
                let existingByHash = Dictionary(
                    grouping: transactionHistory, by: \.transactionHash
                )
                var seenIDs: Set<String> = []
                var indexed: [WalletActivityRecord] = []
                var validBatch = true
                for row in rows {
                    guard let record = indexedSuiActivityRecord(
                        row, account: account, networkID: networkID,
                        existingByHash: existingByHash
                    ), seenIDs.insert(record.id).inserted else {
                        validBatch = false
                        break
                    }
                    indexed.append(record)
                }
                guard validBatch, !indexed.isEmpty else { continue }
                let hashes = Set(indexed.map(\.transactionHash))
                let replacedIDs = transactionHistory.filter {
                    $0.networkID == networkID && $0.accountID == account.id
                        && hashes.contains($0.transactionHash)
                }.map(\.id)
                transactionHistory.removeAll {
                    $0.networkID == networkID && $0.accountID == account.id
                        && hashes.contains($0.transactionHash)
                }
                for id in replacedIDs { try? publicStore?.deleteActivity(id: id) }
                transactionHistory.append(contentsOf: indexed)
                quarantineSuiActivityAssets(from: rows, networkID: networkID)
                changed = true
            } catch {
                continue
            }
        }
        if changed {
            transactionHistory.sort { $0.submittedAt > $1.submittedAt }
            if transactionHistory.count > 500 {
                let removed = transactionHistory.suffix(from: 500).map(\.id)
                transactionHistory.removeLast(transactionHistory.count - 500)
                for id in removed { try? publicStore?.deleteActivity(id: id) }
            }
        }
        if changed { persistActivity() }
    }

    private func indexedActivityRecord(
        _ row: [String: Any],
        account: WalletAccount,
        networkID: String,
        headBlock: UInt64?,
        existingByHash: [String: [WalletActivityRecord]]
    ) -> WalletActivityRecord? {
        guard let rawID = row["id"] as? String,
              !rawID.isEmpty, rawID.utf8.count <= 256,
              let hash = row["transaction_hash"] as? String,
              hash.count == 66, hash.hasPrefix("0x"),
              hash.dropFirst(2).allSatisfy(\.isHexDigit),
              let block = WalletBaseUnits.normalize(
                  row["block_number"] as? String ?? ""
              ),
              let timestamp = row["occurred_at"] as? TimeInterval,
              timestamp.isFinite, timestamp >= 0,
              timestamp <= Date().addingTimeInterval(300).timeIntervalSince1970,
              let from = row["from"] as? String, Self.validAddress(from, chain: .evm),
              let to = row["to"] as? String, Self.validAddress(to, chain: .evm),
              let assetID = row["asset_id"] as? String,
              let amount = WalletBaseUnits.normalize(
                  row["amount_base_units"] as? String ?? ""
              ),
              let kindValue = row["asset_kind"] as? String,
              let kind = WalletAssetKind(rawValue: kindValue),
              validIndexedAssetID(assetID, kind: kind, networkID: networkID) else {
            return nil
        }
        let accountAddress = account.address.lowercased()
        let normalizedFrom = from.lowercased()
        let normalizedTo = to.lowercased()
        let direction: WalletActivityDirection
        if normalizedFrom == accountAddress && normalizedTo == accountAddress {
            direction = .selfTransfer
        } else if normalizedTo == accountAddress {
            direction = .inbound
        } else if normalizedFrom == accountAddress {
            direction = .outbound
        } else {
            return nil
        }
        let symbol = sanitizedProviderLabel(
            row["asset_symbol"], fallback: "Asset", limit: 32
        )
        let prior = existingByHash[hash.lowercased()]?.first
        let actionKind: WalletActionKind = switch kind {
        case .native: .nativeTransfer
        case .fungibleToken: .fungibleTokenTransfer
        case .nft, .collectible: .nftTransfer
        }
        let verb = switch direction {
        case .inbound: "Received"
        case .outbound: "Sent"
        case .selfTransfer: "Moved"
        }
        return WalletActivityRecord(
            id: "indexed:\(networkID):\(rawID)",
            intentID: prior?.intentID ?? "indexed:\(rawID)",
            transactionHash: hash.lowercased(), networkID: networkID,
            accountID: account.id, summary: "\(verb) \(symbol)",
            submittedAt: Date(timeIntervalSince1970: timestamp),
            state: .confirmed, blockNumber: block, lastCheckedAt: Date(), detail: nil,
            direction: direction, source: prior?.source, actionKind: actionKind,
            assetID: assetID, amountBaseUnits: amount,
            finality: Self.evmFinality(block: block, head: headBlock),
            expiresAt: nil, replacedByTransactionHash: nil
        )
    }

    private func indexedSolanaActivityRecord(
        _ row: [String: Any],
        account: WalletAccount,
        networkID: String,
        existingByHash: [String: [WalletActivityRecord]]
    ) -> WalletActivityRecord? {
        guard let rawID = row["id"] as? String,
              !rawID.isEmpty, rawID.utf8.count <= 1_024,
              let signature = row["transaction_hash"] as? String,
              WalletSolanaBase58.decode(signature, exactLength: 64) != nil,
              let slot = WalletBaseUnits.normalize(
                  row["block_number"] as? String ?? ""
              ), UInt64(slot) != nil,
              let timestamp = row["occurred_at"] as? TimeInterval,
              timestamp.isFinite, timestamp >= 1_232_000_000,
              timestamp <= Date().addingTimeInterval(300).timeIntervalSince1970,
              let status = row["status"] as? String,
              status == "confirmed" || status == "failed",
              row["owner"] as? String == account.address,
              let fee = WalletBaseUnits.normalize(
                  row["fee_base_units"] as? String ?? ""
              ), UInt64(fee) != nil else { return nil }
        let prior = existingByHash[signature]?.first
        var direction: WalletActivityDirection?
        var actionKind: WalletActionKind?
        var assetID: String?
        var amount: String?
        var summary = status == "failed"
            ? "Failed Solana transaction" : "Solana transaction"
        let hasAssetFields = row["asset_id"] != nil
            || row["asset_reference"] != nil || row["asset_kind"] != nil
            || row["amount_base_units"] != nil || row["direction"] != nil
        if status == "confirmed", hasAssetFields {
            guard let rawAssetID = row["asset_id"] as? String,
                  let rawKind = row["asset_kind"] as? String,
                  let kind = WalletAssetKind(rawValue: rawKind),
                  let rawAmount = row["amount_base_units"] as? String,
                  WalletBaseUnits.normalize(rawAmount) == rawAmount,
                  rawAmount != "0",
                  let rawDirection = row["direction"] as? String,
                  let parsedDirection = WalletActivityDirection(
                    rawValue: rawDirection
                  ) else { return nil }
            let symbol: String
            if rawAssetID == WalletNetworkCatalog.descriptor(
                id: networkID
            )?.nativeAssetID {
                guard kind == .native, row["asset_reference"] == nil,
                      parsedDirection != .selfTransfer else { return nil }
                actionKind = .nativeTransfer
                symbol = "SOL"
            } else if let identity = WalletSolanaAssetIdentity.parse(rawAssetID) {
                guard identity.networkID == networkID,
                      kind == .fungibleToken,
                      row["asset_reference"] as? String == identity.mint,
                      parsedDirection != .selfTransfer else { return nil }
                actionKind = .fungibleTokenTransfer
                symbol = "token"
            } else if let identity = WalletSolanaCollectibleIdentity.parse(
                rawAssetID
            ) {
                guard identity.networkID == networkID, identity.standard == .core,
                      kind == .nft || kind == .collectible,
                      row["asset_reference"] as? String == identity.address,
                      rawAmount == "1" else { return nil }
                actionKind = .nftTransfer
                symbol = "Core asset"
            } else {
                return nil
            }
            let verb = switch parsedDirection {
            case .inbound: "Received"
            case .outbound: "Sent"
            case .selfTransfer: "Moved"
            }
            summary = "\(verb) \(symbol)"
            direction = parsedDirection
            assetID = rawAssetID
            amount = rawAmount
        } else if hasAssetFields {
            return nil
        }
        return WalletActivityRecord(
            id: "indexed:\(networkID):\(rawID)",
            intentID: prior?.intentID ?? "indexed:\(signature)",
            transactionHash: signature, networkID: networkID,
            accountID: account.id, summary: summary,
            submittedAt: Date(timeIntervalSince1970: timestamp),
            state: status == "failed" ? .failed : .confirmed,
            blockNumber: slot, lastCheckedAt: Date(),
            detail: fee == "0" ? nil : "Network fee: \(fee) lamports",
            direction: direction, source: prior?.source,
            actionKind: actionKind, assetID: assetID,
            amountBaseUnits: amount,
            finality: status == "failed" ? .failed : .finalized,
            expiresAt: nil, replacedByTransactionHash: nil
        )
    }

    private func indexedSuiActivityRecord(
        _ row: [String: Any],
        account: WalletAccount,
        networkID: String,
        existingByHash: [String: [WalletActivityRecord]]
    ) -> WalletActivityRecord? {
        guard let rawID = row["id"] as? String,
              !rawID.isEmpty, rawID.utf8.count <= 1_024,
              let digest = row["transaction_hash"] as? String,
              WalletSolanaBase58.decode(digest, exactLength: 32) != nil,
              let block = WalletBaseUnits.normalize(
                  row["block_number"] as? String ?? ""
              ),
              let timestamp = row["occurred_at"] as? TimeInterval,
              timestamp.isFinite, timestamp >= 0,
              timestamp <= Date().addingTimeInterval(300).timeIntervalSince1970,
              let status = row["status"] as? String,
              status == "confirmed" || status == "failed",
              row["owner"] as? String == account.address else { return nil }
        if let sender = row["sender"] as? String,
           !WalletSuiAddress.isCanonical(sender) { return nil }
        let prior = existingByHash[digest]?.first
        var direction: WalletActivityDirection?
        var actionKind: WalletActionKind?
        var assetID: String?
        var amount: String?
        var summary = status == "failed" ? "Failed Sui transaction" : "Sui transaction"
        if status == "confirmed", let rawAssetID = row["asset_id"] as? String {
            guard let kindValue = row["asset_kind"] as? String,
                  let kind = WalletAssetKind(rawValue: kindValue),
                  let rawAmount = row["amount_base_units"] as? String,
                  let normalizedAmount = WalletBaseUnits.normalize(rawAmount),
                  normalizedAmount == rawAmount, normalizedAmount != "0",
                  let rawDirection = row["direction"] as? String,
                  let parsedDirection = WalletActivityDirection(rawValue: rawDirection),
                  parsedDirection != .selfTransfer else { return nil }
            if let identity = WalletSuiAssetIdentity.parse(rawAssetID) {
                guard identity.networkID == networkID,
                      row["asset_reference"] as? String == identity.coinType,
                      (identity.coinType == WalletSuiAssetIdentity.nativeCoinType
                          ? kind == .native : kind == .fungibleToken),
                      row["object_type"] == nil,
                      row["has_public_transfer"] == nil else { return nil }
                actionKind = kind == .native ? .nativeTransfer : .fungibleTokenTransfer
                let symbol = identity.coinType == WalletSuiAssetIdentity.nativeCoinType
                    ? "SUI"
                    : String(
                        (identity.coinType.components(separatedBy: "::").last ?? "COIN")
                            .prefix(32)
                    )
                summary = parsedDirection == .inbound
                    ? "Received \(symbol)" : "Sent \(symbol)"
            } else {
                guard let identity = WalletSuiObjectIdentity.parse(rawAssetID),
                      identity.networkID == networkID,
                      row["asset_reference"] as? String == identity.objectID,
                      kind == .nft || kind == .collectible,
                      normalizedAmount == "1",
                      let objectType = row["object_type"] as? String,
                      WalletSuiAssetIdentity.isCanonicalCoinType(objectType),
                      !(objectType.hasPrefix("0x2::coin::Coin<")
                        && objectType.hasSuffix(">")),
                      row["has_public_transfer"] is Bool else { return nil }
                let symbol = String(
                    (objectType.components(separatedBy: "::").last ?? "OBJECT")
                        .prefix(32)
                )
                actionKind = .nftTransfer
                summary = parsedDirection == .inbound
                    ? "Received \(symbol)" : "Sent \(symbol)"
            }
            direction = parsedDirection
            assetID = rawAssetID
            amount = normalizedAmount
        } else if row["asset_id"] != nil || row["asset_reference"] != nil
                    || row["asset_kind"] != nil || row["amount_base_units"] != nil
                    || row["direction"] != nil || row["object_type"] != nil
                    || row["has_public_transfer"] != nil {
            return nil
        }
        return WalletActivityRecord(
            id: "indexed:\(networkID):\(rawID)",
            intentID: prior?.intentID ?? "indexed:\(digest)",
            transactionHash: digest, networkID: networkID,
            accountID: account.id, summary: summary,
            submittedAt: Date(timeIntervalSince1970: timestamp),
            state: status == "failed" ? .failed : .confirmed,
            blockNumber: block, lastCheckedAt: Date(), detail: nil,
            direction: direction, source: prior?.source,
            actionKind: actionKind, assetID: assetID,
            amountBaseUnits: amount,
            finality: status == "failed" ? .failed : .finalized,
            expiresAt: nil, replacedByTransactionHash: nil
        )
    }

    private func quarantineSolanaActivityAssets(
        from rows: [[String: Any]],
        networkID: String
    ) {
        for row in rows {
            guard row["status"] as? String == "confirmed",
                  let assetID = row["asset_id"] as? String,
                  assets.contains(where: { $0.id == assetID }) == false else {
                continue
            }
            let asset: WalletAsset
            if let identity = WalletSolanaAssetIdentity.parse(assetID) {
                guard identity.networkID == networkID,
                      row["asset_reference"] as? String == identity.mint,
                      row["asset_kind"] as? String
                        == WalletAssetKind.fungibleToken.rawValue else { continue }
                asset = WalletAsset(
                    canonicalID: assetID, networkID: networkID,
                    chain: .solana, kind: .fungibleToken,
                    reference: identity.mint, name: "Unknown Solana token",
                    symbol: "TOKEN", decimals: nil,
                    trust: .quarantined, manifestRevision: 0
                )
            } else {
                guard let identity = WalletSolanaCollectibleIdentity.parse(assetID),
                      identity.networkID == networkID, identity.standard == .core,
                      row["asset_reference"] as? String == identity.address,
                      let rawKind = row["asset_kind"] as? String,
                      rawKind == WalletAssetKind.nft.rawValue
                        || rawKind == WalletAssetKind.collectible.rawValue,
                      row["amount_base_units"] as? String == "1" else { continue }
                asset = WalletAsset(
                    canonicalID: assetID, networkID: networkID,
                    chain: .solana, kind: .collectible,
                    reference: identity.address, name: "Unknown Core asset",
                    symbol: "CORE", decimals: nil,
                    trust: .quarantined, manifestRevision: 0
                )
            }
            assets.append(asset)
            try? publicStore?.upsertAsset(asset)
        }
    }

    private func quarantineSuiActivityAssets(
        from rows: [[String: Any]],
        networkID: String
    ) {
        for row in rows {
            guard row["status"] as? String == "confirmed",
                  let assetID = row["asset_id"] as? String,
                  assets.contains(where: { $0.id == assetID }) == false else {
                continue
            }
            let asset: WalletAsset
            if let identity = WalletSuiAssetIdentity.parse(assetID) {
                guard identity.networkID == networkID,
                      identity.coinType != WalletSuiAssetIdentity.nativeCoinType,
                      row["asset_reference"] as? String == identity.coinType,
                      row["asset_kind"] as? String
                        == WalletAssetKind.fungibleToken.rawValue else { continue }
                let symbol = String(
                    (identity.coinType.components(separatedBy: "::").last ?? "COIN")
                        .prefix(32)
                )
                asset = WalletAsset(
                    canonicalID: assetID, networkID: networkID,
                    chain: .sui, kind: .fungibleToken,
                    reference: identity.coinType, name: "Unknown Sui Coin",
                    symbol: symbol, decimals: nil,
                    trust: .quarantined, manifestRevision: 0
                )
            } else {
                guard let identity = WalletSuiObjectIdentity.parse(assetID),
                      identity.networkID == networkID,
                      row["asset_reference"] as? String == identity.objectID,
                      row["asset_kind"] as? String
                        == WalletAssetKind.collectible.rawValue,
                      row["amount_base_units"] as? String == "1",
                      let objectType = row["object_type"] as? String,
                      WalletSuiAssetIdentity.isCanonicalCoinType(objectType),
                      row["has_public_transfer"] is Bool else { continue }
                let symbol = String(
                    (objectType.components(separatedBy: "::").last ?? "OBJECT")
                        .prefix(32)
                )
                asset = WalletAsset(
                    canonicalID: assetID, networkID: networkID,
                    chain: .sui, kind: .collectible,
                    reference: identity.objectID, name: "Unknown Sui object",
                    symbol: symbol, decimals: nil,
                    trust: .quarantined, manifestRevision: 0
                )
            }
            assets.append(asset)
            try? publicStore?.upsertAsset(asset)
        }
    }

    private static func evmFinality(block: String?, head: UInt64?) -> WalletActivityFinality {
        guard let block, let head else { return .confirmed }
        let blockNumber = block.lowercased().hasPrefix("0x")
            ? WalletEthereumQuantity.hexToUInt64(block) : UInt64(block)
        guard let blockNumber else { return .confirmed }
        guard head >= blockNumber else { return .confirmed }
        return head - blockNumber >= 64 ? .finalized : .confirmed
    }

    private func quarantineDiscoveredAssets(
        from rows: [[String: Any]],
        networkID: String
    ) {
        for row in rows {
            guard let assetID = row["asset_id"] as? String,
                  assets.contains(where: { $0.id == assetID }) == false,
                  let kindValue = row["asset_kind"] as? String,
                  let kind = WalletAssetKind(rawValue: kindValue), kind != .native,
                  validIndexedAssetID(assetID, kind: kind, networkID: networkID),
                  let reference = row["asset_reference"] as? String,
                  Self.validAddress(reference, chain: .evm) else { continue }
            let decimals = row["asset_decimals"] as? Int
            guard decimals.map({ (0...255).contains($0) }) != false else { continue }
            let asset = WalletAsset(
                canonicalID: assetID, networkID: networkID, chain: .evm,
                kind: kind, reference: reference.lowercased(),
                name: sanitizedProviderLabel(
                    row["asset_name"], fallback: "Unknown asset", limit: 128
                ),
                symbol: sanitizedProviderLabel(
                    row["asset_symbol"], fallback: "UNKNOWN", limit: 32
                ),
                decimals: decimals, trust: .quarantined, manifestRevision: 0
            )
            assets.append(asset)
            try? publicStore?.upsertAsset(asset)
        }
    }

    private func validIndexedAssetID(
        _ assetID: String,
        kind: WalletAssetKind,
        networkID: String
    ) -> Bool {
        if kind == .native {
            return assetID == WalletNetworkCatalog.descriptor(id: networkID)?.nativeAssetID
        }
        guard let identity = WalletEVMAssetIdentity.parse(assetID),
              identity.networkID == networkID else { return false }
        switch (kind, identity.standard) {
        case (.fungibleToken, .erc20): return identity.tokenID == nil
        case (.nft, .erc721), (.collectible, .erc721): return identity.tokenID != nil
        case (.nft, .erc1155), (.collectible, .erc1155): return identity.tokenID != nil
        default: return false
        }
    }

    private func sanitizedProviderLabel(
        _ value: Any?, fallback: String, limit: Int
    ) -> String {
        guard let value = value as? String else { return fallback }
        let scalars = value.unicodeScalars.filter {
            ($0.value >= 0x20 && $0.value != 0x7f) || $0.value == 0x09
        }.prefix(limit)
        let normalized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? fallback : normalized
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
            replaceVaultAccounts(publicAccounts)
            var discoveredAssetBalances: [String: String] = [:]
            for account in publicAccounts {
                for networkID in account.networkIDs where WalletNetworkCatalog.descriptor(
                    id: networkID
                )?.chain == account.chain {
                    guard let result = try? await signer.performRead(
                        tool: "wallet_get_assets",
                        arguments: [
                            "account_id": account.id,
                            "network_id": networkID,
                        ]
                    ), let rows = result["assets"] as? [[String: Any]],
                       rows.count <= 10_000 else { continue }
                    let reconciled = switch account.chain {
                    case .evm:
                        reconcileEVMAssets(
                            rows, accountID: account.id, networkID: networkID
                        )
                    case .solana:
                        reconcileSolanaAssets(
                            rows, accountID: account.id, networkID: networkID
                        )
                    case .sui:
                        reconcileSuiAssets(
                            rows, accountID: account.id, networkID: networkID
                        )
                    }
                    discoveredAssetBalances.merge(
                        reconciled, uniquingKeysWith: { _, latest in latest }
                    )
                }
            }
            synchronizeAccountSnapshots(with: accounts)
            for snapshot in accountSnapshots {
                if let discovered = discoveredAssetBalances[snapshot.id] {
                    guard let index = accountSnapshots.firstIndex(where: {
                        $0.id == snapshot.id
                    }) else { continue }
                    accountSnapshots[index].balanceBaseUnits = discovered
                    accountSnapshots[index].refreshedAt = Date()
                    accountSnapshots[index].freshness = .current
                    continue
                }
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

    private func reconcileEVMAssets(
        _ rows: [[String: Any]],
        accountID: String,
        networkID: String
    ) -> [String: String] {
        guard WalletNetworkCatalog.descriptor(id: networkID)?.chain == .evm else {
            return [:]
        }
        struct Candidate {
            let identity: WalletEVMAssetIdentity
            let kind: WalletAssetKind
            let balance: String
            let name: String
            let symbol: String
            let decimals: Int?
        }
        var candidates: [Candidate] = []
        var seenAssetIDs: Set<String> = []
        var nftSnapshot: (block: String, hash: String)?
        for row in rows {
            guard let assetID = row["asset_id"] as? String,
                  seenAssetIDs.insert(assetID).inserted,
                  let identity = WalletEVMAssetIdentity.parse(assetID),
                  identity.networkID == networkID,
                  assetID == identity.canonicalID,
                  let reference = row["reference"] as? String,
                  reference == identity.contractAddress,
                  let rawBalance = row["balance_base_units"] as? String,
                  let balance = WalletBaseUnits.normalize(rawBalance),
                  balance == rawBalance, balance != "0" else { return [:] }
            switch identity.standard {
            case .erc20:
                guard identity.tokenID == nil,
                      row["asset_kind"] as? String
                        == WalletAssetKind.fungibleToken.rawValue,
                      row["standard"] == nil, row["token_id"] == nil,
                      row["snapshot_block_number"] == nil,
                      row["snapshot_block_hash"] == nil else { return [:] }
                let abbreviated = "\(identity.contractAddress.prefix(6))…\(identity.contractAddress.suffix(4))"
                candidates.append(Candidate(
                    identity: identity, kind: .fungibleToken, balance: balance,
                    name: "Unknown ERC-20 token", symbol: abbreviated,
                    decimals: nil
                ))
            case .erc721, .erc1155:
                guard let tokenID = identity.tokenID,
                      row["asset_kind"] as? String
                        == WalletAssetKind.collectible.rawValue,
                      row["standard"] as? String == identity.standard.rawValue,
                      row["token_id"] as? String == tokenID,
                      identity.standard != .erc721 || balance == "1",
                      let block = row["snapshot_block_number"] as? String,
                      WalletBaseUnits.normalize(block) == block,
                      let hash = row["snapshot_block_hash"] as? String,
                      hash.count == 66, hash.hasPrefix("0x"),
                      hash.dropFirst(2).allSatisfy(\.isHexDigit) else { return [:] }
                if let nftSnapshot {
                    guard nftSnapshot.block == block,
                          nftSnapshot.hash.caseInsensitiveCompare(hash) == .orderedSame else {
                        return [:]
                    }
                } else {
                    nftSnapshot = (block, hash.lowercased())
                }
                candidates.append(Candidate(
                    identity: identity, kind: .collectible, balance: balance,
                    name: "Unknown Ethereum collectible",
                    symbol: "\(identity.standard.rawValue.uppercased()) #\(tokenID.prefix(16))",
                    decimals: 0
                ))
            }
        }
        for candidate in candidates {
            let identity = candidate.identity
            let assetID = identity.canonicalID
            if let known = assets.first(where: { $0.id == assetID }) {
                guard known.chain == .evm, known.networkID == networkID,
                      known.kind == candidate.kind
                        || (candidate.kind == .collectible && known.kind == .nft),
                      known.reference?.lowercased() == identity.contractAddress,
                      candidate.kind != .collectible
                        || known.decimals == nil || known.decimals == 0 else {
                    return [:]
                }
            }
        }
        var balances: [String: String] = [:]
        for candidate in candidates {
            let identity = candidate.identity
            let assetID = identity.canonicalID
            if assets.contains(where: { $0.id == assetID }) == false {
                let asset = WalletAsset(
                    canonicalID: assetID, networkID: networkID,
                    chain: .evm, kind: candidate.kind,
                    reference: identity.contractAddress,
                    name: candidate.name, symbol: candidate.symbol,
                    decimals: candidate.decimals,
                    trust: .quarantined, manifestRevision: 0
                )
                assets.append(asset)
                try? publicStore?.upsertAsset(asset)
            }
            balances["\(accountID):\(networkID):\(assetID)"] = candidate.balance
        }
        return balances
    }

    private func reconcileSolanaAssets(
        _ rows: [[String: Any]],
        accountID: String,
        networkID: String
    ) -> [String: String] {
        var balances: [String: String] = [:]
        for row in rows {
            guard let assetID = row["asset_id"] as? String else { continue }
            if let collectible = WalletSolanaCollectibleIdentity.parse(assetID) {
                guard collectible.networkID == networkID,
                      row["asset_kind"] as? String
                        == WalletAssetKind.collectible.rawValue,
                      row["collectible_standard"] as? String
                        == collectible.standard.rawValue,
                      row["reference"] as? String == collectible.address,
                      row["balance_base_units"] as? String == "1",
                      row["decimals"] as? Int == 0,
                      row["account_count"] as? Int == 1,
                      row["has_frozen_account"] is Bool,
                      row["delegated"] is Bool,
                      let name = row["name"] as? String,
                      !name.isEmpty, name.count <= 128,
                      let symbol = row["symbol"] as? String,
                      !symbol.isEmpty, symbol.count <= 32 else { continue }
                if let known = assets.first(where: { $0.id == assetID }) {
                    guard known.chain == .solana,
                          known.networkID == networkID,
                          known.reference == collectible.address,
                          known.kind == .nft || known.kind == .collectible,
                          known.decimals == nil || known.decimals == 0 else {
                        continue
                    }
                } else {
                    let asset = WalletAsset(
                        canonicalID: assetID, networkID: networkID,
                        chain: .solana, kind: .collectible,
                        reference: collectible.address, name: name,
                        symbol: symbol, decimals: 0, trust: .quarantined,
                        manifestRevision: 0
                    )
                    assets.append(asset)
                    try? publicStore?.upsertAsset(asset)
                }
                balances["\(accountID):\(networkID):\(assetID)"] = "1"
                continue
            }
            guard
                  let identity = WalletSolanaAssetIdentity.parse(assetID),
                  identity.networkID == networkID,
                  let mint = row["mint"] as? String, mint == identity.mint,
                  row["token_program"] as? String == identity.program.rawValue,
                  let rawBalance = row["balance_base_units"] as? String,
                  let balance = WalletBaseUnits.normalize(rawBalance),
                  balance == rawBalance,
                  let decimals = row["decimals"] as? Int,
                  (0...255).contains(decimals),
                  let accountCount = row["account_count"] as? Int,
                  (1...10_000).contains(accountCount),
                  row["has_frozen_account"] is Bool else { continue }
            if let known = assets.first(where: { $0.id == assetID }) {
                guard known.chain == .solana, known.networkID == networkID,
                      known.reference == mint, known.decimals == decimals else {
                    continue
                }
            } else {
                let abbreviated = "\(mint.prefix(4))…\(mint.suffix(4))"
                let asset = WalletAsset(
                    canonicalID: assetID, networkID: networkID,
                    chain: .solana, kind: .fungibleToken, reference: mint,
                    name: identity.program == .token2022
                        ? "Unknown Token-2022 asset" : "Unknown SPL token",
                    symbol: abbreviated, decimals: decimals,
                    trust: .quarantined, manifestRevision: 0
                )
                assets.append(asset)
                try? publicStore?.upsertAsset(asset)
            }
            balances["\(accountID):\(networkID):\(assetID)"] = balance
        }
        return balances
    }

    private func reconcileSuiAssets(
        _ rows: [[String: Any]],
        accountID: String,
        networkID: String
    ) -> [String: String] {
        guard WalletNetworkCatalog.descriptor(id: networkID)?.chain == .sui else {
            return [:]
        }
        var balances: [String: String] = [:]
        var seenAssetIDs: Set<String> = []
        for row in rows {
            guard let assetID = row["asset_id"] as? String,
                  let kindValue = row["asset_kind"] as? String,
                  let kind = WalletAssetKind(rawValue: kindValue),
                  seenAssetIDs.insert(assetID).inserted else { continue }
            if kind == .nft || kind == .collectible {
                guard let identity = WalletSuiObjectIdentity.parse(assetID),
                      identity.networkID == networkID,
                      row["reference"] as? String == identity.objectID,
                      row["object_id"] as? String == identity.objectID,
                      let version = row["object_version"] as? UInt64,
                      version <= 9_007_199_254_740_991,
                      let digest = row["object_digest"] as? String,
                      WalletSolanaBase58.decode(digest, exactLength: 32) != nil,
                      let moveType = row["move_type"] as? String,
                      !moveType.isEmpty, moveType.utf8.count <= 1_024,
                      !moveType.contains("/"),
                      moveType.unicodeScalars.allSatisfy({
                          $0.isASCII && $0.value >= 0x21
                      }),
                      row["has_public_transfer"] is Bool,
                      row["balance_base_units"] as? String == "1",
                      row["decimals"] as? Int == 0 else { continue }
                if let known = assets.first(where: { $0.id == assetID }) {
                    guard known.chain == .sui, known.networkID == networkID,
                          known.reference == identity.objectID,
                          (known.kind == .nft || known.kind == .collectible) else {
                        continue
                    }
                } else {
                    let typeName = moveType.components(separatedBy: "::").last
                        ?? "OBJECT"
                    let asset = WalletAsset(
                        canonicalID: assetID, networkID: networkID,
                        chain: .sui, kind: .collectible,
                        reference: identity.objectID,
                        name: "Unknown Sui object",
                        symbol: String(typeName.prefix(32)), decimals: 0,
                        trust: .quarantined, manifestRevision: 0
                    )
                    assets.append(asset)
                    try? publicStore?.upsertAsset(asset)
                }
                balances["\(accountID):\(networkID):\(assetID)"] = "1"
                continue
            }
            guard kind == .fungibleToken,
                  let identity = WalletSuiAssetIdentity.parse(assetID),
                  identity.networkID == networkID,
                  row["reference"] as? String == identity.coinType,
                  row["coin_type"] as? String == identity.coinType,
                  let rawTotal = row["balance_base_units"] as? String,
                  let total = WalletBaseUnits.normalize(rawTotal), total == rawTotal,
                  let rawCoins = row["coin_balance_base_units"] as? String,
                  let coins = WalletBaseUnits.normalize(rawCoins), coins == rawCoins,
                  let rawAccumulator = row["address_balance_base_units"] as? String,
                  let accumulator = WalletBaseUnits.normalize(rawAccumulator),
                  accumulator == rawAccumulator,
                  WalletBaseUnits.add(coins, accumulator) == total else { continue }
            if identity.coinType != WalletSuiAssetIdentity.nativeCoinType {
                if let known = assets.first(where: { $0.id == assetID }) {
                    guard known.chain == .sui, known.networkID == networkID,
                          known.reference == identity.coinType,
                          known.kind == .fungibleToken else { continue }
                } else {
                    let typeName = identity.coinType.components(separatedBy: "::").last
                        ?? "COIN"
                    let asset = WalletAsset(
                        canonicalID: assetID, networkID: networkID,
                        chain: .sui, kind: .fungibleToken,
                        reference: identity.coinType,
                        name: "Unknown Sui Coin", symbol: String(typeName.prefix(32)),
                        decimals: nil, trust: .quarantined, manifestRevision: 0
                    )
                    assets.append(asset)
                    try? publicStore?.upsertAsset(asset)
                }
            }
            balances["\(accountID):\(networkID):\(assetID)"] = total
        }
        return balances
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
            recoveryHelperAvailable: recoveryView.isAvailable,
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
                freshness: cached?.freshness ?? .notLoaded,
                ownership: account.ownership
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
                    freshness: cached?.freshness ?? .notLoaded,
                    ownership: account.ownership
                )
            }
            return [native] + additional
        }
    }

    private func replaceVaultAccounts(_ vaultAccounts: [WalletAccount]) {
        let external = accounts.filter { $0.ownership.connectorID != nil }
        accounts = vaultAccounts.map { account in
            WalletAccount(
                id: account.id, chain: account.chain, address: account.address,
                publicKeyBase64: account.publicKeyBase64,
                label: account.label, networkIDs: account.networkIDs,
                ownership: .locusVault
            )
        } + external
    }

    private func applyConnectionStatus(_ serviceStatus: WalletConnectionServiceStatus) {
        guard serviceStatus.protocolVersion == WalletConnectionServiceStatus.protocolVersion,
              Set(serviceStatus.connections.map(\.id)).count
                == serviceStatus.connections.count,
              Set(serviceStatus.accounts.map(\.id)).count == serviceStatus.accounts.count else {
            lastError = "The Wallet Connections helper returned malformed public state."
            return
        }
        let helperManagedConnectors: Set<WalletConnectionConnector> = [
            .metamask, .phantom, .slush, .walletConnect,
        ]
        let preservedLocalConnections = connections.filter {
            $0.connector == .embeddedBrowser
        }
        let priorHelperConnectionIDs = Set(connections.filter {
            helperManagedConnectors.contains($0.connector)
        }.map(\.id))
        let priorByID = Dictionary(uniqueKeysWithValues: connections
            .filter { helperManagedConnectors.contains($0.connector) }
            .map { ($0.id, $0) })
        let validConnections = serviceStatus.connections.filter { connection in
            guard helperManagedConnectors.contains(connection.connector) else { return false }
            switch connection.connector {
            case .metamask, .phantom, .slush:
                return connection.direction == .externalAccountToLocus
            case .walletConnect:
                return connection.direction == .locusVaultToDapp
            case .embeddedBrowser:
                return false
            }
        }.map { connection in
            // A late vendor callback cannot resurrect an explicitly revoked
            // local session. Reconnection creates a new reviewed connection ID.
            if let previous = priorByID[connection.id], previous.state == .revoked {
                return previous
            }
            return connection
        }
        let validExternalAccounts = serviceStatus.accounts.filter { account in
            guard let connectorID = account.ownership.connectorID else { return false }
            return validConnections.contains { connection in
                connection.connector.externalConnectorID == connectorID
                    && connection.accountIDs.contains(account.id)
                    && Set(account.networkIDs).isSubset(of: connection.networkIDs)
                    && (connection.state == .connected || connection.state == .reconnecting)
            }
        }
        let replacedAccountIDs = Set(validExternalAccounts.compactMap { current in
            accounts.first(where: { $0.id == current.id }).flatMap {
                $0 == current ? nil : current.id
            }
        })
        connections = (preservedLocalConnections + validConnections).sorted {
            $0.updatedAt > $1.updatedAt
        }
        let currentHelperConnectionIDs = Set(validConnections.map(\.id))
        for removedID in priorHelperConnectionIDs.subtracting(currentHelperConnectionIDs) {
            cancelConnectionAuthority(connectionID: removedID, reason: .disconnected,
                                      previous: priorByID[removedID])
        }
        for current in validConnections {
            if current.state == .expired {
                cancelConnectionAuthority(connectionID: current.id, reason: .expired,
                                          previous: priorByID[current.id])
            } else if current.state.isTerminal || current.state == .reconnecting {
                cancelConnectionAuthority(connectionID: current.id, reason: .disconnected,
                                          previous: priorByID[current.id])
            } else if let prior = priorByID[current.id] {
                if prior.accountIDs != current.accountIDs
                    || !prior.accountIDs.isDisjoint(with: replacedAccountIDs) {
                    cancelConnectionAuthority(connectionID: current.id, reason: .accountChanged,
                                              previous: prior)
                } else if prior.networkIDs != current.networkIDs {
                    cancelConnectionAuthority(connectionID: current.id, reason: .networkChanged,
                                              previous: prior)
                } else if prior.approvedMethods != current.approvedMethods
                            || prior.peerID != current.peerID || prior.peerURL != current.peerURL
                            || prior.accountOwnership != current.accountOwnership
                            || current.expiresAt < prior.expiresAt {
                    cancelConnectionAuthority(connectionID: current.id, reason: .disconnected,
                                              previous: prior)
                }
            }
        }
        let vaultAccounts = accounts.filter { $0.ownership == .locusVault }
        accounts = vaultAccounts + validExternalAccounts
        synchronizeAccountSnapshots(with: accounts)
        for connection in validConnections {
            try? publicStore?.upsertConnection(connection)
        }
    }

    private func cancelConnectionAuthority(
        connectionID: String,
        reason: WalletConnectionCancellationReason,
        previous: WalletConnectionRecord? = nil
    ) {
        let connection = previous ?? connections.first { $0.id == connectionID }
        requestRouter.cancel(connectionID: connectionID, reason: reason)
        let intentIDs = prepared.values.filter { intent in
            if connectionIntentBindings[intent.id]?.connectionID == connectionID { return true }
            guard let connection else { return false }
            if connection.direction == .externalAccountToLocus {
                return connection.accountIDs.contains(intent.accountID)
            }
            return connection.peerID != nil && intent.source.kind == .walletConnectPeer
                && intent.source.peerID == connection.peerID
        }.map(\.id)
        for intentID in intentIDs { cancelConfirmation(intentID: intentID) }
        if let accountID = activeSwapQuoteAccountID,
           connection?.accountIDs.contains(accountID) == true {
            currentSwapQuote = nil
            currentSwapAllowance = .unchecked
            activeSwapQuoteAccountID = nil
        }
        if pendingConnectionProposal?.requestID == connectionID {
            resolveConnectionProposal(approved: false)
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
            label: "Sepolia account", networkIDs: [Self.sepoliaNetworkID],
            ownership: fixture == "transaction-external"
                ? .external(connectorID: .metamask) : .locusVault
        )
        let solana = WalletAccount(
            id: "wallet-fixture-solana", chain: .solana,
            address: "9xQeWvG816bUx9EPfEzphDFTeGmQqoZ8VjPzM8YjWm7k",
            label: "Solana address", networkIDs: ["solana:devnet"],
            ownership: fixture == "transaction-managed"
                ? .connectorManaged(connectorID: .phantom) : .locusVault
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
        case "ready", "activity", "origin", "transaction",
             "transaction-external", "transaction-managed", "transaction-expiring":
            uiFixtureHubState = .ready
            vaultState = .unlocked
            status = .unlocked
        default:
            return
        }

        accounts = [evm, solana, sui]
        if fixture == "transaction-external" || fixture == "transaction-managed" {
            // These presentation fixtures own their synthetic public accounts.
            // A real SDK startup callback must not replace them mid-review.
            connectionsClient.invalidationHandler = nil
            connectionsClient.statusChangeHandler = nil
        }
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
                allowedAssetIDs: [WalletNetworkCatalog.ethereumSepolia.nativeAssetID],
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
        } else if fixture.hasPrefix("transaction") {
            let managed = fixture == "transaction-managed"
            let external = fixture == "transaction-external" || managed
            let account = managed ? solana : evm
            let network = managed
                ? WalletNetworkCatalog.solanaDevnet : WalletNetworkCatalog.ethereumSepolia
            let amount = managed ? "10000000" : "10000000000000000"
            let recipient = managed ? "11111111111111111111111111111111"
                : "0x1111111111111111111111111111111111111111"
            pendingConfirmation = WalletPreparedTransaction(
                id: "wallet-fixture-confirmation", digest: "0xfixture-digest",
                networkID: network.id, accountID: account.id,
                source: external ? .human : .browser(origin: "https://pay.example.com"),
                action: .nativeTransfer(
                    recipient: recipient, amountBaseUnits: amount
                ),
                summary: "Send 0.01 \(network.nativeSymbol)",
                effects: [WalletDecodedEffect(
                    id: "wallet-fixture-effect", kind: "native_transfer",
                    assetID: network.nativeAssetID,
                    amountBaseUnits: amount,
                    from: account.address, to: recipient,
                    spender: nil
                )],
                riskFlags: [], contract: nil,
                adapterID: managed ? "native-sol-transfer-v1" : "native-eth-transfer-v1",
                budgetAssetID: network.nativeAssetID,
                spendBaseUnits: amount,
                maximumFeeBaseUnits: managed ? "10000" : "1000000000000000",
                feeQuoteBaseUnits: managed ? "5000" : "42000000000000", simulation: "Transfer succeeds",
                simulationSucceeded: true, nonce: "7", createdAt: Date(),
                expiresAt: Date().addingTimeInterval(fixture == "transaction-expiring" ? 5 : 120),
                policyDecision: "This transaction requires exact confirmation.", policyID: nil
            )
        }
    }
    #endif

    func lock() {
        #if LOCUS_DIRECT_DOWNLOAD
        cancelExperimentalMainnetActivationReview()
        #endif
        cancelActiveRecoveryCeremony()
        idleLockTimer?.invalidate()
        idleLockTimer = nil
        signer.lock()
        connectionIntentBindings.removeAll()
        activePolicies.removeAll()
        activePolicyStatuses.removeAll()
        prepared.removeAll()
        confirmedIntentIDs.removeAll()
        pendingConfirmation = nil
        resolveConnectionProposal(approved: false)
        requestRouter.cancel(reason: .walletLocked)
        revokeAllBrowserGrants()
        resolveAllConfirmationWaiters(approved: false)
        if connectionsClient.isAvailable {
            Task { try? await connectionsClient.suspendAll() }
        }
        status = signer.isAvailable ? .locked : .securityReviewRequired
        if vaultState == .unlocked { vaultState = .locked }
    }

    private func handleSignerInvalidation() {
        #if LOCUS_DIRECT_DOWNLOAD
        cancelExperimentalMainnetActivationReview()
        #endif
        connectionIntentBindings.removeAll()
        recoveryView.cancel()
        recoveryCeremonyActive = false
        recoveryPresentationState = .idle
        idleLockTimer?.invalidate()
        idleLockTimer = nil
        activePolicies.removeAll()
        activePolicyStatuses.removeAll()
        prepared.removeAll()
        confirmedIntentIDs.removeAll()
        pendingConfirmation = nil
        resolveConnectionProposal(approved: false)
        requestRouter.cancel(reason: .signerLost)
        revokeAllBrowserGrants()
        resolveAllConfirmationWaiters(approved: false)
        status = signer.isAvailable ? .locked : .securityReviewRequired
        if vaultState == .unlocked { vaultState = .locked }
    }

    private func handleConnectionsInvalidation() {
        resolveConnectionProposal(approved: false)
        requestRouter.cancel(reason: .disconnected)
        let externalAccountIDs = Set(accounts.filter { $0.ownership.connectorID != nil }.map(\.id))
        let invalidIntents = prepared.values.filter {
            externalAccountIDs.contains($0.accountID) || $0.source.kind == .walletConnectPeer
        }.map(\.id)
        for intentID in invalidIntents {
            cancelConfirmation(intentID: intentID)
            prepared[intentID] = nil
            confirmedIntentIDs.remove(intentID)
        }
        let now = Date()
        connections = connections.map { connection in
            guard !connection.state.isTerminal else { return connection }
            return connection.transitioning(to: .reconnecting, at: now) ?? connection
        }
        accounts.removeAll { $0.ownership.connectorID != nil }
        synchronizeAccountSnapshots(with: accounts)
        for connection in connections {
            try? publicStore?.upsertConnection(connection)
        }
    }

    private func handleRecoveryInvalidation() {
        guard recoveryCeremonyActive else { return }
        recoveryCeremonyActive = false
        recoveryPresentationState = .idle
        status = signer.isAvailable ? .locked : .securityReviewRequired
        lastError = "The isolated recovery window was interrupted. The vault is locked."
        Task { [weak self] in
            guard let self else { return }
            await self.refreshStatus(clearErrorOnSuccess: false)
        }
    }

    private func cancelActiveRecoveryCeremony() {
        guard recoveryCeremonyActive else { return }
        recoveryCeremonyActive = false
        recoveryPresentationState = .idle
        recoveryView.cancel()
    }

    @discardableResult
    func authorizeSession() async -> Bool {
        guard walletEnabled, signer.isAvailable else { return false }
        do {
            try await signer.authorizeSession()
            replaceVaultAccounts(try await signer.listAccounts())
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
            if let signed = reviewRegistry?.evmContracts.first(where: {
                $0.id == entry.id
                    || ($0.networkID == entry.networkID
                        && $0.checksumAddress.caseInsensitiveCompare(
                            entry.checksumAddress
                        ) == .orderedSame)
            }) {
                guard signed == entry else {
                    throw Error.policyDenied(
                        "A locally verified contract cannot replace signed release metadata."
                    )
                }
                lastError = nil
                return true
            }
            let changed = contractRegistry.first(where: { $0.id == entry.id }).map { $0 != entry } ?? false
            contractRegistry.removeAll { $0.id == entry.id }
            contractRegistry.append(entry)
            contractRegistry.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            persistLocalContractRegistry()
            if changed { await clearPolicies() }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func removeContractRegistryEntry(id: String) async {
        guard reviewRegistry?.evmContracts.contains(where: { $0.id == id }) != true else {
            lastError = "Signed release contracts cannot be removed locally."
            return
        }
        contractRegistry.removeAll { $0.id == id }
        persistLocalContractRegistry()
        await clearPolicies()
    }

    private func persistLocalContractRegistry() {
        let signedIDs = Set(reviewRegistry?.evmContracts.map(\.id) ?? [])
        let local = contractRegistry.filter { !signedIDs.contains($0.id) }
        if let data = try? JSONEncoder().encode(local) {
            userDefaults.set(data, forKey: registryDefaultsKey)
        }
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

    var availableSwapAccounts: [WalletAccount] {
        let networks = Set(
            reviewRegistry?.manifest.uniswapConfigurations.map(\.networkID) ?? []
        )
        return accounts.filter {
            $0.chain == .evm && $0.networkIDs.contains(where: networks.contains)
        }
    }

    func swapNetworkID(accountID: String) -> String? {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            return nil
        }
        let configured = Set(
            reviewRegistry?.manifest.uniswapConfigurations.map(\.networkID) ?? []
        )
        return account.networkIDs.filter(configured.contains).sorted().first
    }

    func availableSwapAssets(networkID: String) -> [WalletAsset] {
        guard let configuration = reviewRegistry?.manifest.uniswapConfigurations.first(
            where: { $0.networkID == networkID }
        ) else { return [] }
        let reviewedIDs = Set(configuration.pools.flatMap {
            [$0.token0AssetID, $0.token1AssetID]
        })
        return assets.filter {
            $0.networkID == networkID && reviewedIDs.contains($0.id)
                && $0.kind == .fungibleToken && $0.trust == .curated
        }.sorted { $0.symbol.localizedCaseInsensitiveCompare($1.symbol) == .orderedAscending }
    }

    private func quoteSwap(
        _ arguments: [String: Any]
    ) async throws -> [String: Any] {
        guard let networkID = nonempty(arguments["network_id"]),
              let accountID = nonempty(arguments["account_id"]),
              let inputAssetID = nonempty(arguments["input_asset_id"]),
              let outputAssetID = nonempty(arguments["output_asset_id"]),
              let amount = WalletBaseUnits.normalize(
                nonempty(arguments["amount_base_units"]) ?? ""
              ), amount != "0",
              let rawSlippage = arguments["slippage_bps"],
              let slippageValues = uint32Values([rawSlippage]),
              slippageValues.count == 1, slippageValues[0] <= 500,
              let account = accounts.first(where: {
                $0.id == accountID && $0.chain == .evm
                    && $0.networkIDs.contains(networkID)
              }) else {
            throw Error.invalidArguments(
                "A swap quote needs a reviewed EVM account, token pair, positive base-unit amount, and at most 500 bps slippage."
            )
        }
        let requestedRouterID = nonempty(
            arguments["universal_router_contract_id"]
        )
        let configurations = reviewRegistry?.manifest.uniswapConfigurations
            .filter {
                $0.networkID == networkID
                    && (requestedRouterID == nil
                        || $0.universalRouterContractID == requestedRouterID)
            } ?? []
        guard configurations.count == 1, let configuration = configurations.first
        else {
            throw Error.invalidArguments(
                "Select the one signed Universal Router configuration for this network."
            )
        }
        if WalletNetworkCatalog.descriptor(id: networkID)?.environment == .mainnet {
            try launchGate.authorize(
                networkID: networkID, capability: .exactInputSwap,
                regionCode: regionCode
            )
        }
        let quote = try await signer.quoteUniswap(
            request: WalletUniswapQuoteRequest(
                networkID: networkID,
                universalRouterContractID:
                    configuration.universalRouterContractID,
                inputAssetID: inputAssetID,
                outputAssetID: outputAssetID,
                amountInBaseUnits: amount,
                slippageBPS: Int(slippageValues[0]),
                recipient: account.address
            ),
            configuration: configuration
        )
        _ = try reviewedSwapContract(for: quote.action, networkID: networkID)
        let allowance = try await uniswapAllowanceState(
            account: account, quote: quote, configuration: configuration
        )
        return [
            "text": "Reviewed on-chain swap quote valid until \(quote.expiresAt.formatted()).",
            "action": try dictionary(quote.action),
            "expires_at": ISO8601DateFormatter().string(from: quote.expiresAt),
            "allowance_state": allowanceLabel(allowance),
        ]
    }

    private func allowanceLabel(_ state: WalletUniswapAllowanceState) -> String {
        switch state {
        case .unchecked: "unchecked"
        case .sufficient: "sufficient"
        case .needsERC20Approval(_, _, _, let zeroFirst):
            zeroFirst ? "needs_erc20_zero_first" : "needs_erc20_approval"
        case .needsPermit2Approval: "needs_permit2_approval"
        }
    }

    private func prepareSwapAllowance(
        _ arguments: [String: Any],
        source: WalletRequestSource
    ) async throws -> [String: Any] {
        let swapRequest = try parsePrepareRequest(arguments, source: source)
        guard swapRequest.action.type == .exactInputSwap,
              let account = accounts.first(where: {
                $0.id == swapRequest.accountID
                    && $0.networkIDs.contains(swapRequest.networkID)
              }) else {
            throw Error.invalidArguments(
                "Allowance setup requires a current reviewed exact-input swap action."
            )
        }
        let allowanceRequest = try await derivedSwapAllowanceRequest(
            from: swapRequest, account: account
        )
        if account.ownership == .locusVault {
            guard status == .unlocked else { throw Error.vaultLocked }
            return response(for: try await prepare(allowanceRequest))
        }
        return try await executeExternal(allowanceRequest)
    }

    private func derivedSwapAllowanceRequest(
        from swapRequest: WalletPrepareRequest,
        account: WalletAccount
    ) async throws -> WalletPrepareRequest {
        let action = swapRequest.action
        let routerEntry = try reviewedSwapContract(
            for: action, networkID: swapRequest.networkID
        )
        guard let route = action.swapRoute,
              let evidence = route.quoteEvidence, evidence.expiresAt > Date(),
              let inputAssetID = action.inputAssetID,
              let input = WalletEVMAssetIdentity.parse(inputAssetID),
              let outputAssetID = action.outputAssetID,
              let amount = action.amountBaseUnits,
              let minimumOutput = action.minimumOutputBaseUnits,
              let recipient = action.recipient,
              let configuration = reviewRegistry?.uniswapConfiguration(
                networkID: swapRequest.networkID,
                universalRouterContractID: routerEntry.id
              ),
              let router = configuration.contract(.universalRouter),
              let permit2 = configuration.contract(.permit2) else {
            throw Error.invalidArguments(
                "The signed swap quote or its allowance identities expired."
            )
        }
        let quote = WalletUniswapQuote(
            action: action, quotedAt: evidence.quotedAt,
            expiresAt: evidence.expiresAt
        )
        let state = try await uniswapAllowanceState(
            account: account, quote: quote, configuration: configuration
        )
        let stage: WalletSwapAllowanceStage
        let approvalAmount: String
        let expiration: String?
        let contractID: String
        let adapterID: String
        switch state {
        case .needsERC20Approval(_, _, let required, let zeroFirst):
            stage = zeroFirst ? .erc20Reset : .erc20ToPermit2
            approvalAmount = zeroFirst ? "0" : required
            expiration = nil
            guard let tokenEntry = contractRegistry.first(where: {
                $0.networkID == swapRequest.networkID
                    && $0.checksumAddress.caseInsensitiveCompare(
                        input.contractAddress
                    ) == .orderedSame
            }) else {
                throw Error.invalidArguments(
                    "The input token is absent from the signed registry."
                )
            }
            contractID = tokenEntry.id
            adapterID = WalletReviewedAdapters.erc20
        case .needsPermit2Approval(_, _, let required, let deadline):
            stage = .permit2ToUniversalRouter
            approvalAmount = required
            expiration = deadline
            contractID = configuration.permit2ContractID
            adapterID = WalletReviewedAdapters.uniswapPermit2AllowanceSetup
        case .sufficient:
            throw Error.invalidArguments(
                "The finite swap allowances are already sufficient."
            )
        case .unchecked:
            throw Error.invalidArguments("The live allowance state is unavailable.")
        }
        let binding = WalletSwapAllowanceBinding(
            networkID: swapRequest.networkID,
            universalRouterContractID: routerEntry.id,
            universalRouterAddress: router.address,
            permit2Address: permit2.address,
            inputAssetID: inputAssetID, outputAssetID: outputAssetID,
            amountInBaseUnits: amount,
            minimumOutputBaseUnits: minimumOutput,
            recipient: recipient, route: route
        )
        guard let bindingDigest = binding.digest() else {
            throw Error.invalidArguments("The allowance binding could not be created.")
        }
        let allowanceAction = WalletSemanticAction.swapAllowanceSetup(
            contractID: contractID, adapterID: adapterID,
            setup: WalletSwapAllowanceSetup(
                stage: stage, binding: binding,
                bindingDigest: bindingDigest,
                approvalAmountBaseUnits: approvalAmount,
                expirationUnixSeconds: expiration
            )
        )
        _ = try reviewedSwapAllowanceContract(
            for: allowanceAction, networkID: swapRequest.networkID
        )
        return WalletPrepareRequest(
            networkID: swapRequest.networkID,
            accountID: swapRequest.accountID,
            source: swapRequest.source,
            action: allowanceAction,
            maximumFeeBaseUnits: swapRequest.maximumFeeBaseUnits
        )
    }

    @discardableResult
    func refreshUniswapQuote(
        accountID: String,
        networkID: String,
        inputAssetID: String,
        outputAssetID: String,
        amountInBaseUnits: String,
        slippageBPS: Int
    ) async -> Bool {
        swapQuoteInProgress = true
        defer { swapQuoteInProgress = false }
        currentSwapQuote = nil
        currentSwapAllowance = .unchecked
        do {
            try authorizeProviderBindings(networkID: networkID)
            guard let account = accounts.first(where: {
                $0.id == accountID && $0.chain == .evm
                    && $0.networkIDs.contains(networkID)
            }), let amount = WalletBaseUnits.normalize(amountInBaseUnits),
            amount == amountInBaseUnits, amount != "0",
            let configuration = reviewRegistry?.manifest.uniswapConfigurations.first(
                where: { $0.networkID == networkID }
            ), (0...500).contains(slippageBPS) else {
                throw Error.invalidArguments(
                    "Choose a reviewed account, token pair, positive base-unit amount, and slippage no greater than 500 bps."
                )
            }
            if WalletNetworkCatalog.descriptor(id: networkID)?.environment == .mainnet {
                try launchGate.authorize(
                    networkID: networkID, capability: .exactInputSwap,
                    regionCode: regionCode
                )
            }
            let quote = try await signer.quoteUniswap(
                request: WalletUniswapQuoteRequest(
                    networkID: networkID,
                    universalRouterContractID: configuration.universalRouterContractID,
                    inputAssetID: inputAssetID, outputAssetID: outputAssetID,
                    amountInBaseUnits: amount, slippageBPS: slippageBPS,
                    recipient: account.address
                ),
                configuration: configuration
            )
            guard quote.expiresAt > Date(),
                  quote.action.recipient?.caseInsensitiveCompare(account.address)
                    == .orderedSame else {
                throw WalletUniswapQuoteError.malformedQuote
            }
            _ = try reviewedSwapContract(for: quote.action, networkID: networkID)
            currentSwapQuote = quote
            activeSwapQuoteAccountID = accountID
            currentSwapAllowance = try await uniswapAllowanceState(
                account: account, quote: quote, configuration: configuration
            )
            lastError = nil
            return true
        } catch {
            currentSwapQuote = nil
            activeSwapQuoteAccountID = nil
            currentSwapAllowance = .unchecked
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func prepareHumanSwap(maximumFeeBaseUnits: String) async -> Bool {
        do {
            guard let quote = currentSwapQuote,
                  let accountID = activeSwapQuoteAccountID,
                  quote.expiresAt > Date(),
                  let networkID = quote.action.swapRoute?.pathAssetIDs.first
                    .flatMap(WalletEVMAssetIdentity.parse)?.networkID,
                  let account = accounts.first(where: { $0.id == accountID }),
                  let configuration = reviewRegistry?.uniswapConfiguration(
                    networkID: networkID,
                    universalRouterContractID: quote.action.contractID ?? ""
                  ),
                  WalletBaseUnits.normalize(maximumFeeBaseUnits)
                    == maximumFeeBaseUnits else {
                throw Error.invalidArguments(
                    "Refresh the quote and provide a valid maximum fee before review."
                )
            }
            currentSwapAllowance = try await uniswapAllowanceState(
                account: account, quote: quote, configuration: configuration
            )
            guard currentSwapAllowance == .sufficient else {
                throw Error.approvalRequired(
                    "Finite Permit2 allowance setup is required before this swap."
                )
            }
            let request = WalletPrepareRequest(
                networkID: networkID, accountID: accountID, source: .human,
                action: quote.action,
                maximumFeeBaseUnits: maximumFeeBaseUnits
            )
            if account.ownership == .locusVault {
                guard status == .unlocked else { throw Error.vaultLocked }
                _ = try await prepare(request)
            } else {
                _ = try await executeExternal(request)
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Derives the next finite allowance transaction from the currently
    /// reviewed quote. Callers never provide approval calldata, a spender, or
    /// an amount independently from the swap.
    @discardableResult
    func prepareNextHumanSwapAllowance(
        maximumFeeBaseUnits: String
    ) async -> Bool {
        do {
            guard let quote = currentSwapQuote,
                  let accountID = activeSwapQuoteAccountID,
                  quote.expiresAt > Date(),
                  WalletBaseUnits.normalize(maximumFeeBaseUnits)
                    == maximumFeeBaseUnits,
                  let route = quote.action.swapRoute,
                  let networkID = route.pathAssetIDs.first
                    .flatMap(WalletEVMAssetIdentity.parse)?.networkID,
                  let account = accounts.first(where: { $0.id == accountID }),
                  let inputAssetID = quote.action.inputAssetID,
                  let input = WalletEVMAssetIdentity.parse(inputAssetID),
                  let outputAssetID = quote.action.outputAssetID,
                  let amount = quote.action.amountBaseUnits,
                  let minimumOutput = quote.action.minimumOutputBaseUnits,
                  let recipient = quote.action.recipient,
                  let routerContractID = quote.action.contractID,
                  let configuration = reviewRegistry?.uniswapConfiguration(
                    networkID: networkID,
                    universalRouterContractID: routerContractID
                  ),
                  let router = configuration.contract(.universalRouter),
                  let permit2 = configuration.contract(.permit2) else {
                throw Error.invalidArguments(
                    "Refresh the reviewed quote before setting up allowances."
                )
            }
            let liveState = try await uniswapAllowanceState(
                account: account, quote: quote, configuration: configuration
            )
            currentSwapAllowance = liveState
            let stage: WalletSwapAllowanceStage
            let approvalAmount: String
            let expiration: String?
            let contractID: String
            let adapterID: String
            switch liveState {
            case .needsERC20Approval(
                _, _, let requiredAmount, let requiresZeroFirst
            ):
                stage = requiresZeroFirst ? .erc20Reset : .erc20ToPermit2
                approvalAmount = requiresZeroFirst ? "0" : requiredAmount
                expiration = nil
                guard let tokenEntry = contractRegistry.first(where: {
                    $0.networkID == networkID
                        && $0.checksumAddress.caseInsensitiveCompare(
                            input.contractAddress
                        ) == .orderedSame
                }) else {
                    throw Error.invalidArguments(
                        "The input token contract is not in the signed registry."
                    )
                }
                contractID = tokenEntry.id
                adapterID = WalletReviewedAdapters.erc20
            case .needsPermit2Approval(_, _, let requiredAmount, let deadline):
                stage = .permit2ToUniversalRouter
                approvalAmount = requiredAmount
                expiration = deadline
                contractID = configuration.permit2ContractID
                adapterID = WalletReviewedAdapters.uniswapPermit2AllowanceSetup
            case .sufficient:
                throw Error.invalidArguments(
                    "The finite allowances are already sufficient for this swap."
                )
            case .unchecked:
                throw Error.invalidArguments(
                    "Allowance state is unavailable; refresh the quote."
                )
            }
            let binding = WalletSwapAllowanceBinding(
                networkID: networkID,
                universalRouterContractID: routerContractID,
                universalRouterAddress: router.address,
                permit2Address: permit2.address,
                inputAssetID: inputAssetID,
                outputAssetID: outputAssetID,
                amountInBaseUnits: amount,
                minimumOutputBaseUnits: minimumOutput,
                recipient: recipient,
                route: route
            )
            guard let bindingDigest = binding.digest() else {
                throw Error.invalidArguments(
                    "The reviewed swap could not be bound to its allowance setup."
                )
            }
            let action = WalletSemanticAction.swapAllowanceSetup(
                contractID: contractID, adapterID: adapterID,
                setup: WalletSwapAllowanceSetup(
                    stage: stage, binding: binding,
                    bindingDigest: bindingDigest,
                    approvalAmountBaseUnits: approvalAmount,
                    expirationUnixSeconds: expiration
                )
            )
            _ = try reviewedSwapAllowanceContract(
                for: action, networkID: networkID
            )
            let request = WalletPrepareRequest(
                networkID: networkID, accountID: accountID,
                source: .human, action: action,
                maximumFeeBaseUnits: maximumFeeBaseUnits
            )
            if account.ownership == .locusVault {
                guard status == .unlocked else { throw Error.vaultLocked }
                _ = try await prepare(request)
            } else {
                _ = try await executeExternal(request)
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func executeExternalHumanTransfer(
        networkID: String,
        accountID: String,
        kind: WalletActionKind,
        assetID: String? = nil,
        tokenID: String? = nil,
        recipient: String,
        amountBaseUnits: String,
        maximumFeeBaseUnits: String
    ) async -> Bool {
        guard kind == .nativeTransfer
                || kind == .fungibleTokenTransfer
                || kind == .nftTransfer else {
            lastError = "That external-wallet action is unavailable."
            return false
        }
        var action: [String: Any] = [
            "type": kind.rawValue,
            "recipient": recipient,
            "amount_base_units": amountBaseUnits,
        ]
        if let assetID { action["asset_id"] = assetID }
        if let tokenID { action["token_id"] = tokenID }
        let result = await perform(
            tool: "wallet_execute_external_transaction",
            arguments: [
                "network_id": networkID,
                "account_id": accountID,
                "maximum_fee_base_units": maximumFeeBaseUnits,
                "action": action,
            ],
            source: .human
        )
        if let error = result["error"] as? String {
            lastError = error
            return false
        }
        lastError = nil
        return result["transaction_hash"] as? String != nil
    }

    @discardableResult
    func confirmAndExecuteHumanIntent(intentID: String) async -> Bool {
        guard let transaction = prepared[intentID], transaction.source.kind == .humanUI,
              accounts.first(where: { $0.id == transaction.accountID })?.ownership == .locusVault
        else { return false }
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
        signer.cancelPreparation(intentID: intentID)
        prepared[intentID] = nil
        connectionIntentBindings[intentID] = nil
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
        if browserOriginGrants.contains(grant) {
            let addresses = browserAccounts(origin: normalized, networkID: networkID)
            return addresses.isEmpty ? nil : addresses
        }
        guard pendingBrowserOriginGrant == nil, browserGrantContinuation == nil else { return nil }
        pendingBrowserOriginGrant = WalletBrowserOriginGrant(
            id: UUID(), origin: normalized, networkID: networkID
        )
        onBrowserAuthorizationNeeded?()
        let approved = await withCheckedContinuation { continuation in
            browserGrantContinuation = continuation
        }
        guard approved else { return nil }
        let addresses = browserAccounts(origin: normalized, networkID: networkID)
        return addresses.isEmpty ? nil : addresses
    }

    func browserAccounts(
        origin: String, networkID: String = "eip155:11155111"
    ) -> [String] {
        guard let normalized = Self.normalizedWebOrigin(origin),
              browserOriginGrants.contains(.init(origin: normalized, networkID: networkID)),
              agentToolingAvailable else { return [] }
        guard let chain = WalletNetworkCatalog.descriptor(id: networkID)?.chain else {
            return []
        }
        let eligible = accounts.filter {
            $0.chain == chain
                && $0.ownership == .locusVault
                && $0.networkIDs.contains(networkID)
        }
        guard eligible.contains(where: { account in
            activeBrowserConnection(
                origin: normalized, networkID: networkID, accountID: account.id,
                requiredMethod: .listAccounts
            ) != nil
        }) else { return [] }
        return eligible.map(\.address)
    }

    /// Public account material exposed to Wallet Standard after the same
    /// origin/network grant used by the EIP-1193 provider. No signer state or
    /// session secret crosses this boundary.
    func browserWalletStandardAccounts(
        origin: String, networkID: String
    ) -> [[String: Any]] {
        let visible = Set(browserAccounts(origin: origin, networkID: networkID))
        return accounts.compactMap { account in
            guard visible.contains(account.address),
                  account.ownership == .locusVault,
                  account.networkIDs.contains(networkID) else { return nil }
            let publicKeyBase64: String?
            if let stored = account.publicKeyBase64 {
                publicKeyBase64 = stored
            } else if account.chain == .solana,
                      let bytes = WalletSolanaBase58.decode(
                        account.address, exactLength: 32
                      ) {
                publicKeyBase64 = Data(bytes).base64EncodedString()
            } else {
                publicKeyBase64 = nil
            }
            guard let publicKeyBase64 else { return nil }
            return [
                "address": account.address,
                "publicKeyBase64": publicKeyBase64,
                "networkID": networkID,
                "label": account.label,
            ]
        }
    }

    func approveBrowserOrigin() {
        guard let request = pendingBrowserOriginGrant else { return }
        browserOriginGrants.insert(.init(origin: request.origin, networkID: request.networkID))
        approvedBrowserOrigins = Set(browserOriginGrants.map(\.origin)).sorted()
        let now = Date()
        let chain = WalletNetworkCatalog.descriptor(id: request.networkID)?.chain
        let candidateMethods: Set<WalletConnectionMethod> = switch chain {
        case .evm:
            [.listAccounts, .switchNetwork, .sendTransaction, .signInWithEthereum]
        case .solana:
            [.listAccounts, .sendTransaction, .signInWithSolana]
        case .sui:
            [.listAccounts, .sendTransaction]
        case nil:
            []
        }
        let methods = Set(candidateMethods.filter { method in
            (try? launchGate.authorizeConnection(
                networkID: request.networkID,
                connector: .embeddedBrowser,
                direction: .locusVaultToDapp,
                method: method,
                regionCode: regionCode
            )) != nil
                && reviewRegistry?.containsConnector(
                    .embeddedBrowser,
                    direction: .locusVaultToDapp,
                    method: method
                ) == true
        })
        guard methods.contains(.listAccounts), methods.contains(.sendTransaction) else {
            denyBrowserOrigin()
            return
        }
        let connection = WalletConnectionRecord(
            id: browserConnectionID(origin: request.origin, networkID: request.networkID),
            direction: .locusVaultToDapp,
            connector: .embeddedBrowser,
            peerName: request.origin,
            peerURL: request.origin,
            networkIDs: [request.networkID],
            approvedMethods: methods,
            accountIDs: Set(accounts.filter {
                $0.ownership == .locusVault
                    && $0.chain == chain
                    && $0.networkIDs.contains(request.networkID)
            }.map(\.id)),
            state: .connected,
            createdAt: now,
            updatedAt: now,
            expiresAt: now.addingTimeInterval(12 * 60 * 60)
        )
        connections.removeAll { $0.id == connection.id }
        connections.insert(connection, at: 0)
        try? publicStore?.upsertConnection(connection)
        pendingBrowserOriginGrant = nil
        browserGrantContinuation?.resume(returning: true)
        browserGrantContinuation = nil
    }

    func denyBrowserOrigin() {
        pendingBrowserOriginGrant = nil
        browserGrantContinuation?.resume(returning: false)
        browserGrantContinuation = nil
    }

    func revokeBrowserOrigin(
        _ origin: String,
        reason: WalletConnectionCancellationReason = .disconnected
    ) {
        guard let normalized = Self.normalizedWebOrigin(origin) else { return }
        browserOriginGrants = Set(browserOriginGrants.filter { $0.origin != normalized })
        approvedBrowserOrigins = Set(browserOriginGrants.map(\.origin)).sorted()
        requestRouter.cancel(origin: normalized, reason: reason)
        let now = Date()
        for index in connections.indices where
            connections[index].connector == .embeddedBrowser
                && connections[index].peerURL == normalized
                && !connections[index].state.isTerminal {
            if let revoked = connections[index].transitioning(to: .revoked, at: now) {
                connections[index] = revoked
                try? publicStore?.upsertConnection(revoked)
            }
        }
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
        try authorizeProviderBindings(networkID: networkID)
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
              let accountAddress = browserAccounts(
                origin: normalizedOrigin, networkID: networkID
              ).first,
              let selectedAccount = accounts.first(where: {
                  $0.ownership == .locusVault
                      && $0.chain == .evm
                      && $0.networkIDs.contains(networkID)
                      && $0.address.caseInsensitiveCompare(accountAddress) == .orderedSame
              }),
              let from = nonempty(transaction["from"]),
              let recipient = nonempty(transaction["to"]),
              canUseBrowserNetwork(networkID) else {
            throw Error.invalidArguments(
                "The browser provider requires one connected account and a bounded transaction."
            )
        }
        if let suppliedChain = nonempty(transaction["chainId"]) {
            let expected = networkID == Self.ethereumMainnetNetworkID ? "0x1" : "0xaa36a7"
            guard suppliedChain.lowercased() == expected else {
                throw Error.invalidArguments("The transaction chain does not match the selected network.")
            }
        }
        let action = try await decodedEVMDappAction(
            .init(from: from, to: recipient, valueHex: rawValue, dataHex: rawData),
            networkID: networkID, account: selectedAccount
        )
        return try await browserExecuteTransaction(
            origin: normalizedOrigin, networkID: networkID,
            account: selectedAccount, action: action
        )
    }

    private func decodedEVMDappAction(
        _ transaction: WalletConnectorDappRequest.EVMTransaction,
        networkID: String,
        account: WalletAccount
    ) async throws -> WalletSemanticAction {
        let router = contractRegistry.first {
            $0.networkID == networkID
                && $0.checksumAddress.caseInsensitiveCompare(transaction.to)
                    == .orderedSame
                && WalletReviewedAdapters.validatedID(for: $0)
                    == WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn
        }
        guard let router else {
            return try WalletDappTransactionDecoder.evm(
                transaction, networkID: networkID, account: account
            )
        }
        guard reviewRegistry?.containsExactContract(router) == true,
              let configuration = reviewRegistry?.uniswapConfiguration(
                networkID: networkID,
                universalRouterContractID: router.id
              ),
              let rawSwap = WalletDappTransactionDecoder.evmUniversalRouterSwap(
                transaction, networkID: networkID, account: account,
                routerContractID: router.id,
                routerAddress: router.checksumAddress
              ),
              rawSwap.minimumHopPriceX36.count
                == rawSwap.pathAssetIDs.count - 1 else {
            throw Error.invalidArguments(
                "The dapp swap is not the single reviewed Universal Router exact-input form."
            )
        }
        let zeroSlippageQuote = try await signer.quoteUniswap(
            request: WalletUniswapQuoteRequest(
                networkID: networkID,
                universalRouterContractID: router.id,
                inputAssetID: rawSwap.inputAssetID,
                outputAssetID: rawSwap.outputAssetID,
                amountInBaseUnits: rawSwap.amountIn,
                slippageBPS: 0,
                recipient: account.address,
                requiredProtocolVersion: rawSwap.protocolVersion,
                requiredPathAssetIDs: rawSwap.pathAssetIDs,
                requiredFeeTiers: rawSwap.feeTiers,
                requiredDeadlineUnixSeconds: rawSwap.deadlineUnixSeconds
            ),
            configuration: configuration
        )
        guard let quotedRoute = zeroSlippageQuote.action.swapRoute,
              let evidence = quotedRoute.quoteEvidence,
              let slippage = (0...500).first(where: { basisPoints in
                WalletBaseUnits.applyingBasisPointFloor(
                    quotedRoute.quotedOutputBaseUnits,
                    bpsToKeep: 10_000 - basisPoints
                ) == rawSwap.minimumAmountOut
              }) else {
            throw Error.invalidArguments(
                "The dapp minimum output is not reproducible within the 500 bps GA limit."
            )
        }
        var expectedHopFloors: [String] = []
        var hopInput = rawSwap.amountIn
        let scaleX36 = "1" + String(repeating: "0", count: 36)
        for output in evidence.perHopOutputBaseUnits {
            guard let scaled = WalletBaseUnits.multiply(output, scaleX36),
                  let rawPrice = WalletBaseUnits.divide(
                    scaled, by: hopInput
                  )?.quotient,
                  let floor = WalletBaseUnits.applyingBasisPointFloor(
                    rawPrice, bpsToKeep: 10_000 - slippage
                  ), floor != "0" else {
                throw WalletUniswapQuoteError.malformedQuote
            }
            expectedHopFloors.append(floor)
            hopInput = output
        }
        guard expectedHopFloors == rawSwap.minimumHopPriceX36 else {
            throw Error.invalidArguments(
                "The dapp per-hop floors do not match the independently reproduced quote."
            )
        }
        let route = WalletExactInputSwapRoute(
            protocolVersion: rawSwap.protocolVersion,
            pathAssetIDs: rawSwap.pathAssetIDs,
            feeTiers: rawSwap.feeTiers,
            minimumHopPriceX36: expectedHopFloors,
            quotedOutputBaseUnits: quotedRoute.quotedOutputBaseUnits,
            slippageBPS: slippage,
            deadlineUnixSeconds: rawSwap.deadlineUnixSeconds,
            quoteEvidence: evidence
        )
        let action = WalletSemanticAction.exactInputSwap(
            adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
            contractID: router.id,
            inputAssetID: rawSwap.inputAssetID,
            outputAssetID: rawSwap.outputAssetID,
            amountInBaseUnits: rawSwap.amountIn,
            minimumOutputBaseUnits: rawSwap.minimumAmountOut,
            recipient: account.address,
            route: route
        )
        _ = try reviewedSwapContract(for: action, networkID: networkID)
        let quote = WalletUniswapQuote(
            action: action, quotedAt: evidence.quotedAt,
            expiresAt: evidence.expiresAt
        )
        let allowance = try await uniswapAllowanceState(
            account: account, quote: quote, configuration: configuration
        )
        guard allowance == .sufficient else {
            throw Error.needsAllowance(allowance)
        }
        return action
    }

    func browserSendSolanaTransaction(
        origin: String, networkID: String, transactionBase64: String,
        accountAddress: String, minimumContextSlot: UInt64?
    ) async throws -> String {
        guard WalletNetworkCatalog.descriptor(id: networkID)?.chain == .solana else {
            throw Error.invalidArguments("The Solana network is not supported.")
        }
        let (normalizedOrigin, account) = try browserAccount(
            origin: origin, networkID: networkID, address: accountAddress
        )
        let action = try await WalletDappTransactionDecoder.solana(
            .init(
                transactionBase64: transactionBase64,
                accountAddress: accountAddress,
                minimumContextSlot: minimumContextSlot
            ),
            networkID: networkID, account: account
        )
        return try await browserExecuteTransaction(
            origin: normalizedOrigin, networkID: networkID,
            account: account, action: action
        )
    }

    func browserSendSuiTransaction(
        origin: String, networkID: String,
        transactionBase64: String, accountAddress: String
    ) async throws -> String {
        guard WalletNetworkCatalog.descriptor(id: networkID)?.chain == .sui else {
            throw Error.invalidArguments("The Sui network is not supported.")
        }
        let (normalizedOrigin, account) = try browserAccount(
            origin: origin, networkID: networkID, address: accountAddress
        )
        let action = try await WalletDappTransactionDecoder.sui(
            .init(
                transactionBase64: transactionBase64,
                accountAddress: accountAddress
            ),
            networkID: networkID, account: account, reviewedAssets: assets
        )
        return try await browserExecuteTransaction(
            origin: normalizedOrigin, networkID: networkID,
            account: account, action: action
        )
    }

    private func browserAccount(
        origin: String, networkID: String, address: String
    ) throws -> (String, WalletAccount) {
        guard let normalizedOrigin = Self.normalizedWebOrigin(origin),
              let chain = WalletNetworkCatalog.descriptor(id: networkID)?.chain,
              let accountAddress = browserAccounts(
                origin: normalizedOrigin, networkID: networkID
              ).first(where: { Self.sameAddress($0, address, chain: chain) }),
              let account = accounts.first(where: {
                  $0.ownership == .locusVault && $0.chain == chain
                      && $0.networkIDs.contains(networkID)
                      && Self.sameAddress($0.address, accountAddress, chain: chain)
              }), canUseBrowserNetwork(networkID) else {
            throw Error.approvalRequired(
                "This website is not connected to the requested Locus Vault account."
            )
        }
        return (normalizedOrigin, account)
    }

    private func browserExecuteTransaction(
        origin normalizedOrigin: String, networkID: String,
        account selectedAccount: WalletAccount, action: WalletSemanticAction
    ) async throws -> String {
        guard let connection = activeBrowserConnection(
            origin: normalizedOrigin, networkID: networkID,
            accountID: selectedAccount.id, requiredMethod: .sendTransaction
        ) else {
            throw Error.approvalRequired("This website connection is missing or expired.")
        }
        let requestNow = Date()
        let binding = WalletConnectionRequestBinding(
            requestID: UUID().uuidString.lowercased(),
            connectionID: connection.id,
            direction: .locusVaultToDapp,
            connector: .embeddedBrowser,
            origin: normalizedOrigin,
            peerID: nil,
            accountID: selectedAccount.id,
            networkID: networkID,
            method: .sendTransaction,
            issuedAt: requestNow,
            expiresAt: min(connection.expiresAt, requestNow.addingTimeInterval(2 * 60))
        )
        try requestRouter.begin(
            WalletRoutedRequest(
                binding: binding,
                payload: .transaction(
                    action: action,
                    maximumFeeBaseUnits: Self.dappFeeCeiling(networkID: networkID)
                )
            ),
            connection: connection,
            account: selectedAccount,
            now: requestNow
        )
        defer {
            requestRouter.cancel(requestID: binding.requestID, reason: .walletRejected)
        }
        let browserSource = WalletRequestSource.embeddedBrowser(origin: normalizedOrigin)
        guard let actionObject = try dictionary(action) as? [String: Any] else {
            throw Error.invalidArguments("The browser action could not be encoded.")
        }
        let preparedResult = await perform(tool: "wallet_prepare_transaction", arguments: [
            "network_id": networkID,
            "account_id": selectedAccount.id,
            "action": actionObject,
            // Testnet-only ceiling. The exact native sheet still displays and
            // approves the authoritative simulated fee before execution.
            "maximum_fee_base_units": Self.dappFeeCeiling(networkID: networkID),
        ], source: browserSource)
        if let message = preparedResult["error"] as? String { throw Error.policyDenied(message) }
        guard let intentID = preparedResult["intent_id"] as? String else {
            throw Error.invalidArguments("The wallet did not return a transaction intent.")
        }
        do { try requestRouter.validatePending(binding: binding) }
        catch { cancelConfirmation(intentID: intentID); throw error }
        connectionIntentBindings[intentID] = binding
        defer { connectionIntentBindings[intentID] = nil }
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
        _ = try requestRouter.complete(
            requestID: binding.requestID,
            callbackBinding: binding
        )
        return hash
    }

    func browserSignInWithEthereum(
        origin: String,
        networkID: String = "eip155:11155111",
        params: [Any]
    ) async throws -> String {
        guard params.count == 2,
              let first = params[0] as? String,
              let second = params[1] as? String,
              let normalizedOrigin = Self.normalizedWebOrigin(origin),
              let accountAddress = browserAccounts(
                  origin: normalizedOrigin, networkID: networkID
              ).first,
              let selectedAccount = accounts.first(where: {
                  $0.ownership == .locusVault && $0.chain == .evm
                      && $0.networkIDs.contains(networkID)
                      && $0.address.caseInsensitiveCompare(accountAddress) == .orderedSame
              }) else {
            throw Error.invalidArguments(
                "personal_sign requires one connected account and one canonical SIWE message."
            )
        }
        let rawMessage: String
        if first.caseInsensitiveCompare(accountAddress) == .orderedSame {
            rawMessage = second
        } else if second.caseInsensitiveCompare(accountAddress) == .orderedSame {
            rawMessage = first
        } else {
            throw Error.invalidArguments(
                "The SIWE account does not match the connected Locus Vault account."
            )
        }
        guard let message = Self.personalSignMessage(rawMessage) else {
            throw Error.invalidArguments("The SIWE message is not valid UTF-8.")
        }
        let request = try WalletStructuredAuthorization.parseCanonicalMessage(
            message, format: .siwe, origin: normalizedOrigin,
            networkID: networkID, account: selectedAccount
        )
        guard reviewRegistry?.containsSignInAdapter(
            format: .siwe, networkID: networkID
        ) == true else {
            throw Error.policyDenied("The SIWE adapter is not in the signed review manifest.")
        }
        if WalletNetworkCatalog.descriptor(id: networkID)?.environment == .mainnet {
            try launchGate.authorize(
                networkID: networkID, capability: .standardizedSignIn,
                regionCode: regionCode
            )
        }
        guard let connection = activeBrowserConnection(
            origin: normalizedOrigin, networkID: networkID,
            accountID: selectedAccount.id, requiredMethod: .signInWithEthereum
        ) else {
            throw Error.approvalRequired("This website is not approved for SIWE.")
        }
        let requestNow = Date()
        let binding = WalletConnectionRequestBinding(
            requestID: UUID().uuidString.lowercased(),
            connectionID: connection.id, direction: .locusVaultToDapp,
            connector: .embeddedBrowser, origin: normalizedOrigin, peerID: nil,
            accountID: selectedAccount.id, networkID: networkID,
            method: .signInWithEthereum, issuedAt: requestNow,
            expiresAt: min(connection.expiresAt, requestNow.addingTimeInterval(2 * 60))
        )
        let routed = WalletRoutedRequest(binding: binding, payload: .signIn(request))
        try requestRouter.begin(
            routed, connection: connection, account: selectedAccount, now: requestNow
        )
        defer {
            requestRouter.cancel(requestID: binding.requestID, reason: .walletRejected)
        }
        let result = try await signer.signStructuredAuthorization(
            request, source: .embeddedBrowser(origin: normalizedOrigin)
        )
        _ = try requestRouter.complete(
            requestID: binding.requestID, callbackBinding: binding
        )
        return result.signature
    }

    func browserSignInWithSolana(
        origin: String, networkID: String,
        message: String, accountAddress: String
    ) async throws -> WalletStructuredAuthorizationResult {
        guard WalletNetworkCatalog.descriptor(id: networkID)?.chain == .solana else {
            throw Error.invalidArguments("The SIWS network is not supported.")
        }
        let (normalizedOrigin, account) = try browserAccount(
            origin: origin, networkID: networkID, address: accountAddress
        )
        let authorization = try WalletStructuredAuthorization.parseCanonicalMessage(
            message, format: .siws, origin: normalizedOrigin,
            networkID: networkID, account: account
        )
        guard reviewRegistry?.containsSignInAdapter(
            format: .siws, networkID: networkID
        ) == true else {
            throw Error.policyDenied("The SIWS adapter is not in the signed review manifest.")
        }
        guard let connection = activeBrowserConnection(
            origin: normalizedOrigin, networkID: networkID,
            accountID: account.id, requiredMethod: .signInWithSolana
        ) else {
            throw Error.approvalRequired("This website is not approved for SIWS.")
        }
        let requestNow = Date()
        let binding = WalletConnectionRequestBinding(
            requestID: UUID().uuidString.lowercased(),
            connectionID: connection.id, direction: .locusVaultToDapp,
            connector: .embeddedBrowser, origin: normalizedOrigin, peerID: nil,
            accountID: account.id, networkID: networkID,
            method: .signInWithSolana, issuedAt: requestNow,
            expiresAt: min(connection.expiresAt, requestNow.addingTimeInterval(2 * 60))
        )
        try requestRouter.begin(
            .init(binding: binding, payload: .signIn(authorization)),
            connection: connection, account: account, now: requestNow
        )
        do {
            let result = try await signer.signStructuredAuthorization(
                authorization, source: .embeddedBrowser(origin: normalizedOrigin)
            )
            _ = try requestRouter.complete(
                requestID: binding.requestID, callbackBinding: binding
            )
            return result
        } catch {
            requestRouter.cancel(requestID: binding.requestID, reason: .walletRejected)
            throw error
        }
    }

    private func handleConnectorDappRequest(
        _ request: WalletConnectorDappRequest
    ) async throws -> WalletConnectorDappResponse {
        guard walletEnabled, status == .unlocked,
              request.expiresAt > Date(),
              let connection = connections.first(where: {
                  $0.id == request.connectionID
                    && $0.connector == .walletConnect
                    && $0.direction == .locusVaultToDapp
                    && $0.peerID == request.peerID
                    && $0.peerURL == request.peerOrigin
                    && $0.networkIDs.contains(request.networkID)
                    && $0.approvedMethods.contains(request.method)
                    && $0.state == .connected
                    && $0.revokedAt == nil
                    && $0.expiresAt > Date()
              }) else {
            throw Error.approvalRequired(
                "The WalletConnect session is unavailable, changed, or expired."
            )
        }
        try launchGate.authorizeConnection(
            networkID: request.networkID, connector: .walletConnect,
            direction: .locusVaultToDapp, method: request.method,
            regionCode: regionCode
        )
        guard reviewRegistry?.containsConnector(
            .walletConnect, direction: .locusVaultToDapp,
            method: request.method
        ) == true else {
            throw WalletLaunchGateError.connectorNotReviewed
        }
        let eligible = accounts.filter {
            $0.ownership == .locusVault
                && $0.networkIDs.contains(request.networkID)
                && connection.accountIDs.contains($0.id)
        }
        let account: WalletAccount
        if let accountID = request.accountID {
            guard let selected = eligible.first(where: { $0.id == accountID }) else {
                throw WalletDappRequestRouterError.accountOwnershipMismatch
            }
            account = selected
        } else {
            guard let selected = eligible.first else {
                throw WalletDappRequestRouterError.accountOwnershipMismatch
            }
            account = selected
        }
        let binding = WalletConnectionRequestBinding(
            requestID: request.requestID,
            connectionID: connection.id,
            direction: .locusVaultToDapp,
            connector: .walletConnect,
            origin: nil,
            peerID: request.peerID,
            accountID: account.id,
            networkID: request.networkID,
            method: request.method,
            issuedAt: Date(),
            expiresAt: min(connection.expiresAt, request.expiresAt)
        )
        let source = WalletRequestSource.walletConnect(
            peerID: request.peerID, origin: request.peerOrigin,
            displayName: request.peerName
        )

        let routedPayload: WalletRoutedRequestPayload
        switch request.payload {
        case .listAccounts:
            routedPayload = .listAccounts
        case .evmTransaction(let transaction):
            routedPayload = .transaction(
                action: try await decodedEVMDappAction(
                    transaction, networkID: request.networkID,
                    account: account
                ),
                maximumFeeBaseUnits: Self.dappFeeCeiling(
                    networkID: request.networkID
                )
            )
        case .canonicalMessage(let format, let message, let address):
            guard let origin = request.peerOrigin,
                  (format == .siwe && request.method == .signInWithEthereum)
                    || (format == .siws && request.method == .signInWithSolana),
                  Self.sameAddress(address, account.address, chain: account.chain)
            else { throw WalletDappRequestRouterError.methodPayloadMismatch }
            let authorization = try WalletStructuredAuthorization.parseCanonicalMessage(
                message, format: format, origin: origin,
                networkID: request.networkID, account: account
            )
            routedPayload = .signIn(authorization)
        case .solanaTransaction(let transaction):
            routedPayload = .transaction(
                action: try await WalletDappTransactionDecoder.solana(
                    transaction, networkID: request.networkID,
                    account: account
                ),
                maximumFeeBaseUnits: Self.dappFeeCeiling(
                    networkID: request.networkID
                )
            )
        case .suiTransaction(let transaction):
            routedPayload = .transaction(
                action: try await WalletDappTransactionDecoder.sui(
                    transaction, networkID: request.networkID,
                    account: account, reviewedAssets: assets
                ),
                maximumFeeBaseUnits: Self.dappFeeCeiling(
                    networkID: request.networkID
                )
            )
        }

        let routed = WalletRoutedRequest(binding: binding, payload: routedPayload)
        guard connections.contains(connection), accounts.contains(account) else {
            throw Error.approvalRequired("The WalletConnect account or connection changed during decoding.")
        }
        try requestRouter.begin(
            routed, connection: connection, account: account, now: binding.issuedAt
        )
        do {
            switch routedPayload {
            case .listAccounts:
                _ = try requestRouter.complete(
                    requestID: binding.requestID, callbackBinding: binding
                )
                return .accounts(eligible.map {
                    WalletConnectorDappAccount(
                        address: $0.address,
                        publicKey: $0.chain == .sui ? $0.publicKeyBase64 : nil
                    )
                })
            case .signIn(let authorization):
                guard reviewRegistry?.containsSignInAdapter(
                    format: authorization.format,
                    networkID: authorization.networkID
                ) == true else {
                    throw Error.policyDenied(
                        "The canonical sign-in adapter is not in the signed review manifest."
                    )
                }
                let signed = try await signer.signStructuredAuthorization(
                    authorization, source: source
                )
                _ = try requestRouter.complete(
                    requestID: binding.requestID, callbackBinding: binding
                )
                return .signature(signed.signature)
            case .transaction(let action, let maximumFee):
                guard let actionObject = try dictionary(action) as? [String: Any] else {
                    throw Error.invalidArguments("The semantic action could not be encoded.")
                }
                let preparedTransaction = try await prepare([
                    "network_id": request.networkID,
                    "account_id": account.id,
                    "action": actionObject,
                    "maximum_fee_base_units": maximumFee,
                ], source: source)
                do { try requestRouter.validatePending(binding: binding) }
                catch { cancelConfirmation(intentID: preparedTransaction.id); throw error }
                connectionIntentBindings[preparedTransaction.id] = binding
                defer { connectionIntentBindings[preparedTransaction.id] = nil }
                guard preparedTransaction.policyDecision != "allowed_by_session_policy" else {
                    throw Error.policyDenied(
                        "Connected dapps can never consume a signer automation policy."
                    )
                }
                onBrowserAuthorizationNeeded?()
                guard await waitForConfirmation(intentID: preparedTransaction.id) else {
                    throw Error.approvalRequired(
                        "The WalletConnect transaction was rejected or expired."
                    )
                }
                try requestRouter.validatePending(binding: binding)
                let executed = try await execute(
                    ["intent_id": preparedTransaction.id], source: source
                )
                _ = try requestRouter.complete(
                    requestID: binding.requestID, callbackBinding: binding
                )
                guard let identifier = executed["transaction_hash"] as? String,
                      !identifier.isEmpty else {
                    throw Error.invalidArguments(
                        "The network provider did not return a transaction identifier."
                    )
                }
                return .transactionIdentifier(identifier)
            case .switchNetwork:
                throw WalletDappRequestRouterError.methodPayloadMismatch
            }
        } catch {
            requestRouter.cancel(
                requestID: binding.requestID, reason: .walletRejected
            )
            throw error
        }
    }

    private static func sameAddress(
        _ lhs: String, _ rhs: String, chain: WalletChain
    ) -> Bool {
        chain == .evm
            ? lhs.caseInsensitiveCompare(rhs) == .orderedSame
            : lhs == rhs
    }

    private static func dappFeeCeiling(networkID: String) -> String {
        switch WalletNetworkCatalog.descriptor(id: networkID)?.chain {
        case .evm: "10000000000000000"       // 0.01 ETH
        case .solana: "10000000"              // 0.01 SOL
        case .sui: "100000000"                // 0.1 SUI
        case nil: "0"
        }
    }

    func canUseBrowserNetwork(_ networkID: String) -> Bool {
        guard WalletNetworkCatalog.descriptor(id: networkID) != nil,
              (try? authorizeProviderBindings(networkID: networkID)) != nil else {
            return false
        }
        return (try? launchGate.authorize(
            networkID: networkID, capability: .embeddedBrowser,
            regionCode: regionCode
        )) != nil
            && reviewRegistry?.containsConnector(
                .embeddedBrowser,
                direction: .locusVaultToDapp,
                method: .listAccounts
            ) == true
    }

    private var evmAddresses: [String] {
        accounts.filter {
            $0.chain == .evm && $0.ownership == .locusVault
        }.map(\.address)
    }

    private func activeBrowserConnection(
        origin: String,
        networkID: String,
        accountID: String,
        requiredMethod: WalletConnectionMethod
    ) -> WalletConnectionRecord? {
        connections.first { connection in
            connection.connector == .embeddedBrowser
                && connection.direction == .locusVaultToDapp
                && connection.peerURL == origin
                && connection.networkIDs.contains(networkID)
                && connection.accountIDs.contains(accountID)
                && connection.approvedMethods.contains(requiredMethod)
                && connection.state == .connected
                && connection.revokedAt == nil
                && connection.expiresAt > Date()
        }
    }

    private func browserConnectionID(origin: String, networkID: String) -> String {
        let digest = SHA256.hash(data: Data("\(origin)|\(networkID)".utf8))
        return "browser-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func personalSignMessage(_ value: String) -> String? {
        guard value.utf8.count <= WalletStructuredAuthorization.maximumCanonicalMessageBytes
        else { return nil }
        guard value.hasPrefix("0x") else { return value }
        let hex = value.dropFirst(2)
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
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
        requestRouter.cancel(reason: .walletDisabled)
        let now = Date()
        for index in connections.indices where
            connections[index].connector == .embeddedBrowser
                && !connections[index].state.isTerminal {
            if let revoked = connections[index].transitioning(to: .revoked, at: now) {
                connections[index] = revoked
                try? publicStore?.upsertConnection(revoked)
            }
        }
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
            if let networkID = arguments["network_id"] as? String {
                try authorizeProviderBindings(networkID: networkID)
            }
            if tool == "wallet_lock" {
                lock()
                return ["text": "Locus Vault locked; intents, policies, and spending rules were cleared."]
            }
            if tool == "wallet_execute_external_transaction" {
                return try await executeExternal(arguments, source: source)
            }
            if tool == "wallet_quote_swap" {
                return try await quoteSwap(arguments)
            }
            if tool == "wallet_prepare_swap_allowance" {
                return try await prepareSwapAllowance(
                    arguments, source: source
                )
            }
            if tool == "wallet_list_accounts" {
                if agentToolingAvailable {
                    replaceVaultAccounts(try await signer.listAccounts())
                }
                await refreshConnections(clearErrorOnSuccess: false)
                let text = accounts.isEmpty ? "No wallet accounts are available." : accounts
                    .map { account in
                        let owner = account.ownership == .locusVault
                            ? "Locus Vault" : account.ownership.connectorID?.rawValue ?? "External"
                        return "\(account.label) · \(owner) · \(account.chain.rawValue) · \(account.address)"
                    }
                    .joined(separator: "\n")
                return ["text": text, "accounts": try dictionary(accounts)]
            }
            guard agentToolingAvailable else {
                throw signer.isAvailable ? Error.vaultLocked : Error.signerUnavailable
            }
            switch tool {
            case "wallet_get_balance", "wallet_get_assets", "wallet_get_activity":
                return try await signer.performRead(tool: tool, arguments: arguments)
            case "wallet_simulate_transaction": return try await simulate(arguments, source: source)
            case "wallet_prepare_transaction": return response(for: try await prepare(arguments, source: source))
            case "wallet_execute_transaction": return try await execute(arguments, source: source)
            case "wallet_authorize_sign_in":
                return try await authorizeStructuredSignIn(arguments, source: source)
            default: throw Error.invalidArguments("Unknown wallet tool \(tool).")
            }
        } catch {
            return ["error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription]
        }
    }

    private func authorizeStructuredSignIn(
        _ arguments: [String: Any],
        source: WalletRequestSource
    ) async throws -> [String: Any] {
        guard let formatText = nonempty(arguments["format"]),
              let format = WalletStructuredAuthorizationFormat(toolValue: formatText),
              let domain = nonempty(arguments["domain"]),
              let origin = nonempty(arguments["origin"]),
              let networkID = nonempty(arguments["network_id"]),
              let accountID = nonempty(arguments["account_id"]),
              let address = nonempty(arguments["address"]),
              let uri = nonempty(arguments["uri"]),
              let nonce = nonempty(arguments["nonce"]),
              let issuedAtText = nonempty(arguments["issued_at"]),
              let expirationText = nonempty(arguments["expiration_time"]),
              let issuedAt = Self.iso8601Date(issuedAtText),
              let expiration = Self.iso8601Date(expirationText),
              let account = accounts.first(where: {
                  $0.id == accountID && $0.ownership == .locusVault
                      && $0.networkIDs.contains(networkID)
              }), reviewRegistry?.containsSignInAdapter(
                  format: format, networkID: networkID
              ) == true else {
            throw Error.invalidArguments(
                "Provide a complete SIWE or SIWS request for a reviewed Locus Vault account and adapter."
            )
        }
        if WalletNetworkCatalog.descriptor(id: networkID)?.environment == .mainnet {
            try launchGate.authorize(
                networkID: networkID,
                capability: .standardizedSignIn,
                regionCode: regionCode
            )
        }
        let resources = arguments["resources"] as? [String] ?? []
        let request = WalletStructuredAuthorizationRequest(
            format: format,
            domain: domain,
            origin: origin,
            networkID: networkID,
            accountID: accountID,
            address: address,
            statement: nonempty(arguments["statement"]),
            uri: uri,
            nonce: nonce,
            issuedAt: issuedAt,
            expirationTime: expiration,
            notBefore: nonempty(arguments["not_before"]).flatMap(Self.iso8601Date),
            requestID: nonempty(arguments["request_id"]),
            resources: resources
        )
        try WalletStructuredAuthorization.validate(request, account: account)
        let result = try await signer.signStructuredAuthorization(request, source: source)
        return [
            "text": "Approved canonical \(format == .siwe ? "SIWE" : "SIWS") for \(domain).",
            "format": format.rawValue,
            "network_id": networkID,
            "account_id": accountID,
            "canonical_message": result.canonicalMessage,
            "message_digest": result.messageDigest,
            "signature": result.signature,
            "signature_encoding": result.signatureEncoding.rawValue,
            "signed_at": ISO8601DateFormatter().string(from: result.signedAt),
        ]
    }

    private static func iso8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func dateArgument(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let text = value as? String { return iso8601Date(text) }
        return nil
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
        return try await prepare(request, now: now)
    }

    private func prepare(
        _ request: WalletPrepareRequest,
        now: Date = Date()
    ) async throws -> WalletPreparedTransaction {
        try authorizeProviderBindings(networkID: request.networkID)
        prepared = prepared.filter { $0.value.expiresAt > now }
        confirmedIntentIDs = confirmedIntentIDs.intersection(Set(prepared.keys))
        guard prepared.count < Self.maximumPreparedIntents else {
            throw Error.policyDenied("Too many wallet intents are pending for this session.")
        }
        guard accounts.contains(where: {
            $0.id == request.accountID
                && $0.ownership == .locusVault
                && $0.networkIDs.contains(request.networkID)
        }) else {
            throw Error.policyDenied(
                "External accounts can never consume a Locus Vault signer policy."
            )
        }
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
        case .fungibleTokenTransfer:
            let chain = WalletNetworkCatalog.descriptor(id: request.networkID)?.chain
            if chain == .solana {
                try validateReviewedSolanaAsset(
                    for: request.action, networkID: request.networkID
                )
                contract = nil
            } else if chain == .sui {
                try validateReviewedSuiAsset(
                    for: request.action, networkID: request.networkID
                )
                contract = nil
            } else {
                contract = try reviewedAssetContract(
                    for: request.action, networkID: request.networkID
                )
            }
        case .nftTransfer:
            let chain = WalletNetworkCatalog.descriptor(
                id: request.networkID
            )?.chain
            if chain == .solana {
                try validateReviewedSolanaCollectible(
                    for: request.action, networkID: request.networkID
                )
                contract = nil
            } else if chain == .sui {
                try validateReviewedSuiObject(
                    for: request.action, networkID: request.networkID
                )
                contract = nil
            } else {
                contract = try reviewedAssetContract(
                    for: request.action, networkID: request.networkID
                )
            }
        case .exactInputSwap:
            let reviewed = try reviewedSwapContract(
                for: request.action, networkID: request.networkID
            )
            guard let account = accounts.first(where: {
                $0.id == request.accountID
            }), let route = request.action.swapRoute,
            let evidence = route.quoteEvidence,
            let configuration = reviewRegistry?.uniswapConfiguration(
                networkID: request.networkID,
                universalRouterContractID: reviewed.id
            ) else {
                throw Error.invalidArguments(
                    "The active reviewed swap quote is incomplete."
                )
            }
            let allowance = try await uniswapAllowanceState(
                account: account,
                quote: WalletUniswapQuote(
                    action: request.action, quotedAt: evidence.quotedAt,
                    expiresAt: evidence.expiresAt
                ),
                configuration: configuration
            )
            guard allowance == .sufficient else {
                throw Error.needsAllowance(allowance)
            }
            contract = reviewed
        case .swapAllowanceSetup:
            contract = try reviewedSwapAllowanceContract(
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

    private func executeExternal(
        _ arguments: [String: Any],
        source: WalletRequestSource
    ) async throws -> [String: Any] {
        guard walletEnabled, connectionsClient.isAvailable else {
            throw Error.connectionHelperUnavailable
        }
        let prepare = try parsePrepareRequest(arguments, source: source)
        return try await executeExternal(prepare)
    }

    private func executeExternal(
        _ prepare: WalletPrepareRequest
    ) async throws -> [String: Any] {
        try authorizeProviderBindings(networkID: prepare.networkID)
        #if !LOCUS_DIRECT_DOWNLOAD
        _ = prepare
        throw Error.connectionHelperUnavailable
        #else
        guard walletEnabled, connectionsClient.isAvailable else {
            throw Error.connectionHelperUnavailable
        }
        let contract = try validateExternalAction(
            prepare.action, networkID: prepare.networkID
        )
        guard let account = accounts.first(where: {
            $0.id == prepare.accountID
                && $0.networkIDs.contains(prepare.networkID)
                && $0.ownership.connectorID != nil
        }), let connectorID = account.ownership.connectorID,
        let connection = connections.first(where: {
            $0.connector.externalConnectorID == connectorID
                && $0.direction == .externalAccountToLocus
                && $0.accountIDs.contains(account.id)
                && $0.networkIDs.contains(prepare.networkID)
                && $0.approvedMethods.contains(.sendTransaction)
                && $0.state == .connected
                && $0.revokedAt == nil
                && $0.expiresAt > Date()
        }) else {
            throw Error.externalWallet(
                "The selected external account is not connected for that network and action."
            )
        }
        let now = Date()
        let binding = WalletConnectionRequestBinding(
            requestID: UUID().uuidString.lowercased(),
            connectionID: connection.id,
            direction: .externalAccountToLocus,
            connector: connection.connector,
            origin: nil,
            peerID: nil,
            accountID: account.id,
            networkID: prepare.networkID,
            method: .sendTransaction,
            issuedAt: now,
            expiresAt: min(connection.expiresAt, now.addingTimeInterval(2 * 60))
        )
        let routed: WalletRoutedRequest
        if prepare.action.type == .swapAllowanceSetup {
            guard let contract, let setup = prepare.action.swapAllowanceSetup,
                  let configuration = reviewRegistry?.uniswapConfiguration(
                    networkID: prepare.networkID,
                    universalRouterContractID: setup.binding.universalRouterContractID
                  ) else {
                throw Error.invalidArguments(
                    "Refresh the reviewed swap before setting up its finite allowance."
                )
            }
            routed = try requestRouter.beginInternalSwapAllowance(
                WalletInternalSwapAllowanceRequest(
                    preparation: prepare, reviewedContract: contract,
                    reviewedConfiguration: configuration
                ),
                binding: binding, connection: connection, account: account, now: now
            )
        } else {
            routed = WalletRoutedRequest(
                binding: binding,
                payload: .transaction(
                    action: prepare.action,
                    maximumFeeBaseUnits: prepare.maximumFeeBaseUnits
                )
            )
            try requestRouter.begin(
                routed, connection: connection, account: account, now: now
            )
        }
        do {
            let result: WalletExternalExecutionResult
            var reviewedSemanticDigest: String?
            let external = try await DirectWalletExternalPreparer.prepare(
                request: prepare, binding: binding, account: account,
                contract: contract,
                uniswapConfiguration: {
                    let routerID = prepare.action.swapAllowanceSetup?
                        .binding.universalRouterContractID
                        ?? (prepare.action.type == .exactInputSwap
                            ? prepare.action.contractID : nil)
                    return routerID.flatMap {
                        reviewRegistry?.uniswapConfiguration(
                            networkID: prepare.networkID,
                            universalRouterContractID: $0
                        )
                    }
                }()
            )
            try requestRouter.validatePending(binding: binding)
            prepared[external.review.id] = external.review
            connectionIntentBindings[external.review.id] = binding
            defer { connectionIntentBindings[external.review.id] = nil }
            pendingConfirmation = external.review
            guard await waitForConfirmation(intentID: external.review.id) else {
                throw Error.approvalRequired(
                    "Exact Locus review is required before this connector may submit."
                )
            }
            let refreshed = try await DirectWalletExternalPreparer.recheck(
                external, request: prepare, binding: binding, account: account
            )
            try requestRouter.validatePending(binding: binding)
            try authorizeProviderBindings(networkID: prepare.networkID)
            try launchGate.authorizeConnection(
                networkID: prepare.networkID, connector: connection.connector,
                direction: connection.direction, method: .sendTransaction,
                regionCode: regionCode
            )
            reviewedSemanticDigest = refreshed.semanticDigest
            let evmCommitment = try refreshed.payload.evm.map {
                try WalletSubmittedTransactionReconciler.evmTransactionCommitment($0,
                    maximumFeeBaseUnits: external.review.maximumFeeBaseUnits)
            }
            try await requireCurrentReleaseAuthority(networkID: prepare.networkID)
            try requestRouter.validatePending(binding: binding)
            try WalletCanaryBudget.reserve(
                transaction: external.review,
                ownership: .required(for: connection.connector), connector: connection.connector,
                manifest: verifiedReleaseAuthority?.budgetManifest() ?? launchGate.effectiveManifest,
                sourceRevision: verifiedReleaseAuthority?.checkpoint.signedTransition.envelope.candidateID
                    ?? installedReleaseIdentity?.sourceRevision ?? "",
                signerOwned: false, enforcePermanentLimits: true
            )
            result = try await connectionsClient.executeExternal(
                WalletExternalExecutionRequest(
                    request: routed, prepared: refreshed
                )
            )
            prepared[external.review.id] = nil
            confirmedIntentIDs.remove(external.review.id)
            guard result.binding == binding, !result.transactionID.isEmpty else {
                throw Error.externalWallet(
                    "The external wallet did not return a transaction identifier."
                )
            }
            let record = WalletActivityRecord(
                id: result.transactionID.lowercased(),
                intentID: binding.requestID,
                transactionHash: result.transactionID,
                networkID: prepare.networkID,
                accountID: account.id,
                summary: externalActionSummary(prepare.action, connectorID: connectorID),
                submittedAt: result.submittedAt,
                state: .submitted,
                blockNumber: nil,
                lastCheckedAt: nil,
                detail: "Confirmed and submitted by \(connectorID.rawValue).",
                direction: .outbound,
                source: prepare.source,
                actionKind: prepare.action.type,
                assetID: prepare.action.assetID ?? prepare.action.inputAssetID,
                amountBaseUnits: prepare.action.amountBaseUnits,
                finality: .pending,
                expiresAt: binding.expiresAt,
                expectedAction: prepare.action,
                semanticDigest: reviewedSemanticDigest,
                expectedContractAddress: contract?.checksumAddress,
                expectedEVMTransactionDigest: evmCommitment,
                expectedEVMMaximumFeeBaseUnits: evmCommitment == nil ? nil : external.review.maximumFeeBaseUnits
            )
            transactionHistory.removeAll { $0.id == record.id }
            transactionHistory.insert(record, at: 0)
            try? publicStore?.upsertActivity(record)
            // Keep the broadcast record even when authority was canceled while
            // the wallet prompt was open; a canceled caller must not erase a
            // transaction that still needs independent reconciliation.
            _ = try requestRouter.complete(
                requestID: binding.requestID, callbackBinding: result.binding
            )
            // Attempt the first independent chain fetch immediately. A relay
            // identifier alone keeps the record pending; only reconciled
            // sender/network/effects can promote it to successful activity.
            await refreshTransactionHistory()
            return [
                "text": account.ownership.requiresWalletOwnedConfirmation
                    ? "Submitted by \(connectorID.rawValue) after wallet confirmation."
                    : "Submitted by Phantom after exact Locus review.",
                "intent_id": binding.requestID,
                "transaction_hash": result.transactionID,
                "network_id": prepare.networkID,
                "status": "submitted",
            ]
        } catch {
            cancelConfirmation(intentID: binding.requestID)
            requestRouter.cancel(requestID: binding.requestID, reason: .walletRejected)
            throw error
        }
        #endif
    }

    private func validateExternalAction(
        _ action: WalletSemanticAction,
        networkID: String
    ) throws -> WalletContractRegistryEntry? {
        switch action.type {
        case .nativeTransfer:
            return nil
        case .fungibleTokenTransfer:
            let chain = WalletNetworkCatalog.descriptor(id: networkID)?.chain
            if chain == .solana {
                try validateReviewedSolanaAsset(for: action, networkID: networkID)
                return nil
            } else if chain == .sui {
                try validateReviewedSuiAsset(for: action, networkID: networkID)
                return nil
            } else {
                return try reviewedAssetContract(for: action, networkID: networkID)
            }
        case .nftTransfer:
            let chain = WalletNetworkCatalog.descriptor(id: networkID)?.chain
            if chain == .solana {
                try validateReviewedSolanaCollectible(for: action, networkID: networkID)
                return nil
            } else if chain == .sui {
                try validateReviewedSuiObject(for: action, networkID: networkID)
                return nil
            } else {
                return try reviewedAssetContract(for: action, networkID: networkID)
            }
        case .exactInputSwap:
            return try reviewedSwapContract(for: action, networkID: networkID)
        case .swapAllowanceSetup:
            return try reviewedSwapAllowanceContract(
                for: action, networkID: networkID
            )
        case .reviewedCall, .standardizedSignIn, .reviewedTypedAuthorization,
             .contractCall:
            throw Error.invalidArguments(
                "That external-wallet operation is outside the reviewed action set."
            )
        }
    }

    private func externalActionSummary(
        _ action: WalletSemanticAction,
        connectorID: WalletExternalConnectorID
    ) -> String {
        let operation = switch action.type {
        case .nativeTransfer: "native transfer"
        case .fungibleTokenTransfer: "token transfer"
        case .nftTransfer: "collectible transfer"
        case .exactInputSwap: "exact-input swap"
        case .swapAllowanceSetup: "finite swap allowance setup"
        case .reviewedCall, .contractCall: "reviewed call"
        case .standardizedSignIn, .reviewedTypedAuthorization: "authorization"
        }
        return "\(connectorID.rawValue) \(operation)"
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
        if asset.trust == .curated,
           reviewRegistry?.containsExactContract(entry) != true {
            throw Error.invalidArguments(
                "The curated asset contract is not present in the signed release review manifest."
            )
        }
        return entry
    }

    private func reviewedSwapContract(
        for action: WalletSemanticAction,
        networkID: String
    ) throws -> WalletContractRegistryEntry {
        guard action.type == .exactInputSwap,
              let contractID = action.contractID,
              let adapterID = action.adapterID,
              let route = action.swapRoute,
              adapterID
                == WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
              let entry = contractRegistry.first(where: {
                  $0.id == contractID && $0.networkID == networkID
              }),
              let configuration = reviewRegistry?.uniswapConfiguration(
                networkID: networkID,
                universalRouterContractID: contractID
              ),
              WalletReviewedAdapters.validatedID(for: entry) == adapterID,
              reviewRegistry?.containsExactContract(entry) == true,
              validUniswapQuoteEvidence(
                action: action, route: route,
                configuration: configuration, routerEntry: entry
              ),
              route.pathAssetIDs.allSatisfy({ assetID in
                  guard let identity = WalletEVMAssetIdentity.parse(assetID),
                        identity.networkID == networkID,
                        identity.standard == .erc20,
                        let asset = assets.first(where: { $0.id == assetID }),
                        asset.chain == .evm, asset.kind == .fungibleToken,
                        asset.trust == .curated,
                        asset.reference?.caseInsensitiveCompare(
                            identity.contractAddress
                        ) == .orderedSame else { return false }
                  return reviewRegistry?.containsExactAsset(asset) == true
              }) else {
            throw Error.invalidArguments(
                "The swap router, adapter, and complete asset route are not present in the signed review manifest."
            )
        }
        return entry
    }

    private func reviewedSwapAllowanceContract(
        for action: WalletSemanticAction,
        networkID: String
    ) throws -> WalletContractRegistryEntry {
        guard action.type == .swapAllowanceSetup,
              let setup = action.swapAllowanceSetup,
              setup.binding.networkID == networkID,
              setup.binding.digest() == setup.bindingDigest,
              let configuration = reviewRegistry?.uniswapConfiguration(
                networkID: networkID,
                universalRouterContractID:
                    setup.binding.universalRouterContractID
              ),
              configuration.permit2ContractID.count > 0,
              (try? reviewedSwapContract(
                for: setup.binding.exactInputSwapAction(),
                networkID: networkID
              )) != nil,
              let entry = contractRegistry.first(where: {
                $0.id == action.contractID && $0.networkID == networkID
              }),
              reviewRegistry?.containsExactContract(entry) == true,
              WalletSwapAllowanceAdapter.resolve(
                action: action, registryEntry: entry,
                configuration: configuration
              ) != nil else {
            throw Error.invalidArguments(
                "The allowance must be finite and derived from an active signed swap quote."
            )
        }
        if setup.stage == .erc20Reset {
            guard configuration.zeroFirstApprovalAssetIDs.contains(
                setup.binding.inputAssetID
            ) else {
                throw Error.invalidArguments(
                    "This reviewed token does not require a zero-first allowance."
                )
            }
        }
        return entry
    }

    private func validUniswapQuoteEvidence(
        action: WalletSemanticAction,
        route: WalletExactInputSwapRoute,
        configuration: WalletReviewedUniswapConfiguration,
        routerEntry: WalletContractRegistryEntry,
        now: Date = Date()
    ) -> Bool {
        guard let evidence = route.quoteEvidence,
              let amountIn = WalletBaseUnits.normalize(
                action.amountBaseUnits ?? ""
              ), amountIn != "0",
              WalletBaseUnits.normalize(evidence.blockNumber) == evidence.blockNumber,
              evidence.blockHash.count == 66,
              evidence.blockHash.hasPrefix("0x"),
              evidence.blockHash.dropFirst(2).allSatisfy(\.isHexDigit),
              evidence.quotedAt <= now.addingTimeInterval(5),
              evidence.expiresAt > now,
              evidence.expiresAt.timeIntervalSince(evidence.quotedAt) <= 60.5,
              let deadline = UInt64(route.deadlineUnixSeconds),
              deadline <= UInt64(max(0, evidence.quotedAt.timeIntervalSince1970)) + 600,
              route.slippageBPS <= 500,
              evidence.perHopOutputBaseUnits.count == route.pathAssetIDs.count - 1,
              evidence.perHopOutputBaseUnits.allSatisfy({
                  WalletBaseUnits.normalize($0) == $0 && $0 != "0"
              }),
              evidence.perHopOutputBaseUnits.last == route.quotedOutputBaseUnits,
              evidence.gasEstimate != "0",
              WalletBaseUnits.normalize(evidence.gasEstimate) == evidence.gasEstimate,
              let router = configuration.contract(.universalRouter),
              router.address.caseInsensitiveCompare(routerEntry.checksumAddress)
                == .orderedSame,
              router.runtimeCodeHash.caseInsensitiveCompare(routerEntry.runtimeCodeHash)
                == .orderedSame else { return false }
        #if DEBUG
        guard evidence.agreeingProviderCount >= 1 else { return false }
        #else
        guard evidence.agreeingProviderCount >= 2 else { return false }
        #endif
        let quoteRole: WalletReviewedUniswapContractRole =
            route.protocolVersion == .v2 ? .v2Router : .v3QuoterV2
        guard let quoteContract = configuration.contract(quoteRole),
              quoteContract.address.caseInsensitiveCompare(
                evidence.quoteContractAddress
              ) == .orderedSame,
              quoteContract.runtimeCodeHash.caseInsensitiveCompare(
                evidence.quoteContractRuntimeCodeHash
              ) == .orderedSame else { return false }
        let candidates = WalletUniswapRoutePlanner.candidates(
            configuration: configuration,
            inputAssetID: route.pathAssetIDs.first ?? "",
            outputAssetID: route.pathAssetIDs.last ?? ""
        )
        guard candidates.contains(where: {
            $0.protocolVersion == route.protocolVersion
                && $0.pathAssetIDs == route.pathAssetIDs
                && $0.feeTiers == route.feeTiers
        }) else { return false }
        guard route.minimumHopPriceX36.count == evidence.perHopOutputBaseUnits.count else {
            return false
        }
        var hopInput = amountIn
        let scaleX36 = "1" + String(repeating: "0", count: 36)
        for index in evidence.perHopOutputBaseUnits.indices {
            let output = evidence.perHopOutputBaseUnits[index]
            guard let scaled = WalletBaseUnits.multiply(output, scaleX36),
                  let rawPrice = WalletBaseUnits.divide(scaled, by: hopInput)?.quotient,
                  let expected = WalletBaseUnits.applyingBasisPointFloor(
                    rawPrice, bpsToKeep: 10_000 - route.slippageBPS
                  ), expected == route.minimumHopPriceX36[index] else { return false }
            hopInput = output
        }
        return true
    }

    private func uniswapAllowanceState(
        account: WalletAccount,
        quote: WalletUniswapQuote,
        configuration: WalletReviewedUniswapConfiguration
    ) async throws -> WalletUniswapAllowanceState {
        guard let inputAssetID = quote.action.inputAssetID,
              let input = WalletEVMAssetIdentity.parse(inputAssetID),
              input.networkID == configuration.networkID,
              input.standard == .erc20, input.tokenID == nil,
              let amount = WalletBaseUnits.normalize(
                quote.action.amountBaseUnits ?? ""
              ), amount != "0",
              WalletBaseUnits.lessThanOrEqual(
                amount,
                "1461501637330902918203684832716283019655932542975"
              ),
              let deadline = WalletBaseUnits.normalize(
                quote.action.swapRoute?.deadlineUnixSeconds ?? ""
              ),
              let permit2 = configuration.contract(.permit2),
              let router = configuration.contract(.universalRouter),
              let ownerWord = Self.evmABIAddressWord(account.address),
              let permit2Word = Self.evmABIAddressWord(permit2.address),
              let tokenWord = Self.evmABIAddressWord(input.contractAddress),
              let routerWord = Self.evmABIAddressWord(router.address) else {
            throw WalletUniswapQuoteError.malformedRequest
        }
        let erc20Response = try await signer.browserRPC(
            networkID: configuration.networkID,
            method: "eth_call",
            params: [[
                "to": input.contractAddress,
                "data": "0xdd62ed3e" + ownerWord + permit2Word,
            ], "latest"]
        )
        guard let erc20Encoded = erc20Response as? String,
              let erc20Allowance = Self.singleABIUnsigned(erc20Encoded) else {
            throw WalletUniswapQuoteError.malformedQuote
        }
        if !WalletBaseUnits.lessThanOrEqual(amount, erc20Allowance) {
            return .needsERC20Approval(
                tokenAddress: input.contractAddress,
                permit2Address: permit2.address,
                amountBaseUnits: amount,
                requiresZeroFirst:
                    configuration.zeroFirstApprovalAssetIDs.contains(inputAssetID)
                        && erc20Allowance != "0"
            )
        }
        let permit2Response = try await signer.browserRPC(
            networkID: configuration.networkID,
            method: "eth_call",
            params: [[
                "to": permit2.address,
                "data": "0x927da105" + ownerWord + tokenWord + routerWord,
            ], "latest"]
        )
        guard let permit2Encoded = permit2Response as? String,
              let words = Self.evmABIWords(permit2Encoded), words.count == 3,
              let permit2Allowance = WalletEthereumQuantity.hexToDecimal(words[0]),
              let expiration = WalletEthereumQuantity.hexToDecimal(words[1]) else {
            throw WalletUniswapQuoteError.malformedQuote
        }
        guard WalletBaseUnits.lessThanOrEqual(amount, permit2Allowance),
              WalletBaseUnits.lessThanOrEqual(deadline, expiration) else {
            return .needsPermit2Approval(
                tokenAddress: input.contractAddress,
                routerAddress: router.address,
                amountBaseUnits: amount,
                expirationUnixSeconds: deadline
            )
        }
        return .sufficient
    }

    private static func evmABIAddressWord(_ value: String) -> String? {
        guard value.count == 42, value.hasPrefix("0x"),
              value.dropFirst(2).allSatisfy(\.isHexDigit) else { return nil }
        return String(repeating: "0", count: 24)
            + String(value.dropFirst(2)).lowercased()
    }

    private static func evmABIWords(_ value: String) -> [String]? {
        let raw = value.lowercased().hasPrefix("0x")
            ? String(value.dropFirst(2)) : value
        guard !raw.isEmpty, raw.count.isMultiple(of: 64), raw.count <= 64 * 16,
              raw.allSatisfy(\.isHexDigit) else { return nil }
        return stride(from: 0, to: raw.count, by: 64).map { offset in
            let start = raw.index(raw.startIndex, offsetBy: offset)
            let end = raw.index(start, offsetBy: 64)
            return String(raw[start..<end])
        }
    }

    private static func singleABIUnsigned(_ value: String) -> String? {
        guard let words = evmABIWords(value), words.count == 1 else { return nil }
        return WalletEthereumQuantity.hexToDecimal(words[0])
    }

    private func validateReviewedSolanaAsset(
        for action: WalletSemanticAction,
        networkID: String
    ) throws {
        guard action.type == .fungibleTokenTransfer,
              let assetID = action.assetID,
              let identity = WalletSolanaAssetIdentity.parse(assetID),
              identity.networkID == networkID,
              let asset = assets.first(where: { $0.id == assetID }),
              asset.networkID == networkID, asset.chain == .solana,
              asset.kind == .fungibleToken, asset.reference == identity.mint,
              asset.decimals.map({ (0...255).contains($0) }) == true,
              asset.isVisibleByDefault else {
            throw Error.invalidArguments(
                "The selected SPL token is not trusted for reviewed transfers."
            )
        }
    }

    private func validateReviewedSolanaCollectible(
        for action: WalletSemanticAction,
        networkID: String
    ) throws {
        guard action.type == .nftTransfer,
              let assetID = action.assetID,
              let identity = WalletSolanaCollectibleIdentity.parse(assetID),
              identity.networkID == networkID, identity.standard == .core,
              action.tokenID == identity.address,
              action.amountBaseUnits == "1",
              let asset = assets.first(where: { $0.id == assetID }),
              asset.networkID == networkID, asset.chain == .solana,
              asset.kind == .nft || asset.kind == .collectible,
              asset.reference == identity.address,
              asset.decimals == nil || asset.decimals == 0,
              asset.trust == .curated,
              reviewRegistry?.containsExactAsset(asset) == true,
              reviewRegistry?.containsAdapter(
                WalletReviewedAdapters.solanaCoreTransfer
              ) == true else {
            throw Error.invalidArguments(
                "The selected Core asset is not present in the signed asset and adapter manifest."
            )
        }
    }

    private func validateReviewedSuiAsset(
        for action: WalletSemanticAction,
        networkID: String
    ) throws {
        guard action.type == .fungibleTokenTransfer,
              let assetID = action.assetID,
              let identity = WalletSuiAssetIdentity.parse(assetID),
              identity.networkID == networkID,
              identity.coinType != WalletSuiAssetIdentity.nativeCoinType,
              let asset = assets.first(where: { $0.id == assetID }),
              asset.networkID == networkID, asset.chain == .sui,
              asset.kind == .fungibleToken,
              asset.reference == identity.coinType,
              asset.decimals.map({ (0...255).contains($0) }) == true,
              asset.trust == .curated,
              reviewRegistry?.containsExactAsset(asset) == true else {
            throw Error.invalidArguments(
                "The selected Sui Coin type is not present in the signed asset manifest."
            )
        }
    }

    private func validateReviewedSuiObject(
        for action: WalletSemanticAction,
        networkID: String
    ) throws {
        guard action.type == .nftTransfer,
              let assetID = action.assetID,
              let identity = WalletSuiObjectIdentity.parse(assetID),
              identity.networkID == networkID,
              action.tokenID == identity.objectID,
              action.amountBaseUnits == "1",
              let asset = assets.first(where: { $0.id == assetID }),
              asset.networkID == networkID, asset.chain == .sui,
              asset.kind == .nft || asset.kind == .collectible,
              asset.reference == identity.objectID,
              asset.decimals == nil || asset.decimals == 0,
              asset.trust == .curated,
              reviewRegistry?.containsExactAsset(asset) == true else {
            throw Error.invalidArguments(
                "The selected Sui object is not present in the signed asset manifest."
            )
        }
    }

    private func parsePrepareRequest(
        _ arguments: [String: Any],
        source: WalletRequestSource
    ) throws -> WalletPrepareRequest {
        guard let networkID = nonempty(arguments["network_id"]),
              let descriptor = WalletNetworkCatalog.descriptor(id: networkID),
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
                  Self.validAddress(recipient, chain: descriptor.chain),
                  let amount = WalletBaseUnits.normalize(
                      nonempty(actionObject["amount_base_units"]) ?? ""
                  ), amount != "0" else {
                throw Error.invalidArguments("A native transfer requires recipient and amount_base_units.")
            }
            action = .nativeTransfer(recipient: recipient, amountBaseUnits: amount)
        case .contractCall:
            guard descriptor.chain == .evm,
                  let contractID = nonempty(actionObject["contract_id"]),
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
            guard descriptor.chain == .evm || descriptor.chain == .solana
                    || descriptor.chain == .sui,
                  let assetID = nonempty(actionObject["asset_id"]),
                  (descriptor.chain != .solana
                    || WalletSolanaAssetIdentity.parse(assetID)?.networkID == networkID),
                  (descriptor.chain != .sui
                    || WalletSuiAssetIdentity.parse(assetID)?.networkID == networkID),
                  let recipient = nonempty(actionObject["recipient"]),
                  Self.validAddress(recipient, chain: descriptor.chain),
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
            guard descriptor.chain == .evm || descriptor.chain == .solana
                    || descriptor.chain == .sui,
                  let assetID = nonempty(actionObject["asset_id"]),
                  let recipient = nonempty(actionObject["recipient"]),
                  Self.validAddress(recipient, chain: descriptor.chain),
                  actionObject["calldata"] == nil else {
                throw Error.invalidArguments(
                    "An NFT transfer requires a canonical asset ID, uint256 token ID, and raw recipient."
                )
            }
            let tokenID: String
            if descriptor.chain == .solana {
                guard let identity = WalletSolanaCollectibleIdentity.parse(assetID),
                      identity.networkID == networkID,
                      identity.standard == .core,
                      nonempty(actionObject["token_id"]) == identity.address else {
                    throw Error.invalidArguments(
                        "A Core transfer requires its canonical asset address as token_id."
                    )
                }
                tokenID = identity.address
            } else if descriptor.chain == .sui {
                guard let identity = WalletSuiObjectIdentity.parse(assetID),
                      identity.networkID == networkID,
                      nonempty(actionObject["token_id"]) == identity.objectID else {
                    throw Error.invalidArguments(
                        "A Sui object transfer requires the canonical object ID as token_id."
                    )
                }
                tokenID = identity.objectID
            } else {
                guard let normalized = WalletBaseUnits.normalize(
                    nonempty(actionObject["token_id"]) ?? ""
                ) else {
                    throw Error.invalidArguments(
                        "An EVM NFT transfer requires a canonical uint256 token ID."
                    )
                }
                tokenID = normalized
            }
            action = .nftTransfer(
                assetID: assetID, tokenID: tokenID, recipient: recipient
            )
        case .exactInputSwap:
            guard descriptor.chain == .evm,
                  let contractID = nonempty(actionObject["contract_id"]),
                  let adapterID = nonempty(actionObject["adapter_id"]),
                  adapterID
                    == WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
                  let inputAssetID = nonempty(actionObject["input_asset_id"]),
                  let outputAssetID = nonempty(actionObject["output_asset_id"]),
                  let amount = WalletBaseUnits.normalize(
                    nonempty(actionObject["amount_base_units"]) ?? ""
                  ), amount != "0",
                  let minimumOutput = WalletBaseUnits.normalize(
                    nonempty(actionObject["minimum_output_base_units"]) ?? ""
                  ), minimumOutput != "0",
                  let recipient = nonempty(actionObject["recipient"]),
                  Self.validAddress(recipient, chain: .evm),
                  let routeObject = actionObject["route"] as? [String: Any],
                  let rawProtocol = nonempty(routeObject["protocol_version"]),
                  let protocolVersion = WalletUniversalRouterSwapProtocol(
                    rawValue: rawProtocol
                  ),
                  let path = routeObject["path_asset_ids"] as? [String],
                  (2...4).contains(path.count),
                  path.first == inputAssetID, path.last == outputAssetID,
                  let rawFees = routeObject["fee_tiers"] as? [Any],
                  let feeTiers = uint32Values(rawFees),
                  let hopPrices = routeObject["minimum_hop_price_x36"]
                    as? [String],
                  let normalizedPrices = normalizedBaseUnitValues(hopPrices),
                  let quotedOutput = WalletBaseUnits.normalize(
                    nonempty(routeObject["quoted_output_base_units"]) ?? ""
                  ), quotedOutput != "0",
                  let rawSlippage = routeObject["slippage_bps"],
                  let slippageValues = uint32Values([rawSlippage]),
                  slippageValues.count == 1, slippageValues[0] <= 5_000,
                  let deadline = WalletBaseUnits.normalize(
                    nonempty(routeObject["deadline_unix_seconds"]) ?? ""
                  ),
                  let evidenceObject = routeObject["quote_evidence"]
                    as? [String: Any],
                  let quoteBlock = WalletBaseUnits.normalize(
                    nonempty(evidenceObject["block_number"]) ?? ""
                  ),
                  let quoteBlockHash = nonempty(evidenceObject["block_hash"]),
                  let quoteContractAddress = nonempty(
                    evidenceObject["quote_contract_address"]
                  ),
                  let quoteContractCodeHash = nonempty(
                    evidenceObject["quote_contract_runtime_code_hash"]
                  ),
                  let perHopOutputs = evidenceObject["per_hop_output_base_units"]
                    as? [String],
                  let normalizedHopOutputs = normalizedBaseUnitValues(perHopOutputs),
                  let gasEstimate = WalletBaseUnits.normalize(
                    nonempty(evidenceObject["gas_estimate"]) ?? ""
                  ), gasEstimate != "0",
                  let quotedAt = Self.dateArgument(evidenceObject["quoted_at"]),
                  let quoteExpiresAt = Self.dateArgument(
                    evidenceObject["expires_at"]
                  ),
                  let rawAgreement = evidenceObject["agreeing_provider_count"],
                  let agreementValues = uint32Values([rawAgreement]),
                  agreementValues.count == 1,
                  actionObject["calldata"] == nil,
                  actionObject["commands"] == nil else {
                throw Error.invalidArguments(
                    "An exact-input swap requires a reviewed router, canonical asset route, positive input and minimum output, fee tiers, per-hop floors, and deadline."
                )
            }
            let hopCount = path.count - 1
            guard (protocolVersion == .v2 && feeTiers.isEmpty)
                    || (protocolVersion == .v3 && feeTiers.count == hopCount),
                  feeTiers.allSatisfy({ $0 > 0 && $0 <= 1_000_000 }),
                  normalizedPrices.isEmpty
                    || normalizedPrices.count == hopCount,
                  normalizedPrices.allSatisfy({ $0 != "0" }),
                  path.allSatisfy({ assetID in
                      guard let identity = WalletEVMAssetIdentity.parse(assetID)
                      else { return false }
                      return identity.networkID == networkID
                          && identity.standard == .erc20
                          && identity.canonicalID == assetID
                  }) else {
                throw Error.invalidArguments(
                    "The swap route is outside the reviewed exact-input subset."
                )
            }
            action = .exactInputSwap(
                adapterID: adapterID, contractID: contractID,
                inputAssetID: inputAssetID, outputAssetID: outputAssetID,
                amountInBaseUnits: amount,
                minimumOutputBaseUnits: minimumOutput,
                recipient: recipient,
                route: WalletExactInputSwapRoute(
                    protocolVersion: protocolVersion, pathAssetIDs: path,
                    feeTiers: feeTiers,
                    minimumHopPriceX36: normalizedPrices,
                    quotedOutputBaseUnits: quotedOutput,
                    slippageBPS: Int(slippageValues[0]),
                    deadlineUnixSeconds: deadline,
                    quoteEvidence: WalletUniswapQuoteEvidence(
                        blockNumber: quoteBlock, blockHash: quoteBlockHash,
                        quoteContractAddress: quoteContractAddress,
                        quoteContractRuntimeCodeHash: quoteContractCodeHash,
                        perHopOutputBaseUnits: normalizedHopOutputs,
                        gasEstimate: gasEstimate, quotedAt: quotedAt,
                        expiresAt: quoteExpiresAt,
                        agreeingProviderCount: Int(agreementValues[0])
                    )
                )
            )
        case .swapAllowanceSetup, .reviewedCall, .standardizedSignIn,
             .reviewedTypedAuthorization:
            throw Error.invalidArguments(
                "That operation is internal or requires a reviewed chain adapter that is not active."
            )
        }
        if descriptor.environment == .mainnet {
            let capability: WalletNetworkCapability = switch kind {
            case .nativeTransfer: .nativeTransfer
            case .contractCall, .reviewedCall: .reviewedCall
            case .fungibleTokenTransfer: .fungibleTokenTransfer
            case .nftTransfer: .nftTransfer
            case .exactInputSwap: .exactInputSwap
            case .swapAllowanceSetup: .exactInputSwap
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
        guard executingIntentIDs.insert(intentID).inserted else { throw Error.intentNotFound }
        defer { executingIntentIDs.remove(intentID) }
        func validateCurrentAuthority() throws {
            guard prepared[intentID] == transaction, transaction.expiresAt > Date(),
                  walletEnabled, status == .unlocked,
                  accounts.contains(where: {
                      $0.id == transaction.accountID && $0.ownership == .locusVault
                          && $0.networkIDs.contains(transaction.networkID)
                  }) else { throw Error.intentNotFound }
            if let binding = connectionIntentBindings[intentID] {
                try requestRouter.validatePending(binding: binding)
            }
        }
        try validateCurrentAuthority()
        if transaction.policyDecision != "allowed_by_session_policy" {
            guard confirmedIntentIDs.remove(intentID) != nil else {
                pendingConfirmation = transaction
                throw Error.approvalRequired(transaction.policyDecision)
            }
            try await signer.confirmExecution(intentID: intentID)
            try validateCurrentAuthority()
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
        let policySessionID = signer.sessionID
        let policyStatuses = try? await signer.listPolicies()
        if status == .unlocked, signer.sessionID == policySessionID,
           let policyStatuses {
            activePolicyStatuses = policyStatuses
            activePolicies = policyStatuses.map(\.policy)
        }
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
        if transactionHistory.count > 500 {
            let removed = transactionHistory.suffix(from: 500).map(\.id)
            transactionHistory.removeLast(transactionHistory.count - 500)
            for id in removed { try? publicStore?.deleteActivity(id: id) }
        }
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

    private func uint32Values(_ values: [Any]) -> [UInt32]? {
        var result: [UInt32] = []
        for value in values {
            let text: String
            if let string = value as? String {
                text = string
            } else if let number = value as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() {
                text = number.stringValue
            } else {
                return nil
            }
            guard let normalized = WalletBaseUnits.normalize(text),
                  normalized == text, let parsed = UInt32(normalized) else {
                return nil
            }
            result.append(parsed)
        }
        return result
    }

    private func normalizedBaseUnitValues(_ values: [String]) -> [String]? {
        let normalized = values.compactMap(WalletBaseUnits.normalize)
        guard normalized.count == values.count, normalized == values else {
            return nil
        }
        return normalized
    }

    private func dictionary<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
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

      // Wallet Standard registrations are deliberately implemented on top of
      // the same bounded native request bridge. Transaction objects are
      // reduced to unsigned bytes here; native code re-decodes their intent
      // and the isolated signer rebuilds supported actions from scratch.
      const walletIcon = detail.info.icon;
      const decodeBase64 = value => {
        if (typeof value !== 'string' || value.length > 16384) throw new Error('Malformed wallet bytes.');
        const binary = atob(value);
        return Uint8Array.from(binary, character => character.charCodeAt(0));
      };
      const encodeBase64 = value => {
        const bytes = value instanceof Uint8Array ? value :
          value instanceof ArrayBuffer ? new Uint8Array(value) :
          ArrayBuffer.isView(value) ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength) : null;
        if (!bytes || bytes.byteLength > 8192) throw new Error('A bounded unsigned transaction is required.');
        let binary = '';
        for (const byte of bytes) binary += String.fromCharCode(byte);
        return btoa(binary);
      };
      const decodeBase58 = value => {
        const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
        if (typeof value !== 'string' || !value || value.length > 128) throw new Error('Malformed signature.');
        const bytes = [0];
        for (const character of value) {
          const digit = alphabet.indexOf(character);
          if (digit < 0) throw new Error('Malformed signature.');
          let carry = digit;
          for (let index = 0; index < bytes.length; index++) {
            carry += bytes[index] * 58;
            bytes[index] = carry & 255;
            carry >>= 8;
          }
          while (carry) { bytes.push(carry & 255); carry >>= 8; }
        }
        for (let index = 0; index < value.length - 1 && value[index] === '1'; index++) bytes.push(0);
        return Uint8Array.from(bytes.reverse());
      };
      const standardListeners = () => {
        const values = new Set();
        return {
          emit(accounts) { for (const listener of values) { try { listener({ accounts }); } catch (_) {} } },
          on(event, listener) {
            if (event !== 'change' || typeof listener !== 'function') return () => {};
            values.add(listener); return () => values.delete(listener);
          },
        };
      };
      const standardAccount = (record, chain, features) => Object.freeze({
        address: record.address,
        publicKey: decodeBase64(record.publicKeyBase64),
        chains: Object.freeze([chain]),
        features: Object.freeze(features),
        label: record.label || 'Locus Vault',
        icon: walletIcon,
      });
      const registerStandardWallet = wallet => {
        const register = api => { try { api.register(wallet); } catch (_) {} };
        addEventListener('wallet-standard:app-ready', event => register(event.detail));
        dispatchEvent(new CustomEvent('wallet-standard:register-wallet', {
          detail: api => register(api)
        }));
      };

      const solanaChains = Object.freeze(['solana:mainnet-beta', 'solana:devnet']);
      let solanaAccounts = Object.freeze([]);
      const solanaEvents = standardListeners();
      const solanaConnect = async (input = {}) => {
        const chain = input?.chain;
        if (!solanaChains.includes(chain)) throw new Error('Select a supported Solana network.');
        const records = await request({ method: 'locus_solana_connect', params: [{ networkID: chain }] });
        solanaAccounts = Object.freeze((records || []).map(record => standardAccount(
          record, record.networkID, ['solana:signAndSendTransaction', 'solana:signIn']
        )));
        solanaEvents.emit(solanaAccounts);
        return { accounts: solanaAccounts };
      };
      const solanaDisconnect = async () => {
        await request({ method: 'locus_wallet_standard_disconnect' });
        solanaAccounts = Object.freeze([]); solanaEvents.emit(solanaAccounts);
      };
      const solanaSignAndSend = async (...inputs) => Promise.all(inputs.map(async input => {
        const account = input?.account || solanaAccounts[0];
        if (!account || !input || !solanaChains.includes(input.chain) || !account.chains.includes(input.chain)) {
          throw new Error('A connected account on the selected Solana network is required.');
        }
        const signature = await request({
          method: 'locus_solana_signAndSendTransaction',
          params: [{
            transactionBase64: encodeBase64(input.transaction),
            accountAddress: account.address,
            networkID: input.chain,
            minimumContextSlot: input.options?.minContextSlot == null ? null : String(input.options.minContextSlot),
          }],
        });
        return { signature: decodeBase58(signature) };
      }));
      const canonicalSIWS = (input, address, chain) => {
        const domain = input?.domain || location.host;
        const uri = input?.uri || location.origin;
        const issuedAt = input?.issuedAt || new Date().toISOString();
        const expirationTime = input?.expirationTime || new Date(Date.now() + 600000).toISOString();
        if (domain.toLowerCase() !== location.host.toLowerCase() || !input?.nonce) {
          throw new Error('SIWS requires this origin and a nonce.');
        }
        const lines = [`${domain} wants you to sign in with your Solana account:`, address, ''];
        if (input.statement) lines.push(input.statement, '');
        const chainID = chain === 'solana:mainnet-beta' ? 'mainnet' : 'devnet';
        lines.push(`URI: ${uri}`, 'Version: 1', `Chain ID: ${chainID}`, `Nonce: ${input.nonce}`,
          `Issued At: ${issuedAt}`, `Expiration Time: ${expirationTime}`);
        if (input.notBefore) lines.push(`Not Before: ${input.notBefore}`);
        if (input.requestId) lines.push(`Request ID: ${input.requestId}`);
        if (Array.isArray(input.resources) && input.resources.length) {
          lines.push('Resources:', ...input.resources.map(resource => `- ${resource}`));
        }
        return lines.join('\n');
      };
      const solanaSignIn = async (...inputs) => Promise.all(inputs.map(async input => {
        const account = solanaAccounts.find(item => !input?.address || item.address === input.address) || solanaAccounts[0];
        if (!account || !solanaChains.includes(input?.chain) || !account.chains.includes(input.chain)) {
          throw new Error('Connect Locus Vault on the selected Solana network before signing in.');
        }
        const result = await request({
          method: 'locus_solana_signIn',
          params: [{
            accountAddress: account.address, networkID: input.chain,
            message: canonicalSIWS(input, account.address, input.chain)
          }],
        });
        return {
          account,
          signedMessage: new TextEncoder().encode(result.canonicalMessage),
          signature: decodeBase58(result.signature),
        };
      }));
      const solanaWallet = Object.freeze({
        version: '1.0.0', name: 'Locus Vault', icon: walletIcon, chains: solanaChains,
        get accounts() { return solanaAccounts; },
        features: Object.freeze({
          'standard:connect': Object.freeze({ version: '1.0.0', connect: solanaConnect }),
          'standard:disconnect': Object.freeze({ version: '1.0.0', disconnect: solanaDisconnect }),
          'standard:events': Object.freeze({ version: '1.0.0', on: solanaEvents.on }),
          'solana:signAndSendTransaction': Object.freeze({
            version: '1.0.0', supportedTransactionVersions: Object.freeze(['legacy', 0]),
            signAndSendTransaction: solanaSignAndSend,
          }),
          'solana:signIn': Object.freeze({ version: '1.0.0', signIn: solanaSignIn }),
        }),
      });

      const suiChains = Object.freeze(['sui:mainnet', 'sui:testnet']);
      let suiAccounts = Object.freeze([]);
      const suiEvents = standardListeners();
      const suiConnect = async (input = {}) => {
        const chain = input?.chain;
        if (!suiChains.includes(chain)) throw new Error('Select a supported Sui network.');
        const records = await request({ method: 'locus_sui_connect', params: [{ networkID: chain }] });
        suiAccounts = Object.freeze((records || []).map(record => standardAccount(
          record, record.networkID, ['sui:signAndExecuteTransaction']
        )));
        suiEvents.emit(suiAccounts);
        return { accounts: suiAccounts };
      };
      const suiDisconnect = async () => {
        await request({ method: 'locus_wallet_standard_disconnect' });
        suiAccounts = Object.freeze([]); suiEvents.emit(suiAccounts);
      };
      const suiTransactionBase64 = async input => {
        if (typeof input?.transactionBase64 === 'string') return input.transactionBase64;
        if (typeof input?.transactionBlock === 'string') return input.transactionBlock;
        if (typeof input?.transaction === 'string') return input.transaction;
        if (input?.transaction && typeof input.transaction.serialize === 'function') {
          return encodeBase64(await input.transaction.serialize());
        }
        return encodeBase64(input?.transaction);
      };
      const suiSignAndExecute = async input => {
        const account = input?.account || suiAccounts[0];
        if (!account || !input || !suiChains.includes(input.chain) || !account.chains.includes(input.chain)) {
          throw new Error('A connected account on the selected Sui network is required.');
        }
        const digest = await request({
          method: 'locus_sui_signAndExecuteTransaction',
          params: [{
            transactionBase64: await suiTransactionBase64(input),
            accountAddress: account.address,
            networkID: input.chain,
          }],
        });
        return { digest };
      };
      const suiWallet = Object.freeze({
        version: '1.0.0', name: 'Locus Vault', icon: walletIcon, chains: suiChains,
        get accounts() { return suiAccounts; },
        features: Object.freeze({
          'standard:connect': Object.freeze({ version: '1.0.0', connect: suiConnect }),
          'standard:disconnect': Object.freeze({ version: '1.0.0', disconnect: suiDisconnect }),
          'standard:events': Object.freeze({ version: '1.0.0', on: suiEvents.on }),
          'sui:signAndExecuteTransaction': Object.freeze({
            version: '2.0.0', signAndExecuteTransaction: suiSignAndExecute,
          }),
        }),
      });
      registerStandardWallet(solanaWallet);
      registerStandardWallet(suiWallet);
      Object.defineProperty(globalThis, '__locusWalletStandardDisconnect', {
        configurable: false, enumerable: false,
        value() {
          solanaAccounts = Object.freeze([]); solanaEvents.emit(solanaAccounts);
          suiAccounts = Object.freeze([]); suiEvents.emit(suiAccounts);
        },
      });
    })();
    """#
}
