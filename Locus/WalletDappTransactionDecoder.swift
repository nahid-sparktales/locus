import Foundation

/// Decodes serialized dapp requests into the same narrow semantic actions used
/// by first-party transfers. No signature, blockhash, lookup-table account, or
/// caller-selected instruction survives this boundary: WalletSigner rebuilds a
/// fresh transaction after review.
enum WalletDappTransactionDecoder {
    private static let systemProgram = "11111111111111111111111111111111"
    private static let tokenProgram = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    private static let associatedTokenProgram =
        "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
    private static let lookupTableProgram =
        "AddressLookupTab1e1111111111111111111111111"
    private static let coreProgram =
        "CoREENxT6tW1HoK8ypY1SxRMZTcVPm7R94rH4PZNhX7d"

    struct SolanaLookupTable: Equatable, Sendable {
        let address: String
        let slot: UInt64
        let addresses: [String]
    }

    private struct SolanaInstruction: Equatable {
        let programIndex: Int
        let accountIndexes: [Int]
        let data: Data
    }

    private struct SolanaLookup: Equatable {
        let address: String
        let writableIndexes: [Int]
        let readonlyIndexes: [Int]
    }

    private struct SolanaMessage: Equatable {
        let version: WalletSolanaTransactionVersion
        let requiredSignatures: Int
        let readonlySigned: Int
        let readonlyUnsigned: Int
        let staticAccounts: [String]
        let instructions: [SolanaInstruction]
        let lookups: [SolanaLookup]
    }

    private struct ResolvedSolanaAccount: Equatable {
        let address: String
        let signer: Bool
        let writable: Bool
    }

    private struct SolanaTokenAccountEvidence: Equatable {
        let address: String
        let owner: String
        let mint: String
        let decimals: UInt8
        let programID: String
    }

    private struct SuiObjectReference: Equatable {
        let objectID: String
        let version: UInt64
        let digest: String
    }

    private enum SuiInput: Equatable {
        case pure(Data)
        case owned(SuiObjectReference)
    }

    private enum SuiArgument: Equatable {
        case gas
        case input(UInt16)
        case result(UInt16)
        case nestedResult(UInt16, UInt16)
    }

    private enum SuiCommand: Equatable {
        case transfer(objects: [SuiArgument], address: SuiArgument)
        case split(coin: SuiArgument, amounts: [SuiArgument])
    }

    private struct SuiTransaction: Equatable {
        let inputs: [SuiInput]
        let commands: [SuiCommand]
        let sender: String
        let gasObject: SuiObjectReference
        let gasOwner: String
        let gasPrice: UInt64
        let gasBudget: UInt64
    }

    static func evm(
        _ transaction: WalletConnectorDappRequest.EVMTransaction,
        networkID: String,
        account: WalletAccount
    ) throws -> WalletSemanticAction {
        guard WalletNetworkCatalog.descriptor(id: networkID)?.chain == .evm,
              account.chain == .evm,
              transaction.from.caseInsensitiveCompare(account.address) == .orderedSame,
              evmAddress(transaction.to),
              let value = WalletEthereumQuantity.hexToDecimal(transaction.valueHex),
              transaction.dataHex.hasPrefix("0x"),
              transaction.dataHex.dropFirst(2).count.isMultiple(of: 2),
              transaction.dataHex.dropFirst(2).allSatisfy(\.isHexDigit),
              transaction.dataHex.dropFirst(2).count <= 256 * 1_024 * 2 else {
            throw malformed("The EVM request is malformed or unbound.")
        }
        let data = transaction.dataHex.lowercased()
        if data == "0x" {
            guard value != "0" else {
                throw malformed("A native transfer amount must be positive.")
            }
            return .nativeTransfer(
                recipient: transaction.to, amountBaseUnits: value
            )
        }
        guard value == "0" else {
            throw malformed(
                "Reviewed token and collectible transfers cannot carry native value."
            )
        }
        let raw = String(data.dropFirst(2))
        let selector = String(raw.prefix(8))
        let body = String(raw.dropFirst(8))
        guard body.count.isMultiple(of: 64) else {
            throw malformed("The reviewed calldata has a non-canonical ABI shape.")
        }
        let words = stride(from: 0, to: body.count, by: 64).map { offset -> String in
            let start = body.index(body.startIndex, offsetBy: offset)
            return String(body[start..<body.index(start, offsetBy: 64)])
        }
        switch selector {
        case "a9059cbb":
            guard words.count == 2,
                  let recipient = evmAddressWord(words[0]),
                  let amount = evmUnsignedWord(words[1]), amount != "0" else {
                throw malformed("The ERC-20 transfer calldata is not canonical.")
            }
            return .fungibleTokenTransfer(
                assetID: "\(networkID)/erc20:\(transaction.to.lowercased())",
                recipient: recipient, amountBaseUnits: amount
            )
        case "42842e0e":
            guard words.count == 3,
                  let sender = evmAddressWord(words[0]),
                  sender.caseInsensitiveCompare(account.address) == .orderedSame,
                  let recipient = evmAddressWord(words[1]),
                  let tokenID = evmUnsignedWord(words[2]) else {
                throw malformed("The ERC-721 transfer calldata is not canonical.")
            }
            return .nftTransfer(
                assetID: "\(networkID)/erc721:\(transaction.to.lowercased())",
                tokenID: tokenID, recipient: recipient
            )
        case "f242432a":
            guard words.count == 6,
                  let sender = evmAddressWord(words[0]),
                  sender.caseInsensitiveCompare(account.address) == .orderedSame,
                  let recipient = evmAddressWord(words[1]),
                  let tokenID = evmUnsignedWord(words[2]),
                  evmUnsignedWord(words[3]) == "1",
                  evmUnsignedWord(words[4]) == "160",
                  evmUnsignedWord(words[5]) == "0" else {
                throw malformed("The ERC-1155 transfer calldata is not canonical.")
            }
            return .nftTransfer(
                assetID: "\(networkID)/erc1155:\(transaction.to.lowercased())/\(tokenID)",
                tokenID: tokenID, recipient: recipient
            )
        default:
            throw malformed(
                "Only decoded native, ERC-20, ERC-721, and ERC-1155 requests are enabled for this dapp connection."
            )
        }
    }

