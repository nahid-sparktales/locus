import Foundation

final class WalletXPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

@MainActor
enum WalletSignerClientFactory {
    static func make() -> WalletSignerClient {
        #if LOCUS_DIRECT_DOWNLOAD
        let client = XPCWalletSignerClient()
        return client.isAvailable ? client : UnavailableWalletSignerClient()
        #else
        return UnavailableWalletSignerClient()
        #endif
    }
}

#if LOCUS_DIRECT_DOWNLOAD
private struct WalletSuiClientIntent {
    let packet: WalletSuiPreparationPacket
    let unsigned: WalletSuiUnsignedIntent
}

@MainActor
final class XPCWalletSignerClient: WalletSignerClient {
    let isAvailable: Bool
    private(set) var sessionID: String?
    var invalidationHandler: (() -> Void)?

    private var connection: NSXPCConnection?
    private var bootstrapConnection: NSXPCConnection?
    private var connectionSetupInProgress = false
    private var connectionWaiters: [CheckedContinuation<NSXPCConnection, Error>] = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rpcClients: [String: WalletEVMProviderCoordinator]
    private let solanaRPCClients: [String: WalletSolanaProviderCoordinator]
    private let suiRPCClients: [String: WalletSuiProviderCoordinator]
    private var preparationPackets: [String: WalletEVMPreparationPacket] = [:]
    private var solanaPreparationPackets: [String: WalletSolanaPreparationPacket] = [:]
    private var suiPreparationPackets: [String: WalletSuiClientIntent] = [:]

    init(bundle: Bundle = .main) {
        var clients: [String: WalletEVMProviderCoordinator] = [:]
        for network in [
            WalletNetworkCatalog.ethereumSepolia,
            WalletNetworkCatalog.ethereumMainnet,
        ] {
            guard let configuration = WalletBundledProviderConfiguration.ethereum(
                network: network, bundle: bundle
            ), let coordinator = try? WalletEVMProviderCoordinator(
                network: network, configuration: configuration
            ) else { continue }
            clients[network.id] = coordinator
        }
        rpcClients = clients
        var solanaClients: [String: WalletSolanaProviderCoordinator] = [:]
        for network in [
            WalletNetworkCatalog.solanaMainnet,
            WalletNetworkCatalog.solanaDevnet,
        ] {
            guard let configuration = WalletSolanaProviderConfiguration.bundled(
                network: network, bundle: bundle
            ), let coordinator = try? WalletSolanaProviderCoordinator(
                network: network, configuration: configuration
            ) else { continue }
            solanaClients[network.id] = coordinator
        }
        solanaRPCClients = solanaClients
        var suiClients: [String: WalletSuiProviderCoordinator] = [:]
        for network in [
            WalletNetworkCatalog.suiMainnet,
            WalletNetworkCatalog.suiTestnet,
        ] {
            guard let configuration = WalletSuiProviderConfiguration.bundled(
                network: network, bundle: bundle
            ), let coordinator = try? WalletSuiProviderCoordinator(
                network: network, configuration: configuration
            ) else { continue }
            suiClients[network.id] = coordinator
        }
        suiRPCClients = suiClients
        let serviceURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("WalletSigner.xpc", isDirectory: true)
        isAvailable = FileManager.default.fileExists(atPath: serviceURL.path)
    }

    func signerStatus() async throws -> WalletSignerStatus {
        let status: WalletSignerStatus = try await call { proxy, reply in proxy.status(reply: reply) }
        sessionID = status.sessionID
        return status
    }

    func applyReleaseActivation(
        _ envelope: WalletSignedReleaseActivationEnvelope
    ) async throws -> WalletReleaseActivationStatus {
        let data = try encoder.encode(envelope)
        return try await call { proxy, reply in
            proxy.applyReleaseActivation(data, reply: reply)
        }
    }

    func releaseAuthorityStatus() async throws -> WalletReleaseAuthorityStatus {
        try await call { proxy, reply in proxy.releaseAuthorityStatus(reply: reply) }
    }

    func applyReleaseHistory(_ history: WalletReleaseHistoryRequest) async throws -> WalletReleaseAuthorityStatus {
        let data = try encoder.encode(history)
        return try await call { proxy, reply in proxy.applyReleaseHistory(data, reply: reply) }
    }

    func deleteVault(confirmation: String) async throws -> WalletSignerStatus {
        let status: WalletSignerStatus = try await call { proxy, reply in
            proxy.deleteVault(confirmation, reply: reply)
        }
        sessionID = nil
        return status
    }

    func deleteRecoveryVault(confirmation: String) async throws -> WalletSignerStatus {
        try await call { proxy, reply in
            proxy.deleteRecoveryVault(confirmation, reply: reply)
        }
    }

    func authorizeSession() async throws {
        let status: WalletSignerStatus = try await call { proxy, reply in
            proxy.authorizeSession(
                "Unlock Locus Vault for this application session",
                reply: reply
            )
        }
        guard status.vaultState == .unlocked, let id = status.sessionID else {
            throw WalletGateway.Error.vaultLocked
        }
        sessionID = id
    }

    func listAccounts() async throws -> [WalletAccount] {
        try await call { proxy, reply in proxy.listAccounts(reply: reply) }
    }

    func signStructuredAuthorization(
        _ request: WalletStructuredAuthorizationRequest,
        source: WalletRequestSource
    ) async throws -> WalletStructuredAuthorizationResult {
        let accounts = try await listAccounts()
        guard let account = accounts.first(where: {
            $0.id == request.accountID && $0.ownership == .locusVault
                && $0.networkIDs.contains(request.networkID)
        }) else {
            throw WalletGateway.Error.invalidArguments(
                "The structured authorization account does not exist in Locus Vault."
            )
        }
        let canonical = try WalletStructuredAuthorization.canonicalMessage(
            request, account: account
        )
        let data = try authorized(request, source: source)
        let result: WalletStructuredAuthorizationResult = try await call { proxy, reply in
            proxy.signStructuredAuthorization(data, reply: reply)
        }
        guard result.request == request,
              result.canonicalMessage == canonical,
              result.signedAt <= Date(),
              result.signedAt >= request.issuedAt,
              result.signedAt < request.expirationTime else {
            throw WalletGateway.Error.invalidArguments(
                "The signer returned a different structured authorization."
            )
        }
        return result
    }

