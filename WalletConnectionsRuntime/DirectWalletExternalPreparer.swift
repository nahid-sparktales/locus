import CryptoKit
import Foundation

enum DirectWalletExternalEvidence: Equatable, Sendable {
    case evm(WalletEVMPreparationPacket)
    case solana(WalletSolanaPreparationPacket)
    case sui(DirectWalletSuiEvidence)
}

struct DirectWalletSuiEvidence: Equatable, Sendable {
    let packet: WalletSuiPreparationPacket
    let simulation: WalletSuiSimulationPacket
    let transactionDigest: String
}

struct DirectWalletExternalPreparation: Equatable, Sendable {
    let transaction: WalletExternalPreparedTransaction
    let review: WalletPreparedTransaction
    let evidence: DirectWalletExternalEvidence
}

/// Independently prepares connector transactions in Swift. This path never
/// calls WalletSigner, links signer-core, or accepts caller-supplied calldata.
enum DirectWalletExternalPreparer {
    static func prepare(
        request: WalletPrepareRequest,
        binding: WalletConnectionRequestBinding,
        account: WalletAccount,
        contract: WalletContractRegistryEntry?,
        uniswapConfiguration: WalletReviewedUniswapConfiguration? = nil,
        bundle: Bundle = .main,
        now: Date = Date()
    ) async throws -> DirectWalletExternalPreparation {
        guard binding.accountID == request.accountID,
              binding.networkID == request.networkID,
              binding.expiresAt > now,
              account.id == request.accountID,
              account.networkIDs.contains(request.networkID),
              account.ownership.connectorID == binding.connector.externalConnectorID,
              let network = WalletNetworkCatalog.descriptor(id: request.networkID),
              network.chain == account.chain else {
            throw WalletConnectionProtocolError.bindingMismatch
        }
        switch network.chain {
        case .evm:
            return try await prepareEVM(
                request: request, binding: binding, account: account,
                network: network, contract: contract,
                uniswapConfiguration: uniswapConfiguration,
                bundle: bundle, now: now
            )
        case .solana:
            return try await prepareSolana(
                request: request, binding: binding, account: account,
                network: network, bundle: bundle, now: now
            )
        case .sui:
            return try await prepareSui(
                request: request, binding: binding, account: account,
                network: network, bundle: bundle, now: now
            )
        }
    }

    static func recheck(
        _ preparation: DirectWalletExternalPreparation,
        request: WalletPrepareRequest,
        binding: WalletConnectionRequestBinding,
        account: WalletAccount,
        bundle: Bundle = .main,
        now: Date = Date()
    ) async throws -> WalletExternalPreparedTransaction {
        let semanticDigest = try digest(request.action)
        guard preparation.transaction.binding == binding,
              preparation.transaction.action == request.action,
              preparation.transaction.accountAddress == account.address,
              preparation.transaction.semanticDigest == semanticDigest,
              preparation.transaction.expiresAt > now,
              let network = WalletNetworkCatalog.descriptor(id: request.networkID),
              account.networkIDs.contains(network.id) else {
            throw WalletConnectionProtocolError.bindingMismatch
        }
        switch preparation.evidence {
        case .evm(let packet):
            guard let configuration = WalletBundledProviderConfiguration.ethereum(
                network: network, bundle: bundle
            ) else { throw WalletProviderCoordinatorError.noProvider(network.id) }
            let coordinator = try WalletEVMProviderCoordinator(
                network: network, configuration: configuration
            )
            let refreshed = try await coordinator.recheck(
                intentID: binding.requestID, packet: packet
            )
            guard refreshed.chainID == packet.transaction.chainID,
                  refreshed.pendingNonce == packet.transaction.nonce,
                  refreshed.feeQuoteBaseUnits == packet.feeQuoteBaseUnits,
                  refreshed.simulationSucceeded,
                  refreshed.observedRuntimeCodeHash == packet.observedRuntimeCodeHash else {
                throw WalletRPCError.simulation(
                    "critical EVM evidence changed after review"
                )
            }
        case .solana(let packet):
            guard let configuration = WalletSolanaProviderConfiguration.bundled(
                network: network, bundle: bundle
            ) else { throw WalletProviderCoordinatorError.noProvider(network.id) }
            let coordinator = try WalletSolanaProviderCoordinator(
                network: network, configuration: configuration
            )
            let refreshed = try await coordinator.recheckExternal(
                intentID: binding.requestID, packet: packet
            )
            guard refreshed.evidence.genesisHash == packet.genesisHash,
                  refreshed.evidence.resolvedAccountsDigest
                    == packet.resolvedAccountsDigest,
                  refreshed.evidence.feeQuoteBaseUnits == packet.feeQuoteBaseUnits,
                  refreshed.evidence.simulationSucceeded,
                  preparation.transaction.payload.transactionBase64
                    == refreshed.unsignedTransaction.base64EncodedString() else {
                throw WalletRPCError.simulation(
                    "critical Solana evidence changed after review"
                )
            }
        case .sui(let evidence):
            guard let configuration = WalletSuiProviderConfiguration.bundled(
                network: network, bundle: bundle
            ) else { throw WalletProviderCoordinatorError.noProvider(network.id) }
            let coordinator = try WalletSuiProviderCoordinator(
                network: network, configuration: configuration
            )
            let rebuilt = try WalletSuiCanonicalTransaction(packet: evidence.packet)
            guard rebuilt.transactionBCS.base64EncodedString()
                    == preparation.transaction.payload.transactionBase64,
                  rebuilt.transactionDigest == evidence.transactionDigest else {
                throw WalletRPCError.simulation(
                    "the reviewed Sui transaction bytes changed"
                )
            }
            let refreshed = try await simulateSui(
                packet: evidence.packet, transaction: rebuilt,
                intentID: binding.requestID, coordinator: coordinator
            )
            guard refreshed.chainIdentifier == evidence.simulation.chainIdentifier,
                  refreshed.transactionDigest == evidence.simulation.transactionDigest,
                  refreshed.effectsDigest == evidence.simulation.effectsDigest,
                  refreshed.sender == evidence.simulation.sender,
                  refreshed.recipient == evidence.simulation.recipient,
                  refreshed.assetID == evidence.simulation.assetID,
                  refreshed.amountBaseUnits == evidence.simulation.amountBaseUnits,
                  refreshed.actualFeeBaseUnits == evidence.simulation.actualFeeBaseUnits else {
                throw WalletRPCError.simulation(
                    "critical Sui simulation evidence changed after review"
                )
            }
        }
        return preparation.transaction
    }