    /// Decodes only the single-command Universal Router ABI shape that Locus
    /// can independently quote and rebuild. It returns semantic route fields;
    /// the caller must still reproduce the quote and allowance state before
    /// constructing an executable action.
    static func evmUniversalRouterSwap(
        _ transaction: WalletConnectorDappRequest.EVMTransaction,
        networkID: String,
        account: WalletAccount,
        routerContractID: String,
        routerAddress: String,
        now: Date = Date()
    ) -> WalletUniversalRouterV2Swap? {
        guard account.chain == .evm,
              account.networkIDs.contains(networkID),
              transaction.from.caseInsensitiveCompare(account.address)
                == .orderedSame,
              transaction.to.caseInsensitiveCompare(routerAddress)
                == .orderedSame,
              !routerContractID.isEmpty,
              WalletEthereumQuantity.hexToDecimal(transaction.valueHex) == "0"
        else { return nil }
        let data = transaction.dataHex.lowercased()
        guard data.hasPrefix("0x3593564c") else { return nil }
        let body = String(data.dropFirst(10))
        guard body.count.isMultiple(of: 64), body.count <= 64 * 64,
              body.allSatisfy(\.isHexDigit) else { return nil }
        let words = stride(from: 0, to: body.count, by: 64).map { offset in
            let start = body.index(body.startIndex, offsetBy: offset)
            return String(body[start..<body.index(start, offsetBy: 64)])
        }
        guard words.count >= 9,
              evmUnsignedWord(words[0]) == "96",
              evmUnsignedWord(words[1]) == "160",
              let deadline = evmUnsignedWord(words[2]),
              evmUnsignedWord(words[3]) == "1",
              words[4].dropFirst(2).allSatisfy({ $0 == "0" }),
              evmUnsignedWord(words[5]) == "1",
              evmUnsignedWord(words[6]) == "32",
              let inputByteCountText = evmUnsignedWord(words[7]),
              let inputByteCount = Int(inputByteCountText),
              inputByteCount > 0, inputByteCount <= 2_048 else { return nil }
        let inputWordCount = (inputByteCount + 31) / 32
        guard words.count == 8 + inputWordCount else { return nil }
        let paddedInput = words[8...].joined()
        let inputHexCount = inputByteCount * 2
        guard paddedInput.count >= inputHexCount else { return nil }
        let inputEnd = paddedInput.index(
            paddedInput.startIndex, offsetBy: inputHexCount
        )
        guard paddedInput[inputEnd...].allSatisfy({ $0 == "0" }) else {
            return nil
        }
        let command = "0x" + String(words[4].prefix(2))
        let input = "0x" + String(paddedInput[..<inputEnd])
        let typed = WalletSemanticAction.contractCall(
            contractID: routerContractID,
            function: "execute(bytes,bytes[],uint256)",
            arguments: [
                WalletTypedArgument(type: "bytes", value: command),
                WalletTypedArgument(type: "bytes[]", value: "[\(input)]"),
                WalletTypedArgument(type: "uint256", value: deadline),
            ]
        )
        return WalletUniversalRouterV2V3Adapter.decode(
            action: typed, accountAddress: account.address,
            networkID: networkID, now: now
        )
    }

    static func solana(
        _ request: WalletConnectorDappRequest.SolanaTransaction,
        networkID: String,
        account: WalletAccount,
        bundle: Bundle = .main,
        allowsSubmittedSignature: Bool = false
    ) async throws -> WalletSemanticAction {
        guard WalletNetworkCatalog.descriptor(id: networkID)?.chain == .solana,
              account.chain == .solana,
              request.accountAddress == account.address,
              WalletSolanaBase58.decode(account.address, exactLength: 32) != nil,
              let serialized = Data(base64Encoded: request.transactionBase64),
              serialized.base64EncodedString() == request.transactionBase64,
              (66...1_232).contains(serialized.count) else {
            throw malformed("The Solana request is malformed or unbound.")
        }
        let parsed = try parseSolanaTransaction(
            serialized, allowsSubmittedSignature: allowsSubmittedSignature
        )
        guard parsed.requiredSignatures == 1,
              parsed.readonlySigned == 0,
              parsed.staticAccounts.first == account.address else {
            throw malformed("The Solana request has an unexpected signer set.")
        }
        let resolved = try await resolveSolanaAccounts(
            parsed, networkID: networkID, bundle: bundle
        )
        guard Set(resolved.map(\.address)).count == resolved.count,
              resolved.first == ResolvedSolanaAccount(
                address: account.address, signer: true, writable: true
              ) else {
            throw malformed("The Solana account roles are ambiguous.")
        }

        if parsed.instructions.count == 1,
           let action = try decodeSolanaNativeOrCore(
             parsed.instructions[0], accounts: resolved,
             networkID: networkID, owner: account.address
           ) {
            return action
        }
        return try await decodeSolanaTokenTransfer(
            parsed.instructions, accounts: resolved,
            networkID: networkID, owner: account.address, bundle: bundle
        )
    }

