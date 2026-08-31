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

    private static let nativeCoinType = "0x2::sui::SUI"
    private static let maximumRequestBytes = 16 * 1_024
    private static let maximumResponseBytes = 1_048_576
    private static let maximumCheckpointAge: TimeInterval = 15 * 60
    private static let maximumFutureDrift: TimeInterval = 2 * 60

    private static let networkStatusQuery = """
    query LocusSuiNetworkStatus {
      chainIdentifier
      checkpoint { sequenceNumber timestamp }
      epoch { epochId referenceGasPrice }
    }
    """

    private static let accountOverviewQuery = """
    query LocusSuiAccountOverview($address: SuiAddress!, $coinType: String!) {
      chainIdentifier
      checkpoint { sequenceNumber timestamp }
      epoch { epochId referenceGasPrice }
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

    func balance(address: String) async throws -> String {
        try await accountOverview(address: address).totalBalance
    }

    func accountOverview(address: String) async throws -> WalletSuiAccountOverview {
        guard Self.isCanonicalAddress(address) else {
            throw WalletGateway.Error.invalidArguments(
                "The Sui balance request requires a canonical 32-byte address."
            )
        }
        let data = try await query(
            document: Self.accountOverviewQuery,
            variables: ["address": address, "coinType": Self.nativeCoinType]
        )
        let status = try parseNetworkStatus(data)
        guard let addressObject = data["address"] as? [String: Any],
              let reportedAddress = addressObject["address"] as? String,
              reportedAddress == address,
              let balance = addressObject["balance"] as? [String: Any],
              let coinType = balance["coinType"] as? [String: Any],
              coinType["repr"] as? String == Self.nativeCoinType,
              let total = Self.canonicalBaseUnits(balance["totalBalance"]),
              let coins = Self.canonicalBaseUnits(balance["coinBalance"]),
              let accumulator = Self.canonicalBaseUnits(balance["addressBalance"]),
              WalletBaseUnits.add(coins, accumulator) == total else {
            throw WalletRPCError.invalidResponse(
                "Sui returned inconsistent native balance evidence"
            )
        }
        return WalletSuiAccountOverview(
            network: status, address: reportedAddress,
            coinType: Self.nativeCoinType, totalBalance: total,
            coinBalance: coins, addressBalance: accumulator
        )
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
              let epoch = data["epoch"] as? [String: Any],
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
        value.count == 66 && value.hasPrefix("0x")
            && value == value.lowercased()
            && value.utf8.dropFirst(2).allSatisfy {
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            }
    }

    private static func canonicalBaseUnits(_ value: Any?) -> String? {
        guard let value = value as? String,
              let normalized = WalletBaseUnits.normalize(value),
              normalized == value else { return nil }
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

    func accountOverview(address: String) async throws -> WalletSuiAccountOverview {
        do { return try await primary.accountOverview(address: address) }
        catch {
            guard let fallback else { throw error }
            return try await fallback.accountOverview(address: address)
        }
    }
}