    func prepare(
        _ request: WalletPrepareRequest,
        contract: WalletContractRegistryEntry?
    ) async throws -> WalletPreparedTransaction {
        let accounts = try await listAccounts()
        guard let descriptor = WalletNetworkCatalog.descriptor(id: request.networkID),
              let account = accounts.first(where: {
                  $0.id == request.accountID && $0.chain == descriptor.chain
                      && $0.networkIDs.contains(request.networkID)
              }) else {
            throw WalletGateway.Error.invalidArguments(
                "The selected chain account does not exist in Locus Vault."
            )
        }
        switch descriptor.chain {
        case .evm:
            let encodedContract: WalletEncodedContractCall?
            if let contract {
                let encodingRequest = WalletContractEncodingRequest(
                    action: request.action, registryEntry: contract,
                    accountID: request.accountID
                )
                let requestData = try authorized(
                    encodingRequest, source: request.source
                )
                encodedContract = try await call { proxy, reply in
                    proxy.encodeEVMContract(requestData, reply: reply)
                }
            } else {
                encodedContract = nil
            }
            let rpc = try rpcClient(for: request.networkID)
            let packet = try await rpc.prepare(
                request: request, fromAddress: account.address,
                contract: contract, encodedContract: encodedContract
            )
            let data = try authorized(packet, source: request.source)
            let transaction: WalletPreparedTransaction = try await call { proxy, reply in
                proxy.prepareEVM(data, reply: reply)
            }
            preparationPackets[transaction.id] = packet
            return transaction
        case .solana:
            guard contract == nil else {
                throw WalletGateway.Error.invalidArguments(
                    "Solana transactions do not use an EVM contract registry entry."
                )
            }
            let recipientAssociatedTokenAddress: String?
            if request.action.type == .fungibleTokenTransfer,
               let assetID = request.action.assetID,
               let identity = WalletSolanaAssetIdentity.parse(assetID),
               identity.networkID == request.networkID,
               let owner = request.action.recipient {
                let derivation = WalletSolanaAssociatedTokenRequest(
                    networkID: request.networkID, owner: owner,
                    mint: identity.mint,
                    tokenProgramID: identity.program.programID
                )
                let data = try authorized(derivation, source: request.source)
                let result: WalletSolanaAssociatedTokenAddress = try await call {
                    proxy, reply in
                    proxy.deriveSolanaAssociatedToken(data, reply: reply)
                }
                recipientAssociatedTokenAddress = result.address
            } else {
                recipientAssociatedTokenAddress = nil
            }
            let rpc = try solanaRPCClient(for: request.networkID)
            let packet = try await rpc.prepare(
                request: request, feePayer: account.address,
                recipientAssociatedTokenAddress: recipientAssociatedTokenAddress
            )
            let data = try authorized(packet, source: request.source)
            let transaction: WalletPreparedTransaction = try await call { proxy, reply in
                proxy.prepareSolana(data, reply: reply)
            }
            solanaPreparationPackets[transaction.id] = packet
            return transaction
        case .sui:
            guard contract == nil,
                  request.action.type == .nativeTransfer
                    || request.action.type == .fungibleTokenTransfer
                    || request.action.type == .nftTransfer,
                  let amount = request.action.amountBaseUnits else {
                throw WalletGateway.Error.invalidArguments(
                    "Sui supports only reviewed native and curated Coin transfers."
                )
            }
            let rpc = try suiRPCClient(for: request.networkID)
            let assetID: String
            let coinType: String
            let coinObject: WalletSuiObjectReference?
            let coinBalance: String?
            let coinCheckpoint: UInt64?
            let coinCheckpointTimestamp: Date?
            let coinNetwork: WalletSuiNetworkStatus?
            let transferredObject: WalletSuiObjectReference?
            let objectHasPublicTransfer: Bool?
            let objectCheckpoint: UInt64?
            let objectCheckpointTimestamp: Date?
            let objectNetwork: WalletSuiNetworkStatus?
            let gasRequired: String
            if request.action.type == .nativeTransfer {
                guard let required = WalletBaseUnits.add(
                    amount, request.maximumFeeBaseUnits
                ) else {
                    throw WalletGateway.Error.invalidArguments(
                        "The SUI amount and gas ceiling overflow."
                    )
                }
                assetID = descriptor.nativeAssetID
                coinType = WalletSuiAssetIdentity.nativeCoinType
                coinObject = nil
                coinBalance = nil
                coinCheckpoint = nil
                coinCheckpointTimestamp = nil
                coinNetwork = nil
                transferredObject = nil
                objectHasPublicTransfer = nil
                objectCheckpoint = nil
                objectCheckpointTimestamp = nil
                objectNetwork = nil
                gasRequired = required
            } else if request.action.type == .fungibleTokenTransfer {
                guard let requestedAssetID = request.action.assetID,
                      let identity = WalletSuiAssetIdentity.parse(requestedAssetID),
                      identity.networkID == request.networkID,
                      identity.coinType != WalletSuiAssetIdentity.nativeCoinType else {
                    throw WalletGateway.Error.invalidArguments(
                        "The reviewed Sui Coin asset identity is invalid."
                    )
                }
                let selection = try await rpc.selectCoinObject(
                    owner: account.address, coinType: identity.coinType,
                    requiredBalanceBaseUnits: amount
                )
                assetID = identity.canonicalID
                coinType = identity.coinType
                coinObject = selection.object.reference
                coinBalance = selection.object.balanceBaseUnits
                coinCheckpoint = selection.snapshot.network.checkpointSequence
                coinCheckpointTimestamp = selection.snapshot.network.checkpointTimestamp
                coinNetwork = selection.snapshot.network
                transferredObject = nil
                objectHasPublicTransfer = nil
                objectCheckpoint = nil
                objectCheckpointTimestamp = nil
                objectNetwork = nil
                gasRequired = request.maximumFeeBaseUnits
            } else {
                guard let requestedAssetID = request.action.assetID,
                      let identity = WalletSuiObjectIdentity.parse(requestedAssetID),
                      identity.networkID == request.networkID,
                      request.action.tokenID == identity.objectID else {
                    throw WalletGateway.Error.invalidArguments(
                        "The reviewed Sui object identity is invalid."
                    )
                }
                let snapshot = try await rpc.ownedObjectSnapshot(owner: account.address)
                guard let object = snapshot.objects.first(where: {
                    $0.identity == identity
                }), object.hasPublicTransfer,
                   WalletSuiAssetIdentity.isCanonicalCoinType(object.moveType) else {
                    throw WalletGateway.Error.invalidArguments(
                        "The reviewed Sui object is missing, generic, or not publicly transferable."
                    )
                }
                assetID = identity.canonicalID
                coinType = ""
                coinObject = nil
                coinBalance = nil
                coinCheckpoint = nil
                coinCheckpointTimestamp = nil
                coinNetwork = nil
                transferredObject = WalletSuiObjectReference(
                    objectID: identity.objectID, version: object.version,
                    digest: object.digest, type: object.moveType
                )
                objectHasPublicTransfer = true
                objectCheckpoint = snapshot.network.checkpointSequence
                objectCheckpointTimestamp = snapshot.network.checkpointTimestamp
                objectNetwork = snapshot.network
                gasRequired = request.maximumFeeBaseUnits
            }
            let gasSelection = try await rpc.selectNativeGasCoin(
                owner: account.address, requiredBalanceBaseUnits: gasRequired
            )
            let status = gasSelection.snapshot.network
            if let coinNetwork, let coinCheckpoint, let coinCheckpointTimestamp {
                guard status.checkpointSequence >= coinCheckpoint,
                      status.checkpointTimestamp >= coinCheckpointTimestamp,
                      status.chainIdentifier == coinNetwork.chainIdentifier,
                      status.epoch == coinNetwork.epoch,
                      status.referenceGasPrice == coinNetwork.referenceGasPrice,
                      coinObject?.objectID != gasSelection.coin.reference.objectID else {
                    throw WalletGateway.Error.invalidArguments(
                        "The Sui Coin and gas evidence do not share a safe checkpoint lineage."
                    )
                }
            }
            if let objectNetwork, let objectCheckpoint,
               let objectCheckpointTimestamp {
                guard status.checkpointSequence >= objectCheckpoint,
                      status.checkpointTimestamp >= objectCheckpointTimestamp,
                      status.chainIdentifier == objectNetwork.chainIdentifier,
                      status.epoch == objectNetwork.epoch,
                      status.referenceGasPrice == objectNetwork.referenceGasPrice,
                      transferredObject?.objectID
                        != gasSelection.coin.reference.objectID else {
                    throw WalletGateway.Error.invalidArguments(
                        "The Sui object and gas evidence do not share a safe checkpoint lineage."
                    )
                }
            }
            let packet = WalletSuiPreparationPacket(
                request: request, chainIdentifier: status.chainIdentifier,
                checkpointSequence: status.checkpointSequence,
                checkpointTimestamp: status.checkpointTimestamp,
                sender: account.address, assetID: assetID, coinType: coinType,
                coinObject: coinObject, coinBalanceBaseUnits: coinBalance,
                coinCheckpointSequence: coinCheckpoint,
                coinCheckpointTimestamp: coinCheckpointTimestamp,
                transferredObject: transferredObject,
                objectHasPublicTransfer: objectHasPublicTransfer,
                objectCheckpointSequence: objectCheckpoint,
                objectCheckpointTimestamp: objectCheckpointTimestamp,
                gasObject: gasSelection.coin.reference,
                gasBalanceBaseUnits: gasSelection.coin.balanceBaseUnits,
                gasBudgetBaseUnits: request.maximumFeeBaseUnits,
                referenceGasPriceBaseUnits: status.referenceGasPrice,
                gasPriceBaseUnits: status.referenceGasPrice,
                currentEpoch: status.epoch, expirationEpoch: status.epoch,
                observedAt: Date()
            )
            let data = try authorized(packet, source: request.source)
            let unsigned: WalletSuiUnsignedIntent = try await call { proxy, reply in
                proxy.prepareSui(data, reply: reply)
            }
            guard unsigned.prepared.networkID == request.networkID,
                  unsigned.prepared.accountID == request.accountID,
                  unsigned.prepared.source == request.source,
                  unsigned.prepared.action == request.action,
                  unsigned.prepared.maximumFeeBaseUnits
                    == request.maximumFeeBaseUnits,
                  !unsigned.prepared.simulationSucceeded else {
                throw WalletGateway.Error.invalidArguments(
                    "The signer returned mismatched Sui preparation evidence."
                )
            }
            let intent = WalletSuiClientIntent(packet: packet, unsigned: unsigned)
            let prepared = try await simulateSui(intent: intent)
            suiPreparationPackets[prepared.id] = intent
            return prepared
        }
    }