    static func sui(
        _ request: WalletConnectorDappRequest.SuiTransaction,
        networkID: String,
        account: WalletAccount,
        reviewedAssets: [WalletAsset],
        bundle: Bundle = .main
    ) async throws -> WalletSemanticAction {
        guard WalletNetworkCatalog.descriptor(id: networkID)?.chain == .sui,
              account.chain == .sui,
              request.accountAddress == account.address,
              WalletSuiAddress.isCanonical(account.address),
              let serialized = Data(base64Encoded: request.transactionBase64),
              serialized.base64EncodedString() == request.transactionBase64,
              !serialized.isEmpty, serialized.count <= 8 * 1_024 else {
            throw malformed("The Sui request is malformed or unbound.")
        }
        let transaction = try parseSuiTransaction(serialized)
        guard transaction.sender == account.address,
              transaction.gasOwner == account.address,
              transaction.gasPrice > 0,
              transaction.gasBudget > 0,
              transaction.gasObject.objectID != account.address else {
            throw malformed("The Sui sender and gas roles are invalid.")
        }

        if transaction.inputs.count == 2,
           transaction.commands.count == 2,
           case .pure(let amountBytes) = transaction.inputs[0],
           case .pure(let recipientBytes) = transaction.inputs[1],
           amountBytes.count == 8,
           let amount = littleEndianUInt64(amountBytes, offset: 0), amount > 0,
           let recipient = suiAddress(recipientBytes),
           transaction.commands[0] == .split(
             coin: .gas, amounts: [.input(0)]
           ),
           transaction.commands[1] == .transfer(
             objects: [.nestedResult(0, 0)], address: .input(1)
           ) {
            guard recipient != account.address,
                  recipient != transaction.gasObject.objectID else {
                throw malformed("The Sui transfer account roles overlap.")
            }
            return .nativeTransfer(
                recipient: recipient, amountBaseUnits: String(amount)
            )
        }

        guard let network = WalletNetworkCatalog.descriptor(id: networkID),
              let configuration = WalletSuiProviderConfiguration.bundled(
                network: network, bundle: bundle
              ) else {
            throw WalletProviderCoordinatorError.noProvider(networkID)
        }
        let coordinator = try WalletSuiProviderCoordinator(
            network: network, configuration: configuration
        )
        if transaction.inputs.count == 3,
           transaction.commands == [
             .split(coin: .input(0), amounts: [.input(1)]),
             .transfer(objects: [.nestedResult(0, 0)], address: .input(2)),
           ],
           case .owned(let coin) = transaction.inputs[0],
           case .pure(let amountBytes) = transaction.inputs[1],
           case .pure(let recipientBytes) = transaction.inputs[2],
           amountBytes.count == 8,
           let amount = littleEndianUInt64(amountBytes, offset: 0), amount > 0,
           let recipient = suiAddress(recipientBytes) {
            guard coin.objectID != transaction.gasObject.objectID,
                  recipient != account.address,
                  recipient != coin.objectID,
                  recipient != transaction.gasObject.objectID else {
                throw malformed("The Sui Coin transfer roles overlap.")
            }
            let candidates = reviewedAssets.compactMap { asset -> WalletSuiAssetIdentity? in
                guard asset.networkID == networkID,
                      asset.chain == .sui,
                      asset.kind == .fungibleToken,
                      asset.isVisibleByDefault,
                      let identity = WalletSuiAssetIdentity.parse(asset.id),
                      identity.coinType != WalletSuiAssetIdentity.nativeCoinType else {
                    return nil
                }
                return identity
            }
            guard candidates.count <= 32 else {
                throw malformed("The reviewed Sui Coin set exceeds the decoder bound.")
            }
            var matched: WalletSuiAssetIdentity?
            for identity in candidates {
                let snapshot = try await coordinator.coinObjects(
                    owner: account.address, coinType: identity.coinType
                )
                if snapshot.objects.contains(where: {
                    $0.reference.objectID == coin.objectID
                        && $0.reference.version == coin.version
                        && $0.reference.digest == coin.digest
                        && WalletBaseUnits.lessThanOrEqual(
                            String(amount), $0.balanceBaseUnits
                        )
                }) {
                    guard matched == nil else {
                        throw malformed("The Sui Coin object has ambiguous identity.")
                    }
                    matched = identity
                }
            }
            guard let matched else {
                throw malformed("The Sui Coin object is not in the reviewed asset set.")
            }
            return .fungibleTokenTransfer(
                assetID: matched.canonicalID,
                recipient: recipient,
                amountBaseUnits: String(amount)
            )
        }

        if transaction.inputs.count == 2,
           transaction.commands == [
             .transfer(objects: [.input(0)], address: .input(1)),
           ],
           case .owned(let object) = transaction.inputs[0],
           case .pure(let recipientBytes) = transaction.inputs[1],
           let recipient = suiAddress(recipientBytes) {
            guard object.objectID != transaction.gasObject.objectID,
                  recipient != account.address,
                  recipient != object.objectID,
                  recipient != transaction.gasObject.objectID else {
                throw malformed("The Sui object transfer roles overlap.")
            }
            let snapshot = try await coordinator.ownedObjectSnapshot(
                owner: account.address
            )
            guard let evidence = snapshot.objects.first(where: {
                $0.identity.objectID == object.objectID
                    && $0.version == object.version
                    && $0.digest == object.digest
                    && $0.hasPublicTransfer
            }) else {
                throw malformed("The Sui object is not an owned public-transfer object.")
            }
            let identity = WalletSuiObjectIdentity(
                networkID: networkID, objectID: evidence.identity.objectID
            )
            return .nftTransfer(
                assetID: identity.canonicalID,
                tokenID: identity.objectID,
                recipient: recipient
            )
        }
        throw malformed(
            "Only native, reviewed Coin, and public-object Sui transfers are enabled."
        )
    }

