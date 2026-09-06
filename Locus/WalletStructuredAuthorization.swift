import Foundation

enum WalletStructuredAuthorizationError: LocalizedError, Equatable {
    case unsupportedFormat
    case domainMismatch
    case networkMismatch
    case addressMismatch
    case invalidNonce
    case invalidTimeWindow
    case malformedField

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "That sign-in format is unavailable."
        case .domainMismatch: "The sign-in domain does not match its requesting origin."
        case .networkMismatch: "The sign-in chain does not match the selected network."
        case .addressMismatch: "The sign-in address does not match the selected account."
        case .invalidNonce: "The sign-in nonce is malformed or was already used."
        case .invalidTimeWindow: "The sign-in time window is invalid or expired."
        case .malformedField: "The sign-in request contains a malformed field."
        }
    }
}

enum WalletStructuredAuthorization {
    static let maximumLifetime: TimeInterval = 10 * 60
    static let maximumClockSkew: TimeInterval = 5 * 60
    static let maximumResources = 16
    static let maximumCanonicalMessageBytes = 16 * 1_024

    static func validate(
        _ request: WalletStructuredAuthorizationRequest,
        account: WalletAccount,
        now: Date = Date()
    ) throws {
        let addressMatches = account.chain == .evm
            ? account.address.caseInsensitiveCompare(request.address) == .orderedSame
            : account.address == request.address
        guard account.id == request.accountID, addressMatches else {
            throw WalletStructuredAuthorizationError.addressMismatch
        }
        guard account.networkIDs.contains(request.networkID),
              let network = WalletNetworkCatalog.descriptor(id: request.networkID) else {
            throw WalletStructuredAuthorizationError.networkMismatch
        }
        switch (request.format, network.chain) {
        case (.siwe, .evm), (.siws, .solana):
            break
        default:
            throw WalletStructuredAuthorizationError.unsupportedFormat
        }
        switch request.format {
        case .siwe:
            guard request.address.count == 42, request.address.hasPrefix("0x"),
                  request.address.utf8.dropFirst(2).allSatisfy({ byte in
                      (48...57).contains(byte) || (65...70).contains(byte)
                          || (97...102).contains(byte)
                  }) else {
                throw WalletStructuredAuthorizationError.addressMismatch
            }
        case .siws:
            guard WalletSolanaBase58.decode(
                request.address, exactLength: 32
            ) != nil else {
                throw WalletStructuredAuthorizationError.addressMismatch
            }
        }
        guard let origin = normalizedOrigin(request.origin, requireBareOrigin: true),
              let originComponents = URLComponents(string: origin),
              let host = originComponents.host,
              let authority = authority(
                  scheme: originComponents.scheme ?? "",
                  host: host,
                  port: originComponents.port
              ),
              authority.caseInsensitiveCompare(request.domain) == .orderedSame,
              let uriComponents = URLComponents(string: request.uri),
              normalizedOrigin(request.uri, requireBareOrigin: false) == origin,
              uriComponents.fragment == nil else {
            throw WalletStructuredAuthorizationError.domainMismatch
        }
        if network.environment == .mainnet,
           originComponents.scheme?.lowercased() != "https" {
            throw WalletStructuredAuthorizationError.domainMismatch
        }
        guard request.nonce.count >= 8, request.nonce.count <= 64,
              request.nonce.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
                      || (97...122).contains(byte)
              }) else {
            throw WalletStructuredAuthorizationError.invalidNonce
        }
        guard request.issuedAt <= now.addingTimeInterval(maximumClockSkew),
              request.expirationTime > now,
              request.expirationTime > request.issuedAt,
              request.expirationTime.timeIntervalSince(request.issuedAt) <= maximumLifetime,
              request.notBefore.map({
                  $0 <= now.addingTimeInterval(maximumClockSkew)
                      && $0 <= request.expirationTime
              }) ?? true else {
            throw WalletStructuredAuthorizationError.invalidTimeWindow
        }
        guard request.domain.count <= 255,
              request.uri.count <= 2_048,
              request.statement.map({ statement in
                  !statement.contains("\n") && statement.count <= 1_024
                      && !["URI: ", "Version: ", "Chain ID: ", "Nonce: ",
                           "Issued At: ", "Expiration Time: ", "Not Before: ",
                           "Request ID: ", "Resources:"].contains(where: {
                              statement.hasPrefix($0)
                           })
              }) ?? true,
              request.requestID.map({ !$0.contains("\n") && $0.count <= 256 }) ?? true,
              request.resources.count <= maximumResources,
              request.resources.allSatisfy({ resource in
                  guard resource.count <= 2_048,
                        let scheme = URLComponents(string: resource)?.scheme?.lowercased()
                  else { return false }
                  return ["https", "ipfs", "urn"].contains(scheme)
              }) else {
            throw WalletStructuredAuthorizationError.malformedField
        }
    }

    static func canonicalMessage(
        _ request: WalletStructuredAuthorizationRequest,
        account: WalletAccount,
        now: Date = Date()
    ) throws -> String {
        try validate(request, account: account, now: now)
        let chainLabel = request.format == .siwe ? "Ethereum" : "Solana"
        var lines = [
            "\(request.domain) wants you to sign in with your \(chainLabel) account:",
            request.address,
            "",
        ]
        if let statement = request.statement {
            lines.append(statement)
            lines.append("")
        }
        lines.append("URI: \(request.uri)")
        lines.append("Version: 1")
        guard let network = WalletNetworkCatalog.descriptor(id: request.networkID) else {
            throw WalletStructuredAuthorizationError.networkMismatch
        }
        let chainID: String
        if request.format == .siwe {
            chainID = network.identity.value
        } else {
            chainID = switch request.networkID {
            case "solana:mainnet-beta": "mainnet"
            case "solana:devnet": "devnet"
            default: throw WalletStructuredAuthorizationError.networkMismatch
            }
        }
        lines.append("Chain ID: \(chainID)")
        lines.append("Nonce: \(request.nonce)")
        lines.append("Issued At: \(iso8601(request.issuedAt))")
        lines.append("Expiration Time: \(iso8601(request.expirationTime))")
        if let notBefore = request.notBefore {
            lines.append("Not Before: \(iso8601(notBefore))")
        }
        if let requestID = request.requestID {
            lines.append("Request ID: \(requestID)")
        }
        if !request.resources.isEmpty {
            lines.append("Resources:")
            lines.append(contentsOf: request.resources.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    /// Parses only the exact canonical format emitted above. This permits
    /// SIWE/SIWS compatibility without turning `personal_sign` into an
    /// arbitrary-message primitive: the signer still receives typed fields and
    /// independently reconstructs the message before signing.
    static func parseCanonicalMessage(
        _ message: String,
        format: WalletStructuredAuthorizationFormat,
        origin: String,
        networkID: String,
        account: WalletAccount,
        now: Date = Date()
    ) throws -> WalletStructuredAuthorizationRequest {
        guard !message.isEmpty,
              message.utf8.count <= maximumCanonicalMessageBytes,
              !message.contains("\r"), !message.contains("\0") else {
            throw WalletStructuredAuthorizationError.malformedField
        }
        let lines = message.components(separatedBy: "\n")
        guard lines.count >= 9 else {
            throw WalletStructuredAuthorizationError.malformedField
        }
        let chainLabel = format == .siwe ? "Ethereum" : "Solana"
        let headerSuffix = " wants you to sign in with your \(chainLabel) account:"
        guard lines[0].hasSuffix(headerSuffix) else {
            throw WalletStructuredAuthorizationError.unsupportedFormat
        }
        let domain = String(lines[0].dropLast(headerSuffix.count))
        let address = lines[1]
        guard !domain.isEmpty, !address.isEmpty, lines[2].isEmpty else {
            throw WalletStructuredAuthorizationError.malformedField
        }

        var index = 3
        var statement: String?
        if index < lines.count, !lines[index].hasPrefix("URI: ") {
            guard !lines[index].isEmpty, index + 1 < lines.count,
                  lines[index + 1].isEmpty else {
                throw WalletStructuredAuthorizationError.malformedField
            }
            statement = lines[index]
            index += 2
        }
        func take(_ prefix: String) throws -> String {
            guard index < lines.count, lines[index].hasPrefix(prefix) else {
                throw WalletStructuredAuthorizationError.malformedField
            }
            defer { index += 1 }
            let value = String(lines[index].dropFirst(prefix.count))
            guard !value.isEmpty else {
                throw WalletStructuredAuthorizationError.malformedField
            }
            return value
        }
        let uri = try take("URI: ")
        guard try take("Version: ") == "1" else {
            throw WalletStructuredAuthorizationError.malformedField
        }
        let chainID = try take("Chain ID: ")
        guard let network = WalletNetworkCatalog.descriptor(id: networkID) else {
            throw WalletStructuredAuthorizationError.networkMismatch
        }
        let expectedChainID: String = switch format {
        case .siwe: network.identity.value
        case .siws:
            switch networkID {
            case "solana:mainnet-beta": "mainnet"
            case "solana:devnet": "devnet"
            default: throw WalletStructuredAuthorizationError.networkMismatch
            }
        }
        guard chainID == expectedChainID else {
            throw WalletStructuredAuthorizationError.networkMismatch
        }
        let nonce = try take("Nonce: ")
        guard let issuedAt = parseISO8601(try take("Issued At: ")),
              let expirationTime = parseISO8601(try take("Expiration Time: ")) else {
            throw WalletStructuredAuthorizationError.invalidTimeWindow
        }
        var notBefore: Date?
        var requestID: String?
        if index < lines.count, lines[index].hasPrefix("Not Before: ") {
            notBefore = parseISO8601(try take("Not Before: "))
            guard notBefore != nil else {
                throw WalletStructuredAuthorizationError.invalidTimeWindow
            }
        }
        if index < lines.count, lines[index].hasPrefix("Request ID: ") {
            requestID = try take("Request ID: ")
        }
        var resources: [String] = []
        if index < lines.count {
            guard lines[index] == "Resources:" else {
                throw WalletStructuredAuthorizationError.malformedField
            }
            index += 1
            while index < lines.count {
                guard lines[index].hasPrefix("- "), lines[index].count > 2 else {
                    throw WalletStructuredAuthorizationError.malformedField
                }
                resources.append(String(lines[index].dropFirst(2)))
                index += 1
            }
            guard !resources.isEmpty else {
                throw WalletStructuredAuthorizationError.malformedField
            }
        }
        guard index == lines.count else {
            throw WalletStructuredAuthorizationError.malformedField
        }
        let request = WalletStructuredAuthorizationRequest(
            format: format, domain: domain, origin: origin,
            networkID: networkID, accountID: account.id, address: address,
            statement: statement, uri: uri, nonce: nonce, issuedAt: issuedAt,
            expirationTime: expirationTime, notBefore: notBefore,
            requestID: requestID, resources: resources
        )
        try validate(request, account: account, now: now)
        guard try canonicalMessage(request, account: account, now: now) == message else {
            throw WalletStructuredAuthorizationError.malformedField
        }
        return request
    }

    private static func normalizedOrigin(
        _ value: String,
        requireBareOrigin: Bool
    ) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              (!requireBareOrigin || (
                  components.path.isEmpty
                      && components.query == nil
                      && components.fragment == nil
              )) else { return nil }
        let isStandardPort = (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80)
        let port = components.port.map { isStandardPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func authority(
        scheme: String,
        host: String,
        port: Int?
    ) -> String? {
        guard !host.isEmpty else { return nil }
        let standard = (scheme == "https" && port == 443)
            || (scheme == "http" && port == 80)
        return host + (port.map { standard ? "" : ":\($0)" } ?? "")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
