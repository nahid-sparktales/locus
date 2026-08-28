import CryptoKit
import Foundation

enum WalletRPCError: LocalizedError {
    case invalidEndpoint
    case invalidResponse(String)
    case rpc(code: Int, message: String)
    case wrongChain(String)
    case simulation(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The Sepolia RPC URL is not a valid HTTPS address."
        case .invalidResponse(let message): "The Sepolia RPC returned an invalid response: \(message)"
        case .rpc(_, let message): "Sepolia RPC error: \(message)"
        case .wrongChain(let value): "The configured RPC is on chain \(value), not Sepolia."
        case .simulation(let message): "Transaction simulation failed: \(message)"
        }
    }
}

enum WalletEthereumQuantity {
    static func decimalToHex(_ value: String) -> String? {
        guard var digits = WalletBaseUnits.normalize(value) else { return nil }
        if digits == "0" { return "0x0" }
        let alphabet = Array("0123456789abcdef")
        var result = ""
        while digits != "0" {
            var quotient = ""
            var remainder = 0
            for character in digits {
                guard let digit = character.wholeNumberValue else { return nil }
                let current = remainder * 10 + digit
                if !quotient.isEmpty || current / 16 > 0 {
                    quotient.append(String(current / 16))
                }
                remainder = current % 16
            }
            result.append(alphabet[remainder])
            digits = quotient.isEmpty ? "0" : quotient
        }
        return "0x" + String(result.reversed())
    }

    static func hexToDecimal(_ value: String) -> String? {
        let raw = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard !raw.isEmpty, raw.allSatisfy({ $0.isHexDigit }) else { return nil }
        var result = "0"
        for character in raw.lowercased() {
            guard let digit = Int(String(character), radix: 16),
                  let shifted = WalletBaseUnits.multiply(result, "16"),
                  let next = WalletBaseUnits.add(shifted, String(digit)) else { return nil }
            result = next
        }
        return result
    }

    static func hexToUInt64(_ value: String) -> UInt64? {
        let raw = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
        return UInt64(raw, radix: 16)
    }
}