    private static func parseSuiTransaction(_ data: Data) throws -> SuiTransaction {
        var reader = ByteReader(data: data)
        guard try reader.byte() == 0, // TransactionData::V1
              try reader.byte() == 0 else { // ProgrammableTransaction
            throw malformed("Only a Sui V1 programmable transaction is supported.")
        }
        let inputCount = try reader.uleb128(maximum: 3)
        guard inputCount > 0 else {
            throw malformed("The Sui transaction contains no inputs.")
        }
        var inputs: [SuiInput] = []
        for _ in 0..<inputCount {
            switch try reader.byte() {
            case 0:
                let count = try reader.uleb128(maximum: 256)
                inputs.append(.pure(try reader.read(count: count)))
            case 1:
                guard try reader.byte() == 0 else {
                    throw malformed("Shared and receiving Sui inputs are unavailable.")
                }
                inputs.append(.owned(try reader.suiObjectReference()))
            default:
                throw malformed("The Sui input type is unavailable.")
            }
        }
        let commandCount = try reader.uleb128(maximum: 2)
        guard commandCount > 0 else {
            throw malformed("The Sui transaction contains no commands.")
        }
        var commands: [SuiCommand] = []
        for _ in 0..<commandCount {
            switch try reader.byte() {
            case 1:
                let count = try reader.uleb128(maximum: 1)
                guard count == 1 else {
                    throw malformed("Sui object batches are unavailable.")
                }
                let objects = try (0..<count).map { _ in
                    try reader.suiArgument()
                }
                commands.append(.transfer(
                    objects: objects, address: try reader.suiArgument()
                ))
            case 2:
                let coin = try reader.suiArgument()
                let count = try reader.uleb128(maximum: 1)
                guard count == 1 else {
                    throw malformed("Sui split batches are unavailable.")
                }
                let amounts = try (0..<count).map { _ in
                    try reader.suiArgument()
                }
                commands.append(.split(coin: coin, amounts: amounts))
            default:
                throw malformed("Move calls and unsupported Sui commands are unavailable.")
            }
        }
        let sender = try reader.suiAddress()
        let gasCount = try reader.uleb128(maximum: 1)
        guard gasCount == 1 else {
            throw malformed("A Sui request must contain exactly one gas object.")
        }
        let gasObject = try reader.suiObjectReference()
        let gasOwner = try reader.suiAddress()
        guard let gasPrice = try reader.uint64(), gasPrice > 0,
              let gasBudget = try reader.uint64(), gasBudget > 0 else {
            throw malformed("The Sui gas values are malformed.")
        }
        switch try reader.byte() {
        case 0:
            break
        case 1:
            guard let epoch = try reader.uint64(), epoch > 0 else {
                throw malformed("The Sui expiration epoch is malformed.")
            }
        default:
            throw malformed("The Sui expiration form is unavailable.")
        }
        guard reader.isAtEnd else {
            throw malformed("The Sui transaction contains trailing bytes.")
        }
        return SuiTransaction(
            inputs: inputs, commands: commands,
            sender: sender, gasObject: gasObject, gasOwner: gasOwner,
            gasPrice: gasPrice, gasBudget: gasBudget
        )
    }