    func simulate(intentID: String) async throws -> WalletPreparedTransaction {
        if let packet = preparationPackets[intentID] {
            let rpc = try rpcClient(for: packet.request.networkID)
            let recheck = try await rpc.recheck(intentID: intentID, packet: packet)
            let data = try authorized(recheck, source: packet.request.source)
            return try await call { proxy, reply in proxy.simulateEVM(data, reply: reply) }
        }
        if let packet = solanaPreparationPackets[intentID] {
            let rpc = try solanaRPCClient(for: packet.request.networkID)
            let recheck = try await rpc.recheck(intentID: intentID, packet: packet)
            let data = try authorized(recheck, source: packet.request.source)
            return try await call { proxy, reply in
                proxy.simulateSolana(data, reply: reply)
            }
        }
        if let intent = suiPreparationPackets[intentID] {
            return try await simulateSui(intent: intent)
        }
        throw WalletGateway.Error.intentNotFound
    }

    func confirmExecution(intentID: String) async throws {
        if let packet = preparationPackets[intentID] {
            let request = try authorized(intentID, source: packet.request.source)
            let _: WalletPreparedTransaction = try await call { proxy, reply in
                proxy.confirmEVM(request, reply: reply)
            }
            return
        }
        if let packet = solanaPreparationPackets[intentID] {
            let request = try authorized(intentID, source: packet.request.source)
            let _: WalletPreparedTransaction = try await call { proxy, reply in
                proxy.confirmSolana(request, reply: reply)
            }
            return
        }
        if let intent = suiPreparationPackets[intentID] {
            let request = try authorized(
                intentID, source: intent.packet.request.source
            )
            let _: WalletPreparedTransaction = try await call { proxy, reply in
                proxy.confirmSui(request, reply: reply)
            }
            return
        }
        throw WalletGateway.Error.intentNotFound
    }

