import Combine
import CryptoKit
import Foundation
import WalletConnectSign

@MainActor
final class WalletConnectDriver: WalletConnectorDriver {
    let connector = WalletConnectionConnector.walletConnect
    let events: AsyncStream<WalletConnectorEvent>
    var dappRequestHandler: (@MainActor (WalletConnectorDappRequest) async throws
        -> WalletConnectorDappResponse)?

    private static let groupIdentifier = "4X4RJA7GMD.io.sparktales.locus"
    private static let bindingsKey = "LocusWalletConnectPrivateBindingsV1"
    private static let maximumPeerTextBytes = 512
    private static let maximumSessionLifetime: TimeInterval = 30 * 24 * 60 * 60

    private struct PersistedBinding: Codable, Equatable {
        let connectionID: String
        let accounts: [WalletAccount]
    }

    private struct ProposalWaiter {
        let requestID: String
        let continuation: CheckedContinuation<Session.Proposal, Error>
    }

    private let client: SignClientProtocol?
    private let defaults: UserDefaults?
    private let eventContinuation: AsyncStream<WalletConnectorEvent>.Continuation
    private var bindings: [String: PersistedBinding]
    private var proposalWaiters: [String: ProposalWaiter] = [:]
    private var activeProposals: [String: Session.Proposal] = [:]
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var completedRequestKeys: Set<String> = []
    private var completedRequestOrder: [String] = []
    private var cancellables: Set<AnyCancellable> = []

    private static let maximumRequestBytes = 256 * 1_024
    private static let maximumCompletedRequests = 2_048

    init(bundle: Bundle, environment: [String: String]) {
        var continuation: AsyncStream<WalletConnectorEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation

        let defaults = UserDefaults(suiteName: Self.groupIdentifier)
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.bindingsKey),
           let decoded = try? JSONDecoder().decode(
               [String: PersistedBinding].self, from: data
           ) {
            bindings = decoded
        } else {
            bindings = [:]
        }

        let configuration = WalletConnectorReleaseConfiguration.runtimeValues(
            from: bundle, environment: environment
        )
        let projectID = configuration["LocusReownProjectID"] ?? ""
        let redirectValue = configuration["LocusWalletConnectRedirectURL"] ?? ""
        guard let registry = WalletSignedReviewCeiling.bundledConfigurationRegistry(bundle: bundle)
                ?? WalletReviewRegistry.loadBundled(from: bundle),
              let entry = registry.manifest.connectors.first(where: { $0.connector == .walletConnect }),
              let method = entry.methods.sorted(by: { $0.rawValue < $1.rawValue }).first,
              registry.containsConnector(
                  .walletConnect, direction: .locusVaultToDapp, method: method,
                  configurationValues: configuration
              ), Self.validProjectID(projectID),
              Self.validRedirectURL(redirectValue),
              let redirect = try? AppMetadata.Redirect(
                  native: redirectValue, universal: nil
              ) else {
            client = nil
            return
        }