    private static func suiAddress(_ data: Data) -> String? {
        guard data.count == 32 else { return nil }
        return "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    private static func parseSolanaTransaction(
        _ data: Data, allowsSubmittedSignature: Bool
    ) throws -> SolanaMessage {
        var reader = ByteReader(data: data)
        let signatureCount = try reader.shortVector(maximum: 16)
        guard signatureCount > 0 else {
            throw malformed("The Solana transaction has no signer slot.")
        }
        for _ in 0..<signatureCount {
            let signature = try reader.read(count: 64)
            guard allowsSubmittedSignature || signature.allSatisfy({ $0 == 0 }) else {
                throw malformed("A dapp must submit an unsigned Solana transaction.")
            }
        }
        let first = try reader.byte()
        let version: WalletSolanaTransactionVersion
        let requiredSignatures: Int
        if first & 0x80 == 0 {
            version = .legacy
            requiredSignatures = Int(first)
        } else {
            guard first & 0x7f == 0 else {
                throw malformed("Solana v1 and unknown transaction versions are unavailable.")
            }
            version = .v0
            requiredSignatures = Int(try reader.byte())
        }
        let readonlySigned = Int(try reader.byte())
        let readonlyUnsigned = Int(try reader.byte())
        let accountCount = try reader.shortVector(maximum: 64)
        guard accountCount >= requiredSignatures,
              requiredSignatures == signatureCount,
              readonlySigned <= requiredSignatures,
              readonlyUnsigned <= accountCount - requiredSignatures else {
            throw malformed("The Solana message header is inconsistent.")
        }
        var accounts: [String] = []
        accounts.reserveCapacity(accountCount)
        for _ in 0..<accountCount {
            accounts.append(WalletSolanaBase58.encode(try reader.read(count: 32)))
        }
        guard Set(accounts).count == accounts.count else {
            throw malformed("The Solana static account list contains duplicates.")
        }
        _ = try reader.read(count: 32) // recent blockhash is freshness only
        let instructionCount = try reader.shortVector(maximum: 16)
        guard instructionCount > 0 else {
            throw malformed("The Solana request contains no action.")
        }
        var instructions: [SolanaInstruction] = []
        instructions.reserveCapacity(instructionCount)
        for _ in 0..<instructionCount {
            let programIndex = Int(try reader.byte())
            let indexCount = try reader.shortVector(maximum: 32)
            let indexes = try reader.read(count: indexCount).map(Int.init)
            let dataCount = try reader.shortVector(maximum: 1_232)
            instructions.append(SolanaInstruction(
                programIndex: programIndex,
                accountIndexes: indexes,
                data: try reader.read(count: dataCount)
            ))
        }
        var lookups: [SolanaLookup] = []
        if version == .v0 {
            let lookupCount = try reader.shortVector(maximum: 8)
            var seen: Set<String> = []
            var loadedCount = 0
            for _ in 0..<lookupCount {
                let address = WalletSolanaBase58.encode(try reader.read(count: 32))
                let writableCount = try reader.shortVector(maximum: 32)
                let writable = try reader.read(count: writableCount).map(Int.init)
                let readonlyCount = try reader.shortVector(maximum: 32)
                let readonly = try reader.read(count: readonlyCount).map(Int.init)
                guard seen.insert(address).inserted,
                      Set(writable).count == writable.count,
                      Set(readonly).count == readonly.count,
                      Set(writable).isDisjoint(with: Set(readonly)) else {
                    throw malformed("A Solana address-table lookup is ambiguous.")
                }
                loadedCount += writable.count + readonly.count
                guard loadedCount <= 64 else {
                    throw malformed("The Solana request resolves too many lookup accounts.")
                }
                lookups.append(SolanaLookup(
                    address: address,
                    writableIndexes: writable,
                    readonlyIndexes: readonly
                ))
            }
        }
        guard reader.isAtEnd else {
            throw malformed("The Solana transaction contains trailing bytes.")
        }
        return SolanaMessage(
            version: version,
            requiredSignatures: requiredSignatures,
            readonlySigned: readonlySigned,
            readonlyUnsigned: readonlyUnsigned,
            staticAccounts: accounts,
            instructions: instructions,
            lookups: lookups
        )
    }

    private static func resolveSolanaAccounts(
        _ message: SolanaMessage,
        networkID: String,
        bundle: Bundle
    ) async throws -> [ResolvedSolanaAccount] {
        guard let network = WalletNetworkCatalog.descriptor(id: networkID),
              let configuration = WalletSolanaProviderConfiguration.bundled(
                network: network, bundle: bundle
              ) else {
            throw WalletProviderCoordinatorError.noProvider(networkID)
        }
        let coordinator = try WalletSolanaProviderCoordinator(
            network: network, configuration: configuration
        )
        var resolved: [ResolvedSolanaAccount] = message.staticAccounts.enumerated().map {
            index, address in
            let signer = index < message.requiredSignatures
            let writable = signer
                ? index < message.requiredSignatures - message.readonlySigned
                : index < message.staticAccounts.count - message.readonlyUnsigned
            return ResolvedSolanaAccount(
                address: address, signer: signer, writable: writable
            )
        }
        var writable: [ResolvedSolanaAccount] = []
        var readonly: [ResolvedSolanaAccount] = []
        for lookup in message.lookups {
            let table = try await solanaLookupTable(
                lookup.address, coordinator: coordinator
            )
            for index in lookup.writableIndexes {
                guard index < table.addresses.count else {
                    throw malformed("A Solana writable lookup index is out of range.")
                }
                writable.append(ResolvedSolanaAccount(
                    address: table.addresses[index], signer: false, writable: true
                ))
            }
            for index in lookup.readonlyIndexes {
                guard index < table.addresses.count else {
                    throw malformed("A Solana read-only lookup index is out of range.")
                }
                readonly.append(ResolvedSolanaAccount(
                    address: table.addresses[index], signer: false, writable: false
                ))
            }
        }
        resolved.append(contentsOf: writable)
        resolved.append(contentsOf: readonly)
        let upperBound = resolved.count
        guard message.instructions.allSatisfy({ instruction in
            instruction.programIndex < upperBound
                && instruction.accountIndexes.allSatisfy({ $0 < upperBound })
        }) else {
            throw malformed("A Solana instruction account index is out of range.")
        }
        return resolved
    }

