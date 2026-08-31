import CryptoKit
import Foundation

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

struct WalletSolanaCanonicalSPLTransfer: Equatable, Sendable {
    static let associatedTokenProgramID =
        "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
    static let safeToken2022MintExtensions: Set<String> = [
        "metadataPointer", "tokenMetadata",
    ]
    static let safeToken2022AccountExtensions: Set<String> = [
        "immutableOwner",
    ]
    let feePayer: String
    let sourceTokenAccount: String
    let mint: String
    let destinationTokenAccount: String
    let recipientOwner: String
    let tokenProgramID: String
    let recentBlockhash: String
    let amount: UInt64
    let decimals: UInt8
    let createsDestinationAssociatedAccount: Bool
    let mintExtensions: [String]
    let sourceAccountExtensions: [String]
    let destinationAccountExtensions: [String]
    let message: Data
    let unsignedTransaction: Data
    let canonicalMessageDigest: String
    let resolvedAccountsDigest: String
    let associatedTokenCreationAccounts: [WalletSolanaResolvedAccount]

    init(
        feePayer: String,
        sourceTokenAccount: String,
        mint: String,
        destinationTokenAccount: String,
        recipientOwner: String,
        tokenProgramID: String,
        recentBlockhash: String,
        amountBaseUnits: String,
        decimals: Int,
        createsDestinationAssociatedAccount: Bool = false,
        mintExtensions: [String] = [],
        sourceAccountExtensions: [String] = [],
        destinationAccountExtensions: [String] = []
    ) throws {
        guard WalletSolanaTokenProgram.allCases.contains(where: {
                  $0.programID == tokenProgramID
              }),
              let payer = WalletSolanaBase58.decode(feePayer, exactLength: 32),
              let source = WalletSolanaBase58.decode(
                  sourceTokenAccount, exactLength: 32
              ),
              let mintBytes = WalletSolanaBase58.decode(mint, exactLength: 32),
              let destination = WalletSolanaBase58.decode(
                  destinationTokenAccount, exactLength: 32
              ),
              WalletSolanaBase58.decode(recipientOwner, exactLength: 32) != nil,
              let program = WalletSolanaBase58.decode(tokenProgramID, exactLength: 32),
              let blockhash = WalletSolanaBase58.decode(recentBlockhash, exactLength: 32),
              let amount = UInt64(amountBaseUnits), amount > 0,
              (0...255).contains(decimals),
              Set([
                  feePayer, sourceTokenAccount, mint, destinationTokenAccount,
                  recipientOwner, tokenProgramID, Self.associatedTokenProgramID,
              ]).count == 7 else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Solana token transfer requires distinct canonical accounts, a reviewed token program, a valid blockhash, and positive u64 units."
            )
        }
        let canonicalMintExtensions = Self.canonicalExtensions(mintExtensions)
        let canonicalSourceExtensions = Self.canonicalExtensions(
            sourceAccountExtensions
        )
        let canonicalDestinationExtensions = Self.canonicalExtensions(
            destinationAccountExtensions
        )
        guard canonicalMintExtensions == mintExtensions,
              canonicalSourceExtensions == sourceAccountExtensions,
              canonicalDestinationExtensions == destinationAccountExtensions else {
            throw WalletGateway.Error.invalidArguments(
                "Solana token extension evidence must be unique and canonical."
            )
        }
        if tokenProgramID == WalletSolanaTokenProgram.spl.programID {
            guard mintExtensions.isEmpty, sourceAccountExtensions.isEmpty,
                  destinationAccountExtensions.isEmpty else {
                throw WalletGateway.Error.invalidArguments(
                    "Classic SPL transfers cannot carry Token-2022 extension evidence."
                )
            }
        } else {
            guard Set(mintExtensions).isSubset(of: Self.safeToken2022MintExtensions),
                  Set(sourceAccountExtensions).isSubset(
                    of: Self.safeToken2022AccountExtensions
                  ),
                  Set(destinationAccountExtensions).isSubset(
                    of: Self.safeToken2022AccountExtensions
                  ),
                  !createsDestinationAssociatedAccount
                    || destinationAccountExtensions == ["immutableOwner"] else {
                throw WalletGateway.Error.invalidArguments(
                    "The Token-2022 extensions can change reviewed transfer semantics."
                )
            }
        }

        let creationAccounts: [WalletSolanaResolvedAccount]
        var message: Data
        if createsDestinationAssociatedAccount {
            guard let owner = WalletSolanaBase58.decode(
                      recipientOwner, exactLength: 32
                  ), let associatedProgram = WalletSolanaBase58.decode(
                      Self.associatedTokenProgramID, exactLength: 32
                  ) else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed associated-token accounts are malformed."
                )
            }
            message = Data([1, 0, 5])
            message.append(Self.shortVector(8))
            for account in [
                payer, source, destination, owner, mintBytes,
                Data(repeating: 0, count: 32), program, associatedProgram,
            ] {
                message.append(account)
            }
            message.append(blockhash)
            message.append(Self.shortVector(2))
            message.append(7)
            message.append(Self.shortVector(6))
            message.append(contentsOf: [0, 2, 3, 4, 5, 6])
            message.append(Self.shortVector(1))
            message.append(1)
            message.append(6)
            message.append(Self.shortVector(4))
            message.append(contentsOf: [1, 4, 2, 0])
            creationAccounts = [
                .init(
                    address: feePayer, isSigner: true, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                .init(
                    address: destinationTokenAccount, isSigner: false,
                    isWritable: true, lookupTableAddress: nil,
                    lookupTableSlot: nil
                ),
                .init(
                    address: recipientOwner, isSigner: false, isWritable: false,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                .init(
                    address: mint, isSigner: false, isWritable: false,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                .init(
                    address: WalletSolanaCanonicalNativeTransfer.systemProgramID,
                    isSigner: false, isWritable: false,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                .init(
                    address: tokenProgramID, isSigner: false, isWritable: false,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
            ]
        } else {
            message = Data([1, 0, 2])
            message.append(Self.shortVector(5))
            for account in [payer, source, destination, mintBytes, program] {
                message.append(account)
            }
            message.append(blockhash)
            message.append(Self.shortVector(1))
            message.append(4)
            message.append(Self.shortVector(4))
            message.append(contentsOf: [1, 3, 2, 0])
            creationAccounts = []
        }
        var instructionData = Data([12])
        instructionData.appendLittleEndian(amount)
        instructionData.append(UInt8(decimals))
        message.append(Self.shortVector(instructionData.count))
        message.append(instructionData)

        var transaction = Data([1])
        transaction.append(Data(repeating: 0, count: 64))
        transaction.append(message)
        self.feePayer = feePayer
        self.sourceTokenAccount = sourceTokenAccount
        self.mint = mint
        self.destinationTokenAccount = destinationTokenAccount
        self.recipientOwner = recipientOwner
        self.tokenProgramID = tokenProgramID
        self.recentBlockhash = recentBlockhash
        self.amount = amount
        self.decimals = UInt8(decimals)
        self.createsDestinationAssociatedAccount =
            createsDestinationAssociatedAccount
        self.mintExtensions = mintExtensions
        self.sourceAccountExtensions = sourceAccountExtensions
        self.destinationAccountExtensions = destinationAccountExtensions
        self.message = message
        unsignedTransaction = transaction
        canonicalMessageDigest = Self.sha256(message)
        resolvedAccountsDigest = Self.resolvedDigest(
            feePayer: feePayer, sourceTokenAccount: sourceTokenAccount,
            mint: mint, destinationTokenAccount: destinationTokenAccount,
            recipientOwner: recipientOwner, tokenProgramID: tokenProgramID,
            createsDestinationAssociatedAccount: createsDestinationAssociatedAccount,
            mintExtensions: mintExtensions,
            sourceAccountExtensions: sourceAccountExtensions,
            destinationAccountExtensions: destinationAccountExtensions
        )
        associatedTokenCreationAccounts = creationAccounts
    }

    static func resolvedDigest(
        feePayer: String,
        sourceTokenAccount: String,
        mint: String,
        destinationTokenAccount: String,
        recipientOwner: String,
        tokenProgramID: String,
        createsDestinationAssociatedAccount: Bool = false,
        mintExtensions: [String] = [],
        sourceAccountExtensions: [String] = [],
        destinationAccountExtensions: [String] = []
    ) -> String {
        var value =
            "legacy|\(tokenProgramID)|\(feePayer):signer:writable|\(sourceTokenAccount):nonsigner:writable|\(mint):nonsigner:readonly|\(destinationTokenAccount):nonsigner:writable|owner:\(recipientOwner)"
        if createsDestinationAssociatedAccount {
            value += "|create_ata:\(associatedTokenProgramID)"
        }
        if tokenProgramID == WalletSolanaTokenProgram.token2022.programID {
            value += "|mint_exts:\(mintExtensions.joined(separator: ","))"
            value += "|source_exts:\(sourceAccountExtensions.joined(separator: ","))"
            value += "|destination_exts:\(destinationAccountExtensions.joined(separator: ","))"
        }
        return sha256(Data(value.utf8))
    }

    static func canonicalExtensions(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func shortVector(_ value: Int) -> Data {
        precondition((0...127).contains(value))
        return Data([UInt8(value)])
    }

    private static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
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
        feePayer: String,
        recipientAssociatedTokenAddress: String? = nil
    ) async throws -> WalletSolanaPreparationPacket {
        switch request.action.type {
        case .nativeTransfer:
            return try await prepareNative(request: request, feePayer: feePayer)
        case .fungibleTokenTransfer:
            return try await prepareSPLTransfer(
                request: request, feePayer: feePayer,
                recipientAssociatedTokenAddress: recipientAssociatedTokenAddress
            )
        default:
            throw WalletGateway.Error.invalidArguments(
                "That Solana semantic action has no reviewed provider adapter."
            )
        }
    }

    private func prepareNative(
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

    private func prepareSPLTransfer(
        request: WalletPrepareRequest,
        feePayer: String,
        recipientAssociatedTokenAddress: String?
    ) async throws -> WalletSolanaPreparationPacket {
        let action = request.action
        guard request.networkID == network.id,
              action.type == .fungibleTokenTransfer,
              let assetID = action.assetID,
              let identity = WalletSolanaAssetIdentity.parse(assetID),
              identity.networkID == network.id,
              action.tokenID == nil, action.inputAssetID == nil,
              action.outputAssetID == nil, action.minimumOutputBaseUnits == nil,
              action.adapterID == nil, action.authorizationFormat == nil,
              action.metadataDigest == nil, action.contractID == nil,
              action.function == nil, action.arguments.isEmpty,
              action.valueBaseUnits == nil,
              let recipient = action.recipient,
              WalletSolanaBase58.decode(recipient, exactLength: 32) != nil,
              recipient != feePayer,
              let amountText = action.amountBaseUnits,
              let amount = UInt64(amountText), amount > 0,
              String(amount) == amountText else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Solana token adapter accepts only canonical transfers."
            )
        }
        let genesisHash = try await verifiedGenesisHash()
        let mintState = try await mintEvidence(identity: identity)
        let decimals = mintState.decimals
        try requireSafeTransferExtensions(
            program: identity.program, mint: mintState.extensions,
            source: [], destination: [], validateAccounts: false
        )
        let sourceAccounts = try await tokenAccounts(owner: feePayer).filter {
            $0.identity == identity && $0.state == "initialized" && !$0.isNative
                && WalletBaseUnits.lessThanOrEqual(amountText, $0.amountBaseUnits)
                && $0.decimals == decimals
                && Self.isSafeTransferAccountExtensions(
                    $0.extensions, program: identity.program
                )
        }
        guard let source = sourceAccounts.sorted(by: { $0.address < $1.address }).first else {
            throw WalletGateway.Error.invalidArguments(
                "No single initialized SPL token account has enough balance for this transfer."
            )
        }
        guard let associatedAddress = recipientAssociatedTokenAddress,
              WalletSolanaBase58.decode(associatedAddress, exactLength: 32) != nil,
              ![feePayer, source.address, identity.mint, recipient,
                 identity.program.programID].contains(associatedAddress) else {
            throw WalletGateway.Error.invalidArguments(
                "The signer did not provide a valid recipient associated token address."
            )
        }
        let destinationAccounts = try await tokenAccounts(owner: recipient).filter {
            $0.identity == identity && $0.state == "initialized" && !$0.isNative
                && $0.decimals == decimals
                && Self.isSafeTransferAccountExtensions(
                    $0.extensions, program: identity.program
                )
        }
        let destination: WalletSolanaTokenAccount
        let createDestinationAssociatedAccount: Bool
        if let existing = destinationAccounts.first(where: {
            $0.address == associatedAddress
        }) {
            destination = existing
            createDestinationAssociatedAccount = false
        } else {
            try await requireUnallocatedAccount(address: associatedAddress)
            destination = WalletSolanaTokenAccount(
                address: associatedAddress, owner: recipient, identity: identity,
                amountBaseUnits: "0", decimals: decimals,
                state: "initialized", isNative: false,
                extensions: identity.program == .token2022
                    ? ["immutableOwner"] : []
            )
            createDestinationAssociatedAccount = true
        }
        try requireSafeTransferExtensions(
            program: identity.program, mint: mintState.extensions,
            source: source.extensions, destination: destination.extensions,
            validateAccounts: true
        )
        let latest = try await latestBlockhash()
        let transfer = try WalletSolanaCanonicalSPLTransfer(
            feePayer: feePayer, sourceTokenAccount: source.address,
            mint: identity.mint, destinationTokenAccount: destination.address,
            recipientOwner: recipient, tokenProgramID: identity.program.programID,
            recentBlockhash: latest.blockhash, amountBaseUnits: amountText,
            decimals: decimals,
            createsDestinationAssociatedAccount: createDestinationAssociatedAccount,
            mintExtensions: mintState.extensions,
            sourceAccountExtensions: source.extensions,
            destinationAccountExtensions: destination.extensions
        )
        let fee = try await feeForMessage(transfer.message)
        guard WalletBaseUnits.lessThanOrEqual(fee, request.maximumFeeBaseUnits) else {
            throw WalletGateway.Error.policyDenied(
                "The Solana network fee exceeds the requested fee ceiling."
            )
        }
        let simulation = try await simulate(transfer.unsignedTransaction)
        let adapterID = identity.program == .token2022
            ? WalletReviewedAdapters.solanaToken2022TransferChecked
            : WalletReviewedAdapters.solanaSPLTransferChecked
        var transferArguments: [String: String] = [
            "amount": amountText,
            "asset_id": assetID,
            "decimals": String(decimals),
            "destination_owner": recipient,
            "destination_token_account": destination.address,
            "mint": identity.mint,
            "source_token_account": source.address,
        ]
        if identity.program == .token2022 {
            transferArguments["mint_extensions"] = mintState.extensions.joined(
                separator: ","
            )
            transferArguments["source_extensions"] = source.extensions.joined(
                separator: ","
            )
            transferArguments["destination_extensions"] =
                destination.extensions.joined(separator: ",")
        }
        let transferInstruction = WalletSolanaReviewedInstruction(
            programID: identity.program.programID,
            adapterID: adapterID,
            semanticOperation: WalletActionKind.fungibleTokenTransfer.rawValue,
            accounts: [
                .init(
                    address: feePayer, isSigner: true, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                .init(
                    address: source.address, isSigner: false, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                .init(
                    address: identity.mint, isSigner: false, isWritable: false,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                .init(
                    address: destination.address, isSigner: false, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
            ],
            canonicalArguments: transferArguments
        )
        var instructions: [WalletSolanaReviewedInstruction] = []
        if createDestinationAssociatedAccount {
            instructions.append(WalletSolanaReviewedInstruction(
                programID: WalletSolanaCanonicalSPLTransfer.associatedTokenProgramID,
                adapterID: WalletReviewedAdapters.solanaAssociatedTokenCreateIdempotent,
                semanticOperation: "create_associated_token_account_idempotent",
                accounts: transfer.associatedTokenCreationAccounts,
                canonicalArguments: [
                    "associated_token_account": destination.address,
                    "destination_owner": recipient,
                    "mint": identity.mint,
                    "token_program_id": identity.program.programID,
                ]
            ))
        }
        instructions.append(transferInstruction)
        return WalletSolanaPreparationPacket(
            request: request, genesisHash: genesisHash, version: .legacy,
            recentBlockhash: latest.blockhash,
            lastValidBlockHeight: latest.lastValidBlockHeight,
            contextSlot: latest.contextSlot, feePayer: feePayer,
            priorityFeeBaseUnits: "0", feeQuoteBaseUnits: fee,
            maximumFeeBaseUnits: request.maximumFeeBaseUnits,
            canonicalMessageDigest: transfer.canonicalMessageDigest,
            resolvedAccountsDigest: transfer.resolvedAccountsDigest,
            instructions: instructions, simulation: simulation,
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
        let message: Data
        let unsignedTransaction: Data
        let canonicalDigest: String
        let resolvedDigest: String
        switch packet.request.action.type {
        case .nativeTransfer:
            let transaction = try WalletSolanaCanonicalNativeTransfer(
                feePayer: packet.feePayer,
                recipient: packet.request.action.recipient ?? "",
                recentBlockhash: packet.recentBlockhash,
                amountBaseUnits: packet.request.action.amountBaseUnits ?? ""
            )
            message = transaction.message
            unsignedTransaction = transaction.unsignedTransaction
            canonicalDigest = transaction.canonicalMessageDigest
            resolvedDigest = transaction.resolvedAccountsDigest
        case .fungibleTokenTransfer:
            let action = packet.request.action
            guard let assetID = action.assetID,
                  let identity = WalletSolanaAssetIdentity.parse(assetID),
                  identity.networkID == network.id,
                  let recipient = action.recipient,
                  let amount = action.amountBaseUnits,
                  (1...2).contains(packet.instructions.count),
                  let instruction = packet.instructions.last,
                  instruction.programID == identity.program.programID,
                  let sourceAddress = instruction.canonicalArguments[
                      "source_token_account"
                  ],
                  let destinationAddress = instruction.canonicalArguments[
                      "destination_token_account"
                  ],
                  let decimalsText = instruction.canonicalArguments["decimals"],
                  let decimals = Int(decimalsText), (0...255).contains(decimals) else {
                throw WalletRPCError.simulation("the reviewed SPL evidence is incomplete")
            }
            let expectedAdapterID = identity.program == .token2022
                ? WalletReviewedAdapters.solanaToken2022TransferChecked
                : WalletReviewedAdapters.solanaSPLTransferChecked
            guard instruction.adapterID == expectedAdapterID else {
                throw WalletRPCError.simulation("the reviewed token adapter changed")
            }
            let boundMintExtensions = try Self.canonicalExtensionArgument(
                instruction.canonicalArguments["mint_extensions"],
                required: identity.program == .token2022
            )
            let boundSourceExtensions = try Self.canonicalExtensionArgument(
                instruction.canonicalArguments["source_extensions"],
                required: identity.program == .token2022
            )
            let boundDestinationExtensions = try Self.canonicalExtensionArgument(
                instruction.canonicalArguments["destination_extensions"],
                required: identity.program == .token2022
            )
            try requireSafeTransferExtensions(
                program: identity.program, mint: boundMintExtensions,
                source: boundSourceExtensions,
                destination: boundDestinationExtensions,
                validateAccounts: true
            )
            let currentMint = try await mintEvidence(identity: identity)
            guard currentMint.decimals == decimals,
                  currentMint.extensions == boundMintExtensions else {
                throw WalletRPCError.simulation("the SPL mint decimals changed")
            }
            let sources = try await tokenAccounts(owner: packet.feePayer)
            let destinations = try await tokenAccounts(owner: recipient)
            guard sources.contains(where: {
                $0.address == sourceAddress && $0.identity == identity
                    && $0.state == "initialized" && !$0.isNative
                    && $0.decimals == decimals
                    && $0.extensions == boundSourceExtensions
                    && WalletBaseUnits.lessThanOrEqual(amount, $0.amountBaseUnits)
            }) else {
                throw WalletRPCError.simulation(
                    "the SPL source account evidence changed"
                )
            }
            let createsDestinationAssociatedAccount = packet.instructions.count == 2
            let destinationIsValid = destinations.contains(where: {
                $0.address == destinationAddress && $0.identity == identity
                    && $0.state == "initialized" && !$0.isNative
                    && $0.decimals == decimals
                    && $0.extensions == boundDestinationExtensions
            })
            if createsDestinationAssociatedAccount {
                guard let creation = packet.instructions.first,
                      creation.programID
                        == WalletSolanaCanonicalSPLTransfer.associatedTokenProgramID,
                      creation.adapterID
                        == WalletReviewedAdapters.solanaAssociatedTokenCreateIdempotent,
                      creation.semanticOperation
                        == "create_associated_token_account_idempotent" else {
                    throw WalletRPCError.simulation(
                        "the associated-token creation evidence changed"
                    )
                }
                if !destinationIsValid {
                    try await requireUnallocatedAccount(address: destinationAddress)
                }
            } else if !destinationIsValid {
                throw WalletRPCError.simulation(
                    "the SPL destination account evidence changed"
                )
            }
            let transaction = try WalletSolanaCanonicalSPLTransfer(
                feePayer: packet.feePayer,
                sourceTokenAccount: sourceAddress, mint: identity.mint,
                destinationTokenAccount: destinationAddress,
                recipientOwner: recipient,
                tokenProgramID: identity.program.programID,
                recentBlockhash: packet.recentBlockhash,
                amountBaseUnits: amount, decimals: decimals,
                createsDestinationAssociatedAccount:
                    createsDestinationAssociatedAccount,
                mintExtensions: boundMintExtensions,
                sourceAccountExtensions: boundSourceExtensions,
                destinationAccountExtensions: boundDestinationExtensions
            )
            let expectedTransferAccounts = [
                WalletSolanaResolvedAccount(
                    address: packet.feePayer, isSigner: true, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                WalletSolanaResolvedAccount(
                    address: sourceAddress, isSigner: false, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                WalletSolanaResolvedAccount(
                    address: identity.mint, isSigner: false, isWritable: false,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                WalletSolanaResolvedAccount(
                    address: destinationAddress, isSigner: false, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
            ]
            var expectedArguments: [String: String] = [
                "amount": amount,
                "asset_id": assetID,
                "decimals": String(decimals),
                "destination_owner": recipient,
                "destination_token_account": destinationAddress,
                "mint": identity.mint,
                "source_token_account": sourceAddress,
            ]
            if identity.program == .token2022 {
                expectedArguments["mint_extensions"] =
                    boundMintExtensions.joined(separator: ",")
                expectedArguments["source_extensions"] =
                    boundSourceExtensions.joined(separator: ",")
                expectedArguments["destination_extensions"] =
                    boundDestinationExtensions.joined(separator: ",")
            }
            guard instruction.semanticOperation
                    == WalletActionKind.fungibleTokenTransfer.rawValue,
                  instruction.accounts == expectedTransferAccounts,
                  instruction.canonicalArguments == expectedArguments else {
                throw WalletRPCError.simulation(
                    "the reviewed SPL instruction roles or arguments changed"
                )
            }
            if createsDestinationAssociatedAccount {
                guard let creation = packet.instructions.first,
                      creation.accounts == transaction.associatedTokenCreationAccounts,
                      creation.canonicalArguments == [
                        "associated_token_account": destinationAddress,
                        "destination_owner": recipient,
                        "mint": identity.mint,
                        "token_program_id": identity.program.programID,
                      ] else {
                    throw WalletRPCError.simulation(
                        "the associated-token account roles or arguments changed"
                    )
                }
            }
            message = transaction.message
            unsignedTransaction = transaction.unsignedTransaction
            canonicalDigest = transaction.canonicalMessageDigest
            resolvedDigest = transaction.resolvedAccountsDigest
        default:
            throw WalletRPCError.simulation("the Solana adapter is not reviewed")
        }
        guard canonicalDigest == packet.canonicalMessageDigest,
              resolvedDigest == packet.resolvedAccountsDigest else {
            throw WalletRPCError.simulation(
                "the prepared Solana message or resolved accounts changed"
            )
        }
        let fee = try await feeForMessage(message)
        guard WalletBaseUnits.lessThanOrEqual(fee, packet.maximumFeeBaseUnits) else {
            throw WalletRPCError.simulation("the refreshed Solana fee exceeds its ceiling")
        }
        let simulation = try await simulate(unsignedTransaction)
        return WalletSolanaRecheckPacket(
            intentID: intentID, genesisHash: genesisHash,
            currentBlockHeight: currentBlockHeight,
            resolvedAccountsDigest: resolvedDigest,
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

    func tokenAccounts(owner: String) async throws -> [WalletSolanaTokenAccount] {
        guard WalletSolanaBase58.decode(owner, exactLength: 32) != nil else {
            throw WalletGateway.Error.invalidArguments("The Solana owner address is malformed.")
        }
        _ = try await verifiedGenesisHash()
        var accounts: [WalletSolanaTokenAccount] = []
        var seenAddresses: Set<String> = []
        for program in WalletSolanaTokenProgram.allCases {
            let result = try await dictionaryResult(
                method: "getTokenAccountsByOwner",
                params: [
                    owner,
                    ["programId": program.programID],
                    ["commitment": "confirmed", "encoding": "jsonParsed"],
                ]
            )
            guard let context = result["context"] as? [String: Any],
                  Self.unsigned(context["slot"]) != nil,
                  let values = result["value"] as? [Any],
                  accounts.count + values.count <= 10_000 else {
                throw WalletRPCError.invalidResponse(
                    "getTokenAccountsByOwner returned malformed or excessive data"
                )
            }
            for value in values {
                let account = try parseTokenAccount(
                    value, expectedOwner: owner, program: program
                )
                guard seenAddresses.insert(account.address).inserted else {
                    throw WalletRPCError.invalidResponse(
                        "getTokenAccountsByOwner returned a duplicate account"
                    )
                }
                accounts.append(account)
            }
        }
        return accounts.sorted { $0.address < $1.address }
    }

    func tokenBalance(
        identity: WalletSolanaAssetIdentity,
        owner: String
    ) async throws -> String {
        guard identity.networkID == network.id else {
            throw WalletGateway.Error.invalidArguments(
                "The token identity belongs to another Solana network."
            )
        }
        let matches = try await tokenAccounts(owner: owner).filter {
            $0.identity == identity
        }
        guard !matches.isEmpty else { return "0" }
        var total = "0"
        for account in matches {
            guard let next = WalletBaseUnits.add(total, account.amountBaseUnits) else {
                throw WalletRPCError.invalidResponse("token balance overflowed wallet bounds")
            }
            total = next
        }
        return total
    }

    /// Reads Digital Asset Standard holdings as untrusted public metadata.
    /// Nothing returned here grants transfer authority; every unknown item
    /// enters quarantine until the user explicitly trusts it or a signed
    /// review manifest curates it.
    func collectibles(owner: String) async throws -> [WalletSolanaCollectible] {
        guard WalletSolanaBase58.decode(owner, exactLength: 32) != nil else {
            throw WalletGateway.Error.invalidArguments(
                "The Solana owner address is malformed."
            )
        }
        _ = try await verifiedGenesisHash()
        let limit = 100
        var page = 1
        var collected: [WalletSolanaCollectible] = []
        var seen: Set<String> = []
        var expectedTotal: UInt64?
        var observedItemCount: UInt64 = 0
        while page <= 100 {
            let result = try await dictionaryResult(
                method: "getAssetsByOwner",
                params: [[
                    "ownerAddress": owner,
                    "page": page,
                    "limit": limit,
                    "displayOptions": [
                        "showCollectionMetadata": true,
                        "showFungible": false,
                        "showNativeBalance": false,
                        "showUnverifiedCollections": true,
                    ],
                ]]
            )
            guard let total = Self.unsigned(result["total"]), total <= 10_000,
                  Self.unsigned(result["page"]) == UInt64(page),
                  Self.unsigned(result["limit"]) == UInt64(limit),
                  let items = result["items"] as? [Any], items.count <= limit else {
                throw WalletRPCError.invalidResponse(
                    "getAssetsByOwner returned invalid pagination evidence"
                )
            }
            guard expectedTotal == nil || expectedTotal == total,
                  observedItemCount + UInt64(items.count) <= total else {
                throw WalletRPCError.invalidResponse(
                    "getAssetsByOwner changed its pagination boundary"
                )
            }
            expectedTotal = total
            observedItemCount += UInt64(items.count)
            for item in items {
                guard let collectible = try? parseCollectible(
                    item, expectedOwner: owner
                ) else { continue }
                guard seen.insert(collectible.id).inserted else {
                    throw WalletRPCError.invalidResponse(
                        "getAssetsByOwner returned a duplicate asset"
                    )
                }
                collected.append(collectible)
            }
            if observedItemCount == total { break }
            guard items.count == limit else {
                throw WalletRPCError.invalidResponse(
                    "getAssetsByOwner truncated a holdings page"
                )
            }
            page += 1
        }
        guard let expectedTotal, observedItemCount == expectedTotal else {
            throw WalletRPCError.invalidResponse(
                "getAssetsByOwner exceeded the bounded holdings window"
            )
        }
        return collected.sorted { $0.id < $1.id }
    }

    private func parseCollectible(
        _ value: Any,
        expectedOwner: String
    ) throws -> WalletSolanaCollectible {
        guard let item = value as? [String: Any], item.count <= 32,
              let address = item["id"] as? String,
              WalletSolanaBase58.decode(address, exactLength: 32) != nil,
              let interface = item["interface"] as? String,
              let ownership = item["ownership"] as? [String: Any],
              ownership["owner"] as? String == expectedOwner,
              ownership["ownership_model"] as? String == "single",
              let frozen = ownership["frozen"] as? Bool,
              let delegated = ownership["delegated"] as? Bool,
              item["burnt"] as? Bool == false,
              let compression = item["compression"] as? [String: Any],
              let compressed = compression["compressed"] as? Bool else {
            throw WalletRPCError.invalidResponse(
                "The DAS collectible identity or ownership is malformed."
            )
        }
        let tokenMetadataInterfaces = ["V1_NFT", "V2_NFT", "ProgrammableNFT"]
        let standard: WalletSolanaCollectibleStandard
        if compressed {
            guard tokenMetadataInterfaces.contains(interface),
                  Self.validCompressedEvidence(compression) else {
                throw WalletRPCError.invalidResponse(
                    "The compressed collectible proof identity is malformed."
                )
            }
            standard = .bubblegum
        } else if interface == "MplCoreAsset" {
            standard = .core
        } else if tokenMetadataInterfaces.contains(interface) {
            standard = .tokenMetadata
        } else {
            throw WalletRPCError.invalidResponse(
                "The DAS interface is not a reviewed collectible standard."
            )
        }

        let content = item["content"] as? [String: Any]
        let metadata = content?["metadata"] as? [String: Any]
        let fallback = "Collectible \(address.prefix(4))…\(address.suffix(4))"
        let name = Self.safeMetadataText(
            metadata?["name"], maximumLength: 128
        ) ?? fallback
        let symbol = Self.safeMetadataText(
            metadata?["symbol"], maximumLength: 32
        ) ?? "NFT"
        let metadataURL = Self.safeHTTPSURL(content?["json_uri"])
        let rasterImageURL = Self.safeRasterImageURL(content?["files"])
        let collectionAddress = try Self.collectionAddress(item["grouping"])
        let identity = WalletSolanaCollectibleIdentity(
            networkID: network.id, standard: standard, address: address
        )
        return WalletSolanaCollectible(
            identity: identity, name: name, symbol: symbol,
            collectionAddress: collectionAddress, metadataURL: metadataURL,
            rasterImageURL: rasterImageURL, frozen: frozen,
            delegated: delegated
        )
    }

    private static func validCompressedEvidence(_ value: [String: Any]) -> Bool {
        guard let tree = value["tree"] as? String,
              WalletSolanaBase58.decode(tree, exactLength: 32) != nil,
              unsigned(value["leaf_id"]) != nil else { return false }
        for key in ["data_hash", "creator_hash", "asset_hash"] {
            guard let hash = value[key] as? String,
                  WalletSolanaBase58.decode(hash, exactLength: 32) != nil else {
                return false
            }
        }
        return true
    }

    private static func collectionAddress(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let groups = value as? [Any], groups.count <= 64 else {
            throw WalletRPCError.invalidResponse(
                "The collectible collection metadata is malformed."
            )
        }
        var collection: String?
        for raw in groups {
            guard let group = raw as? [String: Any],
                  let key = group["group_key"] as? String,
                  let address = group["group_value"] as? String else {
                throw WalletRPCError.invalidResponse(
                    "The collectible grouping is malformed."
                )
            }
            if key == "collection" {
                guard collection == nil,
                      WalletSolanaBase58.decode(address, exactLength: 32) != nil else {
                    throw WalletRPCError.invalidResponse(
                        "The collectible collection identity is ambiguous."
                    )
                }
                collection = address
            }
        }
        return collection
    }

    private static func safeMetadataText(
        _ value: Any?, maximumLength: Int
    ) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength,
              !trimmed.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return trimmed
    }

    private static func safeHTTPSURL(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count <= 2_048,
              let url = URL(string: value), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.host != nil else {
            return nil
        }
        return url.absoluteString
    }

    private static func safeRasterImageURL(_ value: Any?) -> String? {
        guard let files = value as? [Any], files.count <= 64 else { return nil }
        let allowed = Set([
            "image/png", "image/jpeg", "image/webp", "image/avif",
        ])
        for raw in files {
            guard let file = raw as? [String: Any],
                  let mime = file["mime"] as? String,
                  allowed.contains(mime.lowercased()),
                  let url = safeHTTPSURL(file["uri"]) else { continue }
            return url
        }
        return nil
    }

    private func mintEvidence(
        identity: WalletSolanaAssetIdentity
    ) async throws -> (decimals: Int, extensions: [String]) {
        guard identity.networkID == network.id else {
            throw WalletGateway.Error.invalidArguments(
                "The token mint belongs to another Solana network."
            )
        }
        _ = try await verifiedGenesisHash()
        let result = try await dictionaryResult(
            method: "getAccountInfo",
            params: [
                identity.mint,
                ["commitment": "confirmed", "encoding": "jsonParsed"],
            ]
        )
        guard let context = result["context"] as? [String: Any],
              Self.unsigned(context["slot"]) != nil,
              let account = result["value"] as? [String: Any],
              account["owner"] as? String == identity.program.programID,
              account["executable"] as? Bool == false,
              Self.unsigned(account["lamports"]) != nil,
              let data = account["data"] as? [String: Any],
              data["program"] as? String == identity.program.parsedProgramName,
              let parsed = data["parsed"] as? [String: Any],
              parsed["type"] as? String == "mint",
              let info = parsed["info"] as? [String: Any],
              info["isInitialized"] as? Bool == true,
              let number = info["decimals"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.decimalValue >= 0,
              number.decimalValue == Decimal(number.intValue),
              (0...255).contains(number.intValue) else {
            throw WalletRPCError.invalidResponse(
                "getAccountInfo returned an invalid Solana token mint"
            )
        }
        return (
            decimals: number.intValue,
            extensions: try Self.parsedExtensions(info: info)
        )
    }

    private func requireSafeTransferExtensions(
        program: WalletSolanaTokenProgram,
        mint: [String],
        source: [String],
        destination: [String],
        validateAccounts: Bool
    ) throws {
        if program == .spl {
            guard mint.isEmpty, source.isEmpty, destination.isEmpty else {
                throw WalletRPCError.invalidResponse(
                    "Classic SPL accounts returned unexpected extension evidence."
                )
            }
            return
        }
        guard Set(mint).isSubset(
                  of: WalletSolanaCanonicalSPLTransfer.safeToken2022MintExtensions
              ), !validateAccounts || (
                Self.isSafeTransferAccountExtensions(source, program: program)
                    && Self.isSafeTransferAccountExtensions(
                        destination, program: program
                    )
              ) else {
            throw WalletGateway.Error.policyDenied(
                "This Token-2022 mint or account uses extensions that change reviewed transfer semantics."
            )
        }
    }

    private static func isSafeTransferAccountExtensions(
        _ extensions: [String],
        program: WalletSolanaTokenProgram
    ) -> Bool {
        if program == .spl { return extensions.isEmpty }
        return Set(extensions).isSubset(
            of: WalletSolanaCanonicalSPLTransfer.safeToken2022AccountExtensions
        )
    }

    private static func parsedExtensions(info: [String: Any]) throws -> [String] {
        guard let raw = info["extensions"] else { return [] }
        guard let values = raw as? [Any], values.count <= 64 else {
            throw WalletRPCError.invalidResponse(
                "The token extension list is malformed or excessive."
            )
        }
        var extensions: [String] = []
        for value in values {
            guard let keyed = value as? [String: Any],
                  let name = keyed["extension"] as? String,
                  validExtensionName(name) else {
                throw WalletRPCError.invalidResponse(
                    "The token extension evidence is malformed."
                )
            }
            extensions.append(name)
        }
        let canonical = WalletSolanaCanonicalSPLTransfer.canonicalExtensions(
            extensions
        )
        guard canonical.count == extensions.count else {
            throw WalletRPCError.invalidResponse(
                "The token extension evidence contains duplicates."
            )
        }
        return canonical
    }

    private static func canonicalExtensionArgument(
        _ value: String?,
        required: Bool
    ) throws -> [String] {
        if !required {
            guard value == nil else {
                throw WalletRPCError.simulation(
                    "Classic SPL evidence gained Token-2022 extensions."
                )
            }
            return []
        }
        guard let value else {
            throw WalletRPCError.simulation(
                "Token-2022 extension evidence is missing."
            )
        }
        let parsed = value.isEmpty ? [] : value.split(
            separator: ",", omittingEmptySubsequences: false
        ).map(String.init)
        guard parsed.allSatisfy(validExtensionName),
              parsed == WalletSolanaCanonicalSPLTransfer.canonicalExtensions(
                parsed
              ) else {
            throw WalletRPCError.simulation(
                "Token-2022 extension evidence is not canonical."
            )
        }
        return parsed
    }

    private static func validExtensionName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0)
        }
    }

    private func requireUnallocatedAccount(address: String) async throws {
        let result = try await dictionaryResult(
            method: "getAccountInfo",
            params: [
                address,
                ["commitment": "confirmed", "encoding": "base64"],
            ]
        )
        guard let context = result["context"] as? [String: Any],
              Self.unsigned(context["slot"]) != nil,
              result["value"] is NSNull else {
            throw WalletRPCError.invalidResponse(
                "The derived associated token address is already occupied by an unverified account."
            )
        }
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

    private func parseTokenAccount(
        _ value: Any,
        expectedOwner: String,
        program: WalletSolanaTokenProgram
    ) throws -> WalletSolanaTokenAccount {
        guard let keyed = value as? [String: Any],
              let address = keyed["pubkey"] as? String,
              WalletSolanaBase58.decode(address, exactLength: 32) != nil,
              let account = keyed["account"] as? [String: Any],
              account["owner"] as? String == program.programID,
              account["executable"] as? Bool == false,
              Self.unsigned(account["lamports"]) != nil,
              let data = account["data"] as? [String: Any],
              data["program"] as? String == program.parsedProgramName,
              let parsed = data["parsed"] as? [String: Any],
              parsed["type"] as? String == "account",
              let info = parsed["info"] as? [String: Any],
              info["owner"] as? String == expectedOwner,
              let mint = info["mint"] as? String,
              WalletSolanaBase58.decode(mint, exactLength: 32) != nil,
              let state = info["state"] as? String,
              ["initialized", "frozen"].contains(state),
              let tokenAmount = info["tokenAmount"] as? [String: Any],
              let rawAmount = tokenAmount["amount"] as? String,
              let amount = WalletBaseUnits.normalize(rawAmount),
              UInt64(amount) != nil, amount == rawAmount,
              let decimalNumber = tokenAmount["decimals"] as? NSNumber,
              CFGetTypeID(decimalNumber) != CFBooleanGetTypeID(),
              decimalNumber.decimalValue >= 0,
              decimalNumber.decimalValue == Decimal(decimalNumber.intValue),
              (0...255).contains(decimalNumber.intValue) else {
            throw WalletRPCError.invalidResponse(
                "getTokenAccountsByOwner returned an invalid parsed token account"
            )
        }
        let isNative: Bool
        if let value = info["isNative"] {
            guard let parsed = value as? Bool else {
                throw WalletRPCError.invalidResponse(
                    "getTokenAccountsByOwner returned an invalid native-token flag"
                )
            }
            isNative = parsed
        } else {
            isNative = false
        }
        let identity = WalletSolanaAssetIdentity(
            networkID: network.id, program: program, mint: mint
        )
        let extensions = try Self.parsedExtensions(info: info)
        return WalletSolanaTokenAccount(
            address: address, owner: expectedOwner, identity: identity,
            amountBaseUnits: amount, decimals: decimalNumber.intValue,
            state: state, isNative: isNative, extensions: extensions
        )
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
                    "the reviewed Solana transaction produced unexpected inner instructions"
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
            return "Reviewed Solana simulation succeeded; \(units) compute units"
        }
        return "Reviewed Solana simulation succeeded"
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
        feePayer: String,
        recipientAssociatedTokenAddress: String?
    ) async throws -> WalletSolanaPreparationPacket {
        let packet: WalletSolanaPreparationPacket
        do {
            packet = try await primary.prepare(
                request: request, feePayer: feePayer,
                recipientAssociatedTokenAddress: recipientAssociatedTokenAddress
            )
        }
        catch {
            guard let fallback else { throw error }
            return try await fallback.prepare(
                request: request, feePayer: feePayer,
                recipientAssociatedTokenAddress: recipientAssociatedTokenAddress
            )
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

    func tokenAccounts(owner: String) async throws -> [WalletSolanaTokenAccount] {
        do { return try await primary.tokenAccounts(owner: owner) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.tokenAccounts(owner: owner)
        }
    }

    func tokenBalance(
        identity: WalletSolanaAssetIdentity,
        owner: String
    ) async throws -> String {
        do { return try await primary.tokenBalance(identity: identity, owner: owner) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.tokenBalance(identity: identity, owner: owner)
        }
    }

    func collectibles(owner: String) async throws -> [WalletSolanaCollectible] {
        do { return try await primary.collectibles(owner: owner) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.collectibles(owner: owner)
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