    func execute(intentID: String) async throws -> [String: Any] {
        let expectedSessionID = sessionID
        if let packet = preparationPackets[intentID] {
            let rpc = try rpcClient(for: packet.request.networkID)
            let recheck = try await rpc.recheck(intentID: intentID, packet: packet)
            let request = try authorized(recheck, source: packet.request.source)
            let signed: WalletEVMSignedTransaction = try await call(validating: {
                guard self.sessionID == expectedSessionID,
                      self.preparationPackets[intentID] == packet else {
                    throw WalletGateway.Error.intentNotFound
                }
            }) { proxy, reply in
                proxy.executeEVM(request, reply: reply)
            }
            preparationPackets[intentID] = nil
            let broadcastHash: String
            do {
                broadcastHash = try await rpc.broadcast(
                    rawTransaction: signed.rawTransaction
                )
            } catch {
                throw WalletGateway.Error.broadcastUnknown(
                    transactionHash: signed.transactionHash,
                    message: error.localizedDescription
                )
            }
            guard broadcastHash.caseInsensitiveCompare(
                signed.transactionHash
            ) == .orderedSame else {
                throw WalletGateway.Error.broadcastUnknown(
                    transactionHash: signed.transactionHash,
                    message: "The provider returned a transaction hash that does not match the signed bytes."
                )
            }
            return Self.submissionResult(
                intentID: intentID, networkID: packet.request.networkID,
                transactionHash: broadcastHash
            )
        }
        if let packet = solanaPreparationPackets[intentID] {
            let rpc = try solanaRPCClient(for: packet.request.networkID)
            let recheck = try await rpc.recheck(intentID: intentID, packet: packet)
            let request = try authorized(recheck, source: packet.request.source)
            let signed: WalletSolanaSignedTransaction = try await call(validating: {
                guard self.sessionID == expectedSessionID,
                      self.solanaPreparationPackets[intentID] == packet else {
                    throw WalletGateway.Error.intentNotFound
                }
            }) { proxy, reply in
                proxy.executeSolana(request, reply: reply)
            }
            solanaPreparationPackets[intentID] = nil
            let transactionID: String
            do {
                transactionID = try await rpc.broadcast(
                    signedTransaction: signed.signedTransaction,
                    transactionID: signed.transactionID,
                    minimumContextSlot: packet.contextSlot
                )
            } catch {
                throw WalletGateway.Error.broadcastUnknown(
                    transactionHash: signed.transactionID,
                    message: error.localizedDescription
                )
            }
            return Self.submissionResult(
                intentID: intentID, networkID: packet.request.networkID,
                transactionHash: transactionID
            )
        }
        if let intent = suiPreparationPackets[intentID] {
            let rpc = try suiRPCClient(for: intent.packet.request.networkID)
            let snapshot = try await rpc.nativeGasCoins(
                owner: intent.packet.sender
            )
            guard let gasCoin = snapshot.coins.first(where: {
                $0.reference.objectID == intent.packet.gasObject.objectID
            }), gasCoin.reference == intent.packet.gasObject,
               gasCoin.balanceBaseUnits == intent.packet.gasBalanceBaseUnits else {
                throw WalletGateway.Error.invalidArguments(
                    "The selected Sui gas object changed before signing."
                )
            }
            let coinObject: WalletSuiObjectReference?
            let coinBalance: String?
            let coinCheckpoint: UInt64?
            let coinCheckpointTimestamp: Date?
            if let expectedCoin = intent.packet.coinObject,
               let expectedBalance = intent.packet.coinBalanceBaseUnits {
                let coinSnapshot = try await rpc.coinObjects(
                    owner: intent.packet.sender, coinType: intent.packet.coinType
                )
                guard let current = coinSnapshot.objects.first(where: {
                    $0.reference.objectID == expectedCoin.objectID
                }), current.reference == expectedCoin,
                   current.balanceBaseUnits == expectedBalance,
                   coinSnapshot.identity.canonicalID == intent.packet.assetID,
                   coinSnapshot.network.chainIdentifier
                    == intent.packet.chainIdentifier else {
                    throw WalletGateway.Error.invalidArguments(
                        "The selected Sui Coin object changed before signing."
                    )
                }
                coinObject = current.reference
                coinBalance = current.balanceBaseUnits
                coinCheckpoint = coinSnapshot.network.checkpointSequence
                coinCheckpointTimestamp = coinSnapshot.network.checkpointTimestamp
            } else {
                coinObject = nil
                coinBalance = nil
                coinCheckpoint = nil
                coinCheckpointTimestamp = nil
            }
            let transferredObject: WalletSuiObjectReference?
            let objectHasPublicTransfer: Bool?
            let objectCheckpoint: UInt64?
            let objectCheckpointTimestamp: Date?
            if let expectedObject = intent.packet.transferredObject {
                let objectSnapshot = try await rpc.ownedObjectSnapshot(
                    owner: intent.packet.sender
                )
                guard let current = objectSnapshot.objects.first(where: {
                    $0.identity.objectID == expectedObject.objectID
                }), current.version == expectedObject.version,
                   current.digest == expectedObject.digest,
                   current.moveType == expectedObject.type,
                   current.hasPublicTransfer,
                   current.identity.canonicalID == intent.packet.assetID,
                   objectSnapshot.network.chainIdentifier
                    == intent.packet.chainIdentifier else {
                    throw WalletGateway.Error.invalidArguments(
                        "The selected Sui object changed before signing."
                    )
                }
                transferredObject = expectedObject
                objectHasPublicTransfer = true
                objectCheckpoint = objectSnapshot.network.checkpointSequence
                objectCheckpointTimestamp = objectSnapshot.network.checkpointTimestamp
            } else {
                transferredObject = nil
                objectHasPublicTransfer = nil
                objectCheckpoint = nil
                objectCheckpointTimestamp = nil
            }
            let simulation = try await suiSimulation(
                intent: intent, rpc: rpc
            )
            let recheck = WalletSuiRecheckPacket(
                simulation: simulation, coinObject: coinObject,
                coinBalanceBaseUnits: coinBalance,
                coinCheckpointSequence: coinCheckpoint,
                coinCheckpointTimestamp: coinCheckpointTimestamp,
                transferredObject: transferredObject,
                objectHasPublicTransfer: objectHasPublicTransfer,
                objectCheckpointSequence: objectCheckpoint,
                objectCheckpointTimestamp: objectCheckpointTimestamp,
                gasObject: gasCoin.reference,
                gasBalanceBaseUnits: gasCoin.balanceBaseUnits,
                gasCheckpointSequence: snapshot.network.checkpointSequence,
                gasCheckpointTimestamp: snapshot.network.checkpointTimestamp,
                currentEpoch: snapshot.network.epoch,
                referenceGasPriceBaseUnits: snapshot.network.referenceGasPrice
            )
            let request = try authorized(
                recheck, source: intent.packet.request.source
            )
            let signed: WalletSuiSignedTransaction = try await call(validating: {
                guard self.sessionID == expectedSessionID,
                      self.suiPreparationPackets[intentID]?.packet == intent.packet,
                      self.suiPreparationPackets[intentID]?.unsigned == intent.unsigned else {
                    throw WalletGateway.Error.intentNotFound
                }
            }) { proxy, reply in
                proxy.executeSui(request, reply: reply)
            }
            suiPreparationPackets[intentID] = nil
            guard signed.intentID == intentID,
                  signed.transactionDigest == intent.unsigned.prepared.digest,
                  signed.transactionBytes == intent.unsigned.transactionBCS else {
                throw WalletGateway.Error.invalidArguments(
                    "The signer returned different Sui transaction material."
                )
            }
            do {
                let submission = try await rpc.executeTransaction(
                    transactionBCS: signed.transactionBytes,
                    signature: signed.signature,
                    expectedTransactionDigest: signed.transactionDigest
                )
                return Self.submissionResult(
                    intentID: intentID,
                    networkID: intent.packet.request.networkID,
                    transactionHash: submission.transactionDigest
                )
            } catch {
                throw WalletGateway.Error.broadcastUnknown(
                    transactionHash: signed.transactionDigest,
                    message: error.localizedDescription
                )
            }
        }
        throw WalletGateway.Error.intentNotFound
    }

    func activatePolicy(_ policy: WalletSessionPolicy) async throws -> [WalletActivePolicyStatus] {
        let request = try authorized(policy, source: .agent)
        return try await call { proxy, reply in proxy.activatePolicy(request, reply: reply) }
    }

    func listPolicies() async throws -> [WalletActivePolicyStatus] {
        let request = try sessionRequest(source: .agent)
        return try await call { proxy, reply in proxy.listPolicies(request, reply: reply) }
    }

    func clearPolicies() async throws {
        let request = try sessionRequest(source: .agent)
        let _: [WalletActivePolicyStatus] = try await call { proxy, reply in
            proxy.clearPolicies(request, reply: reply)
        }
    }

    func verifyContract(_ draft: WalletContractRegistryDraft) async throws -> WalletContractRegistryEntry {
        let rpc = try rpcClient(for: draft.networkID)
        return try await rpc.verifyContract(draft)
    }