    private static func solanaLookupTable(
        _ address: String,
        coordinator: WalletSolanaProviderCoordinator
    ) async throws -> SolanaLookupTable {
        let raw = try await coordinator.publicRead(
            method: "getAccountInfo",
            params: [address, ["commitment": "finalized", "encoding": "base64"]]
        )
        guard let envelope = raw as? [String: Any], envelope.count <= 4,
              let context = envelope["context"] as? [String: Any],
              let slot = unsigned(context["slot"]),
              let value = envelope["value"] as? [String: Any], value.count <= 8,
              value["owner"] as? String == lookupTableProgram,
              let dataValue = value["data"] as? [Any], dataValue.count == 2,
              dataValue[1] as? String == "base64",
              let encoded = dataValue[0] as? String,
              let data = Data(base64Encoded: encoded),
              data.base64EncodedString() == encoded,
              data.count >= 56, (data.count - 56).isMultiple(of: 32),
              (data.count - 56) / 32 <= 256,
              littleEndianUInt32(data, offset: 0) == 1,
              littleEndianUInt64(data, offset: 4) == UInt64.max,
              let extendedAt = littleEndianUInt64(data, offset: 12),
              extendedAt <= slot else {
            throw malformed("A Solana address lookup table is invalid or inactive.")
        }
        var addresses: [String] = []
        var offset = 56
        while offset < data.count {
            addresses.append(WalletSolanaBase58.encode(data.subdata(in: offset..<offset + 32)))
            offset += 32
        }
        guard Set(addresses).count == addresses.count else {
            throw malformed("A Solana address lookup table contains duplicate accounts.")
        }
        return SolanaLookupTable(address: address, slot: slot, addresses: addresses)
    }

    private static func decodeSolanaNativeOrCore(
        _ instruction: SolanaInstruction,
        accounts: [ResolvedSolanaAccount],
        networkID: String,
        owner: String
    ) throws -> WalletSemanticAction? {
        let program = accounts[instruction.programIndex].address
        if program == systemProgram {
            guard instruction.accountIndexes.count == 2,
                  instruction.data.count == 12,
                  littleEndianUInt32(instruction.data, offset: 0) == 2,
                  let amount = littleEndianUInt64(instruction.data, offset: 4),
                  amount > 0 else {
                throw malformed("The Solana System transfer is not canonical.")
            }
            let source = accounts[instruction.accountIndexes[0]]
            let recipient = accounts[instruction.accountIndexes[1]]
            guard source.address == owner, source.signer, source.writable,
                  !recipient.signer, recipient.writable,
                  recipient.address != owner, recipient.address != systemProgram else {
                throw malformed("The Solana System transfer roles are invalid.")
            }
            return .nativeTransfer(
                recipient: recipient.address, amountBaseUnits: String(amount)
            )
        }
        if program == coreProgram {
            guard instruction.accountIndexes.count == 7,
                  instruction.data == Data([14, 0]) else {
                throw malformed("The Metaplex Core transfer is outside the standalone subset.")
            }
            let mapped = instruction.accountIndexes.map { accounts[$0] }
            guard mapped[0].writable, !mapped[0].signer,
                  mapped[1].address == coreProgram,
                  mapped[2].address == owner, mapped[2].signer,
                  mapped[3].address == coreProgram,
                  !mapped[4].writable, !mapped[4].signer,
                  mapped[5].address == coreProgram,
                  mapped[6].address == coreProgram,
                  mapped[0].address != owner,
                  mapped[4].address != owner,
                  mapped[0].address != mapped[4].address else {
                throw malformed("The Metaplex Core transfer roles are invalid.")
            }
            let assetID = WalletSolanaCollectibleIdentity(
                networkID: networkID, standard: .core,
                address: mapped[0].address
            ).canonicalID
            return .nftTransfer(
                assetID: assetID,
                tokenID: mapped[0].address,
                recipient: mapped[4].address
            )
        }
        return nil
    }

