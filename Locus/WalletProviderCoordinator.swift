import Foundation

enum WalletProviderCoordinatorError: LocalizedError {
    case noProvider(String)
    case preparationDisagreement

    var errorDescription: String? {
        switch self {
        case .noProvider(let networkID):
            "No verified provider is configured for \(networkID)."
        case .preparationDisagreement:
            "Independent wallet providers disagreed about critical transaction evidence."
        }
    }
}

struct WalletBundledProviderConfiguration: Sendable {
    let primary: WalletProviderEndpoint
    let fallback: WalletProviderEndpoint?

    static func ethereum(
        network: WalletNetworkDescriptor,
        bundle: Bundle = .main
    ) -> WalletBundledProviderConfiguration? {
        guard network.chain == .evm else { return nil }
        let suffix = network.environment == .mainnet ? "EthereumMainnet" : "EthereumSepolia"
        let alchemy = endpoint(
            bundle.object(forInfoDictionaryKey: "LocusWalletAlchemy\(suffix)RPCURL") as? String,
            provider: .alchemy, network: network, priority: 0
        )
        let quickNode = endpoint(
            bundle.object(forInfoDictionaryKey: "LocusWalletQuickNode\(suffix)RPCURL") as? String,
            provider: .quickNode, network: network, priority: 1
        )
        if let alchemy {
            return WalletBundledProviderConfiguration(primary: alchemy, fallback: quickNode)
        }

        // Development and unsigned builds retain the existing public endpoint.
        // Release verification requires the vendor-restricted Alchemy and
        // QuickNode identifiers to be injected and checks their absence.
        let developmentURL = network.environment == .mainnet
            ? WalletSepoliaRPCClient.mainnetDefaultEndpoint
            : WalletSepoliaRPCClient.defaultEndpoint
        guard let endpoint = endpoint(
            developmentURL, provider: .userDefined, network: network, priority: 0
        ) else { return nil }
        return WalletBundledProviderConfiguration(primary: endpoint, fallback: nil)
    }

    private static func endpoint(
        _ value: String?,
        provider: WalletProviderKind,
        network: WalletNetworkDescriptor,
        priority: Int
    ) -> WalletProviderEndpoint? {
        guard let value,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return WalletProviderEndpoint(
            id: "\(provider.rawValue):\(network.id)", provider: provider,
            networkID: network.id, url: url, priority: priority,
            expectedIdentity: network.identity
        )
    }
}