    private static func prepareEVM(
        request: WalletPrepareRequest,
        binding: WalletConnectionRequestBinding,
        account: WalletAccount,
        network: WalletNetworkDescriptor,
        contract: WalletContractRegistryEntry?,
        uniswapConfiguration: WalletReviewedUniswapConfiguration?,
        bundle: Bundle,
        now: Date
    ) async throws -> DirectWalletExternalPreparation {
        guard let configuration = WalletBundledProviderConfiguration.ethereum(
            network: network, bundle: bundle
        ) else {
            throw WalletProviderCoordinatorError.noProvider(network.id)
        }
        let actionToEncode: WalletSemanticAction
        switch request.action.type {
        case .nativeTransfer:
            guard contract == nil else {
                throw WalletGateway.Error.invalidArguments(
                    "A native transfer cannot target a reviewed contract."
                )
            }
            actionToEncode = request.action
        case .fungibleTokenTransfer, .nftTransfer:
            guard let contract,
                  let materialized = WalletEVMAssetAdapter.resolve(
                      action: request.action, registryEntry: contract,
                      accountAddress: account.address
                  ) else {
                throw WalletGateway.Error.invalidArguments(
                    "The external asset action is outside its reviewed adapter."
                )
            }
            actionToEncode = .contractCall(
                contractID: contract.id, function: materialized.function,
                arguments: materialized.arguments
            )
        case .exactInputSwap:
            guard let contract, let uniswapConfiguration,
                  reviewedUniswapAction(
                    request.action,
                    routerContractID: contract.id,
                    routerAddress: contract.checksumAddress,
                    routerRuntimeCodeHash: contract.runtimeCodeHash,
                    configuration: uniswapConfiguration, now: now
                  ),
                  let materialized = WalletUniversalRouterV2V3Adapter.contractAction(
                      for: request.action, accountAddress: account.address,
                      networkID: network.id, now: now
                  ) else {
                throw WalletGateway.Error.invalidArguments(
                    "The external swap is outside the reviewed router adapter."
                )
            }
            actionToEncode = materialized
        case .swapAllowanceSetup:
            guard let contract, let uniswapConfiguration,
                  let setup = request.action.swapAllowanceSetup,
                  setup.binding.networkID == network.id,
                  setup.binding.digest() == setup.bindingDigest,
                  reviewedUniswapAction(
                    setup.binding.exactInputSwapAction(),
                    routerContractID:
                        setup.binding.universalRouterContractID,
                    routerAddress: setup.binding.universalRouterAddress,
                    routerRuntimeCodeHash: uniswapConfiguration
                        .contract(.universalRouter)?.runtimeCodeHash ?? "",
                    configuration: uniswapConfiguration, now: now
                  ),
                  let materialized = WalletSwapAllowanceAdapter.resolve(
                    action: request.action, registryEntry: contract,
                    configuration: uniswapConfiguration
                  ) else {
                throw WalletGateway.Error.invalidArguments(
                    "The external allowance is not derived from an active reviewed swap."
                )
            }
            actionToEncode = .contractCall(
                contractID: contract.id, function: materialized.function,
                arguments: materialized.arguments
            )
        case .contractCall, .reviewedCall, .standardizedSignIn,
             .reviewedTypedAuthorization:
            throw WalletGateway.Error.invalidArguments(
                "That external EVM operation is outside the reviewed action set."
            )
        }
        let encoded: WalletEncodedContractCall?
        if let contract {
            encoded = WalletEncodedContractCall(input: try WalletExternalEVMABIEncoder.encode(
                action: actionToEncode, registryEntry: contract
            ))
        } else {
            encoded = nil
        }
        let coordinator = try WalletEVMProviderCoordinator(
            network: network, configuration: configuration
        )
        let packet = try await coordinator.prepare(
            request: request, fromAddress: account.address,
            contract: contract, encodedContract: encoded
        )
        guard packet.simulationSucceeded,
              packet.request == request,
              packet.fromAddress.caseInsensitiveCompare(account.address) == .orderedSame,
              packet.observedAt <= Date(),
              Date().timeIntervalSince(packet.observedAt) <= 60 else {
            throw WalletRPCError.simulation("stale or mismatched preparation evidence")
        }
        let fields = packet.transaction
        guard let value = WalletEthereumQuantity.decimalToHex(fields.value),
              let gas = WalletEthereumQuantity.decimalToHex(String(fields.gasLimit)),
              let maximumFee = WalletEthereumQuantity.decimalToHex(fields.maxFeePerGas),
              let priorityFee = WalletEthereumQuantity.decimalToHex(fields.maxPriorityFeePerGas),
              let nonce = WalletEthereumQuantity.decimalToHex(String(fields.nonce)),
              let chainID = WalletEthereumQuantity.decimalToHex(String(fields.chainID)) else {
            throw WalletRPCError.invalidResponse("invalid prepared EVM quantity")
        }
        let expiry = min(binding.expiresAt, packet.observedAt.addingTimeInterval(60))
        let semanticDigest = try digest(request.action)
        let simulationDigest = try digest(SimulationEvidence(
            networkID: network.id, from: account.address,
            transaction: fields, feeQuoteBaseUnits: packet.feeQuoteBaseUnits,
            simulation: packet.simulation,
            runtimeCodeHash: packet.observedRuntimeCodeHash,
            observedAt: packet.observedAt
        ))
        let prepared = WalletExternalPreparedTransaction(
            binding: binding, action: request.action,
            accountAddress: account.address,
            semanticDigest: semanticDigest,
            simulationDigest: simulationDigest,
            payload: WalletExternalPreparedPayload(
                format: .evmEIP1193,
                evm: WalletExternalEVMTransaction(
                    from: account.address, to: fields.to,
                    valueHex: value, dataHex: fields.input,
                    gasHex: gas, maxFeePerGasHex: maximumFee,
                    maxPriorityFeePerGasHex: priorityFee,
                    nonceHex: nonce, chainIDHex: chainID
                ),
                transactionBase64: nil, minimumContextSlot: nil
            ),
            expiresAt: expiry
        )
        return DirectWalletExternalPreparation(
            transaction: prepared,
            review: review(
                request: request, account: account, contract: contract,
                packet: packet, semanticDigest: semanticDigest,
                binding: binding, expiresAt: expiry
            ),
            evidence: .evm(packet)
        )
    }

