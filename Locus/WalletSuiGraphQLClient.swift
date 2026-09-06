import Foundation

struct WalletSuiNetworkStatus: Equatable, Sendable {
    let chainIdentifier: String
    let checkpointSequence: UInt64
    let checkpointTimestamp: Date
    let epoch: UInt64
    let referenceGasPrice: String
}

struct WalletSuiAccountOverview: Equatable, Sendable {
    let network: WalletSuiNetworkStatus
    let address: String
    let coinType: String
    let totalBalance: String
    let coinBalance: String
    let addressBalance: String
}

struct WalletSuiIndexedActivity: Equatable, Sendable {
    let id: String
    let transactionDigest: String
    let checkpointSequence: UInt64
    let occurredAt: Date
    let sender: String?
    let successful: Bool
    let identity: WalletSuiAssetIdentity?
    let objectIdentity: WalletSuiObjectIdentity?
    let objectType: String?
    let objectHasPublicTransfer: Bool?
    let amountBaseUnits: String?
    let isInbound: Bool?
    var counterpartyAddress: String? = nil
    var counterpartyAmountBaseUnits: String? = nil
}

struct WalletSuiGasCoin: Equatable, Sendable {
    let reference: WalletSuiObjectReference
    let owner: String
    let coinType: String
    let balanceBaseUnits: String
}

struct WalletSuiGasCoinSnapshot: Equatable, Sendable {
    let network: WalletSuiNetworkStatus
    let owner: String
    let totalBalance: String
    let coinBalance: String
    let addressBalance: String
    let coins: [WalletSuiGasCoin]
}

struct WalletSuiGasCoinSelection: Equatable, Sendable {
    let snapshot: WalletSuiGasCoinSnapshot
    let coin: WalletSuiGasCoin
    let requiredBalanceBaseUnits: String
}

struct WalletSuiCoinObject: Equatable, Sendable {
    let reference: WalletSuiObjectReference
    let owner: String
    let identity: WalletSuiAssetIdentity
    let balanceBaseUnits: String
}

struct WalletSuiCoinObjectSnapshot: Equatable, Sendable {
    let network: WalletSuiNetworkStatus
    let owner: String
    let identity: WalletSuiAssetIdentity
    let totalBalance: String
    let coinBalance: String
    let addressBalance: String
    let objects: [WalletSuiCoinObject]
}

struct WalletSuiCoinObjectSelection: Equatable, Sendable {
    let snapshot: WalletSuiCoinObjectSnapshot
    let object: WalletSuiCoinObject
    let requiredBalanceBaseUnits: String
}

struct WalletSuiOwnedObjectSnapshot: Equatable, Sendable {
    let network: WalletSuiNetworkStatus
    let owner: String
    let objects: [WalletSuiOwnedObject]
}

struct WalletSuiGasCostSummary: Codable, Equatable, Sendable {
    let computationCost: String
    let storageCost: String
    let storageRebate: String
    let nonRefundableStorageFee: String
    let actualFeeBaseUnits: String
}

struct WalletSuiNativeTransferSimulation: Equatable, Sendable {
    let network: WalletSuiNetworkStatus
    let transactionDigest: String
    let effectsDigest: String
    let sender: String
    let recipient: String
    let amountBaseUnits: String
    let senderDebitBaseUnits: String
    let recipientCreditBaseUnits: String
    let gasObjectID: String
    let gas: WalletSuiGasCostSummary
}

struct WalletSuiCoinTransferSimulation: Equatable, Sendable {
    let network: WalletSuiNetworkStatus
    let transactionDigest: String
    let effectsDigest: String
    let sender: String
    let recipient: String
    let identity: WalletSuiAssetIdentity
    let coinObjectID: String
    let amountBaseUnits: String
    let senderAssetDebitBaseUnits: String
    let senderGasDebitBaseUnits: String
    let recipientCreditBaseUnits: String
    let gasObjectID: String
    let gas: WalletSuiGasCostSummary
}

struct WalletSuiObjectTransferSimulation: Equatable, Sendable {
    let network: WalletSuiNetworkStatus
    let transactionDigest: String
    let effectsDigest: String
    let sender: String
    let recipient: String
    let inputObject: WalletSuiObjectReference
    let outputObject: WalletSuiObjectReference
    let hasPublicTransfer: Bool
    let senderGasDebitBaseUnits: String
    let gasObjectID: String
    let gas: WalletSuiGasCostSummary
}

private struct WalletSuiSimulatedObjectState {
    let reference: WalletSuiObjectReference
    let owner: String
    let hasPublicTransfer: Bool
}

struct WalletSuiExecutionResult: Equatable, Sendable {
    let transactionDigest: String
    let effectsDigest: String
    let checkpointSequence: UInt64
    let finalizedAt: Date
}

struct WalletSuiProviderConfiguration: Sendable {
    let primary: WalletProviderEndpoint
    let fallback: WalletProviderEndpoint?

    static func bundled(
        network: WalletNetworkDescriptor,
        bundle: Bundle = .main,
        reviewRegistry: WalletReviewRegistry? = nil
    ) -> WalletSuiProviderConfiguration? {
        guard network.chain == .sui else { return nil }
        let suffix = network.environment == .mainnet ? "Mainnet" : "Testnet"
        let reviewRegistry = reviewRegistry ?? WalletReviewRegistry.loadBundled(from: bundle)
        let alchemy = reviewed(endpoint(
            bundle.object(forInfoDictionaryKey: "LocusWalletAlchemySui\(suffix)GraphQLURL")
                as? String,
            provider: .alchemy, network: network, priority: 0
        ), network: network, reviewRegistry: reviewRegistry)
        let quickNode = reviewed(endpoint(
            bundle.object(forInfoDictionaryKey: "LocusWalletQuickNodeSui\(suffix)GraphQLURL")
                as? String,
            provider: .quickNode, network: network, priority: 1
        ), network: network, reviewRegistry: reviewRegistry)
        if let alchemy {
            return WalletSuiProviderConfiguration(primary: alchemy, fallback: quickNode)
        }
        if let quickNode {
            return WalletSuiProviderConfiguration(primary: quickNode, fallback: nil)
        }

        // Development builds retain the Foundation endpoint. Release
        // verification separately requires restricted vendor endpoints.
        guard network.environment != .mainnet else { return nil }
        let foundation = WalletSuiGraphQLClient.testnetDefaultEndpoint
        guard let primary = endpoint(
            foundation, provider: .userDefined, network: network, priority: 0
        ) else { return nil }
        return WalletSuiProviderConfiguration(primary: primary, fallback: nil)
    }

    private static func reviewed(
        _ endpoint: WalletProviderEndpoint?,
        network: WalletNetworkDescriptor,
        reviewRegistry: WalletReviewRegistry?
    ) -> WalletProviderEndpoint? {
        guard let endpoint else { return nil }
        guard network.environment != .mainnet
                || reviewRegistry?.containsProvider(endpoint) == true else { return nil }
        return endpoint
    }

    private static func endpoint(
        _ value: String?,
        provider: WalletProviderKind,
        network: WalletNetworkDescriptor,
        priority: Int
    ) -> WalletProviderEndpoint? {
        guard let value,
              let url = WalletSuiGraphQLClient.validatedEndpoint(value) else { return nil }
        return WalletProviderEndpoint(
            id: "\(provider.rawValue):\(network.id)", provider: provider,
            networkID: network.id, url: url, priority: priority,
            expectedIdentity: network.identity
        )
    }
}

