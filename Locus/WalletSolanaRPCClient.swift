import CryptoKit
import Foundation

private enum WalletSolanaComputeBudget {
    static let programID = "ComputeBudget111111111111111111111111111111"
    static let maximumUnits: UInt32 = 1_400_000

    static func validate(limit: UInt32?, price: UInt64?) throws -> Bool {
        guard (limit == nil) == (price == nil) else {
            throw WalletGateway.Error.invalidArguments(
                "Solana compute-unit limit and price must be bound together."
            )
        }
        guard let limit else { return false }
        guard limit > 0, limit <= maximumUnits else {
            throw WalletGateway.Error.invalidArguments(
                "The Solana compute-unit limit is outside the reviewed range."
            )
        }
        return true
    }

    static func appendInstructions(
        limit: UInt32,
        price: UInt64,
        programIndex: UInt8,
        to message: inout Data
    ) {
        message.append(programIndex)
        message.append(0)
        message.append(5)
        message.append(2)
        message.appendLittleEndian(limit)
        message.append(programIndex)
        message.append(0)
        message.append(9)
        message.append(3)
        message.appendLittleEndian(price)
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
        amountBaseUnits: String,
        computeUnitLimit: UInt32? = nil,
        computeUnitPriceMicroLamports: UInt64? = nil
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

        let hasComputeBudget = try WalletSolanaComputeBudget.validate(
            limit: computeUnitLimit, price: computeUnitPriceMicroLamports
        )
        var message = Data([1, 0, hasComputeBudget ? 2 : 1])
        message.append(Self.shortVector(hasComputeBudget ? 4 : 3))
        message.append(payer)
        message.append(destination)
        message.append(Data(repeating: 0, count: 32))
        if hasComputeBudget {
            guard let computeProgram = WalletSolanaBase58.decode(
                WalletSolanaComputeBudget.programID, exactLength: 32
            ), Set([
                payer, destination, Data(repeating: 0, count: 32), computeProgram,
            ]).count == 4 else {
                throw WalletGateway.Error.invalidArguments(
                    "The compute-budget account overlaps a transfer role."
                )
            }
            message.append(computeProgram)
        }
        message.append(blockhash)
        message.append(Self.shortVector(hasComputeBudget ? 3 : 1))
        if let computeUnitLimit, let computeUnitPriceMicroLamports {
            WalletSolanaComputeBudget.appendInstructions(
                limit: computeUnitLimit, price: computeUnitPriceMicroLamports,
                programIndex: 3, to: &message
            )
        }
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
        destinationAccountExtensions: [String] = [],
        computeUnitLimit: UInt32? = nil,
        computeUnitPriceMicroLamports: UInt64? = nil
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
        let hasComputeBudget = try WalletSolanaComputeBudget.validate(
            limit: computeUnitLimit, price: computeUnitPriceMicroLamports
        )
        let computeProgram: Data?
        if hasComputeBudget {
            computeProgram = WalletSolanaBase58.decode(
                WalletSolanaComputeBudget.programID, exactLength: 32
            )
            guard computeProgram != nil,
                  ![
                      feePayer, sourceTokenAccount, mint,
                      destinationTokenAccount, recipientOwner, tokenProgramID,
                      Self.associatedTokenProgramID,
                      WalletSolanaCanonicalNativeTransfer.systemProgramID,
                  ].contains(WalletSolanaComputeBudget.programID) else {
                throw WalletGateway.Error.invalidArguments(
                    "The compute-budget account overlaps a token role."
                )
            }
        } else {
            computeProgram = nil
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
            message = Data([1, 0, hasComputeBudget ? 6 : 5])
            message.append(Self.shortVector(hasComputeBudget ? 9 : 8))
            for account in [
                payer, source, destination, owner, mintBytes,
                Data(repeating: 0, count: 32), program, associatedProgram,
            ] {
                message.append(account)
            }
            if let computeProgram { message.append(computeProgram) }
            message.append(blockhash)
            message.append(Self.shortVector(hasComputeBudget ? 4 : 2))
            if let computeUnitLimit, let computeUnitPriceMicroLamports {
                WalletSolanaComputeBudget.appendInstructions(
                    limit: computeUnitLimit,
                    price: computeUnitPriceMicroLamports,
                    programIndex: 8, to: &message
                )
            }
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
            message = Data([1, 0, hasComputeBudget ? 3 : 2])
            message.append(Self.shortVector(hasComputeBudget ? 6 : 5))
            for account in [payer, source, destination, mintBytes, program] {
                message.append(account)
            }
            if let computeProgram { message.append(computeProgram) }
            message.append(blockhash)
            message.append(Self.shortVector(hasComputeBudget ? 3 : 1))
            if let computeUnitLimit, let computeUnitPriceMicroLamports {
                WalletSolanaComputeBudget.appendInstructions(
                    limit: computeUnitLimit,
                    price: computeUnitPriceMicroLamports,
                    programIndex: 5, to: &message
                )
            }
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

/// The first transferable Core subset is intentionally narrower than the
/// program itself: one uncompressed, standalone AssetV1 account with no plugin
/// registry, paid for and authorized by the vault owner. Collection accounts,
/// compression proofs, remaining accounts, and caller-supplied instructions
/// are not representable here.
struct WalletSolanaCanonicalCoreTransfer: Equatable, Sendable {
    static let coreProgramID = "CoREENxT6tW1HoK8ypY1SxRMZTcVPm7R94rH4PZNhX7d"

    let feePayer: String
    let asset: String
    let recipient: String
    let recentBlockhash: String
    let message: Data
    let unsignedTransaction: Data
    let canonicalMessageDigest: String
    let resolvedAccountsDigest: String

    init(
        feePayer: String,
        asset: String,
        recipient: String,
        recentBlockhash: String,
        assetDataDigest: String,
        computeUnitLimit: UInt32? = nil,
        computeUnitPriceMicroLamports: UInt64? = nil
    ) throws {
        guard let payer = WalletSolanaBase58.decode(feePayer, exactLength: 32),
              let assetBytes = WalletSolanaBase58.decode(asset, exactLength: 32),
              let destination = WalletSolanaBase58.decode(recipient, exactLength: 32),
              let core = WalletSolanaBase58.decode(Self.coreProgramID, exactLength: 32),
              let blockhash = WalletSolanaBase58.decode(recentBlockhash, exactLength: 32),
              Set([feePayer, asset, recipient, Self.coreProgramID]).count == 4,
              assetDataDigest.hasPrefix("sha256:"), assetDataDigest.count == 71,
              assetDataDigest.dropFirst(7).utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Core transfer requires distinct canonical accounts, a valid blockhash, and exact on-chain asset evidence."
            )
        }

        let hasComputeBudget = try WalletSolanaComputeBudget.validate(
            limit: computeUnitLimit, price: computeUnitPriceMicroLamports
        )
        let computeProgram: Data?
        if hasComputeBudget {
            computeProgram = WalletSolanaBase58.decode(
                WalletSolanaComputeBudget.programID, exactLength: 32
            )
            guard computeProgram != nil,
                  ![feePayer, asset, recipient, Self.coreProgramID]
                    .contains(WalletSolanaComputeBudget.programID) else {
                throw WalletGateway.Error.invalidArguments(
                    "The compute-budget account overlaps a Core role."
                )
            }
        } else {
            computeProgram = nil
        }

        // Legacy account order is fixed by this reviewed adapter rather than
        // delegated to an SDK: payer, writable asset, recipient, Core program.
        // Optional collection/authority/system/log-wrapper accounts all use the
        // Core program sentinel. Payer therefore remains the resolved authority.
        var message = Data([1, 0, hasComputeBudget ? 3 : 2])
        message.append(Data([hasComputeBudget ? 5 : 4]))
        for account in [payer, assetBytes, destination, core] {
            message.append(account)
        }
        if let computeProgram { message.append(computeProgram) }
        message.append(blockhash)
        message.append(Data([hasComputeBudget ? 3 : 1]))
        if let computeUnitLimit, let computeUnitPriceMicroLamports {
            WalletSolanaComputeBudget.appendInstructions(
                limit: computeUnitLimit, price: computeUnitPriceMicroLamports,
                programIndex: 4, to: &message
            )
        }
        message.append(3)
        message.append(Data([7]))
        message.append(contentsOf: [1, 3, 0, 3, 2, 3, 3])
        // TransferV1 discriminator 14 plus Borsh Option<CompressionProof>::None.
        message.append(Data([2, 14, 0]))

        var transaction = Data([1])
        transaction.append(Data(repeating: 0, count: 64))
        transaction.append(message)
        self.feePayer = feePayer
        self.asset = asset
        self.recipient = recipient
        self.recentBlockhash = recentBlockhash
        self.message = message
        unsignedTransaction = transaction
        canonicalMessageDigest = Self.sha256(message)
        resolvedAccountsDigest = Self.resolvedDigest(
            feePayer: feePayer, asset: asset, recipient: recipient,
            assetDataDigest: assetDataDigest
        )
    }

    static func resolvedDigest(
        feePayer: String,
        asset: String,
        recipient: String,
        assetDataDigest: String
    ) -> String {
        sha256(Data(
            "legacy|\(coreProgramID)|\(feePayer):signer:writable|\(asset):nonsigner:writable|\(recipient):nonsigner:readonly|standalone:true|plugins:none|asset_data:\(assetDataDigest)"
                .utf8
        ))
    }

    private static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

struct WalletSolanaCoreAssetEvidence: Equatable, Sendable {
    enum UpdateAuthority: Equatable, Sendable {
        case none
        case address(String)
    }

    let address: String
    let owner: String
    let updateAuthority: UpdateAuthority
    let dataDigest: String
    let slot: UInt64
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

    private struct SignatureEvidence: Sendable {
        let signature: String
        let slot: UInt64
        let blockTime: UInt64?
        let successful: Bool
    }

    private struct ParsedAccountKey: Sendable {
        let address: String
        let signer: Bool
        let writable: Bool
        let source: String
    }

    private struct TokenBalanceEvidence: Sendable {
        let accountIndex: Int
        let identity: WalletSolanaAssetIdentity
        let owner: String?
        let amountBaseUnits: String
        let decimals: Int
    }

    private struct DecodedActivityInstruction: Sendable {
        let path: String
        let programID: String
        let accounts: [String]?
        let data: Data?
    }

    private struct SimulationEvidence: Sendable {
        let summary: String
        let unitsConsumed: UInt64
    }

    private struct PriorityPlan: Sendable {
        let computeUnitLimit: UInt32
        let computeUnitPriceMicroLamports: UInt64
        let priorityFeeBaseUnits: String
    }

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
        case .nftTransfer:
            return try await prepareCoreTransfer(
                request: request, feePayer: feePayer
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
        let provisional = try WalletSolanaCanonicalNativeTransfer(
            feePayer: feePayer, recipient: recipient,
            recentBlockhash: latest.blockhash, amountBaseUnits: amount,
            computeUnitLimit: WalletSolanaComputeBudget.maximumUnits,
            computeUnitPriceMicroLamports: 0
        )
        let baseFee = try await feeForMessage(provisional.message)
        let provisionalSimulation = try await simulateEvidence(
            provisional.unsignedTransaction
        )
        let priority = try await priorityPlan(
            unitsConsumed: provisionalSimulation.unitsConsumed,
            writableAccounts: [feePayer, recipient], baseFee: baseFee,
            maximumFee: request.maximumFeeBaseUnits
        )
        let transaction = try WalletSolanaCanonicalNativeTransfer(
            feePayer: feePayer, recipient: recipient,
            recentBlockhash: latest.blockhash, amountBaseUnits: amount,
            computeUnitLimit: priority.computeUnitLimit,
            computeUnitPriceMicroLamports:
                priority.computeUnitPriceMicroLamports
        )
        let fee = try await feeForMessage(transaction.message)
        try Self.validateFinalFee(
            fee, baseFee: baseFee, plan: priority,
            maximumFee: request.maximumFeeBaseUnits
        )
        let simulation = try await simulateEvidence(transaction.unsignedTransaction)
        guard simulation.unitsConsumed <= UInt64(priority.computeUnitLimit) else {
            throw WalletRPCError.simulation(
                "the final SOL transfer exceeded its reviewed compute limit"
            )
        }
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
            feePayer: feePayer,
            computeUnitLimit: priority.computeUnitLimit,
            computeUnitPriceMicroLamports: String(
                priority.computeUnitPriceMicroLamports
            ),
            priorityFeeBaseUnits: priority.priorityFeeBaseUnits,
            feeQuoteBaseUnits: fee,
            maximumFeeBaseUnits: request.maximumFeeBaseUnits,
            canonicalMessageDigest: transaction.canonicalMessageDigest,
            resolvedAccountsDigest: transaction.resolvedAccountsDigest,
            instructions: [instruction], simulation: simulation.summary,
            simulationSucceeded: true, observedAt: Date()
        )
    }

    private func prepareCoreTransfer(
        request: WalletPrepareRequest,
        feePayer: String
    ) async throws -> WalletSolanaPreparationPacket {
        let action = request.action
        guard request.networkID == network.id,
              action.type == .nftTransfer,
              let assetID = action.assetID,
              let identity = WalletSolanaCollectibleIdentity.parse(assetID),
              identity.networkID == network.id, identity.standard == .core,
              action.tokenID == identity.address,
              action.amountBaseUnits == "1",
              action.inputAssetID == nil, action.outputAssetID == nil,
              action.minimumOutputBaseUnits == nil, action.adapterID == nil,
              action.authorizationFormat == nil, action.metadataDigest == nil,
              action.contractID == nil, action.function == nil,
              action.arguments.isEmpty, action.valueBaseUnits == nil,
              let recipient = action.recipient,
              WalletSolanaBase58.decode(recipient, exactLength: 32) != nil,
              recipient != feePayer else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Core adapter accepts one canonical owner transfer only."
            )
        }
        let genesisHash = try await verifiedGenesisHash()
        let assetEvidence = try await coreAssetEvidence(
            address: identity.address, expectedOwner: feePayer
        )
        let latest = try await latestBlockhash()
        let provisional = try WalletSolanaCanonicalCoreTransfer(
            feePayer: feePayer, asset: identity.address, recipient: recipient,
            recentBlockhash: latest.blockhash,
            assetDataDigest: assetEvidence.dataDigest,
            computeUnitLimit: WalletSolanaComputeBudget.maximumUnits,
            computeUnitPriceMicroLamports: 0
        )
        let baseFee = try await feeForMessage(provisional.message)
        let provisionalSimulation = try await simulateCoreTransferEvidence(
            provisional.unsignedTransaction, asset: identity.address,
            expectedOwner: recipient,
            expectedUpdateAuthority: assetEvidence.updateAuthority
        )
        let priority = try await priorityPlan(
            unitsConsumed: provisionalSimulation.unitsConsumed,
            writableAccounts: [feePayer, identity.address], baseFee: baseFee,
            maximumFee: request.maximumFeeBaseUnits
        )
        let transaction = try WalletSolanaCanonicalCoreTransfer(
            feePayer: feePayer, asset: identity.address, recipient: recipient,
            recentBlockhash: latest.blockhash,
            assetDataDigest: assetEvidence.dataDigest,
            computeUnitLimit: priority.computeUnitLimit,
            computeUnitPriceMicroLamports:
                priority.computeUnitPriceMicroLamports
        )
        let fee = try await feeForMessage(transaction.message)
        try Self.validateFinalFee(
            fee, baseFee: baseFee, plan: priority,
            maximumFee: request.maximumFeeBaseUnits
        )
        let simulation = try await simulateCoreTransferEvidence(
            transaction.unsignedTransaction, asset: identity.address,
            expectedOwner: recipient,
            expectedUpdateAuthority: assetEvidence.updateAuthority
        )
        guard simulation.unitsConsumed <= UInt64(priority.computeUnitLimit) else {
            throw WalletRPCError.simulation(
                "the final Core transfer exceeded its reviewed compute limit"
            )
        }
        let authorityKind: String
        let authorityAddress: String
        switch assetEvidence.updateAuthority {
        case .none:
            authorityKind = "none"
            authorityAddress = ""
        case .address(let address):
            authorityKind = "address"
            authorityAddress = address
        }
        let instruction = WalletSolanaReviewedInstruction(
            programID: WalletSolanaCanonicalCoreTransfer.coreProgramID,
            adapterID: WalletReviewedAdapters.solanaCoreTransfer,
            semanticOperation: WalletActionKind.nftTransfer.rawValue,
            accounts: [
                .init(
                    address: feePayer, isSigner: true, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                .init(
                    address: identity.address, isSigner: false, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                .init(
                    address: recipient, isSigner: false, isWritable: false,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
            ],
            canonicalArguments: [
                "asset_data_digest": assetEvidence.dataDigest,
                "asset_id": assetID,
                "collection": "none",
                "compression": "none",
                "plugins": "none",
                "recipient": recipient,
                "update_authority": authorityAddress,
                "update_authority_kind": authorityKind,
            ]
        )
        return WalletSolanaPreparationPacket(
            request: request, genesisHash: genesisHash, version: .legacy,
            recentBlockhash: latest.blockhash,
            lastValidBlockHeight: latest.lastValidBlockHeight,
            contextSlot: max(latest.contextSlot, assetEvidence.slot),
            feePayer: feePayer,
            computeUnitLimit: priority.computeUnitLimit,
            computeUnitPriceMicroLamports: String(
                priority.computeUnitPriceMicroLamports
            ),
            priorityFeeBaseUnits: priority.priorityFeeBaseUnits,
            feeQuoteBaseUnits: fee,
            maximumFeeBaseUnits: request.maximumFeeBaseUnits,
            canonicalMessageDigest: transaction.canonicalMessageDigest,
            resolvedAccountsDigest: transaction.resolvedAccountsDigest,
            instructions: [instruction], simulation: simulation.summary,
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
        let provisional = try WalletSolanaCanonicalSPLTransfer(
            feePayer: feePayer, sourceTokenAccount: source.address,
            mint: identity.mint, destinationTokenAccount: destination.address,
            recipientOwner: recipient, tokenProgramID: identity.program.programID,
            recentBlockhash: latest.blockhash, amountBaseUnits: amountText,
            decimals: decimals,
            createsDestinationAssociatedAccount: createDestinationAssociatedAccount,
            mintExtensions: mintState.extensions,
            sourceAccountExtensions: source.extensions,
            destinationAccountExtensions: destination.extensions,
            computeUnitLimit: WalletSolanaComputeBudget.maximumUnits,
            computeUnitPriceMicroLamports: 0
        )
        let baseFee = try await feeForMessage(provisional.message)
        let provisionalSimulation = try await simulateEvidence(
            provisional.unsignedTransaction
        )
        let priority = try await priorityPlan(
            unitsConsumed: provisionalSimulation.unitsConsumed,
            writableAccounts: [feePayer, source.address, destination.address],
            baseFee: baseFee, maximumFee: request.maximumFeeBaseUnits
        )
        let transfer = try WalletSolanaCanonicalSPLTransfer(
            feePayer: feePayer, sourceTokenAccount: source.address,
            mint: identity.mint, destinationTokenAccount: destination.address,
            recipientOwner: recipient, tokenProgramID: identity.program.programID,
            recentBlockhash: latest.blockhash, amountBaseUnits: amountText,
            decimals: decimals,
            createsDestinationAssociatedAccount: createDestinationAssociatedAccount,
            mintExtensions: mintState.extensions,
            sourceAccountExtensions: source.extensions,
            destinationAccountExtensions: destination.extensions,
            computeUnitLimit: priority.computeUnitLimit,
            computeUnitPriceMicroLamports:
                priority.computeUnitPriceMicroLamports
        )
        let fee = try await feeForMessage(transfer.message)
        try Self.validateFinalFee(
            fee, baseFee: baseFee, plan: priority,
            maximumFee: request.maximumFeeBaseUnits
        )
        let simulation = try await simulateEvidence(transfer.unsignedTransaction)
        guard simulation.unitsConsumed <= UInt64(priority.computeUnitLimit) else {
            throw WalletRPCError.simulation(
                "the final Solana token transfer exceeded its reviewed compute limit"
            )
        }
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
            computeUnitLimit: priority.computeUnitLimit,
            computeUnitPriceMicroLamports: String(
                priority.computeUnitPriceMicroLamports
            ), priorityFeeBaseUnits: priority.priorityFeeBaseUnits,
            feeQuoteBaseUnits: fee,
            maximumFeeBaseUnits: request.maximumFeeBaseUnits,
            canonicalMessageDigest: transfer.canonicalMessageDigest,
            resolvedAccountsDigest: transfer.resolvedAccountsDigest,
            instructions: instructions, simulation: simulation.summary,
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
        guard packet.computeUnitLimit > 0,
              packet.computeUnitLimit <= WalletSolanaComputeBudget.maximumUnits,
              let computeUnitPrice = UInt64(
                  packet.computeUnitPriceMicroLamports
              ), String(computeUnitPrice)
                == packet.computeUnitPriceMicroLamports,
              Self.priorityFee(
                  computeUnitLimit: packet.computeUnitLimit,
                  priceMicroLamports: computeUnitPrice
              ) == packet.priorityFeeBaseUnits else {
            throw WalletRPCError.simulation(
                "the prepared Solana priority-fee evidence is malformed"
            )
        }
        let message: Data
        let unsignedTransaction: Data
        let canonicalDigest: String
        let resolvedDigest: String
        var coreUpdateAuthority: WalletSolanaCoreAssetEvidence.UpdateAuthority? = nil
        switch packet.request.action.type {
        case .nativeTransfer:
            let transaction = try WalletSolanaCanonicalNativeTransfer(
                feePayer: packet.feePayer,
                recipient: packet.request.action.recipient ?? "",
                recentBlockhash: packet.recentBlockhash,
                amountBaseUnits: packet.request.action.amountBaseUnits ?? "",
                computeUnitLimit: packet.computeUnitLimit,
                computeUnitPriceMicroLamports: computeUnitPrice
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
                destinationAccountExtensions: boundDestinationExtensions,
                computeUnitLimit: packet.computeUnitLimit,
                computeUnitPriceMicroLamports: computeUnitPrice
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
        case .nftTransfer:
            let action = packet.request.action
            guard let assetID = action.assetID,
                  let identity = WalletSolanaCollectibleIdentity.parse(assetID),
                  identity.networkID == network.id, identity.standard == .core,
                  action.tokenID == identity.address,
                  action.amountBaseUnits == "1",
                  let recipient = action.recipient,
                  packet.instructions.count == 1,
                  let instruction = packet.instructions.first,
                  instruction.programID
                    == WalletSolanaCanonicalCoreTransfer.coreProgramID,
                  instruction.adapterID
                    == WalletReviewedAdapters.solanaCoreTransfer,
                  instruction.semanticOperation
                    == WalletActionKind.nftTransfer.rawValue,
                  let assetDataDigest = instruction.canonicalArguments[
                    "asset_data_digest"
                  ] else {
                throw WalletRPCError.simulation(
                    "the reviewed Core transfer evidence is incomplete"
                )
            }
            let current = try await coreAssetEvidence(
                address: identity.address, expectedOwner: packet.feePayer
            )
            let authorityKind: String
            let authorityAddress: String
            switch current.updateAuthority {
            case .none:
                authorityKind = "none"
                authorityAddress = ""
            case .address(let address):
                authorityKind = "address"
                authorityAddress = address
            }
            let expectedAccounts = [
                WalletSolanaResolvedAccount(
                    address: packet.feePayer, isSigner: true, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                WalletSolanaResolvedAccount(
                    address: identity.address, isSigner: false, isWritable: true,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
                WalletSolanaResolvedAccount(
                    address: recipient, isSigner: false, isWritable: false,
                    lookupTableAddress: nil, lookupTableSlot: nil
                ),
            ]
            let expectedArguments = [
                "asset_data_digest": current.dataDigest,
                "asset_id": assetID,
                "collection": "none",
                "compression": "none",
                "plugins": "none",
                "recipient": recipient,
                "update_authority": authorityAddress,
                "update_authority_kind": authorityKind,
            ]
            guard current.dataDigest == assetDataDigest,
                  instruction.accounts == expectedAccounts,
                  instruction.canonicalArguments == expectedArguments else {
                throw WalletRPCError.simulation(
                    "the Core owner, authority, plugin boundary, or instruction roles changed"
                )
            }
            let transaction = try WalletSolanaCanonicalCoreTransfer(
                feePayer: packet.feePayer, asset: identity.address,
                recipient: recipient, recentBlockhash: packet.recentBlockhash,
                assetDataDigest: current.dataDigest,
                computeUnitLimit: packet.computeUnitLimit,
                computeUnitPriceMicroLamports: computeUnitPrice
            )
            message = transaction.message
            unsignedTransaction = transaction.unsignedTransaction
            canonicalDigest = transaction.canonicalMessageDigest
            resolvedDigest = transaction.resolvedAccountsDigest
            coreUpdateAuthority = current.updateAuthority
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
        guard fee == packet.feeQuoteBaseUnits,
              WalletBaseUnits.lessThanOrEqual(
                  fee, packet.maximumFeeBaseUnits
              ) else {
            throw WalletRPCError.simulation(
                "the refreshed Solana fee changed or exceeded its ceiling"
            )
        }
        let simulation: String
        if packet.request.action.type == .nftTransfer,
           let assetID = packet.request.action.assetID,
           let identity = WalletSolanaCollectibleIdentity.parse(assetID),
           let recipient = packet.request.action.recipient,
           let coreUpdateAuthority {
            let evidence = try await simulateCoreTransferEvidence(
                unsignedTransaction, asset: identity.address,
                expectedOwner: recipient,
                expectedUpdateAuthority: coreUpdateAuthority
            )
            guard evidence.unitsConsumed <= UInt64(packet.computeUnitLimit) else {
                throw WalletRPCError.simulation(
                    "the Core recheck exceeded its reviewed compute limit"
                )
            }
            simulation = evidence.summary
        } else {
            let evidence = try await simulateEvidence(unsignedTransaction)
            guard evidence.unitsConsumed <= UInt64(packet.computeUnitLimit) else {
                throw WalletRPCError.simulation(
                    "the Solana recheck exceeded its reviewed compute limit"
                )
            }
            simulation = evidence.summary
        }
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

    /// Returns the newest bounded finalized transaction history. Every fetched
    /// signature produces a transaction-level record. Exact owner balance
    /// deltas and the narrow standalone Core instruction are additional effects;
    /// unknown instructions are never guessed into a transfer standard.
    func activity(owner: String) async throws -> [WalletSolanaIndexedActivity] {
        guard WalletSolanaBase58.decode(owner, exactLength: 32) != nil else {
            throw WalletGateway.Error.invalidArguments(
                "The Solana owner address is malformed."
            )
        }
        _ = try await verifiedGenesisHash()
        let pageLimit = 100
        let maximumSignatures = 500
        var before: String?
        var evidence: [SignatureEvidence] = []
        var seen: Set<String> = []
        var previousSlot: UInt64?
        while evidence.count < maximumSignatures {
            var configuration: [String: Any] = [
                "commitment": "finalized",
                "limit": min(pageLimit, maximumSignatures - evidence.count),
            ]
            if let before { configuration["before"] = before }
            let result = try await rpc(
                method: "getSignaturesForAddress", params: [owner, configuration]
            )
            guard let rows = result as? [Any], rows.count <= pageLimit else {
                throw WalletRPCError.invalidResponse(
                    "getSignaturesForAddress returned malformed or excessive data"
                )
            }
            if rows.isEmpty { break }
            for row in rows {
                guard let value = row as? [String: Any], value.count <= 8,
                      let signature = value["signature"] as? String,
                      WalletSolanaBase58.decode(signature, exactLength: 64) != nil,
                      let slot = Self.unsigned(value["slot"]),
                      value["confirmationStatus"] as? String == "finalized",
                      value.keys.contains("err"),
                      let blockTime = Self.unsigned(value["blockTime"]),
                      Self.validOptionalMemo(value["memo"]),
                      previousSlot.map({ slot <= $0 }) != false,
                      seen.insert(signature).inserted else {
                    throw WalletRPCError.invalidResponse(
                        "finalized Solana signature evidence was malformed, duplicated, or reordered"
                    )
                }
                previousSlot = slot
                evidence.append(SignatureEvidence(
                    signature: signature, slot: slot, blockTime: blockTime,
                    successful: value["err"] is NSNull
                ))
            }
            guard let cursor = evidence.last?.signature, cursor != before else {
                throw WalletRPCError.invalidResponse(
                    "Solana activity pagination repeated its cursor"
                )
            }
            before = cursor
            if rows.count < pageLimit { break }
        }

        var indexed: [(Int, [WalletSolanaIndexedActivity])] = []
        for start in stride(from: 0, to: evidence.count, by: 8) {
            let end = min(start + 8, evidence.count)
            let batch = Array(evidence[start..<end])
            let results = try await withThrowingTaskGroup(
                of: (Int, [WalletSolanaIndexedActivity]).self
            ) { group in
                for (offset, item) in batch.enumerated() {
                    group.addTask {
                        let records = try await self.activity(
                            for: item, owner: owner
                        )
                        return (start + offset, records)
                    }
                }
                var values: [(Int, [WalletSolanaIndexedActivity])] = []
                for try await value in group { values.append(value) }
                return values
            }
            indexed.append(contentsOf: results)
        }
        indexed.sort { $0.0 < $1.0 }
        let records = indexed.flatMap(\.1)
        guard records.count <= 16_500,
              Set(records.map(\.id)).count == records.count else {
            throw WalletRPCError.invalidResponse(
                "Solana activity effects were excessive or duplicated"
            )
        }
        guard records.count > 500 else { return records }
        let transactions = indexed.compactMap { $0.1.first }
        var bounded = transactions
        for (_, group) in indexed {
            for effect in group.dropFirst() where bounded.count < 500 {
                bounded.append(effect)
            }
            if bounded.count == 500 { break }
        }
        return bounded
    }

    private func activity(
        for evidence: SignatureEvidence,
        owner: String
    ) async throws -> [WalletSolanaIndexedActivity] {
        let raw = try await rpc(method: "getTransaction", params: [
            evidence.signature,
            [
                "commitment": "finalized", "encoding": "jsonParsed",
                "maxSupportedTransactionVersion": 1,
            ],
        ])
        guard let result = raw as? [String: Any], result.count <= 12,
              Self.unsigned(result["slot"]) == evidence.slot,
              let rawVersion = result["version"],
              let version = Self.transactionVersion(rawVersion),
              let transaction = result["transaction"] as? [String: Any],
              transaction.count <= 4,
              let signatures = transaction["signatures"] as? [String],
              !signatures.isEmpty, signatures.count <= 64,
              signatures.first == evidence.signature,
              signatures.allSatisfy({
                  WalletSolanaBase58.decode($0, exactLength: 64) != nil
              }),
              let message = transaction["message"] as? [String: Any],
              message.count <= 8,
              let accountRows = message["accountKeys"] as? [Any],
              !accountRows.isEmpty, accountRows.count <= 256,
              let meta = result["meta"] as? [String: Any], meta.count <= 24,
              meta.keys.contains("err"),
              (meta["err"] is NSNull) == evidence.successful,
              let fee = Self.unsigned(meta["fee"]),
              let occurredAt = Self.transactionDate(
                  result["blockTime"], fallback: evidence.blockTime
              ) else {
            throw WalletRPCError.invalidResponse(
                "getTransaction returned mismatched finalized evidence"
            )
        }
        var accountKeys: [ParsedAccountKey] = []
        var seenAccounts: Set<String> = []
        for row in accountRows {
            guard let value = row as? [String: Any], value.count <= 6,
                  let address = value["pubkey"] as? String,
                  WalletSolanaBase58.decode(address, exactLength: 32) != nil,
                  let signer = value["signer"] as? Bool,
                  let writable = value["writable"] as? Bool,
                  let source = value["source"] as? String,
                  source == "transaction" || source == "lookupTable",
                  seenAccounts.insert(address).inserted else {
                throw WalletRPCError.invalidResponse(
                    "the finalized Solana account list was malformed"
                )
            }
            accountKeys.append(ParsedAccountKey(
                address: address, signer: signer, writable: writable,
                source: source
            ))
        }
        try Self.validateActivityVersionEnvelope(
            version: version, message: message, meta: meta,
            accountKeys: accountKeys
        )
        guard let ownerIndex = accountKeys.firstIndex(where: {
            $0.address == owner
        }), accountKeys.first?.signer == true,
           signatures.count == accountKeys.filter(\.signer).count,
           let preBalances = Self.unsignedArray(meta["preBalances"]),
           let postBalances = Self.unsignedArray(meta["postBalances"]),
           preBalances.count == accountKeys.count,
           postBalances.count == accountKeys.count,
           Self.validActivityLogs(meta["logMessages"]) else {
            throw WalletRPCError.invalidResponse(
                "the finalized Solana balance or signer evidence was malformed"
            )
        }
        let base = WalletSolanaIndexedActivity(
            id: "\(evidence.signature):transaction",
            signature: evidence.signature, slot: evidence.slot,
            occurredAt: occurredAt, successful: evidence.successful,
            owner: owner, feeBaseUnits: String(fee), direction: nil,
            assetID: nil, assetKind: nil, assetReference: nil,
            amountBaseUnits: nil
        )
        guard evidence.successful else { return [base] }

        var effects: [WalletSolanaIndexedActivity] = [base]
        let preNative = preBalances[ownerIndex]
        let postNative = postBalances[ownerIndex]
        if preNative != postNative {
            let inbound = postNative > preNative
            let amount = inbound ? postNative - preNative : preNative - postNative
            effects.append(WalletSolanaIndexedActivity(
                id: "\(evidence.signature):native",
                signature: evidence.signature, slot: evidence.slot,
                occurredAt: occurredAt, successful: true, owner: owner,
                feeBaseUnits: String(fee),
                direction: inbound ? .inbound : .outbound,
                assetID: network.nativeAssetID, assetKind: .native,
                assetReference: nil, amountBaseUnits: String(amount)
            ))
        }

        let preTokens = try tokenBalanceEvidence(
            meta["preTokenBalances"], accountCount: accountKeys.count
        )
        let postTokens = try tokenBalanceEvidence(
            meta["postTokenBalances"], accountCount: accountKeys.count
        )
        effects.append(contentsOf: try tokenEffects(
            pre: preTokens, post: postTokens, owner: owner,
            signature: evidence.signature, slot: evidence.slot,
            occurredAt: occurredAt, fee: String(fee)
        ))
        effects.append(contentsOf: try coreEffects(
            message: message, meta: meta, accountKeys: accountKeys,
            owner: owner, signature: evidence.signature, slot: evidence.slot,
            occurredAt: occurredAt, fee: String(fee)
        ))
        guard effects.count <= 33 else {
            throw WalletRPCError.invalidResponse(
                "one Solana transaction produced excessive owner effects"
            )
        }
        return effects
    }

    private func tokenBalanceEvidence(
        _ raw: Any?,
        accountCount: Int
    ) throws -> [TokenBalanceEvidence] {
        if raw == nil || raw is NSNull { return [] }
        guard let rows = raw as? [Any], rows.count <= 256 else {
            throw WalletRPCError.invalidResponse(
                "Solana token-balance evidence was excessive"
            )
        }
        var result: [TokenBalanceEvidence] = []
        var seen: Set<Int> = []
        for row in rows {
            guard let value = row as? [String: Any], value.count <= 10,
                  let rawIndex = Self.unsigned(value["accountIndex"]),
                  rawIndex < UInt64(accountCount),
                  let mint = value["mint"] as? String,
                  WalletSolanaBase58.decode(mint, exactLength: 32) != nil,
                  let tokenAmount = value["uiTokenAmount"] as? [String: Any],
                  tokenAmount.count <= 8,
                  let amount = tokenAmount["amount"] as? String,
                  WalletBaseUnits.normalize(amount) == amount,
                  UInt64(amount) != nil,
                  let rawDecimals = Self.unsigned(tokenAmount["decimals"]),
                  rawDecimals <= 255,
                  seen.insert(Int(rawIndex)).inserted else {
                throw WalletRPCError.invalidResponse(
                    "Solana token-balance evidence was malformed or duplicated"
                )
            }
            let programID: String?
            if value["programId"] == nil || value["programId"] is NSNull {
                programID = nil
            } else if let candidate = value["programId"] as? String,
                      WalletSolanaBase58.decode(candidate, exactLength: 32) != nil {
                programID = candidate
            } else {
                throw WalletRPCError.invalidResponse(
                    "Solana token-program evidence was malformed"
                )
            }
            guard let program = WalletSolanaTokenProgram.allCases.first(where: {
                $0.programID == programID
            }) else {
                // Preserve the transaction-level record, but do not infer an
                // asset effect for an unreviewed token program.
                continue
            }
            let tokenOwner: String?
            if value["owner"] == nil || value["owner"] is NSNull {
                tokenOwner = nil
            } else if let owner = value["owner"] as? String,
                      WalletSolanaBase58.decode(owner, exactLength: 32) != nil {
                tokenOwner = owner
            } else {
                throw WalletRPCError.invalidResponse(
                    "Solana token-balance owner evidence was malformed"
                )
            }
            result.append(TokenBalanceEvidence(
                accountIndex: Int(rawIndex),
                identity: WalletSolanaAssetIdentity(
                    networkID: network.id, program: program, mint: mint
                ),
                owner: tokenOwner, amountBaseUnits: amount,
                decimals: Int(rawDecimals)
            ))
        }
        return result
    }

    private func tokenEffects(
        pre: [TokenBalanceEvidence],
        post: [TokenBalanceEvidence],
        owner: String,
        signature: String,
        slot: UInt64,
        occurredAt: Date,
        fee: String
    ) throws -> [WalletSolanaIndexedActivity] {
        let preByIndex = Dictionary(uniqueKeysWithValues: pre.map {
            ($0.accountIndex, $0)
        })
        let postByIndex = Dictionary(uniqueKeysWithValues: post.map {
            ($0.accountIndex, $0)
        })
        for index in Set(preByIndex.keys).intersection(postByIndex.keys) {
            guard preByIndex[index]?.identity == postByIndex[index]?.identity,
                  preByIndex[index]?.decimals == postByIndex[index]?.decimals else {
                throw WalletRPCError.invalidResponse(
                    "a Solana token account changed mint, program, or decimals"
                )
            }
        }
        var identities: [String: WalletSolanaAssetIdentity] = [:]
        var decimals: [String: Int] = [:]
        var preTotals: [String: String] = [:]
        var postTotals: [String: String] = [:]
        for item in pre + post {
            let id = item.identity.canonicalID
            guard decimals[id] == nil || decimals[id] == item.decimals else {
                throw WalletRPCError.invalidResponse(
                    "one Solana mint reported conflicting decimals"
                )
            }
            identities[id] = item.identity
            decimals[id] = item.decimals
        }
        for item in pre where item.owner == owner {
            let id = item.identity.canonicalID
            guard let total = WalletBaseUnits.add(
                preTotals[id] ?? "0", item.amountBaseUnits
            ) else {
                throw WalletRPCError.invalidResponse(
                    "Solana pre-token balances exceeded wallet arithmetic"
                )
            }
            preTotals[id] = total
        }
        for item in post where item.owner == owner {
            let id = item.identity.canonicalID
            guard let total = WalletBaseUnits.add(
                postTotals[id] ?? "0", item.amountBaseUnits
            ) else {
                throw WalletRPCError.invalidResponse(
                    "Solana post-token balances exceeded wallet arithmetic"
                )
            }
            postTotals[id] = total
        }
        var effects: [WalletSolanaIndexedActivity] = []
        for id in Set(preTotals.keys).union(postTotals.keys).sorted() {
            let before = preTotals[id] ?? "0"
            let after = postTotals[id] ?? "0"
            guard before != after, let identity = identities[id] else { continue }
            let inbound = WalletBaseUnits.compare(after, before) == .orderedDescending
            guard let amount = inbound
                    ? WalletBaseUnits.subtract(after, before)
                    : WalletBaseUnits.subtract(before, after),
                  amount != "0" else {
                throw WalletRPCError.invalidResponse(
                    "Solana token delta could not be normalized"
                )
            }
            effects.append(WalletSolanaIndexedActivity(
                id: "\(signature):token:\(id)", signature: signature,
                slot: slot, occurredAt: occurredAt, successful: true,
                owner: owner, feeBaseUnits: fee,
                direction: inbound ? .inbound : .outbound,
                assetID: id, assetKind: .fungibleToken,
                assetReference: identity.mint, amountBaseUnits: amount
            ))
        }
        return effects
    }

    private func coreEffects(
        message: [String: Any],
        meta: [String: Any],
        accountKeys: [ParsedAccountKey],
        owner: String,
        signature: String,
        slot: UInt64,
        occurredAt: Date,
        fee: String
    ) throws -> [WalletSolanaIndexedActivity] {
        let instructions = try activityInstructions(message: message, meta: meta)
        let accountMap = Dictionary(uniqueKeysWithValues: accountKeys.map {
            ($0.address, $0)
        })
        var effects: [WalletSolanaIndexedActivity] = []
        for instruction in instructions where
            instruction.programID == WalletSolanaCanonicalCoreTransfer.coreProgramID {
            guard instruction.data == Data([14, 0]),
                  let accounts = instruction.accounts, accounts.count == 7,
                  accountMap[instruction.programID] != nil,
                  accounts.allSatisfy({ accountMap[$0] != nil }),
                  accounts[1] == instruction.programID,
                  accounts[3] == instruction.programID,
                  accounts[5] == instruction.programID,
                  accounts[6] == instruction.programID,
                  let asset = accountMap[accounts[0]], asset.writable,
                  let payer = accountMap[accounts[2]], payer.signer, payer.writable,
                  let newOwner = accountMap[accounts[4]], !newOwner.writable else {
                continue
            }
            let direction: WalletSolanaActivityDirection
            if payer.address == owner && newOwner.address == owner {
                direction = .selfTransfer
            } else if newOwner.address == owner {
                direction = .inbound
            } else if payer.address == owner {
                direction = .outbound
            } else {
                continue
            }
            let identity = WalletSolanaCollectibleIdentity(
                networkID: network.id, standard: .core, address: asset.address
            )
            effects.append(WalletSolanaIndexedActivity(
                id: "\(signature):core:\(instruction.path)", signature: signature,
                slot: slot, occurredAt: occurredAt, successful: true,
                owner: owner, feeBaseUnits: fee, direction: direction,
                assetID: identity.canonicalID, assetKind: .collectible,
                assetReference: identity.address, amountBaseUnits: "1"
            ))
        }
        return effects
    }

    private func activityInstructions(
        message: [String: Any],
        meta: [String: Any]
    ) throws -> [DecodedActivityInstruction] {
        guard let top = message["instructions"] as? [Any], top.count <= 64 else {
            throw WalletRPCError.invalidResponse(
                "Solana transaction instructions were malformed or excessive"
            )
        }
        var decoded: [DecodedActivityInstruction] = []
        for (index, raw) in top.enumerated() {
            decoded.append(try Self.activityInstruction(
                raw, path: "top-\(index)"
            ))
        }
        if meta["innerInstructions"] == nil || meta["innerInstructions"] is NSNull {
            return decoded
        }
        guard let groups = meta["innerInstructions"] as? [Any], groups.count <= 64 else {
            throw WalletRPCError.invalidResponse(
                "Solana inner instructions were excessive"
            )
        }
        var seenIndexes: Set<UInt64> = []
        for group in groups {
            guard let value = group as? [String: Any], value.count <= 4,
                  let index = Self.unsigned(value["index"]),
                  index < UInt64(top.count), seenIndexes.insert(index).inserted,
                  let rows = value["instructions"] as? [Any], rows.count <= 128,
                  decoded.count + rows.count <= 512 else {
                throw WalletRPCError.invalidResponse(
                    "Solana inner-instruction evidence was malformed"
                )
            }
            for (offset, raw) in rows.enumerated() {
                decoded.append(try Self.activityInstruction(
                    raw, path: "inner-\(index)-\(offset)"
                ))
            }
        }
        return decoded
    }

    private static func activityInstruction(
        _ raw: Any,
        path: String
    ) throws -> DecodedActivityInstruction {
        guard let value = raw as? [String: Any], value.count <= 8,
              let programID = value["programId"] as? String,
              WalletSolanaBase58.decode(programID, exactLength: 32) != nil else {
            throw WalletRPCError.invalidResponse(
                "a parsed Solana instruction was malformed"
            )
        }
        if let parsed = value["parsed"] as? [String: Any] {
            guard parsed.count <= 8,
                  let program = value["program"] as? String,
                  !program.isEmpty, program.utf8.count <= 64 else {
                throw WalletRPCError.invalidResponse(
                    "a jsonParsed Solana instruction was malformed"
                )
            }
            return DecodedActivityInstruction(
                path: path, programID: programID, accounts: nil, data: nil
            )
        }
        guard let accounts = value["accounts"] as? [String], accounts.count <= 64,
              accounts.allSatisfy({
                  WalletSolanaBase58.decode($0, exactLength: 32) != nil
              }),
              let encoded = value["data"] as? String,
              encoded.utf8.count <= 2_048,
              let data = encoded.isEmpty ? Data() : WalletSolanaBase58.decode(encoded),
              data.count <= 1_232 else {
            throw WalletRPCError.invalidResponse(
                "a partially decoded Solana instruction was malformed"
            )
        }
        return DecodedActivityInstruction(
            path: path, programID: programID, accounts: accounts, data: data
        )
    }

    private static func validOptionalMemo(_ value: Any?) -> Bool {
        value == nil || value is NSNull
            || (value as? String).map({ $0.utf8.count <= 512 }) == true
    }

    private static func transactionVersion(
        _ value: Any
    ) -> WalletSolanaTransactionVersion? {
        if value as? String == "legacy" { return .legacy }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        if number.decimalValue == 0 { return .v0 }
        if number.decimalValue == 1 { return .v1 }
        return nil
    }

    private static func validateActivityVersionEnvelope(
        version: WalletSolanaTransactionVersion,
        message: [String: Any],
        meta: [String: Any],
        accountKeys: [ParsedAccountKey]
    ) throws {
        switch version {
        case .legacy:
            guard message["transactionConfig"] == nil,
                  emptyOrAbsent(message["addressTableLookups"]),
                  emptyLoadedAddressesOrAbsent(meta["loadedAddresses"]),
                  accountKeys.allSatisfy({ $0.source == "transaction" }) else {
                throw WalletRPCError.invalidResponse(
                    "legacy Solana activity carried versioned-message evidence"
                )
            }
        case .v0:
            guard message["transactionConfig"] == nil else {
                throw WalletRPCError.invalidResponse(
                    "v0 Solana activity carried a v1 transaction configuration"
                )
            }
            try validateV0LookupEvidence(
                message["addressTableLookups"], loaded: meta["loadedAddresses"],
                accountKeys: accountKeys
            )
        case .v1:
            guard message.keys.contains("transactionConfig"),
                  message["addressTableLookups"] == nil,
                  emptyLoadedAddressesOrAbsent(meta["loadedAddresses"]),
                  accountKeys.allSatisfy({ $0.source == "transaction" }) else {
                throw WalletRPCError.invalidResponse(
                    "v1 Solana activity carried lookup-table evidence"
                )
            }
            try validateV1TransactionConfig(message["transactionConfig"])
        }
    }

    private static func validateV0LookupEvidence(
        _ rawLookups: Any?,
        loaded rawLoaded: Any?,
        accountKeys: [ParsedAccountKey]
    ) throws {
        guard let lookups = rawLookups as? [Any], lookups.count <= 32 else {
            throw WalletRPCError.invalidResponse(
                "v0 Solana address-table lookups were missing or excessive"
            )
        }
        var tableAddresses: Set<String> = []
        var writableCount = 0
        var readonlyCount = 0
        for raw in lookups {
            guard let lookup = raw as? [String: Any], lookup.count == 3,
                  let table = lookup["accountKey"] as? String,
                  WalletSolanaBase58.decode(table, exactLength: 32) != nil,
                  tableAddresses.insert(table).inserted,
                  let writable = byteIndexes(lookup["writableIndexes"]),
                  let readonly = byteIndexes(lookup["readonlyIndexes"]),
                  Set(writable).isDisjoint(with: Set(readonly)) else {
                throw WalletRPCError.invalidResponse(
                    "a v0 Solana address-table lookup was malformed"
                )
            }
            writableCount += writable.count
            readonlyCount += readonly.count
        }
        guard writableCount + readonlyCount <= 64 else {
            throw WalletRPCError.invalidResponse(
                "v0 Solana activity resolved excessive lookup-table accounts"
            )
        }
        let transactionAccounts = accountKeys.prefix {
            $0.source == "transaction"
        }
        let lookupAccounts = Array(accountKeys.dropFirst(transactionAccounts.count))
        guard transactionAccounts.allSatisfy({ $0.source == "transaction" }),
              lookupAccounts.allSatisfy({
                  $0.source == "lookupTable" && !$0.signer
              }), lookupAccounts.count == writableCount + readonlyCount else {
            throw WalletRPCError.invalidResponse(
                "v0 Solana resolved account sources did not match its lookups"
            )
        }
        if lookups.isEmpty {
            guard emptyLoadedAddressesOrAbsent(rawLoaded), lookupAccounts.isEmpty else {
                throw WalletRPCError.invalidResponse(
                    "v0 Solana empty lookups carried resolved addresses"
                )
            }
            return
        }
        guard let loaded = rawLoaded as? [String: Any], loaded.count == 2,
              let writable = canonicalAddressArray(loaded["writable"]),
              let readonly = canonicalAddressArray(loaded["readonly"]),
              writable.count == writableCount,
              readonly.count == readonlyCount,
              Set(writable).isDisjoint(with: Set(readonly)),
              Set(writable + readonly).isDisjoint(with: Set(
                  transactionAccounts.map(\.address)
              )),
              lookupAccounts.map(\.address) == writable + readonly,
              lookupAccounts.prefix(writable.count).allSatisfy(\.writable),
              lookupAccounts.dropFirst(writable.count).allSatisfy({ !$0.writable }) else {
            throw WalletRPCError.invalidResponse(
                "v0 Solana loaded addresses were substituted or reordered"
            )
        }
    }

    private static func validateV1TransactionConfig(_ raw: Any?) throws {
        guard let config = raw as? [String: Any], config.count == 4,
              Set(config.keys) == Set([
                  "computeUnitLimit", "heapSize",
                  "loadedAccountsDataSizeLimit", "priorityFee",
              ]),
              let computeLimit = unsigned(config["computeUnitLimit"]),
              computeLimit > 0, computeLimit <= UInt64(UInt32.max),
              optionalUInt32(config["heapSize"]),
              let loadedLimit = unsigned(config["loadedAccountsDataSizeLimit"]),
              loadedLimit <= UInt64(UInt32.max),
              optionalUInt64(config["priorityFee"]) else {
            throw WalletRPCError.invalidResponse(
                "v1 Solana transaction resource limits were malformed"
            )
        }
    }

    private static func byteIndexes(_ raw: Any?) -> [UInt8]? {
        guard let values = raw as? [Any], values.count <= 64 else { return nil }
        var result: [UInt8] = []
        var seen: Set<UInt8> = []
        for value in values {
            guard let number = unsigned(value), number <= UInt64(UInt8.max),
                  seen.insert(UInt8(number)).inserted else { return nil }
            result.append(UInt8(number))
        }
        return result
    }

    private static func canonicalAddressArray(_ raw: Any?) -> [String]? {
        guard let values = raw as? [String], values.count <= 64,
              values.allSatisfy({
                  WalletSolanaBase58.decode($0, exactLength: 32) != nil
              }), Set(values).count == values.count else { return nil }
        return values
    }

    private static func emptyOrAbsent(_ raw: Any?) -> Bool {
        raw == nil || (raw as? [Any])?.isEmpty == true
    }

    private static func emptyLoadedAddressesOrAbsent(_ raw: Any?) -> Bool {
        if raw == nil { return true }
        guard let loaded = raw as? [String: Any], loaded.count == 2,
              let writable = loaded["writable"] as? [Any], writable.isEmpty,
              let readonly = loaded["readonly"] as? [Any], readonly.isEmpty else {
            return false
        }
        return true
    }

    private static func optionalUInt32(_ raw: Any?) -> Bool {
        raw is NSNull || unsigned(raw).map({ $0 <= UInt64(UInt32.max) }) == true
    }

    private static func optionalUInt64(_ raw: Any?) -> Bool {
        raw is NSNull || unsigned(raw) != nil
    }

    private static func transactionDate(
        _ raw: Any?,
        fallback: UInt64?
    ) -> Date? {
        let value = unsigned(raw) ?? fallback
        guard let value, value >= 1_232_000_000 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(value))
        return date <= Date().addingTimeInterval(300) ? date : nil
    }

    private static func unsignedArray(_ value: Any?) -> [UInt64]? {
        guard let rows = value as? [Any] else { return nil }
        var result: [UInt64] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let value = unsigned(row) else { return nil }
            result.append(value)
        }
        return result
    }

    private static func validActivityLogs(_ value: Any?) -> Bool {
        guard value != nil, !(value is NSNull) else { return true }
        guard let logs = value as? [String], logs.count <= 1_000 else { return false }
        return logs.allSatisfy { $0.utf8.count <= 1_024 }
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

    private func coreAssetEvidence(
        address: String,
        expectedOwner: String
    ) async throws -> WalletSolanaCoreAssetEvidence {
        guard WalletSolanaBase58.decode(address, exactLength: 32) != nil,
              WalletSolanaBase58.decode(expectedOwner, exactLength: 32) != nil else {
            throw WalletGateway.Error.invalidArguments(
                "The Core asset or owner address is malformed."
            )
        }
        let result = try await dictionaryResult(
            method: "getAccountInfo",
            params: [
                address,
                ["commitment": "confirmed", "encoding": "base64"],
            ]
        )
        guard let context = result["context"] as? [String: Any],
              let slot = Self.unsigned(context["slot"]),
              let account = result["value"] as? [String: Any] else {
            throw WalletRPCError.invalidResponse(
                "getAccountInfo returned no Core asset evidence"
            )
        }
        return try Self.parseCoreAssetAccount(
            account, address: address, expectedOwner: expectedOwner, slot: slot
        )
    }

    private static func parseCoreAssetAccount(
        _ account: [String: Any],
        address: String,
        expectedOwner: String,
        slot: UInt64
    ) throws -> WalletSolanaCoreAssetEvidence {
        guard account["owner"] as? String
                == WalletSolanaCanonicalCoreTransfer.coreProgramID,
              account["executable"] as? Bool == false,
              let lamports = unsigned(account["lamports"]), lamports > 0,
              let encoded = account["data"] as? [Any], encoded.count == 2,
              encoded[1] as? String == "base64",
              let base64 = encoded[0] as? String, base64.utf8.count <= 96 * 1_024,
              let data = Data(base64Encoded: base64),
              (43...65_536).contains(data.count),
              data.base64EncodedString() == base64,
              unsigned(account["space"]) == UInt64(data.count) else {
            throw WalletRPCError.invalidResponse(
                "The Core asset account envelope is malformed."
            )
        }
        var offset = 0
        func take(_ count: Int) -> Data? {
            guard count >= 0, offset <= data.count,
                  count <= data.count - offset else { return nil }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        func byte() -> UInt8? { take(1)?.first }
        func littleEndianUInt32() -> UInt32? {
            guard let bytes = take(4) else { return nil }
            return bytes.enumerated().reduce(UInt32(0)) { partial, item in
                partial | (UInt32(item.element) << UInt32(item.offset * 8))
            }
        }
        // Key::AssetV1 is discriminator 1. HashedAssetV1 and every future
        // account shape fail closed before any authority can be prepared.
        guard byte() == 1, let ownerBytes = take(32) else {
            throw WalletRPCError.invalidResponse(
                "The account is not an uncompressed Core AssetV1."
            )
        }
        let owner = WalletSolanaBase58.encode(ownerBytes)
        guard owner == expectedOwner else {
            throw WalletRPCError.invalidResponse(
                "The Core asset is no longer owned by the selected account."
            )
        }
        let updateAuthority: WalletSolanaCoreAssetEvidence.UpdateAuthority
        switch byte() {
        case 0:
            updateAuthority = .none
        case 1:
            guard let authority = take(32) else {
                throw WalletRPCError.invalidResponse(
                    "The Core update authority is truncated."
                )
            }
            updateAuthority = .address(WalletSolanaBase58.encode(authority))
        case 2:
            throw WalletRPCError.invalidResponse(
                "Collection-backed Core assets remain read-only until collection plugins are independently verified."
            )
        default:
            throw WalletRPCError.invalidResponse(
                "The Core update-authority discriminator is unknown."
            )
        }
        for maximumLength in [1_024, 4_096] {
            guard let length = littleEndianUInt32(), length <= maximumLength,
                  let text = take(Int(length)), String(data: text, encoding: .utf8) != nil else {
                throw WalletRPCError.invalidResponse(
                    "The Core on-chain string data is malformed or excessive."
                )
            }
        }
        switch byte() {
        case 0:
            break
        case 1:
            guard take(8) != nil else {
                throw WalletRPCError.invalidResponse(
                    "The Core sequence evidence is truncated."
                )
            }
        default:
            throw WalletRPCError.invalidResponse(
                "The Core sequence discriminator is unknown."
            )
        }
        // Any trailing byte is a plugin header/registry or an unknown future
        // extension. Neither is silently treated as the simple transfer shape.
        guard offset == data.count else {
            throw WalletRPCError.invalidResponse(
                "Plugin-bearing Core assets remain read-only in this adapter."
            )
        }
        let digest = "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        return WalletSolanaCoreAssetEvidence(
            address: address, owner: owner, updateAuthority: updateAuthority,
            dataDigest: digest, slot: slot
        )
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

    private func priorityPlan(
        unitsConsumed: UInt64,
        writableAccounts: [String],
        baseFee: String,
        maximumFee: String
    ) async throws -> PriorityPlan {
        guard unitsConsumed > 0,
              unitsConsumed <= UInt64(WalletSolanaComputeBudget.maximumUnits),
              !writableAccounts.isEmpty, writableAccounts.count <= 128,
              Set(writableAccounts).count == writableAccounts.count,
              writableAccounts.allSatisfy({
                  WalletSolanaBase58.decode($0, exactLength: 32) != nil
              }),
              let base = UInt64(baseFee), String(base) == baseFee,
              let maximum = UInt64(maximumFee), String(maximum) == maximumFee,
              base <= maximum else {
            throw WalletRPCError.invalidResponse(
                "Solana compute or fee evidence was outside reviewed bounds"
            )
        }
        let margin = max(UInt64(1), (unitsConsumed + 9) / 10)
        let bounded = min(
            UInt64(WalletSolanaComputeBudget.maximumUnits),
            unitsConsumed + margin
        )
        guard let limit = UInt32(exactly: bounded), limit > 0 else {
            throw WalletRPCError.invalidResponse(
                "Solana compute-unit evidence could not be bounded"
            )
        }
        let raw = try await rpc(
            method: "getRecentPrioritizationFees", params: [writableAccounts]
        )
        guard let rows = raw as? [Any], !rows.isEmpty, rows.count <= 150 else {
            throw WalletRPCError.invalidResponse(
                "getRecentPrioritizationFees returned excessive data"
            )
        }
        var recent: [(slot: UInt64, price: UInt64)] = []
        var slots: Set<UInt64> = []
        for row in rows {
            guard let value = row as? [String: Any], value.count == 2,
                  let slot = Self.unsigned(value["slot"]),
                  let price = Self.unsigned(value["prioritizationFee"]),
                  slots.insert(slot).inserted else {
                throw WalletRPCError.invalidResponse(
                    "getRecentPrioritizationFees returned malformed evidence"
                )
            }
            recent.append((slot, price))
        }
        let latestPrices = recent.sorted { $0.slot > $1.slot }
            .prefix(20).map(\.price).sorted()
        let recommended = latestPrices.isEmpty ? 0
            : latestPrices[(latestPrices.count - 1) * 3 / 4]
        let available = maximum - base
        let maximumPrice: UInt64
        if available > UInt64.max / 1_000_000 {
            maximumPrice = UInt64.max
        } else {
            maximumPrice = available * 1_000_000 / UInt64(limit)
        }
        let price = min(recommended, maximumPrice)
        guard let priority = Self.priorityFee(
                  computeUnitLimit: limit, priceMicroLamports: price
              ),
              let total = WalletBaseUnits.add(baseFee, priority),
              WalletBaseUnits.lessThanOrEqual(total, maximumFee) else {
            throw WalletRPCError.invalidResponse(
                "Solana priority-fee arithmetic exceeded its exact ceiling"
            )
        }
        return PriorityPlan(
            computeUnitLimit: limit,
            computeUnitPriceMicroLamports: price,
            priorityFeeBaseUnits: priority
        )
    }

    private static func priorityFee(
        computeUnitLimit: UInt32,
        priceMicroLamports: UInt64
    ) -> String? {
        guard let microLamports = WalletBaseUnits.multiply(
            String(computeUnitLimit), String(priceMicroLamports)
        ), let normalized = WalletBaseUnits.normalize(microLamports) else {
            return nil
        }
        guard normalized != "0" else { return "0" }
        if normalized.count <= 6 { return "1" }
        let split = normalized.index(normalized.endIndex, offsetBy: -6)
        let whole = String(normalized[..<split])
        let remainder = normalized[split...]
        return remainder.allSatisfy({ $0 == "0" })
            ? whole : WalletBaseUnits.add(whole, "1")
    }

    private static func validateFinalFee(
        _ totalFee: String,
        baseFee: String,
        plan: PriorityPlan,
        maximumFee: String
    ) throws {
        guard let expected = WalletBaseUnits.add(
                  baseFee, plan.priorityFeeBaseUnits
              ), expected == totalFee,
              WalletBaseUnits.lessThanOrEqual(totalFee, maximumFee) else {
            throw WalletRPCError.invalidResponse(
                "getFeeForMessage did not match the reviewed priority fee"
            )
        }
    }

    private func simulateEvidence(
        _ unsignedTransaction: Data
    ) async throws -> SimulationEvidence {
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
        guard let units = Self.unsigned(value["unitsConsumed"]), units > 0,
              units <= UInt64(WalletSolanaComputeBudget.maximumUnits) else {
            throw WalletRPCError.invalidResponse("simulation compute units were invalid")
        }
        return SimulationEvidence(
            summary: "Reviewed Solana simulation succeeded; \(units) compute units",
            unitsConsumed: units
        )
    }

    private func simulateCoreTransferEvidence(
        _ unsignedTransaction: Data,
        asset: String,
        expectedOwner: String,
        expectedUpdateAuthority: WalletSolanaCoreAssetEvidence.UpdateAuthority
    ) async throws -> SimulationEvidence {
        let result = try await dictionaryResult(method: "simulateTransaction", params: [
            unsignedTransaction.base64EncodedString(),
            [
                "accounts": ["addresses": [asset], "encoding": "base64"],
                "commitment": "confirmed", "encoding": "base64",
                "innerInstructions": true, "replaceRecentBlockhash": false,
                "sigVerify": false,
            ],
        ])
        guard let context = result["context"] as? [String: Any],
              let slot = Self.unsigned(context["slot"]),
              let value = result["value"] as? [String: Any],
              value.keys.contains("err"), value["err"] is NSNull,
              let accounts = value["accounts"] as? [Any], accounts.count == 1,
              let account = accounts.first as? [String: Any] else {
            throw WalletRPCError.simulation(
                "the Core transfer did not return one successful post-state"
            )
        }
        if let inner = value["innerInstructions"], !(inner is NSNull) {
            guard let entries = inner as? [Any], entries.isEmpty else {
                throw WalletRPCError.simulation(
                    "the Core transfer produced unexpected inner instructions"
                )
            }
        }
        let evidence = try Self.parseCoreAssetAccount(
            account, address: asset, expectedOwner: expectedOwner, slot: slot
        )
        guard evidence.updateAuthority == expectedUpdateAuthority else {
            throw WalletRPCError.simulation(
                "the Core transfer unexpectedly changed update authority"
            )
        }
        let logs = (value["logs"] as? [String]) ?? []
        guard logs.count <= 1_000,
              logs.allSatisfy({ $0.utf8.count <= 1_024 }),
              let units = Self.unsigned(value["unitsConsumed"]), units > 0,
              units <= UInt64(WalletSolanaComputeBudget.maximumUnits) else {
            throw WalletRPCError.invalidResponse(
                "Core simulation output exceeded wallet limits"
            )
        }
        return SimulationEvidence(
            summary: "Reviewed Core owner transition succeeded; \(units) compute units",
            unitsConsumed: units
        )
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

    func activity(owner: String) async throws -> [WalletSolanaIndexedActivity] {
        do { return try await primary.activity(owner: owner) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.activity(owner: owner)
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