    private static func reviewedUniswapAction(
        _ action: WalletSemanticAction,
        routerContractID: String,
        routerAddress: String,
        routerRuntimeCodeHash: String,
        configuration: WalletReviewedUniswapConfiguration,
        now: Date
    ) -> Bool {
        guard action.type == .exactInputSwap,
              action.contractID == configuration.universalRouterContractID,
              action.adapterID
                == WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
              routerContractID == configuration.universalRouterContractID,
              let router = configuration.contract(.universalRouter),
              router.address.caseInsensitiveCompare(routerAddress)
                == .orderedSame,
              router.runtimeCodeHash.caseInsensitiveCompare(
                routerRuntimeCodeHash
              ) == .orderedSame,
              let route = action.swapRoute,
              let evidence = route.quoteEvidence,
              evidence.quotedAt <= now.addingTimeInterval(5),
              evidence.expiresAt > now,
              evidence.expiresAt.timeIntervalSince(evidence.quotedAt) <= 60.5,
              let deadline = UInt64(route.deadlineUnixSeconds),
              deadline <= UInt64(max(
                0, evidence.quotedAt.timeIntervalSince1970
              )) + 600,
              route.slippageBPS <= 500,
              evidence.perHopOutputBaseUnits.count
                == route.pathAssetIDs.count - 1,
              evidence.perHopOutputBaseUnits.last
                == route.quotedOutputBaseUnits,
              let quoteContract = configuration.contract(
                route.protocolVersion == .v2 ? .v2Router : .v3QuoterV2
              ),
              quoteContract.address.caseInsensitiveCompare(
                evidence.quoteContractAddress
              ) == .orderedSame,
              quoteContract.runtimeCodeHash.caseInsensitiveCompare(
                evidence.quoteContractRuntimeCodeHash
              ) == .orderedSame,
              WalletUniswapRoutePlanner.candidates(
                configuration: configuration,
                inputAssetID: route.pathAssetIDs.first ?? "",
                outputAssetID: route.pathAssetIDs.last ?? ""
              ).contains(where: {
                $0.protocolVersion == route.protocolVersion
                    && $0.pathAssetIDs == route.pathAssetIDs
                    && $0.feeTiers == route.feeTiers
              }),
              let expectedMinimum = WalletBaseUnits.applyingBasisPointFloor(
                route.quotedOutputBaseUnits,
                bpsToKeep: 10_000 - route.slippageBPS
              ), expectedMinimum == action.minimumOutputBaseUnits,
              let amount = action.amountBaseUnits else { return false }
        #if DEBUG
        guard evidence.agreeingProviderCount >= 1 else { return false }
        #else
        guard evidence.agreeingProviderCount >= 2 else { return false }
        #endif
        var input = amount
        let scale = "1" + String(repeating: "0", count: 36)
        var floors: [String] = []
        for output in evidence.perHopOutputBaseUnits {
            guard let scaled = WalletBaseUnits.multiply(output, scale),
                  let price = WalletBaseUnits.divide(scaled, by: input)?.quotient,
                  let floor = WalletBaseUnits.applyingBasisPointFloor(
                    price, bpsToKeep: 10_000 - route.slippageBPS
                  ) else { return false }
            floors.append(floor)
            input = output
        }
        return floors == route.minimumHopPriceX36
    }

