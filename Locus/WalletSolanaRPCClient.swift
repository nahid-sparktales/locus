import CryptoKit
import Foundation

enum WalletSolanaBase58 {
    private static let alphabet = Array(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8
    )
    private static let positions = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) }
    )

    static func decode(_ value: String, exactLength: Int? = nil) -> Data? {
        let encoded = Array(value.utf8)
        guard !encoded.isEmpty, encoded.count <= 128 else { return nil }
        var littleEndian: [UInt8] = []
        for character in encoded {
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
        }
        let leadingZeroCount = encoded.prefix { $0 == alphabet[0] }.count
        let decoded = Data(
            Array(repeatElement(UInt8(0), count: leadingZeroCount))
                + Array(littleEndian.reversed())
        )
        guard exactLength.map({ decoded.count == $0 }) ?? true,
              encode(decoded) == value else { return nil }
        return decoded
    }

    static func encode(_ value: Data) -> String {
        guard !value.isEmpty else { return "" }
        let leadingZeroCount = value.prefix { $0 == 0 }.count
        var digits: [UInt8] = []
        for byte in value {
            var carry = Int(byte)
            for index in digits.indices {
                let next = Int(digits[index]) * 256 + carry
                digits[index] = UInt8(next % 58)
                carry = next / 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        let prefix = String(repeating: Character("1"), count: leadingZeroCount)
        let significant = digits.reversed().map { Character(UnicodeScalar(alphabet[Int($0)])) }
        return prefix + String(significant)
    }
}

struct WalletSolanaCanonicalNativeTransfer: Equatable, Sendable {
    static let systemProgramID = "11111111111111111111111111111111"

    let feePayer: String
    let recipient: String
    let recentBlockhash: String
    let lamports: UInt64
    let message: Data
    let unsignedTransaction: Data
    let canonicalMessageDigest: String
    let resolvedAccountsDigest: String

    init(
        feePayer: String,
        recipient: String,
        recentBlockhash: String,
        amountBaseUnits: String
    ) throws {
        guard let payer = WalletSolanaBase58.decode(feePayer, exactLength: 32),
              let destination = WalletSolanaBase58.decode(recipient, exactLength: 32),
              let blockhash = WalletSolanaBase58.decode(recentBlockhash, exactLength: 32),
              recipient != feePayer, recipient != Self.systemProgramID,
              let amount = UInt64(amountBaseUnits), amount > 0 else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed SOL transfer requires distinct canonical addresses, a valid blockhash, and positive u64 lamports."
            )
        }

        var message = Data([1, 0, 1])
        message.append(Self.shortVector(3))
        message.append(payer)
        message.append(destination)
        message.append(Data(repeating: 0, count: 32))
        message.append(blockhash)
        message.append(Self.shortVector(1))
        message.append(2)
        message.append(Self.shortVector(2))
        message.append(contentsOf: [0, 1])
        var instructionData = Data()
        instructionData.appendLittleEndian(UInt32(2))
        instructionData.appendLittleEndian(amount)
        message.append(Self.shortVector(instructionData.count))
        message.append(instructionData)

        var transaction = Data([1])
        transaction.append(Data(repeating: 0, count: 64))
        transaction.append(message)
        self.feePayer = feePayer
        self.recipient = recipient
        self.recentBlockhash = recentBlockhash
        lamports = amount
        self.message = message
        unsignedTransaction = transaction
        canonicalMessageDigest = Self.sha256(message)
        resolvedAccountsDigest = Self.resolvedDigest(
            feePayer: feePayer, recipient: recipient
        )
    }

    static func resolvedDigest(feePayer: String, recipient: String) -> String {
        sha256(Data(
            "legacy|\(systemProgramID)|\(feePayer):signer:writable|\(recipient):nonsigner:writable"
                .utf8
        ))
    }

    private static func shortVector(_ value: Int) -> Data {
        precondition((0...127).contains(value))
        return Data([UInt8(value)])
    }

    private static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

struct WalletSolanaProviderConfiguration: Sendable {
    let primary: WalletProviderEndpoint
    let fallback: WalletProviderEndpoint?

