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
    private var preparationPackets: [String: WalletEVMPreparationPacket] = [:]

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

    func beginVaultCreation() async throws -> WalletVaultCreation {
        try await call { proxy, reply in proxy.beginCreateVault(reply: reply) }
    }

    func beginMainnetRotation() async throws -> WalletVaultCreation {
        try await call { proxy, reply in proxy.beginRotateForMainnet(reply: reply) }
    }

    func confirmVaultBackup(_ confirmation: WalletBackupConfirmation) async throws -> WalletSignerStatus {
        let data = try encoder.encode(confirmation)
        return try await call { proxy, reply in proxy.confirmBackup(data, reply: reply) }
    }

    func cancelVaultCreation() async throws -> WalletSignerStatus {
        try await call { proxy, reply in proxy.cancelCreateVault(reply: reply) }
    }

    func restoreVault(words: [String]) async throws -> WalletSignerStatus {
        let data = try encoder.encode(WalletVaultRestoreRequest(words: words))
        return try await call { proxy, reply in proxy.restoreVault(data, reply: reply) }
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
        guard let account = accounts.first(where: {
            $0.id == request.accountID && $0.chain == .evm
        }) else {
            throw WalletGateway.Error.invalidArguments("The selected EVM account does not exist in Locus Vault.")
        }
        let encodedContract: WalletEncodedContractCall?
        if let contract {
            let encodingRequest = WalletContractEncodingRequest(
                action: request.action, registryEntry: contract
            )
            let requestData = try authorized(encodingRequest, source: request.source)
            encodedContract = try await call { proxy, reply in
                proxy.encodeEVMContract(requestData, reply: reply)
            }
        } else {
            encodedContract = nil
        }
        let rpc = try rpcClient(for: request.networkID)
        let packet = try await rpc.prepare(
            request: request,
            fromAddress: account.address,
            contract: contract,
            encodedContract: encodedContract
        )
        let data = try authorized(packet, source: request.source)
        let transaction: WalletPreparedTransaction = try await call { proxy, reply in
            proxy.prepareEVM(data, reply: reply)
        }
        preparationPackets[transaction.id] = packet
        return transaction
    }

    func simulate(intentID: String) async throws -> WalletPreparedTransaction {
        guard let packet = preparationPackets[intentID] else {
            throw WalletGateway.Error.intentNotFound
        }
        let rpc = try rpcClient(for: packet.request.networkID)
        let recheck = try await rpc.recheck(intentID: intentID, packet: packet)
        let data = try authorized(recheck, source: packet.request.source)
        return try await call { proxy, reply in proxy.simulateEVM(data, reply: reply) }
    }

    func confirmExecution(intentID: String) async throws {
        guard let packet = preparationPackets[intentID] else {
            throw WalletGateway.Error.intentNotFound
        }
        let request = try authorized(intentID, source: packet.request.source)
        let _: WalletPreparedTransaction = try await call { proxy, reply in
            proxy.confirmEVM(request, reply: reply)
        }
    }

    func execute(intentID: String) async throws -> [String: Any] {
        guard let packet = preparationPackets[intentID] else {
            throw WalletGateway.Error.intentNotFound
        }
        let rpc = try rpcClient(for: packet.request.networkID)
        let recheck = try await rpc.recheck(intentID: intentID, packet: packet)
        let request = try authorized(recheck, source: packet.request.source)
        let signed: WalletEVMSignedTransaction = try await call { proxy, reply in
            proxy.executeEVM(request, reply: reply)
        }
        // The intent is consumed as soon as signed bytes cross the XPC boundary.
        // A broadcast failure must never make the same intent signable again.
        preparationPackets[intentID] = nil
        let broadcastHash: String
        do {
            broadcastHash = try await rpc.broadcast(rawTransaction: signed.rawTransaction)
        } catch {
            throw WalletGateway.Error.broadcastUnknown(
                transactionHash: signed.transactionHash,
                message: error.localizedDescription
            )
        }
        guard broadcastHash.caseInsensitiveCompare(signed.transactionHash) == .orderedSame else {
            throw WalletGateway.Error.broadcastUnknown(
                transactionHash: signed.transactionHash,
                message: "The provider returned a transaction hash that does not match the signed bytes."
            )
        }
        return [
            "text": "Submitted \(packet.request.networkID) transaction \(broadcastHash)",
            "intent_id": intentID,
            "transaction_hash": broadcastHash,
            "network_id": packet.request.networkID,
            "status": "submitted",
        ]
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
        let rpc = try rpcClient(for: networkID)
        return try await rpc.publicRead(method: method, params: params)
    }

    func performRead(tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        switch tool {
        case "wallet_get_balance":
            let accountID = arguments["account_id"] as? String
            let networkID = arguments["network_id"] as? String ?? WalletGateway.sepoliaNetworkID
            let accounts = try await listAccounts()
            guard let account = accounts.first(where: {
                $0.id == accountID && $0.chain == .evm && $0.networkIDs.contains(networkID)
            }) else {
                throw WalletGateway.Error.invalidArguments("Select the Locus Vault EVM account.")
            }
            let rpc = try rpcClient(for: networkID)
            let balance = try await rpc.balance(address: account.address)
            return [
                "text": "\(networkID) balance: \(balance) wei",
                "account_id": account.id,
                "network_id": networkID,
                "asset_id": "\(networkID)/slip44:60",
                "balance_base_units": balance,
            ]
        case "wallet_get_activity":
            return [
                "text": "Submitted Locus Vault transactions are available in Wallet Settings. The configured RPC does not expose indexed account history.",
                "activity": [],
            ]
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
        invalidationHandler?()
    }
}
#endif
