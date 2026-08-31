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
@MainActor
final class XPCWalletSignerClient: WalletSignerClient {
    let isAvailable: Bool
    private(set) var sessionID: String?
    var invalidationHandler: (() -> Void)?

    private var connection: NSXPCConnection?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rpcClients: [String: WalletEVMProviderCoordinator]
    private let solanaRPCClients: [String: WalletSolanaProviderCoordinator]
    private var preparationPackets: [String: WalletEVMPreparationPacket] = [:]
    private var solanaPreparationPackets: [String: WalletSolanaPreparationPacket] = [:]

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

    func beginRecoveryCeremony(
        mode: WalletRecoveryCeremonyMode
    ) async throws -> WalletRecoveryCeremonyLaunch {
        let request = try encoder.encode(WalletRecoveryCeremonyRequest(mode: mode))
        let response: (Data, NSXPCListenerEndpoint?) = try await withCheckedThrowingContinuation {
            continuation in
            let gate = WalletXPCReplyGate()
            do {
                let proxy = try remoteProxy(errorHandler: { error in
                    if gate.take() { continuation.resume(throwing: error) }
                })
                proxy.beginRecoveryCeremony(request) { data, endpoint in
                    if gate.take() { continuation.resume(returning: (data, endpoint)) }
                }
            } catch {
                if gate.take() { continuation.resume(throwing: error) }
            }
        }
        if let failure = try? decoder.decode(WalletSignerErrorPayload.self, from: response.0) {
            throw NSError(
                domain: "WalletSigner", code: 1,
                userInfo: [NSLocalizedDescriptionKey: failure.error]
            )
        }
        let handle = try decoder.decode(WalletRecoveryCeremonyHandle.self, from: response.0)
        guard let endpoint = response.1 else { throw WalletGateway.Error.signerUnavailable }
        return WalletRecoveryCeremonyLaunch(handle: handle, signerEndpoint: endpoint)
    }

    func cancelRecoveryCeremony(id: String) async throws -> WalletSignerStatus {
        try await call { proxy, reply in proxy.cancelRecoveryCeremony(id, reply: reply) }
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
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Sui transaction builder is not active."
            )
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
        throw WalletGateway.Error.intentNotFound
    }

    func execute(intentID: String) async throws -> [String: Any] {
        if let packet = preparationPackets[intentID] {
            let rpc = try rpcClient(for: packet.request.networkID)
            let recheck = try await rpc.recheck(intentID: intentID, packet: packet)
            let request = try authorized(recheck, source: packet.request.source)
            let signed: WalletEVMSignedTransaction = try await call { proxy, reply in
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
            let signed: WalletSolanaSignedTransaction = try await call { proxy, reply in
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
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui provider is not active."
                )
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
            let accounts = try await listAccounts()
            guard let account = accounts.first(where: {
                $0.id == accountID && $0.chain == .solana
                    && $0.networkIDs.contains(networkID)
            }) else {
                throw WalletGateway.Error.invalidArguments(
                    "Select the matching Locus Vault Solana account."
                )
            }
            let tokenAccounts = try await solanaRPCClient(
                for: networkID
            ).tokenAccounts(owner: account.address)
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
            let rows: [[String: Any]] = aggregates.values.sorted {
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
            return [
                "text": "Loaded \(rows.count) Solana token assets.",
                "account_id": account.id,
                "network_id": networkID,
                "assets": rows,
            ]
        case "wallet_get_activity":
            let accountID = arguments["account_id"] as? String
            let networkID = arguments["network_id"] as? String
                ?? WalletGateway.ethereumMainnetNetworkID
            let accounts = try await listAccounts()
            guard let account = accounts.first(where: {
                $0.id == accountID && $0.chain == .evm && $0.networkIDs.contains(networkID)
            }) else {
                throw WalletGateway.Error.invalidArguments("Select the Locus Vault EVM account.")
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
        guard isAvailable else { return }
        do {
            let proxy = try remoteProxy()
            proxy.lock { _ in }
        } catch {
            invalidate()
        }
    }

    private func call<T: Decodable>(
        _ body: @escaping (WalletSignerXPCProtocol, @escaping (Data) -> Void) -> Void
    ) async throws -> T {
        let data = try await rawCall(body)
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
        _ body: @escaping (WalletSignerXPCProtocol, @escaping (Data) -> Void) -> Void
    ) async throws -> Data {
        guard isAvailable else { throw WalletGateway.Error.signerUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = WalletXPCReplyGate()
            do {
                let proxy = try remoteProxy(errorHandler: { error in
                    if gate.take() { continuation.resume(throwing: error) }
                })
                body(proxy) { data in
                    if gate.take() { continuation.resume(returning: data) }
                }
            } catch {
                if gate.take() { continuation.resume(throwing: error) }
            }
        }
    }

    private func remoteProxy(
        errorHandler: @escaping (Error) -> Void = { _ in }
    ) throws -> WalletSignerXPCProtocol {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler)
            as? WalletSignerXPCProtocol else {
            throw WalletGateway.Error.signerUnavailable
        }
        return proxy
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: "io.sparktales.locus.WalletSigner")
        connection.remoteObjectInterface = NSXPCInterface(with: WalletSignerXPCProtocol.self)
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.invalidate() }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.invalidate() }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func invalidate() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        sessionID = nil
        preparationPackets.removeAll()
        solanaPreparationPackets.removeAll()
        invalidationHandler?()
    }
}
#endif
