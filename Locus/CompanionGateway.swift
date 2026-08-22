import Foundation
import Network
import Security

struct CompanionPublishedEvent: Hashable {
    let name: String
    let data: JSONValue
}

actor CompanionGateway {
    typealias CommandHandler = @MainActor @Sendable (CompanionRequest) async -> CompanionResponse
    typealias EventProvider = @MainActor @Sendable () -> [CompanionPublishedEvent]
    typealias StateHandler = @MainActor @Sendable (CompanionGatewayState) -> Void

    private let defaults: UserDefaults
    private let serviceID: String
    private var registry: CompanionDeviceRegistry
    private var nonces = CompanionPairingNonceStore()
    private var idempotency = CompanionIdempotencyCache()
    private var rateLimiter = CompanionRateLimiter()
    private var commandHandler: CommandHandler?
    private var eventProvider: EventProvider?
    private var stateHandler: StateHandler?
    private var listener: NWListener?
    private var tlsMaterial: CompanionTLSMaterial?
    private var connections: [UUID: NWConnection] = [:]
    private var authenticatedDevices: [UUID: String] = [:]
    private var state = CompanionGatewayState.disabled
    private var eventSequence: UInt64 = 0
    private var eventFingerprints: [String: Int] = [:]
    private var eventPump: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let key = "Locus.companion.serviceID"
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            serviceID = existing
        } else {
            let created = UUID().uuidString
            defaults.set(created, forKey: key)
            serviceID = created
        }
        let devices: [CompanionPairedDevice]
        if let data = defaults.data(forKey: "Locus.companion.devices"),
           let decoded = try? JSONDecoder().decode([CompanionPairedDevice].self, from: data) {
            devices = decoded
        } else {
            devices = []
        }
        registry = CompanionDeviceRegistry(serviceID: serviceID, devices: devices)
        state.serviceID = serviceID
        state.pairedDevices = devices.map(\.safeDescription)
    }

    func configure(
        commandHandler: @escaping CommandHandler,
        eventProvider: @escaping EventProvider,
        stateHandler: @escaping StateHandler
    ) {
        self.commandHandler = commandHandler
        self.eventProvider = eventProvider
        self.stateHandler = stateHandler
        publishState()
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            await start()
        } else {
            stop(status: "Mobile Access is off")
        }
    }

    func currentState() -> CompanionGatewayState { state }

    func beginPairing(now: Date = Date()) async throws -> CompanionPairingPayload {
        guard state.running, let tlsMaterial, let port = state.port else {
            throw CompanionProtocolError(
                code: "gateway_offline", message: "Turn on Mobile Access first."
            )
        }
        let issued = try nonces.issue(now: now)
        let endpoints = CompanionEndpointResolver.endpoints(port: port)
        state.endpoints = endpoints
        publishState()
        return CompanionPairingPayload(
            version: CompanionProtocolV1.version,
            serviceID: serviceID,
            endpoints: endpoints,
            certificateFingerprint: tlsMaterial.fingerprint,
            nonce: issued.nonce,
            expiresAt: issued.expiresAt.timeIntervalSince1970
        )
    }

    func revoke(deviceID: String) {
        guard registry.revoke(deviceID: deviceID) else { return }
        for (connectionID, authenticatedID) in authenticatedDevices
            where authenticatedID == deviceID {
            connections[connectionID]?.cancel()
        }
        persistDevices()
        updateDeviceState()
    }

    func revokeAll() {
        registry.revokeAll()
        nonces.revokeAll()
        authenticatedDevices.removeAll()
        connections.values.forEach { $0.cancel() }
        persistDevices()
        updateDeviceState()
    }

    func resetCertificate() async throws {
        let shouldRestart = state.enabled
        stop(status: "Resetting mobile-access security…", preserveEnabled: shouldRestart)
        registry.revokeAll()
        persistDevices()
        tlsMaterial = try CompanionIdentityStore.reset()
        if shouldRestart { await start() }
    }

    func broadcast(event name: String, data: JSONValue) {
        broadcastEvent(name: name, data: data)
    }

    private func start() async {
        guard listener == nil else { return }
        state.enabled = true
        state.status = "Starting Mobile Access…"
        publishState()
        do {
            let material = try tlsMaterial ?? CompanionIdentityStore.loadOrCreate()
            tlsMaterial = material

            let tls = NWProtocolTLS.Options()
            guard let securityIdentity = sec_identity_create(material.identity) else {
                throw CompanionSecurityError.certificate
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, securityIdentity)
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv12
            )
            let webSocket = NWProtocolWebSocket.Options()
            webSocket.autoReplyPing = true
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            parameters.includePeerToPeer = true
            parameters.allowLocalEndpointReuse = true
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
            let listener = try NWListener(using: parameters, on: .any)
            let computerName = Host.current().localizedName?.nilIfEmpty ?? "Mac"
            listener.service = NWListener.Service(
                name: "Locus on \(computerName)", type: CompanionProtocolV1.serviceType
            )
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { await self?.listenerChanged(listenerState) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .global(qos: .utility))
            startEventPump()
        } catch {
            listener = nil
            state.running = false
            state.status = "Mobile Access could not start: \(error.localizedDescription)"
            publishState()
        }
    }

    private func stop(status: String, preserveEnabled: Bool = false) {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        authenticatedDevices.removeAll()
        eventPump?.cancel()
        eventPump = nil
        eventFingerprints.removeAll()
        state.enabled = preserveEnabled
        state.running = false
        state.status = status
        state.port = nil
        state.activeConnections = 0
        state.endpoints = []
        publishState()
    }

    private func listenerChanged(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            guard let listener, let port = listener.port else { return }
            let number = port.rawValue
            state.running = true
            state.port = number
            state.certificateFingerprint = tlsMaterial?.fingerprint ?? ""
            state.endpoints = CompanionEndpointResolver.endpoints(port: number)
            state.status = "Available to paired devices"
            publishState()
        case .failed(let error):
            stop(status: "Mobile Access stopped: \(error.localizedDescription)", preserveEnabled: true)
        case .cancelled:
            if state.enabled && listener != nil {
                state.running = false
                state.status = "Mobile Access stopped"
                publishState()
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < CompanionProtocolV1.maximumConnections else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        state.activeConnections = connections.count
        publishState()
        connection.stateUpdateHandler = { [weak self] connectionState in
            Task { await self?.connectionChanged(connectionState, id: id) }
        }
        connection.start(queue: .global(qos: .utility))
        receiveNext(on: connection, id: id)
    }

    private func connectionChanged(_ connectionState: NWConnection.State, id: UUID) {
        switch connectionState {
        case .ready:
            sendEvent(
                CompanionEvent(
                    version: CompanionProtocolV1.version,
                    event: "connection.status",
                    data: .object(["state": .string("connected")]),
                    sequence: nextSequence()
                ),
                to: connections[id]
            )
        case .failed, .cancelled:
            connections.removeValue(forKey: id)
            authenticatedDevices.removeValue(forKey: id)
            state.activeConnections = connections.count
            publishState()
        default:
            break
        }
    }

    private func receiveNext(on connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] content, _, _, error in
            Task {
                await self?.received(content, error: error, on: connection, id: id)
            }
        }
    }

    private func received(
        _ content: Data?, error: NWError?, on connection: NWConnection, id: UUID
    ) async {
        if let error {
            connection.cancel()
            state.status = "A mobile connection ended: \(error.localizedDescription)"
            publishState()
            return
        }
        guard let content, content.count <= CompanionProtocolV1.maximumPayloadBytes else {
            send(.failure(id: "", code: "payload_too_large", message: "Request is too large."), to: connection)
            connection.cancel()
            return
        }
        let request: CompanionRequest
        do {
            request = try JSONDecoder().decode(CompanionRequest.self, from: content)
        } catch {
            send(.failure(id: "", code: "invalid_request", message: "Request is not valid JSON."), to: connection)
            receiveNext(on: connection, id: id)
            return
        }
        guard request.version == CompanionProtocolV1.version,
              !request.id.isEmpty, request.id.count <= 160 else {
            send(.failure(id: request.id, code: "unsupported_version", message: "Update Locus Mobile and Locus on your Mac."), to: connection)
            receiveNext(on: connection, id: id)
            return
        }

        if request.method == .pairExchange {
            await handlePairing(request, connection: connection, connectionID: id)
            receiveNext(on: connection, id: id)
            return
        }
        guard let token = request.token,
              let device = registry.authenticate(token) else {
            send(.failure(id: request.id, code: "unauthorized", message: "Pair this device again."), to: connection)
            receiveNext(on: connection, id: id)
            return
        }
        let newlyAuthenticated = authenticatedDevices[id] != device.id
        authenticatedDevices[id] = device.id
        persistDevices()
        if newlyAuthenticated { updateDeviceState() }
        guard rateLimiter.allows(device.id) else {
            send(.failure(id: request.id, code: "rate_limited", message: "Too many requests. Try again shortly.", retryable: true), to: connection)
            receiveNext(on: connection, id: id)
            return
        }
        let cacheKey = device.id + ":" + request.id
        if let cached = idempotency.response(for: cacheKey) {
            send(CompanionResponse(
                version: cached.version, id: request.id, ok: cached.ok,
                data: cached.data, error: cached.error
            ), to: connection)
            receiveNext(on: connection, id: id)
            return
        }
        guard let commandHandler else {
            send(.failure(id: request.id, code: "not_ready", message: "Locus is still starting.", retryable: true), to: connection)
            receiveNext(on: connection, id: id)
            return
        }
        var response = await commandHandler(request)
        if let data = response.data {
            response = CompanionResponse(
                version: response.version, id: response.id, ok: response.ok,
                data: CompanionEventSanitizer.sanitize(data), error: response.error
            )
        }
        // Cache under the authenticated device key, while keeping the wire id unchanged.
        idempotency.insert(CompanionResponse(
            version: response.version, id: cacheKey, ok: response.ok,
            data: response.data, error: response.error
        ))
        send(response, to: connection)
        receiveNext(on: connection, id: id)
    }

    private func handlePairing(
        _ request: CompanionRequest,
        connection: NWConnection,
        connectionID: UUID
    ) async {
        guard let nonce = CompanionPayload.string("nonce", in: request.payload) else {
            send(.failure(id: request.id, code: "pairing_expired", message: "That pairing code expired. Create a new one on the Mac."), to: connection)
            return
        }
        guard nonces.consume(nonce) else {
            send(.failure(id: request.id, code: "pairing_expired", message: "That pairing code expired. Create a new one on the Mac."), to: connection)
            return
        }
        do {
            let paired = try registry.pair(
                name: CompanionPayload.string("device_name", in: request.payload) ?? "Mobile device",
                platform: CompanionPayload.string("platform", in: request.payload) ?? "mobile"
            )
            authenticatedDevices[connectionID] = paired.device.id
            persistDevices()
            updateDeviceState()
            let response = CompanionResponse.success(id: request.id, data: .object([
                "device_id": .string(paired.device.id),
                "device_token": .string(paired.token),
                "service_id": .string(serviceID),
            ]))
            send(response, to: connection)
        } catch {
            send(.failure(id: request.id, code: "pairing_failed", message: error.localizedDescription), to: connection)
        }
    }

    private func startEventPump() {
        eventPump?.cancel()
        eventPump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await self.publishChangedEvents()
            }
        }
    }

    private func publishChangedEvents() async {
        guard !authenticatedDevices.isEmpty, let eventProvider else { return }
        let candidates = await eventProvider()
        for candidate in candidates {
            let sanitized = CompanionEventSanitizer.sanitize(candidate.data)
            let fingerprint = sanitized.hashValue
            guard eventFingerprints[candidate.name] != fingerprint else { continue }
            eventFingerprints[candidate.name] = fingerprint
            broadcastEvent(name: candidate.name, data: sanitized)
        }
    }

    private func broadcastEvent(name: String, data: JSONValue) {
        let event = CompanionEvent(
            version: CompanionProtocolV1.version,
            event: name,
            data: CompanionEventSanitizer.sanitize(data),
            sequence: nextSequence()
        )
        for (id, connection) in connections where authenticatedDevices[id] != nil {
            sendEvent(event, to: connection)
        }
    }

    private func send(_ response: CompanionResponse, to connection: NWConnection?) {
        guard let connection, let data = try? JSONEncoder().encode(response) else { return }
        sendData(data, to: connection)
    }

    private func sendEvent(_ event: CompanionEvent, to connection: NWConnection?) {
        guard let connection, let data = try? JSONEncoder().encode(event) else { return }
        sendData(data, to: connection)
    }

    private func sendData(_ data: Data, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "locus.companion.message", metadata: [metadata]
        )
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func nextSequence() -> UInt64 {
        eventSequence &+= 1
        return eventSequence
    }

    private func persistDevices() {
        if let data = try? JSONEncoder().encode(registry.devices) {
            defaults.set(data, forKey: "Locus.companion.devices")
        }
    }

    private func updateDeviceState() {
        state.pairedDevices = registry.devices.map(\.safeDescription)
        publishState()
    }

    private func publishState() {
        state.serviceID = serviceID
        state.pairedDevices = registry.devices.map(\.safeDescription)
        let snapshot = state
        Task { @MainActor [stateHandler] in stateHandler?(snapshot) }
    }
}