    func browserRPC(networkID: String, method: String, params: [Any]) async throws -> Any {
        guard let descriptor = WalletNetworkCatalog.descriptor(id: networkID) else {
            throw WalletGateway.Error.invalidArguments("The wallet network is unknown.")
        }
        switch descriptor.chain {
        case .evm:
            return try await rpcClient(for: networkID).publicRead(
                method: method, params: params
            )
        case .solana:
            return try await solanaRPCClient(for: networkID).publicRead(
                method: method, params: params
            )
        case .sui:
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Sui provider is not active."
            )
        }
    }

    func quoteUniswap(
        request: WalletUniswapQuoteRequest,
        configuration: WalletReviewedUniswapConfiguration
    ) async throws -> WalletUniswapQuote {
        try await rpcClient(for: request.networkID).uniswapQuote(
            request: request, configuration: configuration
        )
    }

    func performRead(tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        switch tool {
        case "wallet_get_balance":
            let accountID = arguments["account_id"] as? String
            let networkID = arguments["network_id"] as? String ?? WalletGateway.sepoliaNetworkID
            let assetID = arguments["asset_id"] as? String
                ?? WalletNetworkCatalog.descriptor(id: networkID)?.nativeAssetID
                ?? "\(networkID)/slip44:60"
            guard let descriptor = WalletNetworkCatalog.descriptor(id: networkID) else {
                throw WalletGateway.Error.invalidArguments("The wallet network is unknown.")
            }
            let accounts = try await listAccounts()
            guard let account = accounts.first(where: {
                $0.id == accountID && $0.chain == descriptor.chain
                    && $0.networkIDs.contains(networkID)
            }) else {
                throw WalletGateway.Error.invalidArguments(
                    "Select the matching Locus Vault chain account."
                )
            }
            let balance: String
            switch descriptor.chain {
            case .evm:
                let rpc = try rpcClient(for: networkID)
                if assetID == descriptor.nativeAssetID {
                    balance = try await rpc.balance(address: account.address)
                } else {
                    guard let identity = WalletEVMAssetIdentity.parse(assetID),
                          identity.networkID == networkID else {
                        throw WalletGateway.Error.invalidArguments(
                            "The requested asset ID is not canonical for this network."
                        )
                    }
                    balance = try await rpc.assetBalance(
                        identity: identity, address: account.address
                    )
                }
            case .solana:
                let coordinator = try solanaRPCClient(for: networkID)
                if assetID == descriptor.nativeAssetID {
                    balance = try await coordinator.balance(address: account.address)
                } else {
                    guard let identity = WalletSolanaAssetIdentity.parse(assetID),
                          identity.networkID == networkID else {
                        throw WalletGateway.Error.invalidArguments(
                            "The requested Solana asset ID is not canonical for this network."
                        )
                    }
                    balance = try await coordinator.tokenBalance(
                        identity: identity, owner: account.address
                    )
                }
            case .sui:
                let coordinator = try suiRPCClient(for: networkID)
                if assetID == descriptor.nativeAssetID {
                    balance = try await coordinator.balance(address: account.address)
                } else {
                    guard let identity = WalletSuiAssetIdentity.parse(assetID),
                          identity.networkID == networkID else {
                        throw WalletGateway.Error.invalidArguments(
                            "The requested Sui asset ID is not canonical for this network."
                        )
                    }
                    balance = try await coordinator.balance(
                        address: account.address, coinType: identity.coinType
                    )
                }
            }
            return [
                "text": "\(assetID) balance: \(balance) base units",
                "account_id": account.id,
                "network_id": networkID,
                "asset_id": assetID,
                "balance_base_units": balance,
            ]
        case "wallet_get_assets":
            let accountID = arguments["account_id"] as? String
            let networkID = arguments["network_id"] as? String
                ?? WalletNetworkCatalog.solanaDevnet.id
            guard let descriptor = WalletNetworkCatalog.descriptor(id: networkID),
                  descriptor.chain == .evm || descriptor.chain == .solana
                    || descriptor.chain == .sui else {
                throw WalletGateway.Error.invalidArguments(
                    "Asset discovery is active only for reviewed wallet providers."
                )
            }
            let accounts = try await listAccounts()
            guard let account = accounts.first(where: {
                $0.id == accountID && $0.chain == descriptor.chain
                    && $0.networkIDs.contains(networkID)
            }) else {
                throw WalletGateway.Error.invalidArguments(
                    "Select the matching Locus Vault chain account."
                )
            }
            if descriptor.chain == .evm {
                let balances = try await rpcClient(for: networkID).tokenBalances(
                    address: account.address
                )
                let nftSnapshot = try await rpcClient(for: networkID).nftBalances(
                    address: account.address
                )
                var rows: [[String: Any]] = balances.map { item in
                    [
                        "asset_id": item.identity.canonicalID,
                        "asset_kind": WalletAssetKind.fungibleToken.rawValue,
                        "reference": item.identity.contractAddress,
                        "balance_base_units": item.balanceBaseUnits,
                    ]
                }
                rows.append(contentsOf: nftSnapshot.assets.map { item in
                    [
                        "asset_id": item.identity.canonicalID,
                        "asset_kind": WalletAssetKind.collectible.rawValue,
                        "reference": item.identity.contractAddress,
                        "standard": item.identity.standard.rawValue,
                        "token_id": item.identity.tokenID ?? "",
                        "balance_base_units": item.balanceBaseUnits,
                        "snapshot_block_number": String(nftSnapshot.blockNumber),
                        "snapshot_block_hash": nftSnapshot.blockHash,
                    ]
                })
                rows.sort {
                    ($0["asset_id"] as? String ?? "")
                        < ($1["asset_id"] as? String ?? "")
                }
                return [
                    "text": "Loaded \(rows.count) Ethereum assets and collectibles.",
                    "account_id": account.id,
                    "network_id": networkID,
                    "assets": rows,
                ]
            }
            if descriptor.chain == .sui {
                let balances = try await suiRPCClient(for: networkID).balances(
                    owner: account.address
                )
                let objects = try await suiRPCClient(for: networkID).ownedObjects(
                    owner: account.address
                )
                var rows: [[String: Any]] = balances.map { item in
                    [
                        "asset_id": item.identity.canonicalID,
                        "asset_kind": WalletAssetKind.fungibleToken.rawValue,
                        "reference": item.identity.coinType,
                        "coin_type": item.identity.coinType,
                        "balance_base_units": item.totalBalance,
                        "coin_balance_base_units": item.coinBalance,
                        "address_balance_base_units": item.addressBalance,
                    ]
                }
                rows.append(contentsOf: objects.map { item in
                    [
                        "asset_id": item.identity.canonicalID,
                        "asset_kind": WalletAssetKind.collectible.rawValue,
                        "reference": item.identity.objectID,
                        "object_id": item.identity.objectID,
                        "object_version": item.version,
                        "object_digest": item.digest,
                        "move_type": item.moveType,
                        "has_public_transfer": item.hasPublicTransfer,
                        "balance_base_units": "1",
                        "decimals": 0,
                    ]
                })
                guard rows.count <= 10_000 else {
                    throw WalletGateway.Error.invalidArguments(
                        "The Sui asset snapshot exceeded the wallet boundary."
                    )
                }
                rows.sort {
                    ($0["asset_id"] as? String ?? "")
                        < ($1["asset_id"] as? String ?? "")
                }
                return [
                    "text": "Loaded \(rows.count) Sui Coins and owned objects.",
                    "account_id": account.id,
                    "network_id": networkID,
                    "assets": rows,
                ]
            }
            let coordinator = try solanaRPCClient(for: networkID)
            let tokenAccounts = try await coordinator.tokenAccounts(
                owner: account.address
            )
            let collectibles = (try? await coordinator.collectibles(
                owner: account.address
            )) ?? []
            struct Aggregate {
                let identity: WalletSolanaAssetIdentity
                let decimals: Int
                var balance: String
                var accountCount: Int
                var frozen: Bool
            }
            var aggregates: [String: Aggregate] = [:]
            for tokenAccount in tokenAccounts {
                let key = tokenAccount.identity.canonicalID
                if var existing = aggregates[key] {
                    guard existing.decimals == tokenAccount.decimals,
                          let total = WalletBaseUnits.add(
                              existing.balance, tokenAccount.amountBaseUnits
                          ) else {
                        throw WalletGateway.Error.invalidArguments(
                            "The provider returned inconsistent token accounts for one mint."
                        )
                    }
                    existing.balance = total
                    existing.accountCount += 1
                    existing.frozen = existing.frozen || tokenAccount.state == "frozen"
                    aggregates[key] = existing
                } else {
                    aggregates[key] = Aggregate(
                        identity: tokenAccount.identity,
                        decimals: tokenAccount.decimals,
                        balance: tokenAccount.amountBaseUnits,
                        accountCount: 1,
                        frozen: tokenAccount.state == "frozen"
                    )
                }
            }
            let tokenMetadataMints = Set(collectibles.compactMap { item in
                item.identity.standard == .tokenMetadata
                    ? item.identity.address : nil
            })
            var rows: [[String: Any]] = aggregates.values.filter {
                !tokenMetadataMints.contains($0.identity.mint)
            }.sorted {
                $0.identity.canonicalID < $1.identity.canonicalID
            }.map { item in
                [
                    "asset_id": item.identity.canonicalID,
                    "mint": item.identity.mint,
                    "token_program": item.identity.program.rawValue,
                    "balance_base_units": item.balance,
                    "decimals": item.decimals,
                    "account_count": item.accountCount,
                    "has_frozen_account": item.frozen,
                ]
            }
            rows.append(contentsOf: collectibles.map { item in
                var row: [String: Any] = [
                    "asset_id": item.identity.canonicalID,
                    "asset_kind": WalletAssetKind.collectible.rawValue,
                    "collectible_standard": item.identity.standard.rawValue,
                    "reference": item.identity.address,
                    "name": item.name,
                    "symbol": item.symbol,
                    "balance_base_units": "1",
                    "decimals": 0,
                    "account_count": 1,
                    "has_frozen_account": item.frozen,
                    "delegated": item.delegated,
                ]
                if let collection = item.collectionAddress {
                    row["collection"] = collection
                }
                return row
            })
            rows.sort {
                ($0["asset_id"] as? String ?? "")
                    < ($1["asset_id"] as? String ?? "")
            }
            return [
                "text": "Loaded \(rows.count) Solana assets and collectibles.",
                "account_id": account.id,
                "network_id": networkID,
                "assets": rows,
            ]
        case "wallet_get_activity":
            let accountID = arguments["account_id"] as? String
            let networkID = arguments["network_id"] as? String
                ?? WalletGateway.ethereumMainnetNetworkID
            guard let descriptor = WalletNetworkCatalog.descriptor(id: networkID),
                  descriptor.chain == .evm || descriptor.chain == .solana
                    || descriptor.chain == .sui else {
                throw WalletGateway.Error.invalidArguments(
                    "Indexed activity is active only for reviewed wallet providers."
                )
            }
            let accounts = try await listAccounts()
            guard let account = accounts.first(where: {
                $0.id == accountID && $0.chain == descriptor.chain
                    && $0.networkIDs.contains(networkID)
            }) else {
                throw WalletGateway.Error.invalidArguments(
                    "Select the matching Locus Vault chain account."
                )
            }
            if descriptor.chain == .solana {
                let indexed = try await solanaRPCClient(for: networkID).activity(
                    owner: account.address
                )
                let rows: [[String: Any]] = indexed.map { item in
                    var row: [String: Any] = [
                        "id": item.id,
                        "transaction_hash": item.signature,
                        "block_number": String(item.slot),
                        "occurred_at": item.occurredAt.timeIntervalSince1970,
                        "status": item.successful ? "confirmed" : "failed",
                        "owner": item.owner,
                        "fee_base_units": item.feeBaseUnits,
                    ]
                    if let direction = item.direction,
                       let assetID = item.assetID,
                       let kind = item.assetKind,
                       let amount = item.amountBaseUnits {
                        row["direction"] = direction.rawValue
                        row["asset_id"] = assetID
                        row["asset_kind"] = kind.rawValue
                        row["amount_base_units"] = amount
                        if let reference = item.assetReference {
                            row["asset_reference"] = reference
                        }
                    }
                    return row
                }
                return [
                    "text": "Loaded \(rows.count) finalized Solana activity records.",
                    "account_id": account.id,
                    "network_id": networkID,
                    "activity": rows,
                ]
            }
            if descriptor.chain == .sui {
                let indexed = try await suiRPCClient(for: networkID).activity(
                    owner: account.address
                )
                let rows: [[String: Any]] = indexed.map { item in
                    var row: [String: Any] = [
                        "id": item.id,
                        "transaction_hash": item.transactionDigest,
                        "block_number": String(item.checkpointSequence),
                        "occurred_at": item.occurredAt.timeIntervalSince1970,
                        "status": item.successful ? "confirmed" : "failed",
                        "owner": account.address,
                    ]
                    if let sender = item.sender { row["sender"] = sender }
                    if let identity = item.identity,
                       let amount = item.amountBaseUnits,
                       let inbound = item.isInbound {
                        row["asset_id"] = identity.canonicalID
                        row["asset_reference"] = identity.coinType
                        row["asset_kind"] = identity.coinType
                            == WalletSuiAssetIdentity.nativeCoinType
                            ? WalletAssetKind.native.rawValue
                            : WalletAssetKind.fungibleToken.rawValue
                        row["amount_base_units"] = amount
                        row["direction"] = inbound
                            ? WalletActivityDirection.inbound.rawValue
                            : WalletActivityDirection.outbound.rawValue
                    } else if let identity = item.objectIdentity,
                              let objectType = item.objectType,
                              let hasPublicTransfer = item.objectHasPublicTransfer,
                              item.amountBaseUnits == "1",
                              let inbound = item.isInbound {
                        row["asset_id"] = identity.canonicalID
                        row["asset_reference"] = identity.objectID
                        row["asset_kind"] = WalletAssetKind.collectible.rawValue
                        row["object_type"] = objectType
                        row["has_public_transfer"] = hasPublicTransfer
                        row["amount_base_units"] = "1"
                        row["direction"] = inbound
                            ? WalletActivityDirection.inbound.rawValue
                            : WalletActivityDirection.outbound.rawValue
                    }
                    return row
                }
                return [
                    "text": "Loaded \(rows.count) finalized Sui activity records.",
                    "account_id": account.id,
                    "network_id": networkID,
                    "activity": rows,
                ]
            }
            let coordinator = try rpcClient(for: networkID)
            let indexed = try await coordinator.indexedTransfers(address: account.address)
            let headResponse = try? await coordinator.publicRead(
                method: "eth_blockNumber", params: []
            )
            let activity: [[String: Any]] = indexed.map { transfer in
                var value: [String: Any] = [
                    "id": transfer.id,
                    "transaction_hash": transfer.transactionHash,
                    "block_number": transfer.blockNumber,
                    "occurred_at": transfer.occurredAt.timeIntervalSince1970,
                    "from": transfer.from,
                    "to": transfer.to,
                    "asset_id": transfer.assetID,
                    "amount_base_units": transfer.amountBaseUnits,
                    "asset_kind": transfer.assetKind.rawValue,
                    "asset_name": transfer.assetName,
                    "asset_symbol": transfer.assetSymbol,
                ]
                if let reference = transfer.assetReference {
                    value["asset_reference"] = reference
                }
                if let decimals = transfer.assetDecimals {
                    value["asset_decimals"] = decimals
                }
                return value
            }
            var result: [String: Any] = [
                "text": "Loaded \(indexed.count) indexed account activity records.",
                "account_id": account.id,
                "network_id": networkID,
                "activity": activity,
            ]
            if let headHex = headResponse as? String,
               let headBlock = WalletEthereumQuantity.hexToDecimal(headHex) {
                result["head_block_number"] = headBlock
            }
            return result
        default:
            throw WalletGateway.Error.invalidArguments("Unsupported read-only wallet operation.")
        }
    }

    func rpcHealth() async throws -> String {
        let rpc = try rpcClient(for: WalletGateway.sepoliaNetworkID)
        return try await rpc.health()
    }

    func configureRPCURL(_ value: String) {
        Task {
            guard let rpc = rpcClients[WalletGateway.sepoliaNetworkID] else { return }
            try? await rpc.configurePrimary(
                endpoint: value.isEmpty ? WalletSepoliaRPCClient.defaultEndpoint : value
            )
        }
    }

    func lock() {
        sessionID = nil
        preparationPackets.removeAll()
        solanaPreparationPackets.removeAll()
        suiPreparationPackets.removeAll()
        guard isAvailable else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let proxy = try await self.remoteProxy()
                proxy.lock { _ in }
            } catch {
                self.invalidate()
            }
        }
    }

    func cancelPreparation(intentID: String) {
        preparationPackets[intentID] = nil
        solanaPreparationPackets[intentID] = nil
        suiPreparationPackets[intentID] = nil
    }

    private func call<T: Decodable>(
        validating validation: (() throws -> Void)? = nil,
        _ body: @escaping (WalletSignerXPCProtocol, @escaping (Data) -> Void) -> Void
    ) async throws -> T {
        let data = try await rawCall(validating: validation, body)
        if let error = try? decoder.decode(WalletSignerErrorPayload.self, from: data) {
            throw NSError(domain: "WalletSigner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error.error])
        }
        return try decoder.decode(T.self, from: data)
    }

    private func rpcClient(for networkID: String) throws -> WalletEVMProviderCoordinator {
        guard let rpc = rpcClients[networkID] else {
            throw WalletGateway.Error.invalidArguments(
                "No reviewed EVM provider is configured for \(networkID)."
            )
        }
        return rpc
    }

    private func solanaRPCClient(
        for networkID: String
    ) throws -> WalletSolanaProviderCoordinator {
        guard let rpc = solanaRPCClients[networkID] else {
            throw WalletGateway.Error.invalidArguments(
                "No reviewed Solana provider is configured for \(networkID)."
            )
        }
        return rpc
    }

    private func suiRPCClient(for networkID: String) throws -> WalletSuiProviderCoordinator {
        guard let rpc = suiRPCClients[networkID] else {
            throw WalletGateway.Error.invalidArguments(
                "No reviewed Sui GraphQL provider is configured for \(networkID)."
            )
        }
        return rpc
    }

    private func simulateSui(
        intent: WalletSuiClientIntent
    ) async throws -> WalletPreparedTransaction {
        let rpc = try suiRPCClient(for: intent.packet.request.networkID)
        let simulation = try await suiSimulation(intent: intent, rpc: rpc)
        let data = try authorized(
            simulation, source: intent.packet.request.source
        )
        let prepared: WalletPreparedTransaction = try await call { proxy, reply in
            proxy.simulateSui(data, reply: reply)
        }
        guard prepared.id == intent.unsigned.prepared.id,
              prepared.digest == intent.unsigned.prepared.digest,
              prepared.networkID == intent.packet.request.networkID,
              prepared.accountID == intent.packet.request.accountID,
              prepared.source == intent.packet.request.source,
              prepared.action == intent.packet.request.action,
              prepared.maximumFeeBaseUnits
                == intent.packet.request.maximumFeeBaseUnits,
              prepared.simulationSucceeded else {
            throw WalletGateway.Error.invalidArguments(
                "The signer returned mismatched Sui simulation evidence."
            )
        }
        return prepared
    }

    private func suiSimulation(
        intent: WalletSuiClientIntent,
        rpc: WalletSuiProviderCoordinator
    ) async throws -> WalletSuiSimulationPacket {
        guard let recipient = intent.packet.request.action.recipient,
              let amount = intent.packet.request.action.amountBaseUnits else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Sui transfer is incomplete."
            )
        }
        switch intent.packet.request.action.type {
        case .nativeTransfer:
            let result = try await rpc.simulateNativeTransfer(
                transactionBCS: intent.unsigned.transactionBCS,
                expectedTransactionDigest: intent.unsigned.prepared.digest,
                sender: intent.packet.sender, recipient: recipient,
                amountBaseUnits: amount,
                maximumFeeBaseUnits: intent.packet.request.maximumFeeBaseUnits,
                gasObjectID: intent.packet.gasObject.objectID
            )
            return WalletSuiSimulationPacket(
                intentID: intent.unsigned.prepared.id,
                chainIdentifier: result.network.chainIdentifier,
                checkpointSequence: result.network.checkpointSequence,
                checkpointTimestamp: result.network.checkpointTimestamp,
                currentEpoch: result.network.epoch,
                referenceGasPriceBaseUnits: result.network.referenceGasPrice,
                transactionDigest: result.transactionDigest,
                effectsDigest: result.effectsDigest,
                sender: result.sender, recipient: result.recipient,
                assetID: intent.packet.assetID, coinType: intent.packet.coinType,
                coinObjectID: nil, transferredObjectInput: nil,
                transferredObjectOutput: nil, objectHasPublicTransfer: nil,
                amountBaseUnits: result.amountBaseUnits,
                senderDebitBaseUnits: result.senderDebitBaseUnits,
                senderGasDebitBaseUnits: nil,
                recipientCreditBaseUnits: result.recipientCreditBaseUnits,
                gasObjectID: result.gasObjectID,
                computationCost: result.gas.computationCost,
                storageCost: result.gas.storageCost,
                storageRebate: result.gas.storageRebate,
                nonRefundableStorageFee: result.gas.nonRefundableStorageFee,
                actualFeeBaseUnits: result.gas.actualFeeBaseUnits,
                observedAt: Date()
            )
        case .fungibleTokenTransfer:
            guard let identity = WalletSuiAssetIdentity.parse(intent.packet.assetID),
                  identity.coinType == intent.packet.coinType,
                  let coinObject = intent.packet.coinObject else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui Coin preparation is incomplete."
                )
            }
            let result = try await rpc.simulateCoinTransfer(
                transactionBCS: intent.unsigned.transactionBCS,
                expectedTransactionDigest: intent.unsigned.prepared.digest,
                sender: intent.packet.sender, recipient: recipient,
                identity: identity, coinObjectID: coinObject.objectID,
                amountBaseUnits: amount,
                maximumFeeBaseUnits: intent.packet.request.maximumFeeBaseUnits,
                gasObjectID: intent.packet.gasObject.objectID
            )
            return WalletSuiSimulationPacket(
                intentID: intent.unsigned.prepared.id,
                chainIdentifier: result.network.chainIdentifier,
                checkpointSequence: result.network.checkpointSequence,
                checkpointTimestamp: result.network.checkpointTimestamp,
                currentEpoch: result.network.epoch,
                referenceGasPriceBaseUnits: result.network.referenceGasPrice,
                transactionDigest: result.transactionDigest,
                effectsDigest: result.effectsDigest,
                sender: result.sender, recipient: result.recipient,
                assetID: result.identity.canonicalID,
                coinType: result.identity.coinType,
                coinObjectID: result.coinObjectID,
                transferredObjectInput: nil,
                transferredObjectOutput: nil,
                objectHasPublicTransfer: nil,
                amountBaseUnits: result.amountBaseUnits,
                senderDebitBaseUnits: result.senderAssetDebitBaseUnits,
                senderGasDebitBaseUnits: result.senderGasDebitBaseUnits,
                recipientCreditBaseUnits: result.recipientCreditBaseUnits,
                gasObjectID: result.gasObjectID,
                computationCost: result.gas.computationCost,
                storageCost: result.gas.storageCost,
                storageRebate: result.gas.storageRebate,
                nonRefundableStorageFee: result.gas.nonRefundableStorageFee,
                actualFeeBaseUnits: result.gas.actualFeeBaseUnits,
                observedAt: Date()
            )
        case .nftTransfer:
            guard let object = intent.packet.transferredObject else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui object preparation is incomplete."
                )
            }
            let result = try await rpc.simulateObjectTransfer(
                transactionBCS: intent.unsigned.transactionBCS,
                expectedTransactionDigest: intent.unsigned.prepared.digest,
                sender: intent.packet.sender, recipient: recipient,
                inputObject: object,
                maximumFeeBaseUnits: intent.packet.request.maximumFeeBaseUnits,
                gasObject: intent.packet.gasObject
            )
            return WalletSuiSimulationPacket(
                intentID: intent.unsigned.prepared.id,
                chainIdentifier: result.network.chainIdentifier,
                checkpointSequence: result.network.checkpointSequence,
                checkpointTimestamp: result.network.checkpointTimestamp,
                currentEpoch: result.network.epoch,
                referenceGasPriceBaseUnits: result.network.referenceGasPrice,
                transactionDigest: result.transactionDigest,
                effectsDigest: result.effectsDigest,
                sender: result.sender, recipient: result.recipient,
                assetID: intent.packet.assetID, coinType: "", coinObjectID: nil,
                transferredObjectInput: result.inputObject,
                transferredObjectOutput: result.outputObject,
                objectHasPublicTransfer: result.hasPublicTransfer,
                amountBaseUnits: "1", senderDebitBaseUnits: "0",
                senderGasDebitBaseUnits: result.senderGasDebitBaseUnits,
                recipientCreditBaseUnits: "1",
                gasObjectID: result.gasObjectID,
                computationCost: result.gas.computationCost,
                storageCost: result.gas.storageCost,
                storageRebate: result.gas.storageRebate,
                nonRefundableStorageFee: result.gas.nonRefundableStorageFee,
                actualFeeBaseUnits: result.gas.actualFeeBaseUnits,
                observedAt: Date()
            )
        default:
            throw WalletGateway.Error.invalidArguments(
                "The Sui semantic action has no simulation adapter."
            )
        }
    }

    private static func submissionResult(
        intentID: String,
        networkID: String,
        transactionHash: String
    ) -> [String: Any] {
        [
            "text": "Submitted \(networkID) transaction \(transactionHash)",
            "intent_id": intentID,
            "transaction_hash": transactionHash,
            "network_id": networkID,
            "status": "submitted",
        ]
    }

    private func authorized<Payload: Codable & Equatable & Sendable>(
        _ payload: Payload,
        source: WalletRequestSource
    ) throws -> Data {
        guard let sessionID else { throw WalletGateway.Error.vaultLocked }
        return try encoder.encode(WalletAuthorizedRequest(
            protocolVersion: WalletGateway.protocolVersion,
            sessionID: sessionID,
            source: source,
            payload: payload
        ))
    }

    private func sessionRequest(source: WalletRequestSource) throws -> Data {
        guard let sessionID else { throw WalletGateway.Error.vaultLocked }
        return try encoder.encode(WalletSessionRequest(
            protocolVersion: WalletGateway.protocolVersion,
            sessionID: sessionID,
            source: source
        ))
    }

    private func rawCall(
        validating validation: (() throws -> Void)? = nil,
        _ body: @escaping (WalletSignerXPCProtocol, @escaping (Data) -> Void) -> Void
    ) async throws -> Data {
        guard isAvailable else { throw WalletGateway.Error.signerUnavailable }
        let proxy = try await remoteProxy(errorHandler: { [weak self] _ in
            Task { @MainActor in self?.invalidate() }
        })
        // The provider recheck and endpoint setup both suspend. Revalidate
        // cancellation immediately before the irreversible signer handoff.
        try validation?()
        return try await withCheckedThrowingContinuation { continuation in
            let gate = WalletXPCReplyGate()
            let replyError: (Error) -> Void = { error in
                if gate.take() { continuation.resume(throwing: error) }
            }
            guard let guardedProxy = self.connection?.remoteObjectProxyWithErrorHandler(
                replyError
            ) as? WalletSignerXPCProtocol else {
                return continuation.resume(throwing: WalletGateway.Error.signerUnavailable)
            }
            _ = proxy
            body(guardedProxy) { data in
                if gate.take() { continuation.resume(returning: data) }
            }
        }
    }

    private func remoteProxy(
        errorHandler: @escaping (Error) -> Void = { _ in }
    ) async throws -> WalletSignerXPCProtocol {
        let connection = try await ensureConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler)
            as? WalletSignerXPCProtocol else {
            throw WalletGateway.Error.signerUnavailable
        }
        return proxy
    }

    private func ensureConnection() async throws -> NSXPCConnection {
        if let connection { return connection }
        if connectionSetupInProgress {
            return try await withCheckedThrowingContinuation { continuation in
                connectionWaiters.append(continuation)
            }
        }
        connectionSetupInProgress = true
        do {
            let endpoint = try await requestHostEndpoint()
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.setCodeSigningRequirement(WalletXPCCodeSigningRequirement.signerService)
            connection.remoteObjectInterface = NSXPCInterface(with: WalletSignerXPCProtocol.self)
            connection.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.invalidate() }
            }
            connection.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.invalidate() }
            }
            connection.resume()
            self.connection = connection
            connectionSetupInProgress = false
            let waiters = connectionWaiters
            connectionWaiters.removeAll()
            waiters.forEach { $0.resume(returning: connection) }
            return connection
        } catch {
            connectionSetupInProgress = false
            let waiters = connectionWaiters
            connectionWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func requestHostEndpoint() async throws -> NSXPCListenerEndpoint {
        let bootstrap = bootstrapConnection ?? makeBootstrapConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let gate = WalletXPCReplyGate()
            guard let proxy = bootstrap.remoteObjectProxyWithErrorHandler({ error in
                if gate.take() { continuation.resume(throwing: error) }
            }) as? WalletSignerBootstrapXPCProtocol else {
                return continuation.resume(throwing: WalletGateway.Error.signerUnavailable)
            }
            proxy.connectHost { endpoint in
                guard gate.take() else { return }
                if let endpoint {
                    continuation.resume(returning: endpoint)
                } else {
                    continuation.resume(throwing: WalletGateway.Error.signerUnavailable)
                }
            }
        }
    }

    private func makeBootstrapConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: "io.sparktales.locus.WalletSigner")
        connection.setCodeSigningRequirement(WalletXPCCodeSigningRequirement.signerService)
        connection.remoteObjectInterface = NSXPCInterface(
            with: WalletSignerBootstrapXPCProtocol.self
        )
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.invalidate() }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.invalidate() }
        }
        connection.resume()
        bootstrapConnection = connection
        return connection
    }

    private func invalidate() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        bootstrapConnection?.invalidationHandler = nil
        bootstrapConnection?.interruptionHandler = nil
        bootstrapConnection?.invalidate()
        bootstrapConnection = nil
        sessionID = nil
        preparationPackets.removeAll()
        solanaPreparationPackets.removeAll()
        suiPreparationPackets.removeAll()
        invalidationHandler?()
    }
}
#endif