        Networking.configure(
            groupIdentifier: Self.groupIdentifier,
            projectId: projectID,
            socketFactory: WalletConnectURLSessionSocketFactory()
        )
        Pair.configure(metadata: AppMetadata(
            name: "Locus Vault",
            description: "Reviewed Locus Vault connection",
            url: "https://locus.app",
            icons: [],
            redirect: redirect
        ))
        Sign.configure(crypto: WalletConnectCryptoProvider())
        client = Sign.instance
        subscribe()
    }

    deinit { eventContinuation.finish() }

    var isConfigured: Bool { client != nil }

    func restore() async throws -> [WalletConnectorSession] {
        guard let client else {
            throw WalletConnectorRuntimeError.unconfigured("WalletConnect")
        }
        try Networking.instance.connect()
        var restored: [WalletConnectorSession] = []
        let sessions = client.getSessions()
        let liveTopics = Set(sessions.map(\.topic))
        for topic in bindings.keys where !liveTopics.contains(topic) {
            bindings[topic] = nil
        }
        for session in sessions {
            guard session.expiryDate > Date(),
                  let binding = bindings[session.topic] else {
                try? await client.disconnect(topic: session.topic)
                bindings[session.topic] = nil
                continue
            }
            do {
                restored.append(try publicSession(session, binding: binding))
            } catch {
                try? await client.disconnect(topic: session.topic)
                bindings[session.topic] = nil
            }
        }
        persistBindings()
        return restored
    }

    func connect(
        _ request: WalletConnectorPairingRequest,
        approve: @escaping @MainActor (WalletConnectionProposalReview) async -> Bool
    ) async throws -> WalletConnectorSession {
        guard let client, let uriText = request.pairingURI else {
            throw WalletConnectorRuntimeError.unconfigured("WalletConnect")
        }
        let uri: WalletConnectURI
        do { uri = try WalletConnectURI(uriString: uriText) }
        catch { throw WalletConnectorRuntimeError.malformedRequest }
        guard uri.version == "2", uri.expiryTimestamp > UInt64(Date().timeIntervalSince1970),
              uri.expiryTimestamp <= UInt64(request.expiresAt.timeIntervalSince1970) else {
            throw WalletConnectorRuntimeError.malformedRequest
        }
        try Networking.instance.connect()

        let proposal = try await waitForProposal(
            pairingTopic: uri.topic,
            requestID: request.requestID,
            deadline: request.expiresAt
        ) {
            try await Pair.instance.pair(uri: uri)
        }
        activeProposals[request.requestID] = proposal
        defer { activeProposals[request.requestID] = nil }

        let normalized = try normalize(proposal, for: request)
        let review = WalletConnectionProposalReview(
            requestID: request.requestID,
            peerName: normalized.peerName,
            peerURL: normalized.peerURL,
            namespaces: normalized.proposals,
            expiresAt: min(
                request.expiresAt,
                Date().addingTimeInterval(5 * 60)
            )
        )
        guard await approve(review), review.expiresAt > Date() else {
            try? await client.rejectSession(
                proposalId: proposal.id, reason: .userRejected
            )
            throw WalletConnectorRuntimeError.sdkFailure(
                "The WalletConnect proposal was rejected."
            )
        }
        let session = try await client.approve(
            proposalId: proposal.id,
            namespaces: normalized.sessionNamespaces,
            sessionProperties: nil,
            scopedProperties: nil,
            proposalRequestsResponses: nil
        )
        guard session.expiryDate > Date(),
              session.expiryDate.timeIntervalSince(Date()) <= Self.maximumSessionLifetime else {
            try? await client.disconnect(topic: session.topic)
            throw WalletConnectorRuntimeError.sessionMismatch
        }
        let binding = PersistedBinding(
            connectionID: request.requestID,
            accounts: normalized.accounts
        )
        bindings[session.topic] = binding
        persistBindings()
        return try publicSession(session, binding: binding)
    }

    func execute(_ request: WalletExternalExecutionRequest) async throws
        -> WalletExternalExecutionResult {
        _ = request
        throw WalletConnectorRuntimeError.unsupportedConnector
    }

    func cancel(requestID: String) async {
        if let entry = proposalWaiters.first(where: { $0.value.requestID == requestID }) {
            proposalWaiters[entry.key] = nil
            entry.value.continuation.resume(
                throwing: WalletConnectorRuntimeError.sdkFailure(
                    "The WalletConnect pairing was canceled."
                )
            )
        }
        if let proposal = activeProposals[requestID], let client {
            try? await client.rejectSession(
                proposalId: proposal.id, reason: .userRejected
            )
            activeProposals[requestID] = nil
        }
    }

    func disconnect(connectionID: String) async {
        guard let client,
              let topic = bindings.first(where: {
                  $0.value.connectionID == connectionID
              })?.key else { return }
        try? await client.disconnect(topic: topic)
        bindings[topic] = nil
        persistBindings()
    }

    func suspend() async {
        for task in requestTasks.values { task.cancel() }
        requestTasks.removeAll()
        for waiter in proposalWaiters.values {
            waiter.continuation.resume(
                throwing: WalletConnectorRuntimeError.sdkFailure(
                    "WalletConnect was suspended."
                )
            )
        }
        proposalWaiters.removeAll()
        for proposal in activeProposals.values {
            try? await client?.rejectSession(
                proposalId: proposal.id, reason: .userRejected
            )
        }
        activeProposals.removeAll()
        // An unconfigured driver is a valid dormant state. Reown's global
        // accessor traps before configure(), even inside a try? expression.
        guard client != nil else { return }
        try? Networking.instance.disconnect(closeCode: .goingAway)
    }

    private struct NormalizedProposal {
        let peerName: String
        let peerURL: String?
        let proposals: [WalletConnectionNamespaceProposal]
        let sessionNamespaces: [String: SessionNamespace]
        let accounts: [WalletAccount]
    }

    private func normalize(
        _ proposal: Session.Proposal,
        for request: WalletConnectorPairingRequest
    ) throws -> NormalizedProposal {
        guard proposal.requiredNamespaces.count <= 3,
              proposal.requiredNamespaces.values.allSatisfy({
                  $0.methods.count <= 8 && $0.events.count <= 4
              }) else { throw WalletConnectorRuntimeError.malformedRequest }
        var normalizedByNamespace: [
            WalletConnectionNamespace: WalletConnectionNamespaceProposal
        ] = [:]
        var approvedNamespaces: [String: SessionNamespace] = [:]
        var selectedAccounts: [String: WalletAccount] = [:]

        for (key, namespace) in proposal.requiredNamespaces {
            guard let namespaceName = key.split(separator: ":").first,
                  let kind = WalletConnectionNamespace(rawValue: String(namespaceName))
            else { throw WalletConnectionProtocolError.malformed }
            let chains: [Blockchain]
            if let declared = namespace.chains {
                chains = declared
            } else if let scoped = Blockchain(key) {
                chains = [scoped]
            } else {
                throw WalletConnectionProtocolError.malformed
            }
            let networkIDs = try Set(chains.map(Self.internalNetworkID))
            guard !networkIDs.isEmpty,
                  networkIDs.isSubset(of: request.requestedNetworkIDs) else {
                throw WalletConnectionProtocolError.networkNotApproved
            }
            let methods = try Set(namespace.methods.map {
                try Self.semanticMethod($0, namespace: kind)
            })
            guard methods.isSubset(of: request.requestedMethods) else {
                throw WalletConnectionProtocolError.methodNotApproved
            }
            let events = try Set(namespace.events.map(Self.event))
            let accounts = request.offeredAccounts.filter { account in
                account.ownership == .locusVault
                    && account.chain == Self.chain(kind)
                    && !Set(account.networkIDs).isDisjoint(with: networkIDs)
            }
            guard !accounts.isEmpty else {
                throw WalletConnectionProtocolError.accountNotApproved
            }
            let reownAccounts = try accounts.flatMap { account in
                try account.networkIDs.filter(networkIDs.contains).map { networkID in
                    guard let value = Account(
                        chainIdentifier: try Self.walletConnectNetworkID(networkID),
                        address: account.address
                    ) else { throw WalletConnectionProtocolError.malformed }
                    return value
                }
            }
            approvedNamespaces[key] = SessionNamespace(
                chains: chains,
                accounts: reownAccounts,
                methods: namespace.methods,
                events: namespace.events
            )
            for account in accounts { selectedAccounts[account.id] = account }
            if let existing = normalizedByNamespace[kind] {
                normalizedByNamespace[kind] = WalletConnectionNamespaceProposal(
                    namespace: kind,
                    networkIDs: existing.networkIDs.union(networkIDs),
                    methods: existing.methods.union(methods),
                    events: existing.events.union(events)
                )
            } else {
                normalizedByNamespace[kind] = WalletConnectionNamespaceProposal(
                    namespace: kind,
                    networkIDs: networkIDs,
                    methods: methods,
                    events: events
                )
            }
        }
        let proposals = normalizedByNamespace.values.sorted {
            $0.namespace.rawValue < $1.namespace.rawValue
        }
        try WalletConnectionNamespaceValidator.validate(
            proposals, connector: .walletConnect,
            direction: .locusVaultToDapp
        )
        return NormalizedProposal(
            peerName: Self.bounded(proposal.proposer.name, fallback: "WalletConnect dapp"),
            peerURL: Self.normalizedPeerURL(proposal.proposer.url),
            proposals: proposals,
            sessionNamespaces: approvedNamespaces,
            accounts: selectedAccounts.values.sorted { $0.id < $1.id }
        )
    }

    private func publicSession(
        _ session: Session,
        binding: PersistedBinding
    ) throws -> WalletConnectorSession {
        guard UUID(uuidString: binding.connectionID) != nil else {
            throw WalletConnectorRuntimeError.sessionMismatch
        }
        var networkIDs: Set<String> = []
        var methods: Set<WalletConnectionMethod> = []
        let sessionAccountIDs = Set(session.accounts.map(\.absoluteString))
        for (key, namespace) in session.namespaces {
            guard let namespaceName = key.split(separator: ":").first,
                  let kind = WalletConnectionNamespace(rawValue: String(namespaceName))
            else { throw WalletConnectorRuntimeError.sessionMismatch }
            for account in namespace.accounts {
                networkIDs.insert(try Self.internalNetworkID(account.blockchain))
            }
            for method in namespace.methods {
                methods.insert(try Self.semanticMethod(method, namespace: kind))
            }
        }
        let expectedAccounts = try Set(binding.accounts.flatMap { account in
            try account.networkIDs.filter(networkIDs.contains).map { networkID in
                guard let value = Account(
                    chainIdentifier: try Self.walletConnectNetworkID(networkID),
                    address: account.address
                ) else { throw WalletConnectorRuntimeError.sessionMismatch }
                return value.absoluteString
            }
        })
        guard sessionAccountIDs == expectedAccounts,
              binding.accounts.allSatisfy({
                  $0.ownership == .locusVault
                      && !Set($0.networkIDs).isDisjoint(with: networkIDs)
              }) else { throw WalletConnectorRuntimeError.sessionMismatch }
        let peerURL = Self.normalizedPeerURL(session.peer.url)
        return WalletConnectorSession(
            connectionID: binding.connectionID,
            peerName: Self.bounded(session.peer.name, fallback: "WalletConnect dapp"),
            peerURL: peerURL,
            peerID: Self.peerID(name: session.peer.name, url: peerURL),
            networkIDs: networkIDs,
            approvedMethods: methods,
            accounts: binding.accounts,
            expiresAt: session.expiryDate
        )
    }

    private func subscribe() {
        guard let client else { return }
        client.sessionProposalPublisher
            .sink { [weak self] value in
                Task { @MainActor in self?.receive(value.proposal) }
            }
            .store(in: &cancellables)
        client.sessionRequestPublisher
            .sink { [weak self] value in
                Task { @MainActor in self?.receive(value.request) }
            }
            .store(in: &cancellables)
        client.sessionDeletePublisher
            .sink { [weak self] value in
                Task { @MainActor in self?.deleted(topic: value.0) }
            }
            .store(in: &cancellables)
        client.sessionsPublisher
            .sink { [weak self] sessions in
                Task { @MainActor in self?.sessionsChanged(sessions) }
            }
            .store(in: &cancellables)
    }

    private func waitForProposal(
        pairingTopic: String,
        requestID: String,
        deadline: Date,
        pair: @escaping () async throws -> Void
    ) async throws -> Session.Proposal {
        try await withCheckedThrowingContinuation { continuation in
            proposalWaiters[pairingTopic] = ProposalWaiter(
                requestID: requestID,
                continuation: continuation
            )
            Task { @MainActor [weak self] in
                do { try await pair() }
                catch {
                    self?.failProposal(
                        topic: pairingTopic,
                        requestID: requestID,
                        error: error
                    )
                    return
                }
                let delay = max(0, deadline.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.failProposal(
                    topic: pairingTopic,
                    requestID: requestID,
                    error: WalletConnectorRuntimeError.sdkFailure(
                        "The WalletConnect proposal timed out."
                    )
                )
            }
        }
    }

    private func receive(_ proposal: Session.Proposal) {
        guard let waiter = proposalWaiters.removeValue(
            forKey: proposal.pairingTopic
        ) else {
            Task { try? await client?.rejectSession(
                proposalId: proposal.id, reason: .userRejected
            ) }
            return
        }
        waiter.continuation.resume(returning: proposal)
    }

    private func failProposal(
        topic: String,
        requestID: String,
        error: Error
    ) {
        guard let waiter = proposalWaiters[topic],
              waiter.requestID == requestID else { return }
        proposalWaiters[topic] = nil
        waiter.continuation.resume(throwing: error)
    }

    private func deleted(topic: String) {
        guard let binding = bindings.removeValue(forKey: topic) else { return }
        cancelRequests(connectionID: binding.connectionID)
        persistBindings()
        eventContinuation.yield(.disconnected(
            connectionID: binding.connectionID
        ))
    }

    private func sessionsChanged(_ sessions: [Session]) {
        let byTopic = Dictionary(uniqueKeysWithValues: sessions.map { ($0.topic, $0) })
        for (topic, binding) in bindings {
            guard let session = byTopic[topic] else {
                bindings[topic] = nil
                cancelRequests(connectionID: binding.connectionID)
                eventContinuation.yield(.disconnected(
                    connectionID: binding.connectionID
                ))
                continue
            }
            if session.expiryDate <= Date() {
                bindings[topic] = nil
                cancelRequests(connectionID: binding.connectionID)
                eventContinuation.yield(.expired(
                    connectionID: binding.connectionID
                ))
            }
        }
        persistBindings()
    }

    private func receive(_ request: Request) {
        let key = requestKey(request)
        guard requestTasks[key] == nil, !completedRequestKeys.contains(key) else {
            Task { await respond(
                to: request,
                with: .error(JSONRPCError(
                    code: -32600, message: "Duplicate wallet request."
                ))
            ) }
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.requestTasks[key] = nil
                self.rememberCompleted(key)
            }
            do {
                let decoded = try self.decode(request)
                guard !Task.isCancelled,
                      let handler = self.dappRequestHandler else {
                    throw WalletConnectorRuntimeError.sessionNotFound
                }
                let value = try await handler(decoded)
                guard !Task.isCancelled else {
                    throw CancellationError()
                }
                try self.validate(value, for: decoded)
                await self.respond(to: request, with: self.rpcResult(
                    value, networkID: decoded.networkID
                ))
            } catch {
                let code = error is CancellationError ? 4001 : -32602
                let message = String(((error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription).prefix(512))
                await self.respond(
                    to: request,
                    with: .error(JSONRPCError(code: code, message: message))
                )
            }
        }
        requestTasks[key] = task
    }

    private func decode(_ request: Request) throws -> WalletConnectorDappRequest {
        guard let binding = bindings[request.topic],
              let session = client?.getSessions().first(where: {
                  $0.topic == request.topic
              }),
              session.expiryDate > Date() else {
            throw WalletConnectorRuntimeError.sessionNotFound
        }
        let networkID = try Self.internalNetworkID(request.chainId)
        let eligibleAccounts = binding.accounts.filter {
            $0.networkIDs.contains(networkID)
        }
        guard !eligibleAccounts.isEmpty else {
            throw WalletConnectionProtocolError.accountNotApproved
        }
        guard let namespace = WalletConnectionNamespace(
            rawValue: request.chainId.namespace
        ) else { throw WalletConnectionProtocolError.networkNotApproved }
        let method = try Self.semanticMethod(request.method, namespace: namespace)
        guard session.namespaces.values.contains(where: { value in
            value.methods.contains(request.method)
                && value.accounts.contains(where: { sessionAccount in
                    sessionAccount.blockchain == request.chainId
                        && eligibleAccounts.contains(where: { account in
                            Self.sameAddress(
                                sessionAccount.address, account.address,
                                chain: account.chain
                            )
                        })
                })
        }) else { throw WalletConnectionProtocolError.methodNotApproved }
        let data = try request.params.getDataRepresentation()
        guard data.count <= Self.maximumRequestBytes,
              let object = try JSONSerialization.jsonObject(with: data) as Any? else {
            throw WalletConnectorRuntimeError.malformedRequest
        }
        let payload: WalletConnectorDappRequest.Payload
        let accountID: String?
        if method == .listAccounts {
            payload = try Self.payload(
                method: request.method, object: object,
                account: eligibleAccounts[0], networkID: networkID
            )
            accountID = nil
        } else {
            let matches = eligibleAccounts.compactMap { account -> (
                WalletAccount, WalletConnectorDappRequest.Payload
            )? in
                guard let payload = try? Self.payload(
                    method: request.method, object: object,
                    account: account, networkID: networkID
                ) else { return nil }
                return (account, payload)
            }
            guard matches.count == 1 else {
                throw WalletConnectionProtocolError.accountNotApproved
            }
            accountID = matches[0].0.id
            payload = matches[0].1
        }
        let peerURL = Self.normalizedPeerURL(session.peer.url)
        let peerID = Self.peerID(name: session.peer.name, url: peerURL)
        let expiry = min(session.expiryDate, min(
            request.expiryTimestamp.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            } ?? Date().addingTimeInterval(2 * 60),
            Date().addingTimeInterval(2 * 60)
        ))
        guard expiry > Date() else { throw WalletConnectorRuntimeError.sessionNotFound }
        return WalletConnectorDappRequest(
            requestID: "wc-" + Self.sha256(
                "\(binding.connectionID)|\(request.id.string)|\(request.method)|\(networkID)"
            ),
            connectionID: binding.connectionID,
            peerID: peerID,
            peerOrigin: peerURL,
            peerName: Self.bounded(session.peer.name, fallback: "WalletConnect dapp"),
            networkID: networkID,
            accountID: accountID,
            method: method,
            expiresAt: expiry,
            payload: payload
        )
    }

    private static func payload(
        method: String,
        object: Any,
        account: WalletAccount,
        networkID: String
    ) throws -> WalletConnectorDappRequest.Payload {
        switch method {
        case "solana_getAccounts", "solana_requestAccounts", "sui_getAccounts":
            guard isEmptyParameters(object) else {
                throw WalletConnectorRuntimeError.malformedRequest
            }
            return .listAccounts
        case "eth_sendTransaction":
            guard let values = object as? [[String: Any]], values.count == 1,
                  let transaction = values.first,
                  Set(transaction.keys).isSubset(of: [
                    "from", "to", "value", "data", "input", "gas",
                    "gasLimit", "gasPrice", "maxFeePerGas",
                    "maxPriorityFeePerGas", "nonce", "chainId", "type",
                  ]),
                  let from = boundedString(transaction["from"], maximum: 128),
                  sameAddress(from, account.address, chain: .evm),
                  let to = boundedString(transaction["to"], maximum: 128) else {
                throw WalletConnectorRuntimeError.malformedRequest
            }
            let data = try optionalHex(
                transaction["data"] ?? transaction["input"], fallback: "0x",
                maximumBytes: Self.maximumRequestBytes
            )
            if transaction["data"] != nil, transaction["input"] != nil {
                let explicitData = try optionalHex(
                    transaction["data"], fallback: "0x",
                    maximumBytes: Self.maximumRequestBytes
                )
                let explicitInput = try optionalHex(
                    transaction["input"], fallback: "0x",
                    maximumBytes: Self.maximumRequestBytes
                )
                guard explicitData.caseInsensitiveCompare(explicitInput) == .orderedSame
                else { throw WalletConnectorRuntimeError.malformedRequest }
            }
            return .evmTransaction(.init(
                from: from, to: to,
                valueHex: try optionalHex(
                    transaction["value"], fallback: "0x0", maximumBytes: 32
                ),
                dataHex: data
            ))
        case "personal_sign":
            guard let values = object as? [String], values.count == 2 else {
                throw WalletConnectorRuntimeError.malformedRequest
            }
            let message: String
            if sameAddress(values[0], account.address, chain: .evm) {
                message = values[1]
            } else if sameAddress(values[1], account.address, chain: .evm) {
                message = values[0]
            } else { throw WalletConnectionProtocolError.accountNotApproved }
            guard let decoded = personalSignMessage(message) else {
                throw WalletConnectorRuntimeError.malformedRequest
            }
            return .canonicalMessage(
                format: .siwe, message: decoded, accountAddress: account.address
            )
        case "solana_signAndSendTransaction":
            guard let values = object as? [String: Any],
                  Set(values.keys).isSubset(of: ["transaction", "sendOptions"]),
                  let transaction = base64(values["transaction"], maximumBytes: 128 * 1_024)
            else { throw WalletConnectorRuntimeError.malformedRequest }
            let options = values["sendOptions"] as? [String: Any] ?? [:]
            guard Set(options.keys).isSubset(of: [
                "skipPreflight", "preflightCommitment", "maxRetries", "minContextSlot",
            ]), options["skipPreflight"] as? Bool != true,
                  boundedString(options["preflightCommitment"], maximum: 32)
                    .map({ ["processed", "confirmed", "finalized"].contains($0) }) ?? true,
                  unsignedInteger(options["maxRetries"]) != nil
                    || options["maxRetries"] == nil else {
                throw WalletConnectorRuntimeError.malformedRequest
            }
            let minimumSlot: UInt64?
            if let value = options["minContextSlot"] {
                guard let parsed = unsignedInteger(value) else {
                    throw WalletConnectorRuntimeError.malformedRequest
                }
                minimumSlot = parsed
            } else {
                minimumSlot = nil
            }
            return .solanaTransaction(.init(
                transactionBase64: transaction,
                accountAddress: account.address,
                minimumContextSlot: minimumSlot
            ))
        case "solana_signMessage":
            guard let values = object as? [String: Any],
                  Set(values.keys) == ["message", "pubkey"],
                  boundedString(values["pubkey"], maximum: 128) == account.address,
                  let encoded = base58Message(values["message"]),
                  let message = String(data: encoded, encoding: .utf8) else {
                throw WalletConnectorRuntimeError.malformedRequest
            }
            return .canonicalMessage(
                format: .siws, message: message, accountAddress: account.address
            )
        case "sui_signAndExecuteTransaction":
            guard let values = object as? [String: Any],
                  Set(values.keys) == ["transaction", "address"],
                  boundedString(values["address"], maximum: 128) == account.address,
                  let transaction = base64(values["transaction"], maximumBytes: 128 * 1_024)
            else { throw WalletConnectorRuntimeError.malformedRequest }
            return .suiTransaction(.init(
                transactionBase64: transaction, accountAddress: account.address
            ))
        default:
            throw WalletConnectionProtocolError.methodNotApproved
        }
    }

    private func rpcResult(
        _ value: WalletConnectorDappResponse,
        networkID: String
    ) -> RPCResult {
        switch value {
        case .accounts(let accounts):
            if networkID.hasPrefix("solana:") {
                return .response(AnyCodable(accounts.map { ["pubkey": $0.address] }))
            }
            return .response(AnyCodable(accounts.map {
                ["pubkey": $0.publicKey ?? "", "address": $0.address]
            }))
        case .transactionIdentifier(let identifier):
            if networkID.hasPrefix("eip155:") {
                return .response(AnyCodable(identifier))
            } else if networkID.hasPrefix("solana:") {
                return .response(AnyCodable(["signature": identifier]))
            } else {
                return .response(AnyCodable(["digest": identifier]))
            }
        case .signature(let signature):
            if networkID.hasPrefix("solana:") {
                return .response(AnyCodable(["signature": signature]))
            }
            return .response(AnyCodable(signature))
        }
    }

    private func validate(
        _ response: WalletConnectorDappResponse,
        for request: WalletConnectorDappRequest
    ) throws {
        switch (request.payload, response) {
        case (.listAccounts, .accounts(let accounts)):
            guard !accounts.isEmpty, accounts.count <= 32,
                  accounts.allSatisfy({ !$0.address.isEmpty && $0.address.utf8.count <= 128 }),
                  !request.networkID.hasPrefix("sui:")
                    || accounts.allSatisfy({ $0.publicKey?.isEmpty == false }) else {
                throw WalletConnectorRuntimeError.sessionMismatch
            }
        case (.evmTransaction, .transactionIdentifier(let value)),
             (.solanaTransaction, .transactionIdentifier(let value)),
             (.suiTransaction, .transactionIdentifier(let value)),
             (.canonicalMessage, .signature(let value)):
            guard !value.isEmpty, value.utf8.count <= 512 else {
                throw WalletConnectorRuntimeError.sessionMismatch
            }
        default:
            throw WalletConnectorRuntimeError.sessionMismatch
        }
    }

    private func respond(to request: Request, with result: RPCResult) async {
        try? await client?.respond(
            topic: request.topic, requestId: request.id, response: result
        )
    }

    private func requestKey(_ request: Request) -> String {
        Self.sha256("\(request.topic)|\(request.id.string)")
    }

    private func cancelRequests(connectionID: String) {
        // The relay topic never leaves this driver, so conservatively cancel
        // every in-flight dapp request when any authenticated session dies.
        _ = connectionID
        for (key, task) in requestTasks {
            task.cancel()
            requestTasks[key] = nil
        }
    }

    private func rememberCompleted(_ key: String) {
        guard completedRequestKeys.insert(key).inserted else { return }
        completedRequestOrder.append(key)
        while completedRequestOrder.count > Self.maximumCompletedRequests {
            completedRequestKeys.remove(completedRequestOrder.removeFirst())
        }
    }

    private func persistBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults?.set(data, forKey: Self.bindingsKey)
    }

    private static func semanticMethod(
        _ method: String,
        namespace: WalletConnectionNamespace
    ) throws -> WalletConnectionMethod {
        let mapped: WalletConnectionMethod? = switch (namespace, method) {
        case (.eip155, "eth_sendTransaction"): .sendTransaction
        case (.eip155, "personal_sign"): .signInWithEthereum
        case (.solana, "solana_getAccounts"),
             (.solana, "solana_requestAccounts"): .listAccounts
        case (.solana, "solana_signAndSendTransaction"): .sendTransaction
        case (.solana, "solana_signMessage"): .signInWithSolana
        case (.sui, "sui_getAccounts"): .listAccounts
        case (.sui, "sui_signAndExecuteTransaction"): .sendTransaction
        default: nil
        }
        guard let mapped else { throw WalletConnectionProtocolError.methodNotApproved }
        return mapped
    }

    private static func event(_ event: String) throws -> WalletConnectionEvent {
        switch event {
        case "accountsChanged": .accountsChanged
        case "chainChanged": .networkChanged
        default: throw WalletConnectionProtocolError.methodNotApproved
        }
    }

    private static func chain(_ namespace: WalletConnectionNamespace) -> WalletChain {
        switch namespace {
        case .eip155: .evm
        case .solana: .solana
        case .sui: .sui
        }
    }

    static func walletConnectNetworkID(_ internalID: String) throws -> String {
        switch internalID {
        case "solana:mainnet-beta":
            return "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2d"
        case "solana:devnet":
            return "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"
        default:
            guard WalletNetworkCatalog.descriptor(id: internalID) != nil else {
                throw WalletConnectionProtocolError.networkNotApproved
            }
            return internalID
        }
    }

    static func internalNetworkID(_ blockchain: Blockchain) throws -> String {
        switch blockchain.absoluteString {
        case "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2d":
            return "solana:mainnet-beta"
        case "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1":
            return "solana:devnet"
        default:
            guard WalletNetworkCatalog.descriptor(id: blockchain.absoluteString) != nil else {
                throw WalletConnectionProtocolError.networkNotApproved
            }
            return blockchain.absoluteString
        }
    }

    private static func peerID(name: String, url: String?) -> String {
        let digest = SHA256.hash(data: Data("\(name)|\(url ?? "")".utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func boundedString(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String, !value.isEmpty,
              value.utf8.count <= maximum else { return nil }
        return value
    }

    private static func sameAddress(
        _ lhs: String, _ rhs: String, chain: WalletChain
    ) -> Bool {
        chain == .evm
            ? lhs.caseInsensitiveCompare(rhs) == .orderedSame
            : lhs == rhs
    }

    private static func isEmptyParameters(_ value: Any) -> Bool {
        (value as? [Any])?.isEmpty == true
            || (value as? [String: Any])?.isEmpty == true
            || value is NSNull
    }

    private static func optionalHex(
        _ value: Any?, fallback: String, maximumBytes: Int
    ) throws -> String {
        guard value != nil else { return fallback }
        guard let text = value as? String, text.hasPrefix("0x"),
              !text.dropFirst(2).isEmpty,
              text.dropFirst(2).allSatisfy(\.isHexDigit),
              text.dropFirst(2).count <= maximumBytes * 2 else {
            throw WalletConnectorRuntimeError.malformedRequest
        }
        return text.lowercased()
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let value else { return nil }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue >= 0,
           number.doubleValue.rounded(.down) == number.doubleValue {
            return UInt64(number.stringValue)
        }
        if let text = value as? String {
            return UInt64(text)
        }
        return nil
    }

    private static func base64(_ value: Any?, maximumBytes: Int) -> String? {
        guard let text = boundedString(value, maximum: maximumBytes * 2),
              let data = Data(base64Encoded: text), !data.isEmpty,
              data.count <= maximumBytes,
              data.base64EncodedString() == text else { return nil }
        return text
    }

    private static func personalSignMessage(_ value: String) -> String? {
        guard value.utf8.count <= 64 * 1_024 else { return nil }
        guard value.hasPrefix("0x") else { return value }
        let raw = value.dropFirst(2)
        guard !raw.isEmpty, raw.count.isMultiple(of: 2),
              raw.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(raw.count / 2)
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            let next = raw.index(cursor, offsetBy: 2)
            guard let byte = UInt8(raw[cursor..<next], radix: 16) else { return nil }
            bytes.append(byte)
            cursor = next
        }
        return String(data: bytes, encoding: .utf8)
    }

    private static func base58Message(_ value: Any?) -> Data? {
        guard let text = boundedString(value, maximum: 96 * 1_024) else { return nil }
        let alphabet = Array(
            "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8
        )
        let positions = Dictionary(uniqueKeysWithValues:
            alphabet.enumerated().map { ($0.element, $0.offset) })
        var littleEndian: [UInt8] = []
        for character in text.utf8 {
            guard var carry = positions[character] else { return nil }
            for index in littleEndian.indices {
                let next = Int(littleEndian[index]) * 58 + carry
                littleEndian[index] = UInt8(next & 0xff)
                carry = next >> 8
            }
            while carry > 0 {
                littleEndian.append(UInt8(carry & 0xff))
                carry >>= 8
            }
            guard littleEndian.count <= 64 * 1_024 else { return nil }
        }
        let leadingZeroes = text.utf8.prefix(while: { $0 == alphabet[0] }).count
        return Data(repeating: 0, count: leadingZeroes) + Data(littleEndian.reversed())
    }

    private static func normalizedPeerURL(_ value: String) -> String? {
        guard value.utf8.count <= maximumPeerTextBytes,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        let standardPort = (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        let port = components.port.map { standardPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func bounded(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(128))
    }

    private static func validProjectID(_ value: String) -> Bool {
        (16...128).contains(value.utf8.count)
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
    }

    private static func validRedirectURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "locus-wallet",
              components.host == "walletconnect",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        return components.path.isEmpty || components.path == "/"
    }
}