actor WalletSepoliaRPCClient {
    static let defaultEndpoint = "https://ethereum-sepolia-rpc.publicnode.com"
    static let chainID: UInt64 = 11_155_111

    private var endpoint: URL
    private let session: URLSession
    private var nextID = 1

    init(endpoint: String = WalletSepoliaRPCClient.defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = Self.validatedEndpoint(endpoint)
            ?? URL(string: WalletSepoliaRPCClient.defaultEndpoint)!
        self.session = session
    }

    func configure(endpoint value: String) throws {
        guard let url = Self.validatedEndpoint(value) else { throw WalletRPCError.invalidEndpoint }
        endpoint = url
    }

    func health() async throws -> String {
        let chain = try await verifiedChainID()
        let block = try await stringResult(method: "eth_blockNumber")
        return "Sepolia · chain \(chain) · block \(WalletEthereumQuantity.hexToDecimal(block) ?? block)"
    }

    func prepare(
        request: WalletPrepareRequest,
        fromAddress: String,
        contract: WalletContractRegistryEntry? = nil,
        encodedContract: WalletEncodedContractCall? = nil
    ) async throws -> WalletEVMPreparationPacket {
        guard request.networkID == "eip155:11155111" else {
            throw WalletRPCError.wrongChain(request.networkID)
        }
        let recipient: String
        let amount: String
        let input: String
        let observedRuntimeCodeHash: String?
        switch request.action.type {
        case .nativeTransfer:
            guard contract == nil, encodedContract == nil,
                  let requestedRecipient = request.action.recipient,
                  Self.isAddress(requestedRecipient),
                  let requestedAmount = request.action.amountBaseUnits.flatMap(WalletBaseUnits.normalize) else {
                throw WalletGateway.Error.invalidArguments("The native transfer is malformed.")
            }
            recipient = requestedRecipient
            amount = requestedAmount
            input = "0x"
            observedRuntimeCodeHash = nil
        case .contractCall:
            guard let contract, let encodedContract,
                  contract.networkID == request.networkID,
                  request.action.contractID == contract.id,
                  request.action.function.map(contract.permittedFunctions.contains) == true,
                  Self.isAddress(contract.checksumAddress),
                  encodedContract.input.hasPrefix("0x"), encodedContract.input.count >= 10,
                  let nativeValue = request.action.valueBaseUnits.flatMap(WalletBaseUnits.normalize) else {
                throw WalletGateway.Error.invalidArguments(
                    "The registered contract call is missing authoritative signer encoding."
                )
            }
            let currentCodeHash = try await runtimeCodeHash(address: contract.checksumAddress)
            guard currentCodeHash.caseInsensitiveCompare(contract.runtimeCodeHash) == .orderedSame else {
                throw WalletGateway.Error.policyDenied(
                    "The contract runtime code changed after registry approval."
                )
            }
            recipient = contract.checksumAddress
            amount = nativeValue
            input = encodedContract.input
            observedRuntimeCodeHash = currentCodeHash
        }
        _ = try await verifiedChainID()
        let nonceHex = try await stringResult(
            method: "eth_getTransactionCount", params: [fromAddress, "pending"]
        )
        guard let nonce = WalletEthereumQuantity.hexToUInt64(nonceHex) else {
            throw WalletRPCError.invalidResponse("invalid account nonce")
        }
        let fees = try await feeSuggestion()
        guard let valueHex = WalletEthereumQuantity.decimalToHex(amount),
              let maxFeeHex = WalletEthereumQuantity.decimalToHex(fees.maxFeePerGas),
              let priorityHex = WalletEthereumQuantity.decimalToHex(fees.priorityFeePerGas) else {
            throw WalletRPCError.invalidResponse("fee conversion failed")
        }
        var call: [String: Any] = [
            "from": fromAddress,
            "to": recipient,
            "value": valueHex,
            "data": input,
            "maxFeePerGas": maxFeeHex,
            "maxPriorityFeePerGas": priorityHex,
        ]
        _ = try await stringResult(method: "eth_call", params: [call, "pending"])
        let gasHex = try await stringResult(method: "eth_estimateGas", params: [call, "pending"])
        guard let estimatedGas = WalletEthereumQuantity.hexToUInt64(gasHex) else {
            throw WalletRPCError.invalidResponse("invalid gas estimate")
        }
        // A small deterministic buffer prevents a harmless state change between
        // simulation and submission from consuming the entire estimate.
        let gasLimit = estimatedGas.addingReportingOverflow(estimatedGas / 5)
        guard !gasLimit.overflow,
              let feeQuote = WalletBaseUnits.multiply(String(gasLimit.partialValue), fees.maxFeePerGas),
              WalletBaseUnits.lessThanOrEqual(feeQuote, request.maximumFeeBaseUnits) else {
            throw WalletGateway.Error.policyDenied("The simulated maximum fee exceeds the requested fee ceiling.")
        }
        call["gas"] = WalletEthereumQuantity.decimalToHex(String(gasLimit.partialValue))
        return WalletEVMPreparationPacket(
            request: request,
            fromAddress: fromAddress,
            transaction: WalletEVMTransactionFields(
                chainID: Self.chainID,
                nonce: nonce,
                gasLimit: gasLimit.partialValue,
                maxFeePerGas: fees.maxFeePerGas,
                maxPriorityFeePerGas: fees.priorityFeePerGas,
                to: recipient,
                value: amount,
                input: input
            ),
            feeQuoteBaseUnits: feeQuote,
            simulation: "eth_call succeeded; estimated gas \(estimatedGas)",
            simulationSucceeded: true,
            contractRegistryEntry: contract,
            encodedContractCall: encodedContract,
            observedRuntimeCodeHash: observedRuntimeCodeHash,
            observedAt: Date()
        )
    }

    func recheck(intentID: String, packet: WalletEVMPreparationPacket) async throws -> WalletEVMRecheckPacket {
        _ = try await verifiedChainID()
        let nonceHex = try await stringResult(
            method: "eth_getTransactionCount", params: [packet.fromAddress, "pending"]
        )
        guard let nonce = WalletEthereumQuantity.hexToUInt64(nonceHex) else {
            throw WalletRPCError.invalidResponse("invalid account nonce")
        }
        let transaction = packet.transaction
        let call: [String: Any] = [
            "from": packet.fromAddress,
            "to": transaction.to,
            "value": WalletEthereumQuantity.decimalToHex(transaction.value) ?? "",
            "data": transaction.input,
            "gas": WalletEthereumQuantity.decimalToHex(String(transaction.gasLimit)) ?? "",
            "maxFeePerGas": WalletEthereumQuantity.decimalToHex(transaction.maxFeePerGas) ?? "",
            "maxPriorityFeePerGas": WalletEthereumQuantity.decimalToHex(transaction.maxPriorityFeePerGas) ?? "",
        ]
        _ = try await stringResult(method: "eth_call", params: [call, "pending"])
        let gasHex = try await stringResult(method: "eth_estimateGas", params: [call, "pending"])
        guard let gas = WalletEthereumQuantity.hexToUInt64(gasHex), gas <= transaction.gasLimit,
              let feeQuote = WalletBaseUnits.multiply(
                  String(transaction.gasLimit), transaction.maxFeePerGas
              ) else {
            throw WalletRPCError.simulation("the refreshed gas estimate exceeds the prepared limit")
        }
        let observedRuntimeCodeHash: String?
        if let contract = packet.contractRegistryEntry {
            let current = try await runtimeCodeHash(address: contract.checksumAddress)
            guard current.caseInsensitiveCompare(contract.runtimeCodeHash) == .orderedSame else {
                throw WalletGateway.Error.policyDenied(
                    "The contract runtime code changed after transaction preparation."
                )
            }
            observedRuntimeCodeHash = current
        } else {
            observedRuntimeCodeHash = nil
        }
        return WalletEVMRecheckPacket(
            intentID: intentID,
            chainID: Self.chainID,
            pendingNonce: nonce,
            feeQuoteBaseUnits: feeQuote,
            simulation: "Refreshed eth_call succeeded; estimated gas \(gas)",
            simulationSucceeded: true,
            observedRuntimeCodeHash: observedRuntimeCodeHash,
            observedAt: Date()
        )
    }

    func broadcast(rawTransaction: String) async throws -> String {
        try await stringResult(method: "eth_sendRawTransaction", params: [rawTransaction])
    }

    func balance(address: String) async throws -> String {
        let value = try await stringResult(method: "eth_getBalance", params: [address, "latest"])
        guard let decimal = WalletEthereumQuantity.hexToDecimal(value) else {
            throw WalletRPCError.invalidResponse("invalid balance")
        }
        return decimal
    }

    func verifyContract(_ draft: WalletContractRegistryDraft) async throws -> WalletContractRegistryEntry {
        guard draft.networkID == "eip155:11155111", Self.isAddress(draft.address),
              !draft.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.id.count <= 128,
              !draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.label.count <= 128,
              !draft.permittedFunctions.isEmpty, draft.permittedFunctions.count <= 64,
              draft.abiJSON.utf8.count <= 256 * 1024 else {
            throw WalletGateway.Error.invalidArguments(
                "A Sepolia registry ID, contract address, label, ABI, and at least one canonical function are required."
            )
        }
        _ = try await verifiedChainID()
        guard let abiData = draft.abiJSON.data(using: .utf8),
              JSONSerialization.isValidJSONObject(try JSONSerialization.jsonObject(with: abiData)) else {
            throw WalletGateway.Error.invalidArguments("The contract ABI must be valid JSON.")
        }
        let abiObject = try JSONSerialization.jsonObject(with: abiData)
        let normalizedABIData = try JSONSerialization.data(
            withJSONObject: abiObject, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let normalizedABI = String(data: normalizedABIData, encoding: .utf8) else {
            throw WalletGateway.Error.invalidArguments("The contract ABI could not be normalized.")
        }
        let abiDigest = "sha256:" + SHA256.hash(data: normalizedABIData)
            .map { String(format: "%02x", $0) }.joined()
        let checksumAddress = try await checksumAddress(draft.address)
        let runtimeCodeHash = try await runtimeCodeHash(address: checksumAddress)
        let functions = Array(Set(draft.permittedFunctions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        guard !functions.isEmpty, functions.allSatisfy(Self.isCanonicalFunctionSignature) else {
            throw WalletGateway.Error.invalidArguments(
                "Permitted methods must use canonical signatures such as transfer(address,uint256)."
            )
        }
        var selectors: [String] = []
        for function in functions {
            let encoded = "0x" + function.utf8.map { String(format: "%02x", $0) }.joined()
            let digest = try await stringResult(method: "web3_sha3", params: [encoded])
            guard digest.count == 66 else {
                throw WalletRPCError.invalidResponse("web3_sha3 returned an invalid selector digest")
            }
            selectors.append(String(digest.prefix(10)).lowercased())
        }
        let reviewedAdapterID = WalletReviewedAdapters.classify(
            normalizedABI: normalizedABI, permittedFunctions: functions
        )
        if let requestedAdapterID = draft.reviewedAdapterID,
           requestedAdapterID != reviewedAdapterID {
            throw WalletGateway.Error.invalidArguments(
                "The requested adapter does not match the verified ABI and permitted methods."
            )
        }
        return WalletContractRegistryEntry(
            id: draft.id.trimmingCharacters(in: .whitespacesAndNewlines),
            networkID: draft.networkID,
            checksumAddress: checksumAddress,
            label: draft.label.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedABI: normalizedABI,
            abiDigest: abiDigest,
            runtimeCodeHash: runtimeCodeHash.lowercased(),
            permittedFunctions: functions,
            permittedSelectors: selectors,
            reviewedAdapterID: reviewedAdapterID,
            verifiedAt: Date()
        )
    }

    func publicRead(method: String, params: [Any]) async throws -> Any {
        let allowed = Set([
            "eth_blockNumber", "eth_getBalance", "eth_getCode",
            "eth_getTransactionByHash", "eth_getTransactionReceipt",
            "eth_call", "eth_estimateGas", "eth_gasPrice", "eth_feeHistory",
        ])
        guard allowed.contains(method), params.count <= 4 else {
            throw WalletGateway.Error.invalidArguments("That browser RPC method is not supported.")
        }
        _ = try await verifiedChainID()
        return try await rpc(method: method, params: params)
    }

    private func runtimeCodeHash(address: String) async throws -> String {
        let code = try await stringResult(method: "eth_getCode", params: [address, "latest"])
        guard code != "0x", code != "0x0" else {
            throw WalletGateway.Error.invalidArguments("No runtime bytecode exists at that Sepolia address.")
        }
        return try await stringResult(method: "web3_sha3", params: [code]).lowercased()
    }

    private func checksumAddress(_ value: String) async throws -> String {
        let lowercase = String(value.dropFirst(2)).lowercased()
        let encoded = "0x" + lowercase.utf8.map { String(format: "%02x", $0) }.joined()
        let digest = try await stringResult(method: "web3_sha3", params: [encoded])
        return try Self.checksummedAddress(value, keccakHash: digest)
    }

    static func checksummedAddress(_ value: String, keccakHash digest: String) throws -> String {
        guard isAddress(value) else {
            throw WalletGateway.Error.invalidArguments("The contract address is malformed.")
        }
        let lowercase = String(value.dropFirst(2)).lowercased()
        let hash = String(digest.dropFirst(2)).lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw WalletRPCError.invalidResponse("web3_sha3 returned an invalid address checksum")
        }
        let checksum = zip(lowercase, hash).map { addressCharacter, hashCharacter -> Character in
            guard addressCharacter.isLetter,
                  let nibble = Int(String(hashCharacter), radix: 16), nibble >= 8 else {
                return addressCharacter
            }
            return Character(String(addressCharacter).uppercased())
        }
        return "0x" + String(checksum)
    }

    private func verifiedChainID() async throws -> UInt64 {
        let value = try await stringResult(method: "eth_chainId")
        guard let chain = WalletEthereumQuantity.hexToUInt64(value) else {
            throw WalletRPCError.invalidResponse("invalid chain ID")
        }
        guard chain == Self.chainID else { throw WalletRPCError.wrongChain(String(chain)) }
        return chain
    }

    private func feeSuggestion() async throws -> (maxFeePerGas: String, priorityFeePerGas: String) {
        let block = try await dictionaryResult(method: "eth_getBlockByNumber", params: ["latest", false])
        guard let baseHex = block["baseFeePerGas"] as? String,
              let base = WalletEthereumQuantity.hexToDecimal(baseHex) else {
            throw WalletRPCError.invalidResponse("latest block has no base fee")
        }
        let priorityHex: String
        do { priorityHex = try await stringResult(method: "eth_maxPriorityFeePerGas") }
        catch { priorityHex = "0x3b9aca00" } // 1 gwei, only if this optional RPC method is absent.
        guard let priority = WalletEthereumQuantity.hexToDecimal(priorityHex),
              let doubledBase = WalletBaseUnits.multiply(base, "2"),
              let maxFee = WalletBaseUnits.add(doubledBase, priority) else {
            throw WalletRPCError.invalidResponse("fee suggestion is malformed")
        }
        return (maxFee, priority)
    }

    private func stringResult(method: String, params: [Any] = []) async throws -> String {
        let result = try await rpc(method: method, params: params)
        guard let value = result as? String else {
            throw WalletRPCError.invalidResponse("\(method) did not return a string")
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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        guard body.count <= 256 * 1024 else {
            throw WalletRPCError.invalidResponse("request exceeded the 256 KiB wallet limit")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WalletRPCError.invalidResponse("HTTP request failed")
        }
        guard data.count <= 1_048_576 else {
            throw WalletRPCError.invalidResponse("response exceeded the 1 MiB wallet limit")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WalletRPCError.invalidResponse("response is not JSON-RPC")
        }
        guard object["jsonrpc"] as? String == "2.0",
              let responseID = object["id"] as? NSNumber,
              CFGetTypeID(responseID) != CFBooleanGetTypeID(),
              responseID.decimalValue == Decimal(id) else {
            throw WalletRPCError.invalidResponse("JSON-RPC version or response ID did not match the request")
        }
        let hasResult = object.keys.contains("result")
        let hasError = object.keys.contains("error")
        guard hasResult != hasError else {
            throw WalletRPCError.invalidResponse("response must contain exactly one of result or error")
        }
        if hasError {
            guard let error = object["error"] as? [String: Any],
                  let code = error["code"] as? NSNumber,
                  CFGetTypeID(code) != CFBooleanGetTypeID(),
                  code.decimalValue == Decimal(code.intValue),
                  let rawMessage = error["message"] as? String else {
                throw WalletRPCError.invalidResponse("error payload was malformed")
            }
            let message = String(rawMessage.prefix(512))
            throw WalletRPCError.rpc(
                code: code.intValue,
                message: message
            )
        }
        guard let result = object["result"] else {
            throw WalletRPCError.invalidResponse("result payload was missing")
        }
        return result
    }

    private static func validatedEndpoint(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private static func isAddress(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x") && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func isCanonicalFunctionSignature(_ value: String) -> Bool {
        guard !value.contains(where: \.isWhitespace),
              let open = value.firstIndex(of: "("), value.last == ")", open != value.startIndex else {
            return false
        }
        let name = value[..<open]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