actor WalletSuiGraphQLClient {
    static let mainnetDefaultEndpoint = "https://graphql.mainnet.sui.io/graphql"
    static let testnetDefaultEndpoint = "https://graphql.testnet.sui.io/graphql"

    private static let maximumRequestBytes = 16 * 1_024
    private static let maximumResponseBytes = 1_048_576
    private static let maximumCheckpointAge: TimeInterval = 15 * 60
    private static let maximumFutureDrift: TimeInterval = 2 * 60
    private static let balancePageSize = 100
    private static let maximumBalancePages = 100
    private static let maximumBalances = balancePageSize * maximumBalancePages
    private static let objectPageSize = 100
    private static let maximumObjectPages = 50
    private static let maximumObjects = objectPageSize * maximumObjectPages
    private static let gasCoinPageSize = 100
    private static let maximumGasCoinPages = 50
    private static let maximumGasCoins = gasCoinPageSize * maximumGasCoinPages
    private static let nativeCoinObjectType = "0x2::coin::Coin<0x2::sui::SUI>"
    private static let activityPageSize = 50
    private static let maximumActivityPages = 10
    private static let balanceChangesPerTransaction = 100
    private static let objectChangesPerTransaction = 100

    private static let nativeTransferSimulationQuery = """
    query LocusSuiSimulateNativeTransfer($transaction: JSON!) {
      chainIdentifier
      checkpoint {
        sequenceNumber
        timestamp
        epoch { epochId referenceGasPrice }
      }
      simulateTransaction(
        transaction: $transaction
        checksEnabled: true
        doGasSelection: false
      ) {
        effects {
          digest
          effectsDigest
          status
          executionError { message }
          gasEffects {
            gasObject { address }
            gasSummary {
              computationCost
              storageCost
              storageRebate
              nonRefundableStorageFee
            }
          }
          balanceChanges(first: 3) {
            nodes {
              owner { address }
              coinType { repr }
              amount
            }
            pageInfo { hasNextPage }
          }
          objectChanges(first: 3) {
            nodes {
              address
              idCreated
              idDeleted
              inputState {
                address
                version
                digest
                owner {
                  __typename
                  ... on AddressOwner { address { address } }
                }
                asMoveObject {
                  hasPublicTransfer
                  contents { type { repr } }
                }
              }
              outputState {
                address
                version
                digest
                owner {
                  __typename
                  ... on AddressOwner { address { address } }
                }
                asMoveObject {
                  hasPublicTransfer
                  contents { type { repr } }
                }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
    """

    private static let executeTransactionMutation = """
    mutation LocusSuiExecuteTransaction(
      $transactionDataBcs: Base64!
      $signatures: [Base64!]!
    ) {
      executeTransaction(
        transactionDataBcs: $transactionDataBcs
        signatures: $signatures
      ) {
        effects {
          digest
          effectsDigest
          status
          executionError { message }
          checkpoint { sequenceNumber timestamp }
        }
      }
    }
    """

    private static let networkStatusQuery = """
    query LocusSuiNetworkStatus {
      chainIdentifier
      checkpoint {
        sequenceNumber
        timestamp
        epoch { epochId referenceGasPrice }
      }
    }
    """

    private static let accountOverviewQuery = """
    query LocusSuiAccountOverview($address: SuiAddress!, $coinType: String!) {
      chainIdentifier
      checkpoint {
        sequenceNumber
        timestamp
        epoch { epochId referenceGasPrice }
      }
      address(address: $address) {
        address
        balance(coinType: $coinType) {
          coinType { repr }
          totalBalance
          coinBalance
          addressBalance
        }
      }
    }
    """

    private static let balancesQuery = """
    query LocusSuiBalances(
      $address: SuiAddress!
      $first: Int!
      $after: String
      $checkpoint: UInt53
    ) {
      chainIdentifier
      checkpoint(sequenceNumber: $checkpoint) {
        sequenceNumber
        timestamp
        epoch { epochId referenceGasPrice }
      }
      address(address: $address, atCheckpoint: $checkpoint) {
        address
        balances(first: $first, after: $after) {
          nodes {
            coinType { repr }
            totalBalance
            coinBalance
            addressBalance
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    """

    private static let ownedObjectsQuery = """
    query LocusSuiOwnedObjects(
      $address: SuiAddress!
      $first: Int!
      $after: String
      $checkpoint: UInt53
    ) {
      chainIdentifier
      checkpoint(sequenceNumber: $checkpoint) {
        sequenceNumber
        timestamp
        epoch { epochId referenceGasPrice }
      }
      address(address: $address, atCheckpoint: $checkpoint) {
        address
        objects(first: $first, after: $after) {
          nodes {
            address
            version
            digest
            hasPublicTransfer
            contents { type { repr } }
            owner {
              __typename
              ... on AddressOwner { address { address } }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    private static let gasCoinsQuery = """
    query LocusSuiGasCoins(
      $address: SuiAddress!
      $coinType: String!
      $objectType: String!
      $first: Int!
      $after: String
      $checkpoint: UInt53
    ) {
      chainIdentifier
      checkpoint(sequenceNumber: $checkpoint) {
        sequenceNumber
        timestamp
        epoch { epochId referenceGasPrice }
      }
      address(address: $address, atCheckpoint: $checkpoint) {
        address
        balance(coinType: $coinType) {
          coinType { repr }
          totalBalance
          coinBalance
          addressBalance
        }
        objects(first: $first, after: $after, filter: { type: $objectType }) {
          nodes {
            address
            version
            digest
            contents { type { repr } bcs }
            owner {
              __typename
              ... on AddressOwner { address { address } }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    private static let activityQuery = """
    query LocusSuiActivity(
      $address: SuiAddress!
      $first: Int!
      $after: String
      $checkpoint: UInt53
    ) {
      chainIdentifier
      checkpoint(sequenceNumber: $checkpoint) {
        sequenceNumber
        timestamp
        epoch { epochId referenceGasPrice }
      }
      address(address: $address, atCheckpoint: $checkpoint) {
        address
        transactions(first: $first, after: $after, relation: AFFECTED) {
          nodes {
            digest
            sender { address }
            effects {
              digest
              status
              timestamp
              checkpoint { sequenceNumber }
              balanceChanges(first: 100) {
                nodes {
                  owner { address }
                  coinType { repr }
                  amount
                }
                pageInfo { hasNextPage }
              }
              objectChanges(first: 100) {
                nodes {
                  address
                  idCreated
                  idDeleted
                  inputState {
                    address
                    version
                    digest
                    owner {
                      __typename
                      ... on AddressOwner { address { address } }
                    }
                    asMoveObject {
                      hasPublicTransfer
                      contents { type { repr } }
                    }
                  }
                  outputState {
                    address
                    version
                    digest
                    owner {
                      __typename
                      ... on AddressOwner { address { address } }
                    }
                    asMoveObject {
                      hasPublicTransfer
                      contents { type { repr } }
                    }
                  }
                }
                pageInfo { hasNextPage }
              }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    private let network: WalletNetworkDescriptor
    private let endpoint: URL
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(
        network: WalletNetworkDescriptor,
        endpoint: String,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard network.chain == .sui,
              network.identity.kind == .suiChainIdentifier,
              WalletSuiChainIdentity.shortHex(network.identity.value) != nil,
              let endpoint = Self.validatedEndpoint(endpoint) else {
            throw WalletRPCError.invalidEndpoint
        }
        self.network = network
        self.endpoint = endpoint
        self.session = session
        self.now = now
    }

    #if DEBUG
    /// Local GraphQL integration only. Release has no HTTP initializer.
    init(
        testLoopbackEndpoint value: String,
        expectedChainIdentifier: String,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard let url = URL(string: value), url.scheme == "http",
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.fragment == nil,
              WalletSuiChainIdentity.shortHex(expectedChainIdentifier) != nil else {
            throw WalletRPCError.invalidEndpoint
        }
        let testnet = WalletNetworkCatalog.suiTestnet
        network = WalletNetworkDescriptor(
            canonicalID: testnet.id, chain: .sui, environment: .local,
            displayName: "Sui localnet",
            identity: .init(kind: .suiChainIdentifier, value: expectedChainIdentifier),
            nativeAssetID: testnet.nativeAssetID, nativeSymbol: testnet.nativeSymbol,
            nativeDecimals: testnet.nativeDecimals,
            explorerTransactionURLTemplate: testnet.explorerTransactionURLTemplate,
            staticallyReviewedCapabilities: testnet.staticallyReviewedCapabilities
        )
        endpoint = url
        self.session = session
        self.now = now
    }
    #endif

    static func validatedEndpoint(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            return nil
        }
        return url
    }

    func health() async throws -> String {
        let status = try await networkStatus()
        let short = WalletSuiChainIdentity.shortHex(status.chainIdentifier)
            ?? status.chainIdentifier
        return "\(network.displayName) · chain \(short) · checkpoint \(status.checkpointSequence)"
    }

    func networkStatus() async throws -> WalletSuiNetworkStatus {
        let data = try await query(document: Self.networkStatusQuery, variables: [:])
        return try parseNetworkStatus(data)
    }

    func balance(
        address: String,
        coinType: String = WalletSuiAssetIdentity.nativeCoinType
    ) async throws -> String {
        try await accountOverview(address: address, coinType: coinType).totalBalance
    }

    func accountOverview(
        address: String,
        coinType: String = WalletSuiAssetIdentity.nativeCoinType
    ) async throws -> WalletSuiAccountOverview {
        guard Self.isCanonicalAddress(address) else {
            throw WalletGateway.Error.invalidArguments(
                "The Sui balance request requires a canonical 32-byte address."
            )
        }
        guard WalletSuiAssetIdentity.isCanonicalCoinType(coinType) else {
            throw WalletGateway.Error.invalidArguments(
                "The Sui balance request requires a canonical Coin marker type."
            )
        }
        let data = try await query(
            document: Self.accountOverviewQuery,
            variables: ["address": address, "coinType": coinType]
        )
        let status = try parseNetworkStatus(data)
        guard let addressObject = data["address"] as? [String: Any],
              let reportedAddress = addressObject["address"] as? String,
              reportedAddress == address,
              let balance = addressObject["balance"] as? [String: Any],
              let parsed = Self.parseBalance(balance, networkID: network.id),
              parsed.identity.coinType == coinType else {
            throw WalletRPCError.invalidResponse(
                "Sui returned inconsistent Coin balance evidence"
            )
        }
        return WalletSuiAccountOverview(
            network: status, address: reportedAddress,
            coinType: coinType, totalBalance: parsed.totalBalance,
            coinBalance: parsed.coinBalance,
            addressBalance: parsed.addressBalance
        )
    }

    func balances(owner: String) async throws -> [WalletSuiBalance] {
        guard Self.isCanonicalAddress(owner) else {
            throw WalletGateway.Error.invalidArguments(
                "Sui asset discovery requires a canonical 32-byte owner address."
            )
        }
        var after: String?
        var seenCursors: Set<String> = []
        var seenTypes: Set<String> = []
        var expectedStatus: WalletSuiNetworkStatus?
        var results: [WalletSuiBalance] = []
        for _ in 0..<Self.maximumBalancePages {
            let checkpointValue: Any = expectedStatus.map {
                $0.checkpointSequence as Any
            } ?? NSNull()
            let data = try await query(
                document: Self.balancesQuery,
                variables: [
                    "address": owner,
                    "first": Self.balancePageSize,
                    "after": after ?? NSNull(),
                    "checkpoint": checkpointValue,
                ]
            )
            let status = try parseNetworkStatus(data)
            if let expectedStatus, expectedStatus != status {
                throw WalletRPCError.invalidResponse(
                    "Sui balance pagination changed checkpoint evidence"
                )
            }
            expectedStatus = status
            guard let addressObject = data["address"] as? [String: Any],
                  addressObject["address"] as? String == owner,
                  let connection = addressObject["balances"] as? [String: Any],
                  let nodes = connection["nodes"] as? [[String: Any]],
                  nodes.count <= Self.balancePageSize,
                  let pageInfo = connection["pageInfo"] as? [String: Any],
                  let hasNextPage = pageInfo["hasNextPage"] as? Bool else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned malformed balance pagination evidence"
                )
            }
            for node in nodes {
                guard let balance = Self.parseBalance(node, networkID: network.id),
                      seenTypes.insert(balance.identity.coinType).inserted else {
                    throw WalletRPCError.invalidResponse(
                        "Sui returned a malformed or duplicate Coin balance"
                    )
                }
                results.append(balance)
            }
            guard results.count <= Self.maximumBalances else {
                throw WalletRPCError.invalidResponse("Sui returned too many Coin balances")
            }
            if !hasNextPage {
                guard pageInfo["endCursor"] == nil
                        || pageInfo["endCursor"] is NSNull
                        || pageInfo["endCursor"] is String else {
                    throw WalletRPCError.invalidResponse(
                        "Sui returned malformed terminal pagination evidence"
                    )
                }
                return results.sorted { $0.identity.canonicalID < $1.identity.canonicalID }
            }
            guard let cursor = pageInfo["endCursor"] as? String,
                  !cursor.isEmpty, cursor.utf8.count <= 1_024,
                  cursor.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }),
                  seenCursors.insert(cursor).inserted else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned invalid or repeated balance pagination"
                )
            }
            after = cursor
        }
        throw WalletRPCError.invalidResponse("Sui balance pagination was truncated")
    }

    func ownedObjects(owner: String) async throws -> [WalletSuiOwnedObject] {
        try await ownedObjectSnapshot(owner: owner).objects
    }

    func ownedObjectSnapshot(
        owner: String
    ) async throws -> WalletSuiOwnedObjectSnapshot {
        guard Self.isCanonicalAddress(owner) else {
            throw WalletGateway.Error.invalidArguments(
                "Sui object discovery requires a canonical 32-byte owner address."
            )
        }
        var after: String?
        var seenCursors: Set<String> = []
        var seenObjectIDs: Set<String> = []
        var expectedStatus: WalletSuiNetworkStatus?
        var results: [WalletSuiOwnedObject] = []
        for _ in 0..<Self.maximumObjectPages {
            let checkpointValue: Any = expectedStatus.map {
                $0.checkpointSequence as Any
            } ?? NSNull()
            let data = try await query(
                document: Self.ownedObjectsQuery,
                variables: [
                    "address": owner,
                    "first": Self.objectPageSize,
                    "after": after ?? NSNull(),
                    "checkpoint": checkpointValue,
                ]
            )
            let status = try parseNetworkStatus(data)
            if let expectedStatus, expectedStatus != status {
                throw WalletRPCError.invalidResponse(
                    "Sui object pagination changed checkpoint evidence"
                )
            }
            expectedStatus = status
            guard let addressObject = data["address"] as? [String: Any],
                  addressObject["address"] as? String == owner,
                  let connection = addressObject["objects"] as? [String: Any],
                  let nodes = connection["nodes"] as? [[String: Any]],
                  nodes.count <= Self.objectPageSize,
                  let pageInfo = connection["pageInfo"] as? [String: Any],
                  let hasNextPage = pageInfo["hasNextPage"] as? Bool else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned malformed object pagination evidence"
                )
            }
            for node in nodes {
                guard let object = Self.parseOwnedObject(
                    node, networkID: network.id, owner: owner
                ), seenObjectIDs.insert(object.identity.objectID).inserted else {
                    throw WalletRPCError.invalidResponse(
                        "Sui returned a malformed, misowned, or duplicate object"
                    )
                }
                if !Self.isCoinObjectType(object.moveType) {
                    results.append(object)
                }
            }
            guard results.count <= Self.maximumObjects else {
                throw WalletRPCError.invalidResponse("Sui returned too many owned objects")
            }
            if !hasNextPage {
                guard pageInfo["endCursor"] == nil
                        || pageInfo["endCursor"] is NSNull
                        || pageInfo["endCursor"] is String else {
                    throw WalletRPCError.invalidResponse(
                        "Sui returned malformed terminal object pagination evidence"
                    )
                }
                return WalletSuiOwnedObjectSnapshot(
                    network: status, owner: owner,
                    objects: results.sorted {
                        $0.identity.canonicalID < $1.identity.canonicalID
                    }
                )
            }
            guard let cursor = pageInfo["endCursor"] as? String,
                  !cursor.isEmpty, cursor.utf8.count <= 1_024,
                  cursor.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }),
                  seenCursors.insert(cursor).inserted else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned invalid or repeated object pagination"
                )
            }
            after = cursor
        }
        throw WalletRPCError.invalidResponse("Sui object pagination was truncated")
    }

    func nativeGasCoins(owner: String) async throws -> WalletSuiGasCoinSnapshot {
        guard Self.isCanonicalAddress(owner) else {
            throw WalletGateway.Error.invalidArguments(
                "Sui gas-coin discovery requires a canonical 32-byte owner address."
            )
        }
        var after: String?
        var seenCursors: Set<String> = []
        var seenObjectIDs: Set<String> = []
        var expectedStatus: WalletSuiNetworkStatus?
        var expectedBalance: WalletSuiBalance?
        var coins: [WalletSuiGasCoin] = []
        for _ in 0..<Self.maximumGasCoinPages {
            let checkpointValue: Any = expectedStatus.map {
                $0.checkpointSequence as Any
            } ?? NSNull()
            let data = try await query(
                document: Self.gasCoinsQuery,
                variables: [
                    "address": owner,
                    "coinType": WalletSuiAssetIdentity.nativeCoinType,
                    "objectType": Self.nativeCoinObjectType,
                    "first": Self.gasCoinPageSize,
                    "after": after ?? NSNull(),
                    "checkpoint": checkpointValue,
                ]
            )
            let status = try parseNetworkStatus(data)
            if let expectedStatus, expectedStatus != status {
                throw WalletRPCError.invalidResponse(
                    "Sui gas-coin pagination changed checkpoint evidence"
                )
            }
            expectedStatus = status
            guard let addressObject = data["address"] as? [String: Any],
                  addressObject["address"] as? String == owner,
                  let balanceValue = addressObject["balance"] as? [String: Any],
                  let balance = Self.parseBalance(balanceValue, networkID: network.id),
                  balance.identity.coinType == WalletSuiAssetIdentity.nativeCoinType,
                  let connection = addressObject["objects"] as? [String: Any],
                  let nodes = connection["nodes"] as? [[String: Any]],
                  nodes.count <= Self.gasCoinPageSize,
                  let pageInfo = connection["pageInfo"] as? [String: Any],
                  let hasNextPage = pageInfo["hasNextPage"] as? Bool else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned malformed gas-coin evidence"
                )
            }
            if let expectedBalance, expectedBalance != balance {
                throw WalletRPCError.invalidResponse(
                    "Sui gas-coin pagination changed balance evidence"
                )
            }
            expectedBalance = balance
            for node in nodes {
                guard let coin = Self.parseGasCoin(
                    node, networkID: network.id, owner: owner
                ), seenObjectIDs.insert(coin.reference.objectID).inserted else {
                    throw WalletRPCError.invalidResponse(
                        "Sui returned a malformed, misowned, or duplicate gas coin"
                    )
                }
                coins.append(coin)
            }
            guard coins.count <= Self.maximumGasCoins else {
                throw WalletRPCError.invalidResponse("Sui returned too many gas coins")
            }
            if !hasNextPage {
                guard pageInfo["endCursor"] == nil
                        || pageInfo["endCursor"] is NSNull
                        || pageInfo["endCursor"] is String,
                      let expectedStatus, let expectedBalance,
                      Self.sumCoinBalances(coins) == expectedBalance.coinBalance else {
                    throw WalletRPCError.invalidResponse(
                        "Sui gas coins did not reconcile with checkpoint balance evidence"
                    )
                }
                return WalletSuiGasCoinSnapshot(
                    network: expectedStatus, owner: owner,
                    totalBalance: expectedBalance.totalBalance,
                    coinBalance: expectedBalance.coinBalance,
                    addressBalance: expectedBalance.addressBalance,
                    coins: coins.sorted(by: Self.gasCoinOrder)
                )
            }
            guard let cursor = pageInfo["endCursor"] as? String,
                  !cursor.isEmpty, cursor.utf8.count <= 1_024,
                  cursor.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }),
                  seenCursors.insert(cursor).inserted else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned invalid or repeated gas-coin pagination"
                )
            }
            after = cursor
        }
        throw WalletRPCError.invalidResponse("Sui gas-coin pagination was truncated")
    }

    func selectNativeGasCoin(
        owner: String,
        requiredBalanceBaseUnits: String
    ) async throws -> WalletSuiGasCoinSelection {
        guard let required = Self.canonicalUInt64(requiredBalanceBaseUnits), required != "0" else {
            throw WalletGateway.Error.invalidArguments(
                "Sui gas selection requires a positive canonical u64 balance."
            )
        }
        let snapshot = try await nativeGasCoins(owner: owner)
        guard let selected = snapshot.coins.first(where: {
            WalletBaseUnits.lessThanOrEqual(required, $0.balanceBaseUnits)
        }) else {
            throw WalletRPCError.invalidResponse(
                "No single reviewed SUI coin can cover the transfer and maximum gas budget"
            )
        }
        return WalletSuiGasCoinSelection(
            snapshot: snapshot, coin: selected, requiredBalanceBaseUnits: required
        )
    }

    func coinObjects(
        owner: String,
        coinType: String
    ) async throws -> WalletSuiCoinObjectSnapshot {
        guard Self.isCanonicalAddress(owner),
              WalletSuiAssetIdentity.isCanonicalCoinType(coinType),
              coinType != WalletSuiAssetIdentity.nativeCoinType else {
            throw WalletGateway.Error.invalidArguments(
                "Sui Coin-object discovery requires a canonical non-native Coin type."
            )
        }
        let objectType = "0x2::coin::Coin<\(coinType)>"
        var after: String?
        var seenCursors: Set<String> = []
        var seenObjectIDs: Set<String> = []
        var expectedStatus: WalletSuiNetworkStatus?
        var expectedBalance: WalletSuiBalance?
        var objects: [WalletSuiCoinObject] = []
        for _ in 0..<Self.maximumGasCoinPages {
            let checkpointValue: Any = expectedStatus.map {
                $0.checkpointSequence as Any
            } ?? NSNull()
            let data = try await query(
                document: Self.gasCoinsQuery,
                variables: [
                    "address": owner, "coinType": coinType,
                    "objectType": objectType,
                    "first": Self.gasCoinPageSize,
                    "after": after ?? NSNull(),
                    "checkpoint": checkpointValue,
                ]
            )
            let status = try parseNetworkStatus(data)
            if let expectedStatus, expectedStatus != status {
                throw WalletRPCError.invalidResponse(
                    "Sui Coin-object pagination changed checkpoint evidence"
                )
            }
            expectedStatus = status
            guard let addressObject = data["address"] as? [String: Any],
                  addressObject["address"] as? String == owner,
                  let balanceValue = addressObject["balance"] as? [String: Any],
                  let balance = Self.parseBalance(balanceValue, networkID: network.id),
                  balance.identity.coinType == coinType,
                  let connection = addressObject["objects"] as? [String: Any],
                  let nodes = connection["nodes"] as? [[String: Any]],
                  nodes.count <= Self.gasCoinPageSize,
                  let pageInfo = connection["pageInfo"] as? [String: Any],
                  let hasNextPage = pageInfo["hasNextPage"] as? Bool else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned malformed Coin-object evidence"
                )
            }
            if let expectedBalance, expectedBalance != balance {
                throw WalletRPCError.invalidResponse(
                    "Sui Coin-object pagination changed balance evidence"
                )
            }
            expectedBalance = balance
            for node in nodes {
                guard let object = Self.parseCoinObject(
                    node, networkID: network.id, owner: owner,
                    coinType: coinType, objectType: objectType
                ), seenObjectIDs.insert(object.reference.objectID).inserted else {
                    throw WalletRPCError.invalidResponse(
                        "Sui returned a malformed, misowned, or duplicate Coin object"
                    )
                }
                objects.append(object)
            }
            guard objects.count <= Self.maximumGasCoins else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned too many Coin objects"
                )
            }
            if !hasNextPage {
                guard pageInfo["endCursor"] == nil
                        || pageInfo["endCursor"] is NSNull
                        || pageInfo["endCursor"] is String,
                      let expectedStatus, let expectedBalance,
                      Self.sumCoinObjectBalances(objects)
                        == expectedBalance.coinBalance else {
                    throw WalletRPCError.invalidResponse(
                        "Sui Coin objects did not reconcile with checkpoint balance evidence"
                    )
                }
                let identity = WalletSuiAssetIdentity(
                    networkID: network.id, coinType: coinType
                )
                return WalletSuiCoinObjectSnapshot(
                    network: expectedStatus, owner: owner, identity: identity,
                    totalBalance: expectedBalance.totalBalance,
                    coinBalance: expectedBalance.coinBalance,
                    addressBalance: expectedBalance.addressBalance,
                    objects: objects.sorted(by: Self.coinObjectOrder)
                )
            }
            guard let cursor = pageInfo["endCursor"] as? String,
                  !cursor.isEmpty, cursor.utf8.count <= 1_024,
                  cursor.unicodeScalars.allSatisfy({
                      $0.isASCII && $0.value >= 0x20
                  }), seenCursors.insert(cursor).inserted else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned invalid or repeated Coin-object pagination"
                )
            }
            after = cursor
        }
        throw WalletRPCError.invalidResponse(
            "Sui Coin-object pagination was truncated"
        )
    }

    func selectCoinObject(
        owner: String,
        coinType: String,
        requiredBalanceBaseUnits: String
    ) async throws -> WalletSuiCoinObjectSelection {
        guard let required = Self.canonicalUInt64(requiredBalanceBaseUnits),
              required != "0" else {
            throw WalletGateway.Error.invalidArguments(
                "Sui Coin selection requires a positive canonical u64 balance."
            )
        }
        let snapshot = try await coinObjects(owner: owner, coinType: coinType)
        guard let selected = snapshot.objects.first(where: {
            WalletBaseUnits.lessThanOrEqual(required, $0.balanceBaseUnits)
        }) else {
            throw WalletRPCError.invalidResponse(
                "No single reviewed Coin object can cover the transfer amount"
            )
        }
        return WalletSuiCoinObjectSelection(
            snapshot: snapshot, object: selected,
            requiredBalanceBaseUnits: required
        )
    }

    func simulateNativeTransfer(
        transactionBCS: String,
        expectedTransactionDigest: String,
        sender: String,
        recipient: String,
        amountBaseUnits: String,
        maximumFeeBaseUnits: String,
        gasObjectID: String
    ) async throws -> WalletSuiNativeTransferSimulation {
        guard let transaction = Data(base64Encoded: transactionBCS),
              !transaction.isEmpty, transaction.count <= Self.maximumRequestBytes / 2,
              transaction.base64EncodedString() == transactionBCS,
              WalletSolanaBase58.decode(expectedTransactionDigest, exactLength: 32) != nil,
              Self.isCanonicalAddress(sender), Self.isCanonicalAddress(recipient),
              sender != recipient, Self.isCanonicalAddress(gasObjectID),
              let amount = Self.canonicalUInt64(amountBaseUnits), amount != "0",
              let maximumFee = Self.canonicalUInt64(maximumFeeBaseUnits),
              maximumFee != "0" else {
            throw WalletGateway.Error.invalidArguments(
                "Sui simulation requires canonical signer-built transaction evidence."
            )
        }
        let data = try await query(
            document: Self.nativeTransferSimulationQuery,
            variables: ["transaction": ["bcs": ["value": transactionBCS]]]
        )
        let status = try parseNetworkStatus(data)
        guard let simulation = data["simulateTransaction"] as? [String: Any],
              let effects = simulation["effects"] as? [String: Any],
              effects["digest"] as? String == expectedTransactionDigest,
              let effectsDigest = effects["effectsDigest"] as? String,
              WalletSolanaBase58.decode(effectsDigest, exactLength: 32) != nil,
              effects["status"] as? String == "SUCCESS",
              effects["executionError"] == nil || effects["executionError"] is NSNull,
              let gasEffects = effects["gasEffects"] as? [String: Any],
              let gasObject = gasEffects["gasObject"] as? [String: Any],
              gasObject["address"] as? String == gasObjectID,
              let summary = gasEffects["gasSummary"] as? [String: Any],
              let computation = Self.canonicalUInt53BaseUnits(summary["computationCost"]),
              let storage = Self.canonicalUInt53BaseUnits(summary["storageCost"]),
              let rebate = Self.canonicalUInt53BaseUnits(summary["storageRebate"]),
              let nonRefundable = Self.canonicalUInt53BaseUnits(
                  summary["nonRefundableStorageFee"]
              ),
              // Sui defines the sender charge as computation + storage - rebate.
              // The non-refundable portion is already excluded from that rebate.
              let gross = WalletBaseUnits.add(computation, storage),
              let actualFee = WalletBaseUnits.subtract(gross, rebate),
              actualFee != "0", WalletBaseUnits.lessThanOrEqual(actualFee, maximumFee),
              let changes = effects["balanceChanges"] as? [String: Any],
              let nodes = changes["nodes"] as? [[String: Any]], nodes.count == 2,
              let pageInfo = changes["pageInfo"] as? [String: Any],
              pageInfo["hasNextPage"] as? Bool == false else {
            throw WalletRPCError.invalidResponse(
                "Sui simulation did not return exact successful native-transfer effects"
            )
        }
        var senderDebit: String?
        var recipientCredit: String?
        for node in nodes {
            guard let owner = node["owner"] as? [String: Any],
                  let address = owner["address"] as? String,
                  address == sender || address == recipient,
                  let coinType = node["coinType"] as? [String: Any],
                  Self.normalizedWireCoinType(coinType["repr"]) == WalletSuiAssetIdentity.nativeCoinType,
                  let signed = Self.canonicalSignedBaseUnits(node["amount"]) else {
                throw WalletRPCError.invalidResponse(
                    "Sui simulation returned an unexpected balance change"
                )
            }
            if address == sender, signed.hasPrefix("-") {
                guard senderDebit == nil else {
                    throw WalletRPCError.invalidResponse(
                        "Sui simulation duplicated the sender debit"
                    )
                }
                senderDebit = String(signed.dropFirst())
            } else if address == recipient, !signed.hasPrefix("-") {
                guard recipientCredit == nil else {
                    throw WalletRPCError.invalidResponse(
                        "Sui simulation duplicated the recipient credit"
                    )
                }
                recipientCredit = signed
            } else {
                throw WalletRPCError.invalidResponse(
                    "Sui simulation reversed a native-transfer balance change"
                )
            }
        }
        guard let senderDebit, let recipientCredit,
              recipientCredit == amount,
              WalletBaseUnits.add(amount, actualFee) == senderDebit else {
            throw WalletRPCError.invalidResponse(
                "Sui simulation changed the reviewed amount or gas debit"
            )
        }
        return WalletSuiNativeTransferSimulation(
            network: status, transactionDigest: expectedTransactionDigest,
            effectsDigest: effectsDigest, sender: sender, recipient: recipient,
            amountBaseUnits: amount, senderDebitBaseUnits: senderDebit,
            recipientCreditBaseUnits: recipientCredit, gasObjectID: gasObjectID,
            gas: WalletSuiGasCostSummary(
                computationCost: computation, storageCost: storage,
                storageRebate: rebate, nonRefundableStorageFee: nonRefundable,
                actualFeeBaseUnits: actualFee
            )
        )
    }

    func simulateCoinTransfer(
        transactionBCS: String,
        expectedTransactionDigest: String,
        sender: String,
        recipient: String,
        identity: WalletSuiAssetIdentity,
        coinObjectID: String,
        amountBaseUnits: String,
        maximumFeeBaseUnits: String,
        gasObjectID: String
    ) async throws -> WalletSuiCoinTransferSimulation {
        guard identity.networkID == network.id,
              identity.coinType != WalletSuiAssetIdentity.nativeCoinType,
              let transaction = Data(base64Encoded: transactionBCS),
              !transaction.isEmpty, transaction.count <= Self.maximumRequestBytes / 2,
              transaction.base64EncodedString() == transactionBCS,
              WalletSolanaBase58.decode(expectedTransactionDigest, exactLength: 32) != nil,
              Self.isCanonicalAddress(sender), Self.isCanonicalAddress(recipient),
              sender != recipient, Self.isCanonicalAddress(coinObjectID),
              Self.isCanonicalAddress(gasObjectID), coinObjectID != gasObjectID,
              let amount = Self.canonicalUInt64(amountBaseUnits), amount != "0",
              let maximumFee = Self.canonicalUInt64(maximumFeeBaseUnits),
              maximumFee != "0" else {
            throw WalletGateway.Error.invalidArguments(
                "Sui Coin simulation requires canonical signer-built transaction evidence."
            )
        }
        let data = try await query(
            document: Self.nativeTransferSimulationQuery,
            variables: ["transaction": ["bcs": ["value": transactionBCS]]]
        )
        let status = try parseNetworkStatus(data)
        guard let simulation = data["simulateTransaction"] as? [String: Any],
              let effects = simulation["effects"] as? [String: Any],
              effects["digest"] as? String == expectedTransactionDigest,
              let effectsDigest = effects["effectsDigest"] as? String,
              WalletSolanaBase58.decode(effectsDigest, exactLength: 32) != nil,
              effects["status"] as? String == "SUCCESS",
              effects["executionError"] == nil || effects["executionError"] is NSNull,
              let gasEffects = effects["gasEffects"] as? [String: Any],
              let gasObject = gasEffects["gasObject"] as? [String: Any],
              gasObject["address"] as? String == gasObjectID,
              let summary = gasEffects["gasSummary"] as? [String: Any],
              let computation = Self.canonicalUInt53BaseUnits(summary["computationCost"]),
              let storage = Self.canonicalUInt53BaseUnits(summary["storageCost"]),
              let rebate = Self.canonicalUInt53BaseUnits(summary["storageRebate"]),
              let nonRefundable = Self.canonicalUInt53BaseUnits(
                  summary["nonRefundableStorageFee"]
              ),
              let gross = WalletBaseUnits.add(computation, storage),
              let actualFee = WalletBaseUnits.subtract(gross, rebate),
              actualFee != "0", WalletBaseUnits.lessThanOrEqual(actualFee, maximumFee),
              let changes = effects["balanceChanges"] as? [String: Any],
              let nodes = changes["nodes"] as? [[String: Any]], nodes.count == 3,
              let pageInfo = changes["pageInfo"] as? [String: Any],
              pageInfo["hasNextPage"] as? Bool == false else {
            throw WalletRPCError.invalidResponse(
                "Sui simulation did not return exact successful Coin-transfer effects"
            )
        }
        var senderAssetDebit: String?
        var senderGasDebit: String?
        var recipientCredit: String?
        for node in nodes {
            guard let owner = node["owner"] as? [String: Any],
                  let address = owner["address"] as? String,
                  let coinType = node["coinType"] as? [String: Any],
                  let representation = Self.normalizedWireCoinType(coinType["repr"]),
                  let signed = Self.canonicalSignedBaseUnits(node["amount"]) else {
                throw WalletRPCError.invalidResponse(
                    "Sui simulation returned an undecodable Coin balance change"
                )
            }
            switch (address, representation, signed.hasPrefix("-")) {
            case (sender, identity.coinType, true):
                guard senderAssetDebit == nil else {
                    throw WalletRPCError.invalidResponse(
                        "Sui simulation duplicated the Coin sender debit"
                    )
                }
                senderAssetDebit = String(signed.dropFirst())
            case (recipient, identity.coinType, false):
                guard recipientCredit == nil else {
                    throw WalletRPCError.invalidResponse(
                        "Sui simulation duplicated the Coin recipient credit"
                    )
                }
                recipientCredit = signed
            case (sender, WalletSuiAssetIdentity.nativeCoinType, true):
                guard senderGasDebit == nil else {
                    throw WalletRPCError.invalidResponse(
                        "Sui simulation duplicated the gas debit"
                    )
                }
                senderGasDebit = String(signed.dropFirst())
            default:
                throw WalletRPCError.invalidResponse(
                    "Sui simulation returned an unexpected Coin-transfer balance change"
                )
            }
        }
        guard let senderAssetDebit, let senderGasDebit, let recipientCredit,
              senderAssetDebit == amount, recipientCredit == amount,
              senderGasDebit == actualFee else {
            throw WalletRPCError.invalidResponse(
                "Sui simulation changed the reviewed Coin amount or gas debit"
            )
        }
        return WalletSuiCoinTransferSimulation(
            network: status, transactionDigest: expectedTransactionDigest,
            effectsDigest: effectsDigest, sender: sender, recipient: recipient,
            identity: identity, coinObjectID: coinObjectID,
            amountBaseUnits: amount, senderAssetDebitBaseUnits: senderAssetDebit,
            senderGasDebitBaseUnits: senderGasDebit,
            recipientCreditBaseUnits: recipientCredit, gasObjectID: gasObjectID,
            gas: WalletSuiGasCostSummary(
                computationCost: computation, storageCost: storage,
                storageRebate: rebate, nonRefundableStorageFee: nonRefundable,
                actualFeeBaseUnits: actualFee
            )
        )
    }

    func simulateObjectTransfer(
        transactionBCS: String,
        expectedTransactionDigest: String,
        sender: String,
        recipient: String,
        inputObject: WalletSuiObjectReference,
        maximumFeeBaseUnits: String,
        gasObject: WalletSuiObjectReference
    ) async throws -> WalletSuiObjectTransferSimulation {
        guard inputObject.objectID != gasObject.objectID,
              inputObject.type != Self.nativeCoinObjectType,
              let transaction = Data(base64Encoded: transactionBCS),
              !transaction.isEmpty, transaction.count <= Self.maximumRequestBytes / 2,
              transaction.base64EncodedString() == transactionBCS,
              WalletSolanaBase58.decode(expectedTransactionDigest, exactLength: 32) != nil,
              Self.isCanonicalAddress(sender), Self.isCanonicalAddress(recipient),
              sender != recipient,
              Self.isCanonicalAddress(inputObject.objectID), inputObject.version > 0,
              WalletSolanaBase58.decode(inputObject.digest, exactLength: 32) != nil,
              Self.isSafeMoveTypeLabel(inputObject.type),
              Self.isCanonicalAddress(gasObject.objectID), gasObject.version > 0,
              WalletSolanaBase58.decode(gasObject.digest, exactLength: 32) != nil,
              gasObject.type == Self.nativeCoinObjectType,
              let maximumFee = Self.canonicalUInt64(maximumFeeBaseUnits),
              maximumFee != "0" else {
            throw WalletGateway.Error.invalidArguments(
                "Sui object simulation requires canonical signer-built evidence."
            )
        }
        let data = try await query(
            document: Self.nativeTransferSimulationQuery,
            variables: ["transaction": ["bcs": ["value": transactionBCS]]]
        )
        let status = try parseNetworkStatus(data)
        guard let simulation = data["simulateTransaction"] as? [String: Any],
              let effects = simulation["effects"] as? [String: Any],
              effects["digest"] as? String == expectedTransactionDigest,
              let effectsDigest = effects["effectsDigest"] as? String,
              WalletSolanaBase58.decode(effectsDigest, exactLength: 32) != nil,
              effects["status"] as? String == "SUCCESS",
              effects["executionError"] == nil || effects["executionError"] is NSNull,
              let gasEffects = effects["gasEffects"] as? [String: Any],
              let returnedGasObject = gasEffects["gasObject"] as? [String: Any],
              returnedGasObject["address"] as? String == gasObject.objectID,
              let summary = gasEffects["gasSummary"] as? [String: Any],
              let computation = Self.canonicalUInt53BaseUnits(summary["computationCost"]),
              let storage = Self.canonicalUInt53BaseUnits(summary["storageCost"]),
              let rebate = Self.canonicalUInt53BaseUnits(summary["storageRebate"]),
              let nonRefundable = Self.canonicalUInt53BaseUnits(
                  summary["nonRefundableStorageFee"]
              ),
              let gross = WalletBaseUnits.add(computation, storage),
              let actualFee = WalletBaseUnits.subtract(gross, rebate),
              actualFee != "0", WalletBaseUnits.lessThanOrEqual(actualFee, maximumFee),
              let balances = effects["balanceChanges"] as? [String: Any],
              let balanceNodes = balances["nodes"] as? [[String: Any]],
              balanceNodes.count == 1,
              let balancePage = balances["pageInfo"] as? [String: Any],
              balancePage["hasNextPage"] as? Bool == false,
              let balanceOwner = balanceNodes[0]["owner"] as? [String: Any],
              balanceOwner["address"] as? String == sender,
              let balanceType = balanceNodes[0]["coinType"] as? [String: Any],
              Self.normalizedWireCoinType(balanceType["repr"]) == WalletSuiAssetIdentity.nativeCoinType,
              let signedGas = Self.canonicalSignedBaseUnits(balanceNodes[0]["amount"]),
              signedGas == "-\(actualFee)",
              let changes = effects["objectChanges"] as? [String: Any],
              let nodes = changes["nodes"] as? [[String: Any]], nodes.count == 2,
              let objectPage = changes["pageInfo"] as? [String: Any],
              objectPage["hasNextPage"] as? Bool == false else {
            throw WalletRPCError.invalidResponse(
                "Sui simulation did not return exact successful object-transfer effects"
            )
        }
        var transferredInput: WalletSuiSimulatedObjectState?
        var transferredOutput: WalletSuiSimulatedObjectState?
        var gasInput: WalletSuiSimulatedObjectState?
        var gasOutput: WalletSuiSimulatedObjectState?
        for node in nodes {
            guard node["idCreated"] as? Bool == false,
                  node["idDeleted"] as? Bool == false,
                  let address = node["address"] as? String,
                  address == inputObject.objectID || address == gasObject.objectID,
                  let input = node["inputState"] as? [String: Any],
                  let output = node["outputState"] as? [String: Any],
                  let parsedInput = Self.parseSimulationObjectState(input),
                  let parsedOutput = Self.parseSimulationObjectState(output),
                  parsedInput.reference.objectID == address,
                  parsedOutput.reference.objectID == address,
                  parsedOutput.reference.version > parsedInput.reference.version else {
                throw WalletRPCError.invalidResponse(
                    "Sui simulation returned malformed object ownership effects"
                )
            }
            if address == inputObject.objectID {
                guard transferredInput == nil,
                      parsedInput.reference == inputObject,
                      parsedInput.owner == sender,
                      parsedInput.hasPublicTransfer,
                      parsedOutput.owner == recipient,
                      parsedOutput.reference.type == inputObject.type,
                      parsedOutput.hasPublicTransfer else {
                    throw WalletRPCError.invalidResponse(
                        "Sui simulation changed the reviewed transferred object"
                    )
                }
                transferredInput = parsedInput
                transferredOutput = parsedOutput
            } else {
                guard gasInput == nil,
                      parsedInput.reference == gasObject,
                      parsedInput.owner == sender,
                      parsedInput.reference.type == Self.nativeCoinObjectType,
                      parsedOutput.owner == sender,
                      parsedOutput.reference.type == Self.nativeCoinObjectType else {
                    throw WalletRPCError.invalidResponse(
                        "Sui simulation changed the reviewed gas object"
                    )
                }
                gasInput = parsedInput
                gasOutput = parsedOutput
            }
        }
        guard let transferredInput, let transferredOutput,
              gasInput != nil, gasOutput != nil else {
            throw WalletRPCError.invalidResponse(
                "Sui simulation omitted a reviewed object effect"
            )
        }
        return WalletSuiObjectTransferSimulation(
            network: status, transactionDigest: expectedTransactionDigest,
            effectsDigest: effectsDigest, sender: sender, recipient: recipient,
            inputObject: transferredInput.reference,
            outputObject: transferredOutput.reference,
            hasPublicTransfer: transferredOutput.hasPublicTransfer,
            senderGasDebitBaseUnits: actualFee,
            gasObjectID: gasObject.objectID,
            gas: WalletSuiGasCostSummary(
                computationCost: computation, storageCost: storage,
                storageRebate: rebate, nonRefundableStorageFee: nonRefundable,
                actualFeeBaseUnits: actualFee
            )
        )
    }

    func executeTransaction(
        transactionBCS: String,
        signature: String,
        expectedTransactionDigest: String
    ) async throws -> WalletSuiExecutionResult {
        guard let transaction = Data(base64Encoded: transactionBCS),
              !transaction.isEmpty, transaction.count <= Self.maximumRequestBytes / 2,
              transaction.base64EncodedString() == transactionBCS,
              let signatureBytes = Data(base64Encoded: signature),
              signatureBytes.count == 97,
              signatureBytes.base64EncodedString() == signature,
              WalletSolanaBase58.decode(expectedTransactionDigest, exactLength: 32) != nil else {
            throw WalletGateway.Error.invalidArguments(
                "Sui execution requires canonical signer-produced transaction material."
            )
        }
        // Verify this exact endpoint immediately before the non-idempotent mutation.
        _ = try await networkStatus()
        let data = try await query(
            document: Self.executeTransactionMutation,
            variables: [
                "transactionDataBcs": transactionBCS,
                "signatures": [signature],
            ]
        )
        guard let execution = data["executeTransaction"] as? [String: Any],
              let effects = execution["effects"] as? [String: Any],
              effects["digest"] as? String == expectedTransactionDigest,
              let effectsDigest = effects["effectsDigest"] as? String,
              WalletSolanaBase58.decode(effectsDigest, exactLength: 32) != nil,
              effects["status"] as? String == "SUCCESS",
              effects["executionError"] == nil || effects["executionError"] is NSNull,
              let checkpoint = effects["checkpoint"] as? [String: Any],
              let sequence = Self.unsigned53(checkpoint["sequenceNumber"]),
              let timestampText = checkpoint["timestamp"] as? String,
              timestampText.count <= 64,
              let finalizedAt = Self.date(timestampText), sequence > 0,
              finalizedAt <= now().addingTimeInterval(Self.maximumFutureDrift),
              finalizedAt >= now().addingTimeInterval(-Self.maximumCheckpointAge) else {
            throw WalletRPCError.invalidResponse(
                "Sui execution did not return matching successful finality evidence"
            )
        }
        return WalletSuiExecutionResult(
            transactionDigest: expectedTransactionDigest,
            effectsDigest: effectsDigest,
            checkpointSequence: sequence, finalizedAt: finalizedAt
        )
    }

    func activity(owner: String) async throws -> [WalletSuiIndexedActivity] {
        guard Self.isCanonicalAddress(owner) else {
            throw WalletGateway.Error.invalidArguments(
                "Sui activity requires a canonical 32-byte owner address."
            )
        }
        var after: String?
        var seenCursors: Set<String> = []
        var seenDigests: Set<String> = []
        var expectedStatus: WalletSuiNetworkStatus?
        var results: [WalletSuiIndexedActivity] = []
        for _ in 0..<Self.maximumActivityPages {
            let checkpointValue: Any = expectedStatus.map {
                $0.checkpointSequence as Any
            } ?? NSNull()
            let data = try await query(
                document: Self.activityQuery,
                variables: [
                    "address": owner,
                    "first": Self.activityPageSize,
                    "after": after ?? NSNull(),
                    "checkpoint": checkpointValue,
                ]
            )
            let status = try parseNetworkStatus(data)
            if let expectedStatus, expectedStatus != status {
                throw WalletRPCError.invalidResponse(
                    "Sui activity pagination changed checkpoint evidence"
                )
            }
            expectedStatus = status
            guard let addressObject = data["address"] as? [String: Any],
                  addressObject["address"] as? String == owner,
                  let connection = addressObject["transactions"] as? [String: Any],
                  let nodes = connection["nodes"] as? [[String: Any]],
                  nodes.count <= Self.activityPageSize,
                  let pageInfo = connection["pageInfo"] as? [String: Any],
                  let hasNextPage = pageInfo["hasNextPage"] as? Bool else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned malformed activity pagination evidence"
                )
            }
            for node in nodes {
                guard let digest = node["digest"] as? String,
                      WalletSolanaBase58.decode(digest, exactLength: 32) != nil,
                      seenDigests.insert(digest).inserted else {
                    throw WalletRPCError.invalidResponse(
                        "Sui returned a malformed or duplicate transaction digest"
                    )
                }
                let parsed = try Self.parseActivity(
                    node, digest: digest, owner: owner,
                    networkID: network.id, head: status.checkpointSequence,
                    now: now()
                )
                results.append(contentsOf: parsed)
            }
            guard results.count <= Self.activityPageSize
                    * Self.maximumActivityPages
                    * (Self.balanceChangesPerTransaction
                        + Self.objectChangesPerTransaction + 1) else {
                throw WalletRPCError.invalidResponse("Sui returned too much activity")
            }
            if !hasNextPage {
                guard pageInfo["endCursor"] == nil
                        || pageInfo["endCursor"] is NSNull
                        || pageInfo["endCursor"] is String else {
                    throw WalletRPCError.invalidResponse(
                        "Sui returned malformed terminal activity pagination evidence"
                    )
                }
                return results.sorted { $0.occurredAt > $1.occurredAt }
            }
            guard let cursor = pageInfo["endCursor"] as? String,
                  !cursor.isEmpty, cursor.utf8.count <= 1_024,
                  cursor.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }),
                  seenCursors.insert(cursor).inserted else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned invalid or repeated activity pagination"
                )
            }
            after = cursor
        }
        throw WalletRPCError.invalidResponse("Sui activity pagination was truncated")
    }

    private func query(
        document: String,
        variables: [String: Any]
    ) async throws -> [String: Any] {
        let body = try JSONSerialization.data(
            withJSONObject: ["query": document, "variables": variables],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard body.count <= Self.maximumRequestBytes else {
            throw WalletRPCError.invalidResponse("Sui GraphQL request exceeded its limit")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              responseData.count <= Self.maximumResponseBytes else {
            throw WalletRPCError.invalidResponse("Sui GraphQL transport failed or was oversized")
        }
        let object = try JSONSerialization.jsonObject(with: responseData)
        guard let envelope = object as? [String: Any] else {
            throw WalletRPCError.invalidResponse("Sui GraphQL returned a non-object envelope")
        }
        if let errors = envelope["errors"] {
            guard let rows = errors as? [[String: Any]], !rows.isEmpty else {
                throw WalletRPCError.invalidResponse("Sui GraphQL returned malformed errors")
            }
            let message = rows.compactMap { $0["message"] as? String }
                .map(Self.sanitizedError).joined(separator: "; ")
            throw WalletRPCError.rpc(
                code: -32_000,
                message: message.isEmpty ? "Sui GraphQL rejected the request" : message
            )
        }
        guard let data = envelope["data"] as? [String: Any] else {
            throw WalletRPCError.invalidResponse("Sui GraphQL returned no data")
        }
        return data
    }

    private func parseNetworkStatus(_ data: [String: Any]) throws -> WalletSuiNetworkStatus {
        guard let chainIdentifier = data["chainIdentifier"] as? String,
              chainIdentifier.count <= 64,
              WalletSuiChainIdentity.matches(
                  expected: network.identity.value, reported: chainIdentifier
              ),
              let checkpoint = data["checkpoint"] as? [String: Any],
              let sequence = Self.unsigned53(checkpoint["sequenceNumber"]),
              let timestampText = checkpoint["timestamp"] as? String,
              timestampText.count <= 64,
              let timestamp = Self.date(timestampText),
              let epoch = checkpoint["epoch"] as? [String: Any],
              let epochID = Self.unsigned53(epoch["epochId"]),
              let gasPrice = Self.canonicalBaseUnits(epoch["referenceGasPrice"]),
              gasPrice != "0" else {
            if let reported = data["chainIdentifier"] as? String,
               !WalletSuiChainIdentity.matches(
                   expected: network.identity.value, reported: reported
               ) {
                throw WalletRPCError.wrongChain(reported)
            }
            throw WalletRPCError.invalidResponse("Sui returned malformed network evidence")
        }
        let current = now()
        guard timestamp <= current.addingTimeInterval(Self.maximumFutureDrift),
              timestamp >= current.addingTimeInterval(-Self.maximumCheckpointAge) else {
            throw WalletRPCError.invalidResponse("Sui checkpoint evidence is stale")
        }
        return WalletSuiNetworkStatus(
            chainIdentifier: chainIdentifier, checkpointSequence: sequence,
            checkpointTimestamp: timestamp, epoch: epochID,
            referenceGasPrice: gasPrice
        )
    }

    private static func isCanonicalAddress(_ value: String) -> Bool {
        WalletSuiAddress.isCanonical(value)
    }

    private static func canonicalBaseUnits(_ value: Any?) -> String? {
        guard let value = value as? String,
              let normalized = WalletBaseUnits.normalize(value),
              normalized == value else { return nil }
        return value
    }

    // GraphQL MoveType.repr uses fully padded package addresses (Sui 1.79.0,
    // 46f18562f1f5af2438d35828e8b62d5e0b972db7, TypeInput::to_canonical_string).
    // This is a wire representation conversion, never a public manifest parser
    // or authority grant. Only package address padding changes; identifiers,
    // generic structure, case, and numeric address identity remain exact.
    static func normalizedWireMoveType(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty,
              value.utf8.count <= 512,
              value.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { return nil }
        var parser = WireMoveTypeParser(bytes: Array(value.utf8))
        guard let result = parser.parseType(depth: 0, requiresStruct: true),
              parser.offset == parser.bytes.count else { return nil }
        return result
    }

    private static func normalizedWireCoinType(_ value: Any?) -> String? {
        guard let result = normalizedWireMoveType(value),
              WalletSuiAssetIdentity.isCanonicalCoinType(result) else { return nil }
        return result
    }

    private struct WireMoveTypeParser {
        let bytes: [UInt8]
        var offset = 0
        var nodes = 0

        mutating func parseType(depth: Int, requiresStruct: Bool = false) -> String? {
            guard depth < 16, nodes < 64 else { return nil }
            nodes += 1
            if take("0x") {
                let start = offset
                while offset < bytes.count, Self.isHex(bytes[offset]) { offset += 1 }
                let hex = bytes[start..<offset]
                // Accept the stable upstream 32-byte spelling or the existing
                // canonical short spelling, never arbitrary partial padding.
                guard !hex.isEmpty, hex.count <= 64,
                      hex.count == 64 || hex.first != 48 || hex.count == 1,
                      take("::"), let module = identifier(), take("::"),
                      let name = identifier() else { return nil }
                let significant = hex.drop(while: { $0 == 48 })
                let address = significant.isEmpty ? "0" : String(decoding: significant, as: UTF8.self)
                var result = "0x\(address)::\(module)::\(name)"
                if take("<") {
                    var arguments: [String] = []
                    repeat {
                        guard arguments.count < 16,
                              let argument = parseType(depth: depth + 1) else { return nil }
                        arguments.append(argument)
                    } while take(",")
                    guard take(">") else { return nil }
                    result += "<\(arguments.joined(separator: ","))>"
                }
                return result
            }
            guard !requiresStruct, let name = identifier() else { return nil }
            if name == "vector" {
                guard take("<"), let element = parseType(depth: depth + 1), take(">") else { return nil }
                return "vector<\(element)>"
            }
            return ["bool", "u8", "u16", "u32", "u64", "u128", "u256", "address", "signer"]
                .contains(name) ? name : nil
        }

        mutating func identifier() -> String? {
            guard offset < bytes.count, Self.isIdentifierStart(bytes[offset]) else { return nil }
            let start = offset
            offset += 1
            while offset < bytes.count,
                  Self.isIdentifierStart(bytes[offset]) || (48...57).contains(bytes[offset]) {
                offset += 1
            }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }

        mutating func take(_ token: String) -> Bool {
            let tokenBytes = Array(token.utf8)
            guard bytes[offset...].starts(with: tokenBytes) else { return false }
            offset += tokenBytes.count
            return true
        }

        static func isHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (97...102).contains(byte)
        }

        static func isIdentifierStart(_ byte: UInt8) -> Bool {
            byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }

    private static func parseBalance(
        _ value: [String: Any],
        networkID: String
    ) -> WalletSuiBalance? {
        guard let coinType = value["coinType"] as? [String: Any],
              let representation = normalizedWireCoinType(coinType["repr"]),
              let total = canonicalBaseUnits(value["totalBalance"]),
              let coins = canonicalBaseUnits(value["coinBalance"]),
              let accumulator = canonicalBaseUnits(value["addressBalance"]),
              WalletBaseUnits.add(coins, accumulator) == total else { return nil }
        return WalletSuiBalance(
            identity: WalletSuiAssetIdentity(
                networkID: networkID, coinType: representation
            ),
            totalBalance: total, coinBalance: coins,
            addressBalance: accumulator
        )
    }

    private static func parseOwnedObject(
        _ value: [String: Any],
        networkID: String,
        owner: String
    ) -> WalletSuiOwnedObject? {
        guard let objectID = value["address"] as? String,
              WalletSuiAddress.isCanonical(objectID),
              let version = unsigned53(value["version"]),
              let digest = value["digest"] as? String,
              WalletSolanaBase58.decode(digest, exactLength: 32) != nil,
              let hasPublicTransfer = value["hasPublicTransfer"] as? Bool,
              let contents = value["contents"] as? [String: Any],
              let type = contents["type"] as? [String: Any],
              let moveType = normalizedWireMoveType(type["repr"]),
              isSafeMoveTypeLabel(moveType),
              let ownerValue = value["owner"] as? [String: Any],
              ownerValue["__typename"] as? String == "AddressOwner",
              let ownerAddress = ownerValue["address"] as? [String: Any],
              ownerAddress["address"] as? String == owner else { return nil }
        return WalletSuiOwnedObject(
            identity: WalletSuiObjectIdentity(
                networkID: networkID, objectID: objectID
            ),
            version: version, digest: digest,
            moveType: moveType, hasPublicTransfer: hasPublicTransfer
        )
    }

    private static func parseSimulationObjectState(
        _ value: [String: Any]
    ) -> WalletSuiSimulatedObjectState? {
        guard let objectID = value["address"] as? String,
              isCanonicalAddress(objectID),
              let version = unsigned53(value["version"]), version > 0,
              let digest = value["digest"] as? String,
              WalletSolanaBase58.decode(digest, exactLength: 32) != nil,
              let owner = value["owner"] as? [String: Any],
              owner["__typename"] as? String == "AddressOwner",
              let ownerValue = owner["address"] as? [String: Any],
              let ownerAddress = ownerValue["address"] as? String,
              isCanonicalAddress(ownerAddress),
              let moveObject = value["asMoveObject"] as? [String: Any],
              let hasPublicTransfer = moveObject["hasPublicTransfer"] as? Bool,
              let contents = moveObject["contents"] as? [String: Any],
              let type = contents["type"] as? [String: Any],
              let moveType = normalizedWireMoveType(type["repr"]),
              isSafeMoveTypeLabel(moveType) else { return nil }
        return WalletSuiSimulatedObjectState(
            reference: WalletSuiObjectReference(
                objectID: objectID, version: version,
                digest: digest, type: moveType
            ),
            owner: ownerAddress, hasPublicTransfer: hasPublicTransfer
        )
    }

    private static func parseGasCoin(
        _ value: [String: Any],
        networkID: String,
        owner: String
    ) -> WalletSuiGasCoin? {
        guard let object = parseCoinObject(
            value, networkID: networkID, owner: owner,
            coinType: WalletSuiAssetIdentity.nativeCoinType,
            objectType: nativeCoinObjectType
        ) else { return nil }
        return WalletSuiGasCoin(
            reference: object.reference, owner: object.owner,
            coinType: object.identity.coinType,
            balanceBaseUnits: object.balanceBaseUnits
        )
    }

    private static func parseCoinObject(
        _ value: [String: Any],
        networkID: String,
        owner: String,
        coinType: String,
        objectType: String
    ) -> WalletSuiCoinObject? {
        guard let objectID = value["address"] as? String,
              let objectIDBytes = canonicalAddressBytes(objectID),
              let version = unsigned53(value["version"]), version > 0,
              let digest = value["digest"] as? String,
              WalletSolanaBase58.decode(digest, exactLength: 32) != nil,
              let contents = value["contents"] as? [String: Any],
              let type = contents["type"] as? [String: Any],
              normalizedWireMoveType(type["repr"]) == objectType,
              let encodedBCS = contents["bcs"] as? String,
              let bcs = Data(base64Encoded: encodedBCS), bcs.count == 40,
              bcs.base64EncodedString() == encodedBCS,
              bcs.prefix(32) == objectIDBytes,
              let ownerValue = value["owner"] as? [String: Any],
              ownerValue["__typename"] as? String == "AddressOwner",
              let ownerAddress = ownerValue["address"] as? [String: Any],
              ownerAddress["address"] as? String == owner else { return nil }
        var balance: UInt64 = 0
        for (index, byte) in bcs.suffix(8).enumerated() {
            balance |= UInt64(byte) << UInt64(index * 8)
        }
        return WalletSuiCoinObject(
            reference: WalletSuiObjectReference(
                objectID: objectID, version: version, digest: digest,
                type: objectType
            ),
            owner: owner,
            identity: WalletSuiAssetIdentity(
                networkID: networkID, coinType: coinType
            ),
            balanceBaseUnits: String(balance)
        )
    }

    private static func canonicalAddressBytes(_ value: String) -> Data? {
        guard WalletSuiAddress.isCanonical(value) else { return nil }
        let hexadecimal = value.dropFirst(2)
        var result = Data()
        result.reserveCapacity(32)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let end = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<end], radix: 16) else { return nil }
            result.append(byte)
            index = end
        }
        return result.count == 32 ? result : nil
    }

    private static func canonicalUInt64(_ value: Any?) -> String? {
        guard let value = canonicalBaseUnits(value), UInt64(value) != nil else { return nil }
        return value
    }

    private static func sumCoinBalances(_ coins: [WalletSuiGasCoin]) -> String? {
        coins.reduce(Optional("0")) { total, coin in
            total.flatMap { WalletBaseUnits.add($0, coin.balanceBaseUnits) }
        }
    }

    private static func sumCoinObjectBalances(
        _ objects: [WalletSuiCoinObject]
    ) -> String? {
        objects.reduce(Optional("0")) { total, object in
            total.flatMap { WalletBaseUnits.add($0, object.balanceBaseUnits) }
        }
    }

    private static func gasCoinOrder(
        _ lhs: WalletSuiGasCoin,
        _ rhs: WalletSuiGasCoin
    ) -> Bool {
        switch WalletBaseUnits.compare(lhs.balanceBaseUnits, rhs.balanceBaseUnits) {
        case .orderedAscending: true
        case .orderedDescending: false
        default: lhs.reference.objectID < rhs.reference.objectID
        }
    }

    private static func coinObjectOrder(
        _ lhs: WalletSuiCoinObject,
        _ rhs: WalletSuiCoinObject
    ) -> Bool {
        switch WalletBaseUnits.compare(lhs.balanceBaseUnits, rhs.balanceBaseUnits) {
        case .orderedAscending: true
        case .orderedDescending: false
        default: lhs.reference.objectID < rhs.reference.objectID
        }
    }

    private static func isSafeMoveTypeLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("/")
            && value.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x21 }
    }

    private static func isCoinObjectType(_ value: String) -> Bool {
        value.hasPrefix("0x2::coin::Coin<") && value.hasSuffix(">")
    }

    private static func parseActivity(
        _ value: [String: Any],
        digest: String,
        owner: String,
        networkID: String,
        head: UInt64,
        now: Date
    ) throws -> [WalletSuiIndexedActivity] {
        let sender: String?
        if value["sender"] is NSNull || value["sender"] == nil {
            sender = nil
        } else {
            guard let senderValue = value["sender"] as? [String: Any],
                  let address = senderValue["address"] as? String,
                  WalletSuiAddress.isCanonical(address) else {
                throw WalletRPCError.invalidResponse("Sui returned a malformed sender")
            }
            sender = address
        }
        guard let effects = value["effects"] as? [String: Any],
              effects["digest"] as? String == digest,
              let status = effects["status"] as? String,
              status == "SUCCESS" || status == "FAILURE",
              let timestampText = effects["timestamp"] as? String,
              timestampText.count <= 64,
              let timestamp = date(timestampText),
              timestamp <= now.addingTimeInterval(maximumFutureDrift),
              let checkpoint = effects["checkpoint"] as? [String: Any],
              let sequence = unsigned53(checkpoint["sequenceNumber"]),
              sequence <= head,
              let changes = effects["balanceChanges"] as? [String: Any],
              let nodes = changes["nodes"] as? [[String: Any]],
              nodes.count <= balanceChangesPerTransaction,
              let pageInfo = changes["pageInfo"] as? [String: Any],
              pageInfo["hasNextPage"] as? Bool == false,
              let objectChanges = effects["objectChanges"] as? [String: Any],
              let objectNodes = objectChanges["nodes"] as? [[String: Any]],
              objectNodes.count <= objectChangesPerTransaction,
              let objectPageInfo = objectChanges["pageInfo"] as? [String: Any],
              objectPageInfo["hasNextPage"] as? Bool == false else {
            throw WalletRPCError.invalidResponse("Sui returned malformed activity effects")
        }
        if status == "FAILURE" {
            guard nodes.isEmpty, objectNodes.isEmpty else {
                throw WalletRPCError.invalidResponse(
                    "A failed Sui transaction reported balance or object changes"
                )
            }
            return [WalletSuiIndexedActivity(
                id: digest, transactionDigest: digest,
                checkpointSequence: sequence, occurredAt: timestamp,
                sender: sender, successful: false, identity: nil,
                objectIdentity: nil, objectType: nil,
                objectHasPublicTransfer: nil,
                amountBaseUnits: nil, isInbound: nil
            )]
        }
        let balanceChanges = try nodes.map { node -> (
            owner: String, representation: String, signed: String
        ) in
            guard let changeOwner = node["owner"] as? [String: Any],
                  let ownerAddress = changeOwner["address"] as? String,
                  WalletSuiAddress.isCanonical(ownerAddress),
                  let coinType = node["coinType"] as? [String: Any],
                  let representation = normalizedWireCoinType(coinType["repr"]),
                  let signed = canonicalSignedBaseUnits(node["amount"]) else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned a malformed activity balance change"
                )
            }
            return (ownerAddress, representation, signed)
        }
        var seenTypes: Set<String> = []
        var records: [WalletSuiIndexedActivity] = []
        for change in balanceChanges {
            guard change.owner == owner, change.signed != "0" else { continue }
            let representation = change.representation
            let signed = change.signed
            guard seenTypes.insert(representation).inserted else {
                throw WalletRPCError.invalidResponse(
                    "Sui repeated one Coin type in transaction balance changes"
                )
            }
            let inbound = !signed.hasPrefix("-")
            let amount = inbound ? signed : String(signed.dropFirst())
            let identity = WalletSuiAssetIdentity(
                networkID: networkID, coinType: representation
            )
            let counterparties = balanceChanges.filter {
                $0.owner != owner && $0.representation == representation
                    && $0.signed != "0" && $0.signed.hasPrefix("-") != signed.hasPrefix("-")
            }
            let counterparty = counterparties.count == 1 ? counterparties[0] : nil
            let counterpartyAmount = counterparty.map {
                $0.signed.hasPrefix("-") ? String($0.signed.dropFirst()) : $0.signed
            }
            records.append(WalletSuiIndexedActivity(
                id: "\(digest):\(identity.canonicalID)",
                transactionDigest: digest, checkpointSequence: sequence,
                occurredAt: timestamp, sender: sender, successful: true,
                identity: identity, objectIdentity: nil, objectType: nil,
                objectHasPublicTransfer: nil, amountBaseUnits: amount,
                isInbound: inbound,
                counterpartyAddress: counterparty?.owner,
                counterpartyAmountBaseUnits: counterpartyAmount
            ))
        }
        var seenObjectIDs: Set<String> = []
        for node in objectNodes {
            guard let objectID = node["address"] as? String,
                  WalletSuiAddress.isCanonical(objectID),
                  let idCreated = node["idCreated"] as? Bool,
                  let idDeleted = node["idDeleted"] as? Bool,
                  seenObjectIDs.insert(objectID).inserted else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned a malformed or duplicate activity object change"
                )
            }
            let inputValue = node["inputState"] as? [String: Any]
            let outputValue = node["outputState"] as? [String: Any]
            let inputAbsent = node["inputState"] == nil
                || node["inputState"] is NSNull
            let outputAbsent = node["outputState"] == nil
                || node["outputState"] is NSNull
            guard !(idCreated && idDeleted) else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned contradictory object lifecycle flags"
                )
            }
            if idCreated {
                guard inputAbsent, let outputValue,
                      let outputOwner = try activityAddressOwnerIfPresent(
                          outputValue
                      ) else {
                    if inputAbsent, outputValue != nil { continue }
                    throw WalletRPCError.invalidResponse(
                        "Sui returned ambiguous object-creation evidence"
                    )
                }
                guard outputOwner == owner else { continue }
                guard let output = parseSimulationObjectState(outputValue),
                      output.reference.objectID == objectID else {
                    throw WalletRPCError.invalidResponse(
                        "Sui returned malformed owned object-creation evidence"
                    )
                }
                guard !isCoinObjectType(output.reference.type) else { continue }
                let identity = WalletSuiObjectIdentity(
                    networkID: networkID, objectID: objectID
                )
                records.append(WalletSuiIndexedActivity(
                    id: "\(digest):\(identity.canonicalID)",
                    transactionDigest: digest, checkpointSequence: sequence,
                    occurredAt: timestamp, sender: sender, successful: true,
                    identity: nil, objectIdentity: identity,
                    objectType: output.reference.type,
                    objectHasPublicTransfer: output.hasPublicTransfer,
                    amountBaseUnits: "1", isInbound: true
                ))
                continue
            }
            if idDeleted {
                guard outputAbsent, let inputValue,
                      let inputOwner = try activityAddressOwnerIfPresent(
                          inputValue
                      ) else {
                    if outputAbsent, inputValue != nil { continue }
                    throw WalletRPCError.invalidResponse(
                        "Sui returned ambiguous object-deletion evidence"
                    )
                }
                guard inputOwner == owner else { continue }
                guard let input = parseSimulationObjectState(inputValue),
                      input.reference.objectID == objectID else {
                    throw WalletRPCError.invalidResponse(
                        "Sui returned malformed owned object-deletion evidence"
                    )
                }
                guard !isCoinObjectType(input.reference.type) else { continue }
                let identity = WalletSuiObjectIdentity(
                    networkID: networkID, objectID: objectID
                )
                records.append(WalletSuiIndexedActivity(
                    id: "\(digest):\(identity.canonicalID)",
                    transactionDigest: digest, checkpointSequence: sequence,
                    occurredAt: timestamp, sender: sender, successful: true,
                    identity: nil, objectIdentity: identity,
                    objectType: input.reference.type,
                    objectHasPublicTransfer: input.hasPublicTransfer,
                    amountBaseUnits: "1", isInbound: false
                ))
                continue
            }
            guard !inputAbsent, !outputAbsent else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned incomplete object-mutation evidence"
                )
            }
            guard let inputValue = node["inputState"] as? [String: Any],
                  let outputValue = node["outputState"] as? [String: Any] else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned an incomplete activity object transfer"
                )
            }
            let rawInputOwner = activityAddressOwner(inputValue)
            let rawOutputOwner = activityAddressOwner(outputValue)
            guard rawInputOwner == owner || rawOutputOwner == owner else { continue }
            guard let input = parseSimulationObjectState(inputValue),
                  let output = parseSimulationObjectState(outputValue),
                  input.reference.objectID == objectID,
                  output.reference.objectID == objectID,
                  output.reference.version > input.reference.version,
                  input.reference.type == output.reference.type,
                  input.hasPublicTransfer == output.hasPublicTransfer else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned ambiguous activity object-transfer evidence"
                )
            }
            // Coin mutations (including the gas coin) and same-owner object
            // writes are not collectible ownership changes.
            guard !isCoinObjectType(input.reference.type),
                  input.owner != output.owner else { continue }
            let inbound = output.owner == owner
            guard inbound || input.owner == owner else {
                throw WalletRPCError.invalidResponse(
                    "Sui substituted activity object ownership"
                )
            }
            let identity = WalletSuiObjectIdentity(
                networkID: networkID, objectID: objectID
            )
            records.append(WalletSuiIndexedActivity(
                id: "\(digest):\(identity.canonicalID)",
                transactionDigest: digest, checkpointSequence: sequence,
                occurredAt: timestamp, sender: sender, successful: true,
                identity: nil, objectIdentity: identity,
                objectType: input.reference.type,
                objectHasPublicTransfer: input.hasPublicTransfer,
                amountBaseUnits: "1", isInbound: inbound,
                counterpartyAddress: inbound ? input.owner : output.owner
            ))
        }
        if records.isEmpty {
            records.append(WalletSuiIndexedActivity(
                id: digest, transactionDigest: digest,
                checkpointSequence: sequence, occurredAt: timestamp,
                sender: sender, successful: true, identity: nil,
                objectIdentity: nil, objectType: nil,
                objectHasPublicTransfer: nil,
                amountBaseUnits: nil, isInbound: nil
            ))
        }
        return records
    }

    private static func activityAddressOwner(_ value: [String: Any]) -> String? {
        guard let owner = value["owner"] as? [String: Any],
              owner["__typename"] as? String == "AddressOwner",
              let address = owner["address"] as? [String: Any],
              let value = address["address"] as? String,
              WalletSuiAddress.isCanonical(value) else { return nil }
        return value
    }

    private static func activityAddressOwnerIfPresent(
        _ value: [String: Any]
    ) throws -> String? {
        guard let owner = value["owner"] as? [String: Any],
              let kind = owner["__typename"] as? String,
              !kind.isEmpty, kind.utf8.count <= 64 else {
            throw WalletRPCError.invalidResponse(
                "Sui returned malformed object-owner evidence"
            )
        }
        guard kind == "AddressOwner" else { return nil }
        guard let address = owner["address"] as? [String: Any],
              let result = address["address"] as? String,
              WalletSuiAddress.isCanonical(result) else {
            throw WalletRPCError.invalidResponse(
                "Sui returned malformed address-owned object evidence"
            )
        }
        return result
    }

    private static func canonicalSignedBaseUnits(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        if value.hasPrefix("-") {
            guard value.count > 1,
                  let magnitude = WalletBaseUnits.normalize(String(value.dropFirst())),
                  magnitude != "0", value == "-\(magnitude)" else { return nil }
            return value
        }
        guard WalletBaseUnits.normalize(value) == value else { return nil }
        return value
    }

    private static func unsigned53(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.decimalValue >= 0,
              number.decimalValue == Decimal(number.uint64Value),
              number.uint64Value <= 9_007_199_254_740_991 else { return nil }
        return number.uint64Value
    }

    private static func canonicalUInt53BaseUnits(_ value: Any?) -> String? {
        unsigned53(value).map(String.init)
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func sanitizedError(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            ($0.value >= 0x20 && $0.value != 0x7f) || $0.value == 0x09
        }.prefix(256)
        let result = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Sui GraphQL rejected the request" : result
    }
}

actor WalletSuiProviderCoordinator {
    let network: WalletNetworkDescriptor
    let primaryEndpoint: WalletProviderEndpoint
    let fallbackEndpoint: WalletProviderEndpoint?

    private let primary: WalletSuiGraphQLClient
    private let fallback: WalletSuiGraphQLClient?

    init(
        network: WalletNetworkDescriptor,
        configuration: WalletSuiProviderConfiguration,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard network.chain == .sui,
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
        primary = try WalletSuiGraphQLClient(
            network: network, endpoint: configuration.primary.url.absoluteString,
            session: session, now: now
        )
        fallback = try configuration.fallback.map {
            try WalletSuiGraphQLClient(
                network: network, endpoint: $0.url.absoluteString,
                session: session, now: now
            )
        }
    }

    func health() async throws -> String {
        do { return try await primary.health() }
        catch {
            guard let fallback else { throw error }
            return try await fallback.health()
        }
    }

    func balance(address: String) async throws -> String {
        do { return try await primary.balance(address: address) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.balance(address: address)
        }
    }

    func balance(address: String, coinType: String) async throws -> String {
        do { return try await primary.balance(address: address, coinType: coinType) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.balance(address: address, coinType: coinType)
        }
    }

    func balances(owner: String) async throws -> [WalletSuiBalance] {
        do { return try await primary.balances(owner: owner) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.balances(owner: owner)
        }
    }

    func ownedObjects(owner: String) async throws -> [WalletSuiOwnedObject] {
        try await ownedObjectSnapshot(owner: owner).objects
    }

    func ownedObjectSnapshot(
        owner: String
    ) async throws -> WalletSuiOwnedObjectSnapshot {
        do { return try await primary.ownedObjectSnapshot(owner: owner) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.ownedObjectSnapshot(owner: owner)
        }
    }

    func nativeGasCoins(owner: String) async throws -> WalletSuiGasCoinSnapshot {
        do { return try await primary.nativeGasCoins(owner: owner) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.nativeGasCoins(owner: owner)
        }
    }

    func selectNativeGasCoin(
        owner: String,
        requiredBalanceBaseUnits: String
    ) async throws -> WalletSuiGasCoinSelection {
        do {
            return try await primary.selectNativeGasCoin(
                owner: owner, requiredBalanceBaseUnits: requiredBalanceBaseUnits
            )
        } catch {
            guard let fallback else { throw error }
            return try await fallback.selectNativeGasCoin(
                owner: owner, requiredBalanceBaseUnits: requiredBalanceBaseUnits
            )
        }
    }

    func coinObjects(
        owner: String,
        coinType: String
    ) async throws -> WalletSuiCoinObjectSnapshot {
        do {
            return try await primary.coinObjects(owner: owner, coinType: coinType)
        } catch {
            guard let fallback else { throw error }
            return try await fallback.coinObjects(owner: owner, coinType: coinType)
        }
    }

    func selectCoinObject(
        owner: String,
        coinType: String,
        requiredBalanceBaseUnits: String
    ) async throws -> WalletSuiCoinObjectSelection {
        do {
            return try await primary.selectCoinObject(
                owner: owner, coinType: coinType,
                requiredBalanceBaseUnits: requiredBalanceBaseUnits
            )
        } catch {
            guard let fallback else { throw error }
            return try await fallback.selectCoinObject(
                owner: owner, coinType: coinType,
                requiredBalanceBaseUnits: requiredBalanceBaseUnits
            )
        }
    }

    func simulateNativeTransfer(
        transactionBCS: String,
        expectedTransactionDigest: String,
        sender: String,
        recipient: String,
        amountBaseUnits: String,
        maximumFeeBaseUnits: String,
        gasObjectID: String
    ) async throws -> WalletSuiNativeTransferSimulation {
        do {
            return try await primary.simulateNativeTransfer(
                transactionBCS: transactionBCS,
                expectedTransactionDigest: expectedTransactionDigest,
                sender: sender, recipient: recipient,
                amountBaseUnits: amountBaseUnits,
                maximumFeeBaseUnits: maximumFeeBaseUnits,
                gasObjectID: gasObjectID
            )
        } catch {
            guard let fallback else { throw error }
            return try await fallback.simulateNativeTransfer(
                transactionBCS: transactionBCS,
                expectedTransactionDigest: expectedTransactionDigest,
                sender: sender, recipient: recipient,
                amountBaseUnits: amountBaseUnits,
                maximumFeeBaseUnits: maximumFeeBaseUnits,
                gasObjectID: gasObjectID
            )
        }
    }

    func simulateCoinTransfer(
        transactionBCS: String,
        expectedTransactionDigest: String,
        sender: String,
        recipient: String,
        identity: WalletSuiAssetIdentity,
        coinObjectID: String,
        amountBaseUnits: String,
        maximumFeeBaseUnits: String,
        gasObjectID: String
    ) async throws -> WalletSuiCoinTransferSimulation {
        do {
            return try await primary.simulateCoinTransfer(
                transactionBCS: transactionBCS,
                expectedTransactionDigest: expectedTransactionDigest,
                sender: sender, recipient: recipient, identity: identity,
                coinObjectID: coinObjectID, amountBaseUnits: amountBaseUnits,
                maximumFeeBaseUnits: maximumFeeBaseUnits,
                gasObjectID: gasObjectID
            )
        } catch {
            guard let fallback else { throw error }
            return try await fallback.simulateCoinTransfer(
                transactionBCS: transactionBCS,
                expectedTransactionDigest: expectedTransactionDigest,
                sender: sender, recipient: recipient, identity: identity,
                coinObjectID: coinObjectID, amountBaseUnits: amountBaseUnits,
                maximumFeeBaseUnits: maximumFeeBaseUnits,
                gasObjectID: gasObjectID
            )
        }
    }

    func simulateObjectTransfer(
        transactionBCS: String,
        expectedTransactionDigest: String,
        sender: String,
        recipient: String,
        inputObject: WalletSuiObjectReference,
        maximumFeeBaseUnits: String,
        gasObject: WalletSuiObjectReference
    ) async throws -> WalletSuiObjectTransferSimulation {
        do {
            return try await primary.simulateObjectTransfer(
                transactionBCS: transactionBCS,
                expectedTransactionDigest: expectedTransactionDigest,
                sender: sender, recipient: recipient, inputObject: inputObject,
                maximumFeeBaseUnits: maximumFeeBaseUnits,
                gasObject: gasObject
            )
        } catch {
            guard let fallback else { throw error }
            return try await fallback.simulateObjectTransfer(
                transactionBCS: transactionBCS,
                expectedTransactionDigest: expectedTransactionDigest,
                sender: sender, recipient: recipient, inputObject: inputObject,
                maximumFeeBaseUnits: maximumFeeBaseUnits,
                gasObject: gasObject
            )
        }
    }

    func executeTransaction(
        transactionBCS: String,
        signature: String,
        expectedTransactionDigest: String
    ) async throws -> WalletSuiExecutionResult {
        // Mutations never fail over automatically: once bytes leave this
        // endpoint, a transport error is an ambiguous broadcast outcome.
        try await primary.executeTransaction(
            transactionBCS: transactionBCS, signature: signature,
            expectedTransactionDigest: expectedTransactionDigest
        )
    }

    func activity(owner: String) async throws -> [WalletSuiIndexedActivity] {
        do { return try await primary.activity(owner: owner) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.activity(owner: owner)
        }
    }

    func accountOverview(address: String) async throws -> WalletSuiAccountOverview {
        do { return try await primary.accountOverview(address: address) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.accountOverview(address: address)
        }
    }
}