    private static func decodeSolanaTokenTransfer(
        _ instructions: [SolanaInstruction],
        accounts: [ResolvedSolanaAccount],
        networkID: String,
        owner: String,
        bundle: Bundle
    ) async throws -> WalletSemanticAction {
        guard (1...2).contains(instructions.count),
              let transfer = instructions.last,
              accounts[transfer.programIndex].address == tokenProgram,
              transfer.accountIndexes.count == 4,
              transfer.data.count == 10,
              transfer.data.first == 12,
              let amount = littleEndianUInt64(transfer.data, offset: 1), amount > 0
        else {
            throw malformed("Only one reviewed Solana transfer action is permitted.")
        }
        let source = accounts[transfer.accountIndexes[0]]
        let mint = accounts[transfer.accountIndexes[1]]
        let destination = accounts[transfer.accountIndexes[2]]
        let authority = accounts[transfer.accountIndexes[3]]
        guard source.writable, !source.signer,
              !mint.writable, !mint.signer,
              destination.writable, !destination.signer,
              authority.address == owner, authority.signer,
              Set([source.address, mint.address, destination.address, owner]).count == 4
        else {
            throw malformed("The SPL transfer account roles are invalid.")
        }
        let decimals = transfer.data[transfer.data.index(transfer.data.startIndex, offsetBy: 9)]
        let recipient: String
        if instructions.count == 2 {
            let creation = instructions[0]
            guard accounts[creation.programIndex].address == associatedTokenProgram,
                  creation.data == Data([1]),
                  creation.accountIndexes.count == 6 else {
                throw malformed("The associated-token setup is not idempotent and canonical.")
            }
            let mapped = creation.accountIndexes.map { accounts[$0].address }
            guard mapped[0] == owner,
                  mapped[1] == destination.address,
                  mapped[2] != owner,
                  mapped[3] == mint.address,
                  mapped[4] == systemProgram,
                  mapped[5] == tokenProgram else {
                throw malformed("The associated-token setup roles do not match the transfer.")
            }
            recipient = mapped[2]
        } else {
            guard let network = WalletNetworkCatalog.descriptor(id: networkID),
                  let configuration = WalletSolanaProviderConfiguration.bundled(
                    network: network, bundle: bundle
                  ) else {
                throw WalletProviderCoordinatorError.noProvider(networkID)
            }
            let coordinator = try WalletSolanaProviderCoordinator(
                network: network, configuration: configuration
            )
            let evidence = try await solanaTokenAccount(
                destination.address, coordinator: coordinator
            )
            guard evidence.mint == mint.address,
                  evidence.decimals == decimals,
                  evidence.programID == tokenProgram else {
                throw malformed("The destination token account does not match the transfer.")
            }
            recipient = evidence.owner
        }
        guard recipient != owner,
              let network = WalletNetworkCatalog.descriptor(id: networkID),
              let configuration = WalletSolanaProviderConfiguration.bundled(
                network: network, bundle: bundle
              ) else {
            throw WalletProviderCoordinatorError.noProvider(networkID)
        }
        let coordinator = try WalletSolanaProviderCoordinator(
            network: network, configuration: configuration
        )
        let sourceEvidence = try await solanaTokenAccount(
            source.address, coordinator: coordinator
        )
        guard sourceEvidence.owner == owner,
              sourceEvidence.mint == mint.address,
              sourceEvidence.decimals == decimals,
              sourceEvidence.programID == tokenProgram else {
            throw malformed("The source token account does not belong to the connected account.")
        }
        let identity = WalletSolanaAssetIdentity(
            networkID: networkID, program: .spl, mint: mint.address
        )
        return .fungibleTokenTransfer(
            assetID: identity.canonicalID,
            recipient: recipient,
            amountBaseUnits: String(amount)
        )
    }

