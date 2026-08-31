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
    let amountBaseUnits: String?
    let isInbound: Bool?
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

struct WalletSuiGasCostSummary: Equatable, Sendable {
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

struct WalletSuiProviderConfiguration: Sendable {
    let primary: WalletProviderEndpoint
    let fallback: WalletProviderEndpoint?

    static func bundled(
        network: WalletNetworkDescriptor,
        bundle: Bundle = .main
    ) -> WalletSuiProviderConfiguration? {
        guard network.chain == .sui else { return nil }
        let suffix = network.environment == .mainnet ? "Mainnet" : "Testnet"
        let alchemy = endpoint(
            bundle.object(forInfoDictionaryKey: "LocusWalletAlchemySui\(suffix)GraphQLURL")
                as? String,
            provider: .alchemy, network: network, priority: 0
        )
        let quickNode = endpoint(
            bundle.object(forInfoDictionaryKey: "LocusWalletQuickNodeSui\(suffix)GraphQLURL")
                as? String,
            provider: .quickNode, network: network, priority: 1
        )
        if let alchemy {
            return WalletSuiProviderConfiguration(primary: alchemy, fallback: quickNode)
        }

        // Development builds retain the Foundation endpoint. Release
        // verification separately requires restricted vendor endpoints.
        let foundation = network.environment == .mainnet
            ? WalletSuiGraphQLClient.mainnetDefaultEndpoint
            : WalletSuiGraphQLClient.testnetDefaultEndpoint
        guard let primary = endpoint(
            foundation, provider: .userDefined, network: network, priority: 0
        ) else { return nil }
        return WalletSuiProviderConfiguration(primary: primary, fallback: nil)
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
                return results.sorted {
                    $0.identity.canonicalID < $1.identity.canonicalID
                }
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
                  coinType["repr"] as? String == WalletSuiAssetIdentity.nativeCoinType,
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
                    * (Self.balanceChangesPerTransaction + 1) else {
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

    private static func parseBalance(
        _ value: [String: Any],
        networkID: String
    ) -> WalletSuiBalance? {
        guard let coinType = value["coinType"] as? [String: Any],
              let representation = coinType["repr"] as? String,
              WalletSuiAssetIdentity.isCanonicalCoinType(representation),
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
              let moveType = type["repr"] as? String,
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

    private static func parseGasCoin(
        _ value: [String: Any],
        networkID: String,
        owner: String
    ) -> WalletSuiGasCoin? {
        guard let objectID = value["address"] as? String,
              let objectIDBytes = canonicalAddressBytes(objectID),
              let version = unsigned53(value["version"]), version > 0,
              let digest = value["digest"] as? String,
              WalletSolanaBase58.decode(digest, exactLength: 32) != nil,
              let contents = value["contents"] as? [String: Any],
              let type = contents["type"] as? [String: Any],
              type["repr"] as? String == nativeCoinObjectType,
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
        return WalletSuiGasCoin(
            reference: WalletSuiObjectReference(
                objectID: objectID, version: version, digest: digest,
                type: nativeCoinObjectType
            ),
            owner: owner, coinType: WalletSuiAssetIdentity.nativeCoinType,
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
              pageInfo["hasNextPage"] as? Bool == false else {
            throw WalletRPCError.invalidResponse("Sui returned malformed activity effects")
        }
        if status == "FAILURE" {
            guard nodes.isEmpty else {
                throw WalletRPCError.invalidResponse(
                    "A failed Sui transaction reported balance changes"
                )
            }
            return [WalletSuiIndexedActivity(
                id: digest, transactionDigest: digest,
                checkpointSequence: sequence, occurredAt: timestamp,
                sender: sender, successful: false, identity: nil,
                amountBaseUnits: nil, isInbound: nil
            )]
        }
        var seenTypes: Set<String> = []
        var records: [WalletSuiIndexedActivity] = []
        for node in nodes {
            guard let changeOwner = node["owner"] as? [String: Any],
                  let ownerAddress = changeOwner["address"] as? String,
                  WalletSuiAddress.isCanonical(ownerAddress),
                  let coinType = node["coinType"] as? [String: Any],
                  let representation = coinType["repr"] as? String,
                  WalletSuiAssetIdentity.isCanonicalCoinType(representation),
                  let signed = canonicalSignedBaseUnits(node["amount"]) else {
                throw WalletRPCError.invalidResponse(
                    "Sui returned a malformed activity balance change"
                )
            }
            guard ownerAddress == owner, signed != "0" else { continue }
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
            records.append(WalletSuiIndexedActivity(
                id: "\(digest):\(identity.canonicalID)",
                transactionDigest: digest, checkpointSequence: sequence,
                occurredAt: timestamp, sender: sender, successful: true,
                identity: identity, amountBaseUnits: amount,
                isInbound: inbound
            ))
        }
        if records.isEmpty {
            records.append(WalletSuiIndexedActivity(
                id: digest, transactionDigest: digest,
                checkpointSequence: sequence, occurredAt: timestamp,
                sender: sender, successful: true, identity: nil,
                amountBaseUnits: nil, isInbound: nil
            ))
        }
        return records
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
        do { return try await primary.ownedObjects(owner: owner) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.ownedObjects(owner: owner)
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