    private static func prepareSolana(
        request: WalletPrepareRequest,
        binding: WalletConnectionRequestBinding,
        account: WalletAccount,
        network: WalletNetworkDescriptor,
        bundle: Bundle,
        now: Date
    ) async throws -> DirectWalletExternalPreparation {
        guard account.ownership == .connectorManaged(connectorID: .phantom),
              binding.connector == .phantom,
              let configuration = WalletSolanaProviderConfiguration.bundled(
                network: network, bundle: bundle
              ) else {
            throw WalletProviderCoordinatorError.noProvider(network.id)
        }
        let coordinator = try WalletSolanaProviderCoordinator(
            network: network, configuration: configuration
        )
        let recipientTokenAccount: String?
        if request.action.type == .fungibleTokenTransfer {
            guard let recipient = request.action.recipient,
                  let assetID = request.action.assetID else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Solana token transfer is incomplete."
                )
            }
            recipientTokenAccount = try await coordinator.tokenAccounts(owner: recipient)
                .filter {
                    $0.identity.canonicalID == assetID
                        && $0.state == "initialized" && !$0.isNative
                }
                .map(\.address).sorted().first
            guard recipientTokenAccount != nil else {
                throw WalletGateway.Error.externalWallet(
                    "The recipient needs an existing reviewed token account before Phantom can submit this transfer."
                )
            }
        } else {
            recipientTokenAccount = nil
        }
        let external = try await coordinator.prepareExternal(
            request: request, feePayer: account.address,
            recipientAssociatedTokenAddress: recipientTokenAccount
        )
        let packet = external.packet
        guard packet.request == request,
              packet.feePayer == account.address,
              packet.simulationSucceeded,
              external.material.evidence.simulationSucceeded,
              packet.observedAt <= Date(),
              Date().timeIntervalSince(packet.observedAt) <= 60 else {
            throw WalletRPCError.simulation("stale or mismatched Solana preparation evidence")
        }
        let semanticDigest = try digest(request.action)
        let simulationDigest = try digest(SolanaSimulationEvidence(
            networkID: network.id, feePayer: account.address,
            genesisHash: packet.genesisHash,
            messageDigest: packet.canonicalMessageDigest,
            resolvedAccountsDigest: packet.resolvedAccountsDigest,
            feeQuoteBaseUnits: packet.feeQuoteBaseUnits,
            simulation: packet.simulation, observedAt: packet.observedAt
        ))
        let expiry = min(binding.expiresAt, packet.observedAt.addingTimeInterval(60))
        let prepared = WalletExternalPreparedTransaction(
            binding: binding, action: request.action,
            accountAddress: account.address,
            semanticDigest: semanticDigest, simulationDigest: simulationDigest,
            payload: WalletExternalPreparedPayload(
                format: .solanaBase64, evm: nil,
                transactionBase64: external.material.unsignedTransaction.base64EncodedString(),
                minimumContextSlot: packet.contextSlot
            ),
            expiresAt: expiry
        )
        return DirectWalletExternalPreparation(
            transaction: prepared,
            review: reviewSolana(
                request: request, account: account, packet: packet,
                semanticDigest: semanticDigest, binding: binding, expiresAt: expiry
            ),
            evidence: .solana(packet)
        )
    }

    private static func reviewSolana(
        request: WalletPrepareRequest,
        account: WalletAccount,
        packet: WalletSolanaPreparationPacket,
        semanticDigest: String,
        binding: WalletConnectionRequestBinding,
        expiresAt: Date
    ) -> WalletPreparedTransaction {
        let action = request.action
        let assetID = action.assetID
            ?? WalletNetworkCatalog.descriptor(id: request.networkID)?.nativeAssetID
            ?? request.networkID
        let amount = action.amountBaseUnits ?? "0"
        let effect: WalletDecodedEffect
        if let setup = action.swapAllowanceSetup {
            effect = WalletDecodedEffect(
                id: binding.requestID,
                kind: amount == "0" ? "approval_revoke" : "approval",
                assetID: setup.binding.inputAssetID,
                amountBaseUnits: amount, from: account.address, to: nil,
                spender: setup.stage == .permit2ToUniversalRouter
                    ? setup.binding.universalRouterAddress
                    : setup.binding.permit2Address
            )
        } else {
            effect = WalletDecodedEffect(
                id: binding.requestID, kind: action.type.rawValue,
                assetID: assetID, amountBaseUnits: amount,
                from: account.address, to: action.recipient, spender: nil
            )
        }
        let operation: String = switch action.type {
        case .nativeTransfer: "SOL transfer"
        case .fungibleTokenTransfer: "Solana token transfer"
        case .nftTransfer: "Metaplex Core transfer"
        default: "reviewed Solana action"
        }
        return WalletPreparedTransaction(
            id: binding.requestID, digest: semanticDigest,
            networkID: request.networkID, accountID: request.accountID,
            source: request.source, action: action,
            summary: "Review \(operation) from \(account.label)",
            effects: [effect], riskFlags: [], contract: nil,
            adapterID: action.adapterID, budgetAssetID: assetID,
            spendBaseUnits: amount,
            maximumFeeBaseUnits: request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: packet.feeQuoteBaseUnits,
            simulation: packet.simulation, simulationSucceeded: true,
            nonce: packet.recentBlockhash, createdAt: packet.observedAt,
            expiresAt: expiresAt,
            policyDecision: "exact_confirmation_required", policyID: nil
        )
    }

    private static func prepareSui(
        request: WalletPrepareRequest,
        binding: WalletConnectionRequestBinding,
        account: WalletAccount,
        network: WalletNetworkDescriptor,
        bundle: Bundle,
        now: Date
    ) async throws -> DirectWalletExternalPreparation {
        guard account.ownership == .external(connectorID: .slush),
              binding.connector == .slush,
              let configuration = WalletSuiProviderConfiguration.bundled(
                network: network, bundle: bundle
              ) else {
            throw WalletProviderCoordinatorError.noProvider(network.id)
        }
        let coordinator = try WalletSuiProviderCoordinator(
            network: network, configuration: configuration
        )
        let packet = try await suiPacket(
            request: request, account: account, network: network,
            coordinator: coordinator
        )
        let transaction = try WalletSuiCanonicalTransaction(packet: packet)
        let simulation = try await simulateSui(
            packet: packet, transaction: transaction,
            intentID: binding.requestID, coordinator: coordinator
        )
        let semanticDigest = try digest(request.action)
        let simulationDigest = try digest(simulation)
        let expiry = min(binding.expiresAt, packet.observedAt.addingTimeInterval(60))
        let prepared = WalletExternalPreparedTransaction(
            binding: binding, action: request.action,
            accountAddress: account.address,
            semanticDigest: semanticDigest, simulationDigest: simulationDigest,
            payload: WalletExternalPreparedPayload(
                format: .suiBCSBase64, evm: nil,
                transactionBase64: transaction.transactionBCS.base64EncodedString(),
                minimumContextSlot: nil
            ),
            expiresAt: expiry
        )
        return DirectWalletExternalPreparation(
            transaction: prepared,
            review: reviewSui(
                request: request, account: account, packet: packet,
                simulation: simulation, semanticDigest: semanticDigest,
                binding: binding, expiresAt: expiry
            ),
            evidence: .sui(DirectWalletSuiEvidence(
                packet: packet, simulation: simulation,
                transactionDigest: transaction.transactionDigest
            ))
        )
    }

    private static func suiPacket(
        request: WalletPrepareRequest,
        account: WalletAccount,
        network: WalletNetworkDescriptor,
        coordinator: WalletSuiProviderCoordinator
    ) async throws -> WalletSuiPreparationPacket {
        guard request.action.type == .nativeTransfer
                || request.action.type == .fungibleTokenTransfer
                || request.action.type == .nftTransfer,
              let amount = request.action.amountBaseUnits else {
            throw WalletGateway.Error.invalidArguments(
                "Sui supports only reviewed native, Coin, and public-object transfers."
            )
        }
        let assetID: String
        let coinType: String
        let coinObject: WalletSuiObjectReference?
        let coinBalance: String?
        let coinNetwork: WalletSuiNetworkStatus?
        let transferredObject: WalletSuiObjectReference?
        let objectNetwork: WalletSuiNetworkStatus?
        let gasRequired: String
        switch request.action.type {
        case .nativeTransfer:
            guard let required = WalletBaseUnits.add(
                amount, request.maximumFeeBaseUnits
            ) else {
                throw WalletGateway.Error.invalidArguments(
                    "The SUI amount and gas ceiling overflow."
                )
            }
            assetID = network.nativeAssetID
            coinType = WalletSuiAssetIdentity.nativeCoinType
            coinObject = nil
            coinBalance = nil
            coinNetwork = nil
            transferredObject = nil
            objectNetwork = nil
            gasRequired = required
        case .fungibleTokenTransfer:
            guard let requestedAssetID = request.action.assetID,
                  let identity = WalletSuiAssetIdentity.parse(requestedAssetID),
                  identity.networkID == request.networkID,
                  identity.coinType != WalletSuiAssetIdentity.nativeCoinType else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui Coin identity is invalid."
                )
            }
            let selection = try await coordinator.selectCoinObject(
                owner: account.address, coinType: identity.coinType,
                requiredBalanceBaseUnits: amount
            )
            assetID = identity.canonicalID
            coinType = identity.coinType
            coinObject = selection.object.reference
            coinBalance = selection.object.balanceBaseUnits
            coinNetwork = selection.snapshot.network
            transferredObject = nil
            objectNetwork = nil
            gasRequired = request.maximumFeeBaseUnits
        case .nftTransfer:
            guard let requestedAssetID = request.action.assetID,
                  let identity = WalletSuiObjectIdentity.parse(requestedAssetID),
                  identity.networkID == request.networkID,
                  request.action.tokenID == identity.objectID else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui object identity is invalid."
                )
            }
            let snapshot = try await coordinator.ownedObjectSnapshot(owner: account.address)
            guard let object = snapshot.objects.first(where: { $0.identity == identity }),
                  object.hasPublicTransfer,
                  WalletSuiAssetIdentity.isCanonicalCoinType(object.moveType) else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui object is missing, generic, or not publicly transferable."
                )
            }
            assetID = identity.canonicalID
            coinType = ""
            coinObject = nil
            coinBalance = nil
            coinNetwork = nil
            transferredObject = WalletSuiObjectReference(
                objectID: identity.objectID, version: object.version,
                digest: object.digest, type: object.moveType
            )
            objectNetwork = snapshot.network
            gasRequired = request.maximumFeeBaseUnits
        default:
            throw WalletGateway.Error.invalidArguments("Unsupported Sui action.")
        }
        let gasSelection = try await coordinator.selectNativeGasCoin(
            owner: account.address, requiredBalanceBaseUnits: gasRequired
        )
        let status = gasSelection.snapshot.network
        if let coinNetwork {
            guard status.checkpointSequence >= coinNetwork.checkpointSequence,
                  status.checkpointTimestamp >= coinNetwork.checkpointTimestamp,
                  status.chainIdentifier == coinNetwork.chainIdentifier,
                  status.epoch == coinNetwork.epoch,
                  status.referenceGasPrice == coinNetwork.referenceGasPrice,
                  coinObject?.objectID != gasSelection.coin.reference.objectID else {
                throw WalletGateway.Error.invalidArguments(
                    "The Sui Coin and gas evidence do not share a safe checkpoint lineage."
                )
            }
        }
        if let objectNetwork {
            guard status.checkpointSequence >= objectNetwork.checkpointSequence,
                  status.checkpointTimestamp >= objectNetwork.checkpointTimestamp,
                  status.chainIdentifier == objectNetwork.chainIdentifier,
                  status.epoch == objectNetwork.epoch,
                  status.referenceGasPrice == objectNetwork.referenceGasPrice,
                  transferredObject?.objectID != gasSelection.coin.reference.objectID else {
                throw WalletGateway.Error.invalidArguments(
                    "The Sui object and gas evidence do not share a safe checkpoint lineage."
                )
            }
        }
        return WalletSuiPreparationPacket(
            request: request, chainIdentifier: status.chainIdentifier,
            checkpointSequence: status.checkpointSequence,
            checkpointTimestamp: status.checkpointTimestamp,
            sender: account.address, assetID: assetID, coinType: coinType,
            coinObject: coinObject, coinBalanceBaseUnits: coinBalance,
            coinCheckpointSequence: coinNetwork?.checkpointSequence,
            coinCheckpointTimestamp: coinNetwork?.checkpointTimestamp,
            transferredObject: transferredObject,
            objectHasPublicTransfer: transferredObject == nil ? nil : true,
            objectCheckpointSequence: objectNetwork?.checkpointSequence,
            objectCheckpointTimestamp: objectNetwork?.checkpointTimestamp,
            gasObject: gasSelection.coin.reference,
            gasBalanceBaseUnits: gasSelection.coin.balanceBaseUnits,
            gasBudgetBaseUnits: request.maximumFeeBaseUnits,
            referenceGasPriceBaseUnits: status.referenceGasPrice,
            gasPriceBaseUnits: status.referenceGasPrice,
            currentEpoch: status.epoch, expirationEpoch: status.epoch,
            observedAt: Date()
        )
    }

    private static func simulateSui(
        packet: WalletSuiPreparationPacket,
        transaction: WalletSuiCanonicalTransaction,
        intentID: String,
        coordinator: WalletSuiProviderCoordinator
    ) async throws -> WalletSuiSimulationPacket {
        guard let recipient = packet.request.action.recipient,
              let amount = packet.request.action.amountBaseUnits else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Sui transfer is incomplete."
            )
        }
        let bcs = transaction.transactionBCS.base64EncodedString()
        switch packet.request.action.type {
        case .nativeTransfer:
            let value = try await coordinator.simulateNativeTransfer(
                transactionBCS: bcs,
                expectedTransactionDigest: transaction.transactionDigest,
                sender: packet.sender, recipient: recipient,
                amountBaseUnits: amount,
                maximumFeeBaseUnits: packet.request.maximumFeeBaseUnits,
                gasObjectID: packet.gasObject.objectID
            )
            return WalletSuiSimulationPacket(
                intentID: intentID,
                chainIdentifier: value.network.chainIdentifier,
                checkpointSequence: value.network.checkpointSequence,
                checkpointTimestamp: value.network.checkpointTimestamp,
                currentEpoch: value.network.epoch,
                referenceGasPriceBaseUnits: value.network.referenceGasPrice,
                transactionDigest: value.transactionDigest,
                effectsDigest: value.effectsDigest, sender: value.sender,
                recipient: value.recipient, assetID: packet.assetID,
                coinType: packet.coinType, coinObjectID: nil,
                transferredObjectInput: nil, transferredObjectOutput: nil,
                objectHasPublicTransfer: nil,
                amountBaseUnits: value.amountBaseUnits,
                senderDebitBaseUnits: value.senderDebitBaseUnits,
                senderGasDebitBaseUnits: nil,
                recipientCreditBaseUnits: value.recipientCreditBaseUnits,
                gasObjectID: value.gasObjectID,
                computationCost: value.gas.computationCost,
                storageCost: value.gas.storageCost,
                storageRebate: value.gas.storageRebate,
                nonRefundableStorageFee: value.gas.nonRefundableStorageFee,
                actualFeeBaseUnits: value.gas.actualFeeBaseUnits,
                observedAt: Date()
            )
        case .fungibleTokenTransfer:
            guard let identity = WalletSuiAssetIdentity.parse(packet.assetID),
                  let coinObject = packet.coinObject else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui Coin preparation is incomplete."
                )
            }
            let value = try await coordinator.simulateCoinTransfer(
                transactionBCS: bcs,
                expectedTransactionDigest: transaction.transactionDigest,
                sender: packet.sender, recipient: recipient,
                identity: identity, coinObjectID: coinObject.objectID,
                amountBaseUnits: amount,
                maximumFeeBaseUnits: packet.request.maximumFeeBaseUnits,
                gasObjectID: packet.gasObject.objectID
            )
            return WalletSuiSimulationPacket(
                intentID: intentID,
                chainIdentifier: value.network.chainIdentifier,
                checkpointSequence: value.network.checkpointSequence,
                checkpointTimestamp: value.network.checkpointTimestamp,
                currentEpoch: value.network.epoch,
                referenceGasPriceBaseUnits: value.network.referenceGasPrice,
                transactionDigest: value.transactionDigest,
                effectsDigest: value.effectsDigest, sender: value.sender,
                recipient: value.recipient, assetID: value.identity.canonicalID,
                coinType: value.identity.coinType,
                coinObjectID: value.coinObjectID,
                transferredObjectInput: nil, transferredObjectOutput: nil,
                objectHasPublicTransfer: nil,
                amountBaseUnits: value.amountBaseUnits,
                senderDebitBaseUnits: value.senderAssetDebitBaseUnits,
                senderGasDebitBaseUnits: value.senderGasDebitBaseUnits,
                recipientCreditBaseUnits: value.recipientCreditBaseUnits,
                gasObjectID: value.gasObjectID,
                computationCost: value.gas.computationCost,
                storageCost: value.gas.storageCost,
                storageRebate: value.gas.storageRebate,
                nonRefundableStorageFee: value.gas.nonRefundableStorageFee,
                actualFeeBaseUnits: value.gas.actualFeeBaseUnits,
                observedAt: Date()
            )
        case .nftTransfer:
            guard let object = packet.transferredObject else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui object preparation is incomplete."
                )
            }
            let value = try await coordinator.simulateObjectTransfer(
                transactionBCS: bcs,
                expectedTransactionDigest: transaction.transactionDigest,
                sender: packet.sender, recipient: recipient,
                inputObject: object,
                maximumFeeBaseUnits: packet.request.maximumFeeBaseUnits,
                gasObject: packet.gasObject
            )
            return WalletSuiSimulationPacket(
                intentID: intentID,
                chainIdentifier: value.network.chainIdentifier,
                checkpointSequence: value.network.checkpointSequence,
                checkpointTimestamp: value.network.checkpointTimestamp,
                currentEpoch: value.network.epoch,
                referenceGasPriceBaseUnits: value.network.referenceGasPrice,
                transactionDigest: value.transactionDigest,
                effectsDigest: value.effectsDigest, sender: value.sender,
                recipient: value.recipient, assetID: packet.assetID,
                coinType: "", coinObjectID: nil,
                transferredObjectInput: value.inputObject,
                transferredObjectOutput: value.outputObject,
                objectHasPublicTransfer: value.hasPublicTransfer,
                amountBaseUnits: "1", senderDebitBaseUnits: "0",
                senderGasDebitBaseUnits: value.senderGasDebitBaseUnits,
                recipientCreditBaseUnits: "1", gasObjectID: value.gasObjectID,
                computationCost: value.gas.computationCost,
                storageCost: value.gas.storageCost,
                storageRebate: value.gas.storageRebate,
                nonRefundableStorageFee: value.gas.nonRefundableStorageFee,
                actualFeeBaseUnits: value.gas.actualFeeBaseUnits,
                observedAt: Date()
            )
        default:
            throw WalletGateway.Error.invalidArguments("Unsupported Sui action.")
        }
    }

    private static func reviewSui(
        request: WalletPrepareRequest,
        account: WalletAccount,
        packet: WalletSuiPreparationPacket,
        simulation: WalletSuiSimulationPacket,
        semanticDigest: String,
        binding: WalletConnectionRequestBinding,
        expiresAt: Date
    ) -> WalletPreparedTransaction {
        let effect = WalletDecodedEffect(
            id: binding.requestID, kind: request.action.type.rawValue,
            assetID: packet.assetID,
            amountBaseUnits: request.action.amountBaseUnits ?? "0",
            from: account.address, to: request.action.recipient, spender: nil
        )
        return WalletPreparedTransaction(
            id: binding.requestID, digest: semanticDigest,
            networkID: request.networkID, accountID: request.accountID,
            source: request.source, action: request.action,
            summary: "Review Sui transfer from \(account.label)",
            effects: [effect], riskFlags: [], contract: nil,
            adapterID: request.action.adapterID,
            budgetAssetID: packet.assetID,
            spendBaseUnits: request.action.amountBaseUnits ?? "0",
            maximumFeeBaseUnits: request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: simulation.actualFeeBaseUnits,
            simulation: "Sui simulation succeeded at checkpoint \(simulation.checkpointSequence).",
            simulationSucceeded: true,
            nonce: String(packet.gasObject.version), createdAt: packet.observedAt,
            expiresAt: expiresAt,
            policyDecision: "exact_confirmation_required", policyID: nil
        )
    }

    private static func review(
        request: WalletPrepareRequest,
        account: WalletAccount,
        contract: WalletContractRegistryEntry?,
        packet: WalletEVMPreparationPacket,
        semanticDigest: String,
        binding: WalletConnectionRequestBinding,
        expiresAt: Date
    ) -> WalletPreparedTransaction {
        let action = request.action
        let assetID = action.assetID ?? action.inputAssetID
            ?? WalletNetworkCatalog.descriptor(id: request.networkID)?.nativeAssetID
            ?? request.networkID
        let amount = action.amountBaseUnits ?? "0"
        let effect = WalletDecodedEffect(
            id: binding.requestID, kind: action.type.rawValue,
            assetID: assetID, amountBaseUnits: amount,
            from: account.address, to: action.recipient, spender: nil
        )
        let operation: String = switch action.type {
        case .nativeTransfer: "native transfer"
        case .fungibleTokenTransfer: "token transfer"
        case .nftTransfer: "collectible transfer"
        case .exactInputSwap: "exact-input swap"
        case .swapAllowanceSetup: "finite swap allowance setup"
        case .reviewedCall, .contractCall: "reviewed call"
        case .standardizedSignIn, .reviewedTypedAuthorization: "authorization"
        }
        let identity = contract.map {
            WalletContractIdentity(
                registryID: $0.id, address: $0.checksumAddress,
                label: $0.label,
                function: action.type == .exactInputSwap
                    ? "execute(bytes,bytes[],uint256)"
                    : action.type == .swapAllowanceSetup
                        ? "finite allowance" : "reviewed adapter",
                abiDigest: $0.abiDigest, runtimeCodeHash: $0.runtimeCodeHash
            )
        }
        return WalletPreparedTransaction(
            id: binding.requestID, digest: semanticDigest,
            networkID: request.networkID, accountID: request.accountID,
            source: request.source, action: action,
            summary: "Review \(operation) from \(account.label)",
            effects: [effect], riskFlags: [], contract: identity,
            adapterID: action.adapterID, budgetAssetID: assetID,
            spendBaseUnits: amount,
            maximumFeeBaseUnits: request.maximumFeeBaseUnits,
            feeQuoteBaseUnits: packet.feeQuoteBaseUnits,
            simulation: packet.simulation, simulationSucceeded: true,
            nonce: String(packet.transaction.nonce), createdAt: packet.observedAt,
            expiresAt: expiresAt,
            policyDecision: "exact_confirmation_required", policyID: nil
        )
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private struct SimulationEvidence: Encodable {
        let networkID: String
        let from: String
        let transaction: WalletEVMTransactionFields
        let feeQuoteBaseUnits: String
        let simulation: String
        let runtimeCodeHash: String?
        let observedAt: Date
    }

    private struct SolanaSimulationEvidence: Encodable {
        let networkID: String
        let feePayer: String
        let genesisHash: String
        let messageDigest: String
        let resolvedAccountsDigest: String
        let feeQuoteBaseUnits: String
        let simulation: String
        let observedAt: Date
    }
}