    private static func solanaTokenAccount(
        _ address: String,
        coordinator: WalletSolanaProviderCoordinator
    ) async throws -> SolanaTokenAccountEvidence {
        let raw = try await coordinator.publicRead(
            method: "getAccountInfo",
            params: [address, ["commitment": "finalized", "encoding": "jsonParsed"]]
        )
        guard let envelope = raw as? [String: Any], envelope.count <= 4,
              let context = envelope["context"] as? [String: Any],
              unsigned(context["slot"]) != nil,
              let value = envelope["value"] as? [String: Any], value.count <= 8,
              value["owner"] as? String == tokenProgram,
              let data = value["data"] as? [String: Any], data.count <= 4,
              let parsed = data["parsed"] as? [String: Any], parsed.count <= 4,
              parsed["type"] as? String == "account",
              let info = parsed["info"] as? [String: Any], info.count <= 12,
              let owner = info["owner"] as? String,
              let mint = info["mint"] as? String,
              WalletSolanaBase58.decode(owner, exactLength: 32) != nil,
              WalletSolanaBase58.decode(mint, exactLength: 32) != nil,
              let amount = info["tokenAmount"] as? [String: Any], amount.count <= 8,
              let decimalsValue = unsigned(amount["decimals"]), decimalsValue <= 255
        else {
            throw malformed("A Solana token account response is malformed.")
        }
        return SolanaTokenAccountEvidence(
            address: address, owner: owner, mint: mint,
            decimals: UInt8(decimalsValue), programID: tokenProgram
        )
    }

    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.decimalValue >= 0,
              number.decimalValue == Decimal(number.uint64Value) else { return nil }
        return number.uint64Value
    }

    private static func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data[offset..<offset + 4].enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << UInt32($1.offset * 8)
        }
    }

    private static func littleEndianUInt64(_ data: Data, offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return data[offset..<offset + 8].enumerated().reduce(UInt64(0)) {
            $0 | UInt64($1.element) << UInt64($1.offset * 8)
        }
    }

    private static func evmAddress(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x")
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func evmAddressWord(_ word: String) -> String? {
        guard word.count == 64,
              word.prefix(24).allSatisfy({ $0 == "0" }),
              word.suffix(40).allSatisfy(\.isHexDigit),
              word.suffix(40).contains(where: { $0 != "0" }) else { return nil }
        return "0x" + String(word.suffix(40)).lowercased()
    }

    private static func evmUnsignedWord(_ word: String) -> String? {
        guard word.count == 64, word.allSatisfy(\.isHexDigit) else { return nil }
        return WalletEthereumQuantity.hexToDecimal("0x" + word)
    }

    private static func malformed(_ message: String) -> WalletGateway.Error {
        .invalidArguments(message)
    }

    private struct ByteReader {
        let data: Data
        var offset = 0

        var isAtEnd: Bool { offset == data.count }

        mutating func byte() throws -> UInt8 {
            guard offset < data.count else {
                throw WalletGateway.Error.invalidArguments(
                    "The Solana transaction is truncated."
                )
            }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func read(count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else {
                throw WalletGateway.Error.invalidArguments(
                    "The Solana transaction is truncated."
                )
            }
            defer { offset += count }
            return data.subdata(in: offset..<offset + count)
        }

        mutating func shortVector(maximum: Int) throws -> Int {
            let start = offset
            var result = 0
            var shift = 0
            for _ in 0..<3 {
                let value = try byte()
                result |= Int(value & 0x7f) << shift
                if value & 0x80 == 0 {
                    guard result <= maximum,
                          Self.encodeShortVector(result)
                            == data.subdata(in: start..<offset) else {
                        throw WalletGateway.Error.invalidArguments(
                            "A Solana compact length is non-canonical or excessive."
                        )
                    }
                    return result
                }
                shift += 7
            }
            throw WalletGateway.Error.invalidArguments(
                "A Solana compact length is malformed."
            )
        }

        mutating func uleb128(maximum: Int) throws -> Int {
            let start = offset
            var result: UInt64 = 0
            var shift: UInt64 = 0
            for _ in 0..<10 {
                let value = try byte()
                guard shift < 64,
                      value & 0x7f == 0
                        || UInt64(value & 0x7f) <= UInt64.max >> shift else {
                    throw WalletGateway.Error.invalidArguments(
                        "A Sui vector length overflows."
                    )
                }
                result |= UInt64(value & 0x7f) << shift
                if value & 0x80 == 0 {
                    guard result <= UInt64(maximum),
                          Self.encodeULEB128(result)
                            == data.subdata(in: start..<offset) else {
                        throw WalletGateway.Error.invalidArguments(
                            "A Sui vector length is non-canonical or excessive."
                        )
                    }
                    return Int(result)
                }
                shift += 7
            }
            throw WalletGateway.Error.invalidArguments(
                "A Sui vector length is malformed."
            )
        }

        mutating func uint64() throws -> UInt64? {
            let value = try read(count: 8)
            return WalletDappTransactionDecoder.littleEndianUInt64(
                value, offset: 0
            )
        }

        mutating func suiAddress() throws -> String {
            guard let value = WalletDappTransactionDecoder.suiAddress(
                try read(count: 32)
            ) else {
                throw WalletGateway.Error.invalidArguments(
                    "A Sui address is malformed."
                )
            }
            return value
        }

        mutating func suiObjectReference() throws -> SuiObjectReference {
            let objectID = try suiAddress()
            guard let version = try uint64(), version > 0 else {
                throw WalletGateway.Error.invalidArguments(
                    "A Sui object version is malformed."
                )
            }
            let digestCount = try uleb128(maximum: 32)
            guard digestCount == 32 else {
                throw WalletGateway.Error.invalidArguments(
                    "A Sui object digest is malformed."
                )
            }
            let digest = WalletSolanaBase58.encode(try read(count: 32))
            return SuiObjectReference(
                objectID: objectID, version: version, digest: digest
            )
        }

        mutating func suiArgument() throws -> SuiArgument {
            switch try byte() {
            case 0:
                return .gas
            case 1:
                return .input(try uint16())
            case 2:
                return .result(try uint16())
            case 3:
                return .nestedResult(try uint16(), try uint16())
            default:
                throw WalletGateway.Error.invalidArguments(
                    "A Sui command argument is malformed."
                )
            }
        }

        private mutating func uint16() throws -> UInt16 {
            let value = try read(count: 2)
            return UInt16(value[value.startIndex])
                | UInt16(value[value.index(after: value.startIndex)]) << 8
        }

        private static func encodeShortVector(_ value: Int) -> Data {
            var remaining = value
            var encoded = Data()
            repeat {
                var next = UInt8(remaining & 0x7f)
                remaining >>= 7
                if remaining != 0 { next |= 0x80 }
                encoded.append(next)
            } while remaining != 0
            return encoded
        }

        private static func encodeULEB128(_ value: UInt64) -> Data {
            var remaining = value
            var encoded = Data()
            repeat {
                var next = UInt8(remaining & 0x7f)
                remaining >>= 7
                if remaining != 0 { next |= 0x80 }
                encoded.append(next)
            } while remaining != 0
            return encoded
        }
    }
}