/// Read and preparation failover for one EVM network. Critical preparation
/// evidence is compared when a fallback is configured. A signed transaction is
/// sent to exactly one provider; an ambiguous broadcast is never retried on the
/// fallback because doing so can create duplicate or contradictory delivery.
actor WalletEVMProviderCoordinator {
    let network: WalletNetworkDescriptor
    let primaryEndpoint: WalletProviderEndpoint
    let fallbackEndpoint: WalletProviderEndpoint?

    private let primary: WalletSepoliaRPCClient
    private let fallback: WalletSepoliaRPCClient?

    init(
        network: WalletNetworkDescriptor,
        configuration: WalletBundledProviderConfiguration,
        session: URLSession = .shared
    ) throws {
        guard configuration.primary.networkID == network.id,
              configuration.primary.expectedIdentity == network.identity,
              configuration.fallback?.networkID == nil
                || configuration.fallback?.networkID == network.id,
              configuration.fallback?.expectedIdentity == nil
                || configuration.fallback?.expectedIdentity == network.identity else {
            throw WalletProviderCoordinatorError.noProvider(network.id)
        }
        self.network = network
        primaryEndpoint = configuration.primary
        fallbackEndpoint = configuration.fallback
        primary = try WalletSepoliaRPCClient(
            network: network, endpoint: configuration.primary.url.absoluteString, session: session
        )
        fallback = try configuration.fallback.map {
            try WalletSepoliaRPCClient(
                network: network, endpoint: $0.url.absoluteString, session: session
            )
        }
    }

    func configurePrimary(endpoint: String) async throws {
        try await primary.configure(endpoint: endpoint)
    }

    func health() async throws -> String {
        do { return try await primary.health() }
        catch {
            guard let fallback else { throw error }
            return try await fallback.health()
        }
    }

    func prepare(
        request: WalletPrepareRequest,
        fromAddress: String,
        contract: WalletContractRegistryEntry? = nil,
        encodedContract: WalletEncodedContractCall? = nil
    ) async throws -> WalletEVMPreparationPacket {
        let primaryPacket: WalletEVMPreparationPacket
        do {
            primaryPacket = try await primary.prepare(
                request: request, fromAddress: fromAddress,
                contract: contract, encodedContract: encodedContract
            )
        } catch {
            guard let fallback else { throw error }
            return try await fallback.prepare(
                request: request, fromAddress: fromAddress,
                contract: contract, encodedContract: encodedContract
            )
        }
        if let fallback,
           let secondary = try? await fallback.prepare(
               request: request, fromAddress: fromAddress,
               contract: contract, encodedContract: encodedContract
           ), !Self.criticalEvidenceMatches(primaryPacket, secondary) {
            throw WalletProviderCoordinatorError.preparationDisagreement
        }
        return primaryPacket
    }

    func recheck(
        intentID: String,
        packet: WalletEVMPreparationPacket
    ) async throws -> WalletEVMRecheckPacket {
        let primaryEvidence = try await primary.recheck(intentID: intentID, packet: packet)
        if let fallback,
           let secondary = try? await fallback.recheck(intentID: intentID, packet: packet),
           (primaryEvidence.chainID != secondary.chainID
                || primaryEvidence.pendingNonce != secondary.pendingNonce
                || primaryEvidence.observedRuntimeCodeHash?.lowercased()
                    != secondary.observedRuntimeCodeHash?.lowercased()) {
            throw WalletProviderCoordinatorError.preparationDisagreement
        }
        return primaryEvidence
    }

    func broadcast(rawTransaction: String) async throws -> String {
        try await primary.broadcast(rawTransaction: rawTransaction)
    }

    func balance(address: String) async throws -> String {
        do { return try await primary.balance(address: address) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.balance(address: address)
        }
    }

    func assetBalance(
        identity: WalletEVMAssetIdentity,
        address: String
    ) async throws -> String {
        do { return try await primary.assetBalance(identity: identity, address: address) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.assetBalance(identity: identity, address: address)
        }
    }

    func tokenBalances(address: String) async throws -> [WalletEVMDiscoveredAsset] {
        if primaryEndpoint.provider == .alchemy {
            return try await primary.tokenBalances(
                provider: .alchemy, address: address
            )
        }
        if let fallback, fallbackEndpoint?.provider == .alchemy {
            return try await fallback.tokenBalances(
                provider: .alchemy, address: address
            )
        }
        throw WalletProviderCoordinatorError.noProvider(network.id)
    }

    func indexedTransfers(
        address: String,
        limit: Int = 250
    ) async throws -> [WalletEVMIndexedTransfer] {
        do {
            return try await primary.indexedTransfers(
                provider: primaryEndpoint.provider, address: address, limit: limit
            )
        } catch {
            guard let fallback, let fallbackEndpoint else { throw error }
            return try await fallback.indexedTransfers(
                provider: fallbackEndpoint.provider, address: address, limit: limit
            )
        }
    }

    func verifyContract(
        _ draft: WalletContractRegistryDraft
    ) async throws -> WalletContractRegistryEntry {
        let verified = try await primary.verifyContract(draft)
        if let fallback,
           let secondary = try? await fallback.verifyContract(draft),
           (verified.checksumAddress != secondary.checksumAddress
                || verified.abiDigest != secondary.abiDigest
                || verified.runtimeCodeHash != secondary.runtimeCodeHash
                || verified.permittedSelectors != secondary.permittedSelectors) {
            throw WalletProviderCoordinatorError.preparationDisagreement
        }
        return verified
    }

    func publicRead(method: String, params: [Any]) async throws -> Any {
        do { return try await primary.publicRead(method: method, params: params) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.publicRead(method: method, params: params)
        }
    }

    private static func criticalEvidenceMatches(
        _ lhs: WalletEVMPreparationPacket,
        _ rhs: WalletEVMPreparationPacket
    ) -> Bool {
        lhs.request == rhs.request
            && lhs.fromAddress.caseInsensitiveCompare(rhs.fromAddress) == .orderedSame
            && lhs.transaction.chainID == rhs.transaction.chainID
            && lhs.transaction.nonce == rhs.transaction.nonce
            && lhs.transaction.to.caseInsensitiveCompare(rhs.transaction.to) == .orderedSame
            && lhs.transaction.value == rhs.transaction.value
            && lhs.transaction.input.caseInsensitiveCompare(rhs.transaction.input) == .orderedSame
            && lhs.simulationSucceeded == rhs.simulationSucceeded
            && lhs.observedRuntimeCodeHash?.lowercased()
                == rhs.observedRuntimeCodeHash?.lowercased()
    }
}