enum WalletExternalEVMABIEncoder {
    private static let maximumCalldataBytes = 256 * 1_024

    static func encode(
        action: WalletSemanticAction,
        registryEntry: WalletContractRegistryEntry
    ) throws -> String {
        guard action.type == .contractCall,
              action.contractID == registryEntry.id,
              let function = action.function,
              let index = registryEntry.permittedFunctions.firstIndex(of: function),
              registryEntry.permittedSelectors.indices.contains(index),
              let types = parameterTypes(function),
              types == action.arguments.map(\.type),
              action.arguments.count <= 64 else {
            throw WalletGateway.Error.invalidArguments(
                "The semantic call is not present in the reviewed ABI boundary."
            )
        }
        let selector = registryEntry.permittedSelectors[index].lowercased()
        guard selector.count == 10, selector.hasPrefix("0x"),
              selector.dropFirst(2).allSatisfy(\.isHexDigit),
              let abiData = registryEntry.normalizedABI.data(using: .utf8),
              "sha256:" + SHA256.hash(data: abiData).map({
                  String(format: "%02x", $0)
              }).joined() == registryEntry.abiDigest else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed ABI identity is invalid."
            )
        }
        let values = try zip(types, action.arguments).map { type, argument in
            try ABIValue(type: type, value: argument.value)
        }
        var head: [String] = []
        var tails: [String] = []
        var offset = values.count * 32
        for value in values {
            if let word = value.staticWord {
                head.append(word)
            } else {
                let tail = try value.dynamicEncoding()
                head.append(try word(String(offset)))
                tails.append(tail)
                offset += tail.count / 2
            }
        }
        let body = head.joined() + tails.joined()
        guard body.count / 2 + 4 <= maximumCalldataBytes else {
            throw WalletGateway.Error.invalidArguments("The reviewed calldata is too large.")
        }
        return selector + body
    }

    private enum ABIValue {
        case staticValue(String)
        case bytes(String)
        case bytesArray([String])

        init(type: String, value: String) throws {
            switch type {
            case "address":
                guard value.count == 42, value.hasPrefix("0x"),
                      value.dropFirst(2).allSatisfy(\.isHexDigit),
                      value.dropFirst(2).contains(where: { $0 != "0" }) else {
                    throw WalletGateway.Error.invalidArguments("Invalid reviewed EVM address.")
                }
                self = .staticValue(String(repeating: "0", count: 24) + value.dropFirst(2).lowercased())
            case "uint8", "uint16", "uint24", "uint32", "uint64", "uint128", "uint160", "uint256":
                self = .staticValue(try word(value))
            case "bool":
                guard value == "true" || value == "false" else {
                    throw WalletGateway.Error.invalidArguments("Invalid reviewed boolean.")
                }
                self = .staticValue(try word(value == "true" ? "1" : "0"))
            case "bytes32":
                guard value.count == 66, value.hasPrefix("0x"),
                      value.dropFirst(2).allSatisfy(\.isHexDigit) else {
                    throw WalletGateway.Error.invalidArguments("Invalid reviewed bytes32 value.")
                }
                self = .staticValue(String(value.dropFirst(2)).lowercased())
            case "bytes":
                self = .bytes(try WalletExternalEVMABIEncoder.bytes(value))
            case "bytes[]":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.first == "[", trimmed.last == "]" else {
                    throw WalletGateway.Error.invalidArguments("Invalid reviewed bytes array.")
                }
                let inner = trimmed.dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let entries = inner.isEmpty ? [] : inner.split(separator: ",").map(String.init)
                guard entries.count <= 64 else {
                    throw WalletGateway.Error.invalidArguments("The reviewed bytes array is too large.")
                }
                self = .bytesArray(try entries.map(
                    WalletExternalEVMABIEncoder.bytes
                ))
            default:
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed ABI type \(type) is unavailable to external wallets."
                )
            }
        }

        var staticWord: String? {
            if case .staticValue(let value) = self { return value }
            return nil
        }

        func dynamicEncoding() throws -> String {
            switch self {
            case .staticValue:
                throw WalletGateway.Error.invalidArguments("Invalid ABI encoding state.")
            case .bytes(let value):
                return try Self.encodeBytes(value)
            case .bytesArray(let values):
                var heads: [String] = []
                var tails: [String] = []
                var offset = values.count * 32
                for value in values {
                    let encoded = try Self.encodeBytes(value)
                    heads.append(try word(String(offset)))
                    tails.append(encoded)
                    offset += encoded.count / 2
                }
                return try word(String(values.count)) + heads.joined() + tails.joined()
            }
        }

        private static func encodeBytes(_ value: String) throws -> String {
            let byteCount = value.count / 2
            let padding = (64 - value.count % 64) % 64
            return try word(String(byteCount)) + value + String(repeating: "0", count: padding)
        }
    }

    private static func parameterTypes(_ function: String) -> [String]? {
        guard let open = function.firstIndex(of: "("), function.last == ")",
              open > function.startIndex else { return nil }
        let body = function[function.index(after: open)..<function.index(before: function.endIndex)]
        if body.isEmpty { return [] }
        let types = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return types.allSatisfy({ !$0.isEmpty }) ? types : nil
    }

    private static func bytes(_ value: String) throws -> String {
        guard value.hasPrefix("0x"), value.dropFirst(2).count.isMultiple(of: 2),
              value.dropFirst(2).allSatisfy(\.isHexDigit) else {
            throw WalletGateway.Error.invalidArguments("Invalid reviewed byte string.")
        }
        return String(value.dropFirst(2)).lowercased()
    }

    private static func word(_ decimal: String) throws -> String {
        guard let hexadecimal = WalletEthereumQuantity.decimalToHex(decimal) else {
            throw WalletGateway.Error.invalidArguments("Invalid reviewed unsigned integer.")
        }
        let raw = hexadecimal.dropFirst(2)
        guard raw.count <= 64 else {
            throw WalletGateway.Error.invalidArguments("The reviewed integer exceeds uint256.")
        }
        return String(repeating: "0", count: 64 - raw.count) + raw
    }
}