    static func bundled(
        network: WalletNetworkDescriptor,
        bundle: Bundle = .main
    ) -> WalletSolanaProviderConfiguration? {
        guard network.chain == .solana else { return nil }
        let suffix = network.environment == .mainnet ? "SolanaMainnet" : "SolanaDevnet"
        let alchemy = endpoint(
            bundle.object(forInfoDictionaryKey: "LocusWalletAlchemy\(suffix)RPCURL") as? String,
            provider: .alchemy, network: network, priority: 0
        )
        let quickNode = endpoint(
            bundle.object(forInfoDictionaryKey: "LocusWalletQuickNode\(suffix)RPCURL") as? String,
            provider: .quickNode, network: network, priority: 1
        )
        if let alchemy {
            return .init(primary: alchemy, fallback: quickNode)
        }
        let defaultURL = network.environment == .mainnet
            ? WalletSolanaRPCClient.mainnetDefaultEndpoint
            : WalletSolanaRPCClient.devnetDefaultEndpoint
        guard let development = endpoint(
            defaultURL, provider: .userDefined, network: network, priority: 0
        ) else { return nil }
        return .init(primary: development, fallback: nil)
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

actor WalletSolanaRPCClient {
    static let mainnetDefaultEndpoint = "https://api.mainnet-beta.solana.com"
    static let devnetDefaultEndpoint = "https://api.devnet.solana.com"

    private let network: WalletNetworkDescriptor
    private var endpoint: URL
    private let session: URLSession
    private var nextID = 1

    init(
        network: WalletNetworkDescriptor,
        endpoint: String,
        session: URLSession = .shared
    ) throws {
        guard network.chain == .solana,
              network.identity.kind == .solanaGenesisHash,
              let url = URL(string: endpoint), url.scheme?.lowercased() == "https",
              url.host != nil else { throw WalletRPCError.invalidEndpoint }
        self.network = network
        self.endpoint = url
        self.session = session
    }

    func configure(endpoint value: String) throws {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              url.host != nil else { throw WalletRPCError.invalidEndpoint }
        endpoint = url
    }

    func health() async throws -> String {
        _ = try await verifiedGenesisHash()
        let blockHeight = try await unsignedResult(method: "getBlockHeight", params: [
            ["commitment": "confirmed"],
        ])
        return "\(network.displayName) · verified genesis · block \(blockHeight)"
    }

    func prepare(
        request: WalletPrepareRequest,
        feePayer: String
    ) async throws -> WalletSolanaPreparationPacket {
        guard request.networkID == network.id,
              request.action.type == .nativeTransfer,
              request.action.assetID == nil,
              request.action.tokenID == nil,
              request.action.inputAssetID == nil,
              request.action.outputAssetID == nil,
              request.action.minimumOutputBaseUnits == nil,
              request.action.adapterID == nil,
              request.action.authorizationFormat == nil,
              request.action.metadataDigest == nil,
              request.action.contractID == nil,
              request.action.function == nil,
              request.action.arguments.isEmpty,
              request.action.valueBaseUnits == nil,
              let recipient = request.action.recipient,
              let amount = request.action.amountBaseUnits else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Solana provider accepts semantic native transfers only."
            )
        }
        let genesisHash = try await verifiedGenesisHash()
        let latest = try await latestBlockhash()
        let transaction = try WalletSolanaCanonicalNativeTransfer(
            feePayer: feePayer, recipient: recipient,
            recentBlockhash: latest.blockhash, amountBaseUnits: amount
        )
        let fee = try await feeForMessage(transaction.message)
        guard WalletBaseUnits.lessThanOrEqual(fee, request.maximumFeeBaseUnits) else {
            throw WalletGateway.Error.policyDenied(
                "The Solana network fee exceeds the requested fee ceiling."
            )
        }
        let simulation = try await simulate(transaction.unsignedTransaction)
        let instruction = WalletSolanaReviewedInstruction(
            programID: WalletSolanaCanonicalNativeTransfer.systemProgramID,
            adapterID: WalletReviewedAdapters.solanaNativeTransfer,
            semanticOperation: WalletActionKind.nativeTransfer.rawValue,
            accounts: [
                .init(
                    address: feePayer, isSigner: true, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                .init(
                    address: recipient, isSigner: false, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
            ],
            canonicalArguments: ["lamports": String(transaction.lamports)]
        )
        return WalletSolanaPreparationPacket(
            request: request, genesisHash: genesisHash, version: .legacy,
            recentBlockhash: latest.blockhash,
            lastValidBlockHeight: latest.lastValidBlockHeight,
            contextSlot: latest.contextSlot,
            feePayer: feePayer, priorityFeeBaseUnits: "0",
            feeQuoteBaseUnits: fee,
            maximumFeeBaseUnits: request.maximumFeeBaseUnits,
            canonicalMessageDigest: transaction.canonicalMessageDigest,
            resolvedAccountsDigest: transaction.resolvedAccountsDigest,
            instructions: [instruction], simulation: simulation,
            simulationSucceeded: true, observedAt: Date()
        )
    }

    func recheck(
        intentID: String,
        packet: WalletSolanaPreparationPacket
    ) async throws -> WalletSolanaRecheckPacket {
        let genesisHash = try await verifiedGenesisHash()
        guard genesisHash == packet.genesisHash else {
            throw WalletRPCError.wrongChain(genesisHash)
        }
        let currentBlockHeight = try await unsignedResult(
            method: "getBlockHeight", params: [["commitment": "confirmed"]]
        )
        guard currentBlockHeight <= packet.lastValidBlockHeight else {
            throw WalletRPCError.simulation("the prepared Solana blockhash expired")
        }
        let recipient = packet.request.action.recipient ?? ""
        let amount = packet.request.action.amountBaseUnits ?? ""
        let transaction = try WalletSolanaCanonicalNativeTransfer(
            feePayer: packet.feePayer, recipient: recipient,
            recentBlockhash: packet.recentBlockhash, amountBaseUnits: amount
        )
        guard transaction.canonicalMessageDigest == packet.canonicalMessageDigest,
              transaction.resolvedAccountsDigest == packet.resolvedAccountsDigest else {
            throw WalletRPCError.simulation(
                "the prepared Solana message or resolved accounts changed"
            )
        }
        let fee = try await feeForMessage(transaction.message)
        guard WalletBaseUnits.lessThanOrEqual(fee, packet.maximumFeeBaseUnits) else {
            throw WalletRPCError.simulation("the refreshed Solana fee exceeds its ceiling")
        }
        let simulation = try await simulate(transaction.unsignedTransaction)
        return WalletSolanaRecheckPacket(
            intentID: intentID, genesisHash: genesisHash,
            currentBlockHeight: currentBlockHeight,
            resolvedAccountsDigest: transaction.resolvedAccountsDigest,
            feeQuoteBaseUnits: fee, simulation: simulation,
            simulationSucceeded: true, observedAt: Date()
        )
    }

    func broadcast(
        signedTransaction: String,
        expectedTransactionID: String,
        minimumContextSlot: UInt64
    ) async throws -> String {
        guard let bytes = Data(base64Encoded: signedTransaction),
              (66...1_232).contains(bytes.count), bytes.first == 1,
              let expectedSignature = WalletSolanaBase58.decode(
                  expectedTransactionID, exactLength: 64
              ),
              bytes.subdata(in: 1..<65) == expectedSignature else {
            throw WalletGateway.Error.invalidArguments(
                "The signed Solana transaction is malformed."
            )
        }
        let result = try await stringResult(method: "sendTransaction", params: [
            signedTransaction,
            [
                "encoding": "base64", "skipPreflight": false,
                "preflightCommitment": "confirmed", "maxRetries": 3,
                "minContextSlot": minimumContextSlot,
            ],
        ])
        guard result == expectedTransactionID else {
            throw WalletGateway.Error.broadcastUnknown(
                transactionHash: expectedTransactionID,
                message: "The Solana provider returned an ID that does not match the signed transaction."
            )
        }
        return result
    }

    func balance(address: String) async throws -> String {
        guard WalletSolanaBase58.decode(address, exactLength: 32) != nil else {
            throw WalletGateway.Error.invalidArguments("The Solana address is malformed.")
        }
        _ = try await verifiedGenesisHash()
        let result = try await dictionaryResult(
            method: "getBalance", params: [address, ["commitment": "confirmed"]]
        )
        guard let value = Self.unsigned(result["value"]) else {
            throw WalletRPCError.invalidResponse("getBalance returned an invalid value")
        }
        return String(value)
    }

    func publicRead(method: String, params: [Any]) async throws -> Any {
        let allowed = Set([
            "getBalance", "getBlockHeight", "getGenesisHash", "getLatestBlockhash",
            "getSignatureStatuses", "getTransaction",
        ])
        guard allowed.contains(method) else {
            throw WalletGateway.Error.invalidArguments(
                "That Solana RPC method is not exposed by the wallet."
            )
        }
        _ = try await verifiedGenesisHash()
        return try await rpc(method: method, params: params)
    }

    private func latestBlockhash() async throws -> (
        blockhash: String, lastValidBlockHeight: UInt64, contextSlot: UInt64
    ) {
        let result = try await dictionaryResult(
            method: "getLatestBlockhash", params: [["commitment": "confirmed"]]
        )
        guard let context = result["context"] as? [String: Any],
              let slot = Self.unsigned(context["slot"]),
              let value = result["value"] as? [String: Any],
              let blockhash = value["blockhash"] as? String,
              WalletSolanaBase58.decode(blockhash, exactLength: 32) != nil,
              let lastValid = Self.unsigned(value["lastValidBlockHeight"]),
              lastValid > 0 else {
            throw WalletRPCError.invalidResponse(
                "getLatestBlockhash returned malformed blockhash evidence"
            )
        }
        return (blockhash, lastValid, slot)
    }

    private func feeForMessage(_ message: Data) async throws -> String {
        let result = try await dictionaryResult(method: "getFeeForMessage", params: [
            message.base64EncodedString(),
            ["commitment": "confirmed", "encoding": "base64"],
        ])
        guard let fee = Self.unsigned(result["value"]) else {
            throw WalletRPCError.invalidResponse(
                "getFeeForMessage returned no integer fee"
            )
        }
        return String(fee)
    }

    private func simulate(_ unsignedTransaction: Data) async throws -> String {
        let result = try await dictionaryResult(method: "simulateTransaction", params: [
            unsignedTransaction.base64EncodedString(),
            [
                "commitment": "confirmed", "encoding": "base64",
                "sigVerify": false, "replaceRecentBlockhash": false,
                "innerInstructions": true,
            ],
        ])
        guard let value = result["value"] as? [String: Any],
              value.keys.contains("err"), value["err"] is NSNull else {
            throw WalletRPCError.simulation("the reviewed SOL transfer did not simulate cleanly")
        }
        if let inner = value["innerInstructions"], !(inner is NSNull) {
            guard let entries = inner as? [Any], entries.isEmpty else {
                throw WalletRPCError.simulation(
                    "the native SOL transfer produced unexpected inner instructions"
                )
            }
        }
        let logs = (value["logs"] as? [String]) ?? []
        guard logs.count <= 1_000, logs.allSatisfy({ $0.utf8.count <= 1_024 }) else {
            throw WalletRPCError.invalidResponse("simulation logs exceeded wallet limits")
        }
        let units = Self.unsigned(value["unitsConsumed"])
        guard units.map({ $0 <= 1_400_000 }) != false else {
            throw WalletRPCError.invalidResponse("simulation compute units were invalid")
        }
        if let units {
            return "System Program transfer simulation succeeded; \(units) compute units"
        }
        return "System Program transfer simulation succeeded"
    }

    private func verifiedGenesisHash() async throws -> String {
        let value = try await stringResult(method: "getGenesisHash", params: [])
        guard value == network.identity.value else { throw WalletRPCError.wrongChain(value) }
        return value
    }

    private func stringResult(method: String, params: [Any]) async throws -> String {
        let result = try await rpc(method: method, params: params)
        guard let value = result as? String, value.utf8.count <= 2_048 else {
            throw WalletRPCError.invalidResponse("\(method) did not return a bounded string")
        }
        return value
    }

    private func unsignedResult(method: String, params: [Any]) async throws -> UInt64 {
        let result = try await rpc(method: method, params: params)
        guard let value = Self.unsigned(result) else {
            throw WalletRPCError.invalidResponse("\(method) did not return a u64")
        }
        return value
    }

    private func dictionaryResult(method: String, params: [Any]) async throws -> [String: Any] {
        let result = try await rpc(method: method, params: params)
        guard let value = result as? [String: Any] else {
            throw WalletRPCError.invalidResponse("\(method) did not return an object")
        }
        return value
    }

    private func rpc(method: String, params: [Any]) async throws -> Any {
        let id = nextID
        nextID = nextID == Int.max ? 1 : nextID + 1
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        guard body.count <= 256 * 1_024 else {
            throw WalletRPCError.invalidResponse("request exceeded the 256 KiB wallet limit")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), data.count <= 1_048_576 else {
            throw WalletRPCError.invalidResponse("HTTP response failed or exceeded 1 MiB")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["jsonrpc"] as? String == "2.0",
              let responseID = object["id"] as? NSNumber,
              CFGetTypeID(responseID) != CFBooleanGetTypeID(),
              responseID.decimalValue == Decimal(id) else {
            throw WalletRPCError.invalidResponse("JSON-RPC response identity did not match")
        }
        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
            throw WalletRPCError.invalidResponse(
                "response must contain exactly one of result or error"
            )
        }
        if hasError {
            guard let error = object["error"] as? [String: Any],
                  let code = error["code"] as? NSNumber,
                  CFGetTypeID(code) != CFBooleanGetTypeID(),
                  let message = error["message"] as? String else {
                throw WalletRPCError.invalidResponse("RPC error payload was malformed")
            }
            throw WalletRPCError.rpc(
                code: code.intValue, message: String(message.prefix(512))
            )
        }
        guard let result = object["result"] else {
            throw WalletRPCError.invalidResponse("result payload was missing")
        }
        return result
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.decimalValue >= 0,
              number.decimalValue == Decimal(number.uint64Value) else { return nil }
        return number.uint64Value
    }
}

actor WalletSolanaProviderCoordinator {
    let network: WalletNetworkDescriptor
    let primaryEndpoint: WalletProviderEndpoint
    let fallbackEndpoint: WalletProviderEndpoint?

    private let primary: WalletSolanaRPCClient
    private let fallback: WalletSolanaRPCClient?

    init(
        network: WalletNetworkDescriptor,
        configuration: WalletSolanaProviderConfiguration,
        session: URLSession = .shared
    ) throws {
        guard network.chain == .solana,
              configuration.primary.networkID == network.id,
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
        primary = try WalletSolanaRPCClient(
            network: network, endpoint: configuration.primary.url.absoluteString,
            session: session
        )
        fallback = try configuration.fallback.map {
            try WalletSolanaRPCClient(
                network: network, endpoint: $0.url.absoluteString, session: session
            )
        }
    }

    func prepare(
        request: WalletPrepareRequest,
        feePayer: String
    ) async throws -> WalletSolanaPreparationPacket {
        let packet: WalletSolanaPreparationPacket
        do { packet = try await primary.prepare(request: request, feePayer: feePayer) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.prepare(request: request, feePayer: feePayer)
        }
        if let fallback,
           let secondary = try? await fallback.recheck(intentID: "provider-check", packet: packet),
           (secondary.genesisHash != packet.genesisHash
                || secondary.resolvedAccountsDigest != packet.resolvedAccountsDigest
                || secondary.feeQuoteBaseUnits != packet.feeQuoteBaseUnits
                || !secondary.simulationSucceeded) {
            throw WalletProviderCoordinatorError.preparationDisagreement
        }
        return packet
    }

    func recheck(
        intentID: String,
        packet: WalletSolanaPreparationPacket
    ) async throws -> WalletSolanaRecheckPacket {
        let primaryEvidence = try await primary.recheck(intentID: intentID, packet: packet)
        if let fallback,
           let secondary = try? await fallback.recheck(intentID: intentID, packet: packet),
           (secondary.genesisHash != primaryEvidence.genesisHash
                || secondary.resolvedAccountsDigest != primaryEvidence.resolvedAccountsDigest
                || secondary.feeQuoteBaseUnits != primaryEvidence.feeQuoteBaseUnits
                || !secondary.simulationSucceeded) {
            throw WalletProviderCoordinatorError.preparationDisagreement
        }
        return primaryEvidence
    }

    func broadcast(
        signedTransaction: String,
        transactionID: String,
        minimumContextSlot: UInt64
    ) async throws -> String {
        try await primary.broadcast(
            signedTransaction: signedTransaction,
            expectedTransactionID: transactionID,
            minimumContextSlot: minimumContextSlot
        )
    }

    func balance(address: String) async throws -> String {
        do { return try await primary.balance(address: address) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.balance(address: address)
        }
    }

    func health() async throws -> String {
        do { return try await primary.health() }
        catch {
            guard let fallback else { throw error }
            return try await fallback.health()
        }
    }

    func publicRead(method: String, params: [Any]) async throws -> Any {
        do { return try await primary.publicRead(method: method, params: params) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.publicRead(method: method, params: params)
        }
    }
}
