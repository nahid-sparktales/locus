import Foundation

enum WalletUniswapQuoteError: LocalizedError, Equatable {
    case malformedRequest
    case configurationUnavailable
    case noReviewedRoute
    case changedCodeIdentity
    case providerDisagreement
    case staleBlock
    case malformedQuote

    var errorDescription: String? {
        switch self {
        case .malformedRequest: "The swap quote request is malformed."
        case .configurationUnavailable:
            "The signed review manifest does not enable this Uniswap route."
        case .noReviewedRoute:
            "No acyclic, manifest-approved V2 or V3 route is available."
        case .changedCodeIdentity:
            "A reviewed Uniswap contract or pool changed code identity."
        case .providerDisagreement:
            "Independent wallet providers disagreed about the swap quote."
        case .staleBlock: "The providers could not agree on a current quote block."
        case .malformedQuote: "A quote contract returned malformed evidence."
        }
    }
}

struct WalletUniswapRouteCandidate: Equatable, Sendable {
    let protocolVersion: WalletUniversalRouterSwapProtocol
    let pathAssetIDs: [String]
    let feeTiers: [UInt32]
    let pools: [WalletReviewedUniswapPoolIdentity]

    var canonicalKey: String {
        "\(protocolVersion.rawValue):\(pathAssetIDs.joined(separator: ">")):\(feeTiers.map(String.init).joined(separator: ","))"
    }
}

enum WalletUniswapRoutePlanner {
    static func candidates(
        configuration: WalletReviewedUniswapConfiguration,
        inputAssetID: String,
        outputAssetID: String
    ) -> [WalletUniswapRouteCandidate] {
        guard inputAssetID != outputAssetID else { return [] }
        var result: [WalletUniswapRouteCandidate] = []
        for version in [WalletUniversalRouterSwapProtocol.v2, .v3] {
            walk(
                configuration: configuration,
                version: version,
                current: inputAssetID,
                output: outputAssetID,
                path: [inputAssetID], fees: [], pools: [],
                result: &result
            )
        }
        return result.sorted { $0.canonicalKey < $1.canonicalKey }
    }

    private static func walk(
        configuration: WalletReviewedUniswapConfiguration,
        version: WalletUniversalRouterSwapProtocol,
        current: String,
        output: String,
        path: [String],
        fees: [UInt32],
        pools: [WalletReviewedUniswapPoolIdentity],
        result: inout [WalletUniswapRouteCandidate]
    ) {
        guard pools.count < configuration.maximumHops else { return }
        let edges = configuration.pools.filter {
            $0.protocolVersion == version
                && ($0.token0AssetID == current || $0.token1AssetID == current)
        }.sorted {
            let lhs = "\($0.address.lowercased()):\($0.feeTier ?? 0)"
            let rhs = "\($1.address.lowercased()):\($1.feeTier ?? 0)"
            return lhs < rhs
        }
        for pool in edges {
            let next = pool.token0AssetID == current
                ? pool.token1AssetID : pool.token0AssetID
            guard !path.contains(next),
                  next == output
                    || configuration.allowedIntermediaryAssetIDs.contains(next) else {
                continue
            }
            let nextFees: [UInt32]
            switch version {
            case .v2:
                guard pool.feeTier == nil else { continue }
                nextFees = fees
            case .v3:
                guard let fee = pool.feeTier,
                      configuration.allowedFeeTiers.contains(fee) else { continue }
                nextFees = fees + [fee]
            }
            let candidate = WalletUniswapRouteCandidate(
                protocolVersion: version, pathAssetIDs: path + [next],
                feeTiers: nextFees, pools: pools + [pool]
            )
            if next == output {
                result.append(candidate)
            } else {
                walk(
                    configuration: configuration, version: version,
                    current: next, output: output,
                    path: candidate.pathAssetIDs, fees: nextFees,
                    pools: candidate.pools, result: &result
                )
            }
        }
    }
}

extension WalletSepoliaRPCClient {
    func latestBlockNumber() async throws -> UInt64 {
        let result = try await publicRead(method: "eth_blockNumber", params: [])
        guard let value = result as? String,
              let block = WalletEthereumQuantity.hexToUInt64(value) else {
            throw WalletUniswapQuoteError.malformedQuote
        }
        return block
    }

    func uniswapQuotes(
        candidates: [WalletUniswapRouteCandidate],
        configuration: WalletReviewedUniswapConfiguration,
        amountInBaseUnits: String,
        blockNumber: UInt64
    ) async throws -> [WalletUniswapProviderQuote] {
        let blockTag = "0x" + String(blockNumber, radix: 16)
        let blockObject = try await publicRead(
            method: "eth_getBlockByNumber", params: [blockTag, false]
        )
        guard let block = blockObject as? [String: Any],
              let returnedNumber = block["number"] as? String,
              WalletEthereumQuantity.hexToUInt64(returnedNumber) == blockNumber,
              let blockHash = block["hash"] as? String,
              Self.quoteHash(blockHash) else {
            throw WalletUniswapQuoteError.malformedQuote
        }

        for identity in configuration.contracts {
            let observed = try await runtimeCodeHash(address: identity.address)
            guard observed.caseInsensitiveCompare(identity.runtimeCodeHash) == .orderedSame else {
                throw WalletUniswapQuoteError.changedCodeIdentity
            }
        }
        var checkedPools: Set<String> = []
        for pool in candidates.flatMap(\.pools)
        where checkedPools.insert(pool.address.lowercased()).inserted {
            let observed = try await runtimeCodeHash(address: pool.address)
            guard observed.caseInsensitiveCompare(pool.runtimeCodeHash) == .orderedSame else {
                throw WalletUniswapQuoteError.changedCodeIdentity
            }
        }

        var quotes: [WalletUniswapProviderQuote] = []
        for candidate in candidates {
            do {
            let quoteContract: WalletReviewedUniswapContractIdentity?
            switch candidate.protocolVersion {
            case .v2: quoteContract = configuration.contract(.v2Router)
            case .v3: quoteContract = configuration.contract(.v3QuoterV2)
            }
            guard let quoteContract else {
                throw WalletUniswapQuoteError.configurationUnavailable
            }
            var hopOutputs: [String] = []
            var finalGas = "0"
            for endpointIndex in 1..<candidate.pathAssetIDs.count {
                let prefixAssets = Array(candidate.pathAssetIDs[0...endpointIndex])
                let prefixFees = Array(candidate.feeTiers.prefix(endpointIndex))
                let data: String
                switch candidate.protocolVersion {
                case .v2:
                    data = try Self.v2QuoteCalldata(
                        amount: amountInBaseUnits, pathAssetIDs: prefixAssets
                    )
                case .v3:
                    data = try Self.v3QuoteCalldata(
                        amount: amountInBaseUnits, pathAssetIDs: prefixAssets,
                        feeTiers: prefixFees
                    )
                }
                let response = try await publicRead(
                    method: "eth_call",
                    params: [["to": quoteContract.address, "data": data], blockTag]
                )
                guard let encoded = response as? String else {
                    throw WalletUniswapQuoteError.malformedQuote
                }
                let parsed: (amount: String, gas: String)
                switch candidate.protocolVersion {
                case .v2:
                    parsed = try Self.parseV2Quote(
                        encoded, expectedCount: prefixAssets.count
                    )
                case .v3:
                    parsed = try Self.parseV3Quote(encoded)
                }
                guard parsed.amount != "0" else {
                    throw WalletUniswapQuoteError.malformedQuote
                }
                hopOutputs.append(parsed.amount)
                finalGas = parsed.gas
            }
            if candidate.protocolVersion == .v2 {
                let fullData = try Self.v2QuoteCalldata(
                    amount: amountInBaseUnits,
                    pathAssetIDs: candidate.pathAssetIDs
                )
                let gas = try await publicRead(
                    method: "eth_estimateGas",
                    params: [["to": quoteContract.address, "data": fullData], blockTag]
                )
                guard let gasHex = gas as? String,
                      let gasDecimal = WalletEthereumQuantity.hexToDecimal(gasHex) else {
                    throw WalletUniswapQuoteError.malformedQuote
                }
                finalGas = gasDecimal
            }
            quotes.append(WalletUniswapProviderQuote(
                blockNumber: blockNumber, blockHash: blockHash.lowercased(),
                protocolVersion: candidate.protocolVersion,
                pathAssetIDs: candidate.pathAssetIDs,
                feeTiers: candidate.feeTiers,
                perHopOutputBaseUnits: hopOutputs,
                quoteContractAddress: quoteContract.address.lowercased(),
                quoteContractRuntimeCodeHash: quoteContract.runtimeCodeHash.lowercased(),
                gasEstimate: finalGas
            ))
            } catch WalletRPCError.rpc {
                // A reviewed pool may legitimately have no usable liquidity
                // at this block. Provider errors for this candidate are
                // omitted; code-identity and malformed-success failures above
                // remain fatal.
                continue
            }
        }
        return quotes
    }

    private static func v2QuoteCalldata(
        amount: String, pathAssetIDs: [String]
    ) throws -> String {
        guard let amountWord = abiUnsignedWord(amount),
              let countWord = abiUnsignedWord(String(pathAssetIDs.count)) else {
            throw WalletUniswapQuoteError.malformedRequest
        }
        let addresses = try pathAssetIDs.map { try tokenAddress($0) }
        let addressWords = addresses.compactMap(abiAddressWord)
        guard addressWords.count == addresses.count else {
            throw WalletUniswapQuoteError.malformedRequest
        }
        return "0xd06ca61f" + amountWord
            + String(repeating: "0", count: 62) + "40"
            + countWord + addressWords.joined()
    }

    private static func v3QuoteCalldata(
        amount: String, pathAssetIDs: [String], feeTiers: [UInt32]
    ) throws -> String {
        guard pathAssetIDs.count == feeTiers.count + 1,
              let amountWord = abiUnsignedWord(amount) else {
            throw WalletUniswapQuoteError.malformedRequest
        }
        let addresses = try pathAssetIDs.map { try tokenAddress($0) }
        var path = String(addresses[0].dropFirst(2)).lowercased()
        for index in feeTiers.indices {
            path += String(format: "%06x", feeTiers[index])
            path += String(addresses[index + 1].dropFirst(2)).lowercased()
        }
        guard let lengthWord = abiUnsignedWord(String(path.count / 2)) else {
            throw WalletUniswapQuoteError.malformedRequest
        }
        let padded = path + String(repeating: "0", count: (64 - path.count % 64) % 64)
        return "0xcdca1753" + String(repeating: "0", count: 62) + "40"
            + amountWord + lengthWord + padded
    }

    private static func parseV2Quote(
        _ encoded: String, expectedCount: Int
    ) throws -> (amount: String, gas: String) {
        let words = try abiWords(encoded)
        guard words.count == expectedCount + 2,
              abiDecimal(words[0]) == "32",
              abiDecimal(words[1]) == String(expectedCount),
              let amount = abiDecimal(words.last ?? "") else {
            throw WalletUniswapQuoteError.malformedQuote
        }
        return (amount, "0")
    }

    private static func parseV3Quote(_ encoded: String) throws
        -> (amount: String, gas: String) {
        let words = try abiWords(encoded)
        guard words.count >= 4,
              let amount = abiDecimal(words[0]),
              let firstOffset = abiDecimal(words[1]), UInt64(firstOffset) != nil,
              let secondOffset = abiDecimal(words[2]), UInt64(secondOffset) != nil,
              let gas = abiDecimal(words[3]) else {
            throw WalletUniswapQuoteError.malformedQuote
        }
        return (amount, gas)
    }

    private static func abiWords(_ value: String) throws -> [String] {
        let raw = value.lowercased().hasPrefix("0x")
            ? String(value.dropFirst(2)) : value
        guard !raw.isEmpty, raw.count.isMultiple(of: 64), raw.count <= 64 * 1024,
              raw.allSatisfy(\.isHexDigit) else {
            throw WalletUniswapQuoteError.malformedQuote
        }
        return stride(from: 0, to: raw.count, by: 64).map { offset in
            let start = raw.index(raw.startIndex, offsetBy: offset)
            let end = raw.index(start, offsetBy: 64)
            return String(raw[start..<end])
        }
    }

    private static func abiDecimal(_ word: String) -> String? {
        guard word.count == 64 else { return nil }
        return WalletEthereumQuantity.hexToDecimal(word)
    }

    private static func abiUnsignedWord(_ decimal: String) -> String? {
        guard let hex = WalletEthereumQuantity.decimalToHex(decimal) else { return nil }
        let raw = String(hex.dropFirst(2))
        guard raw.count <= 64 else { return nil }
        return String(repeating: "0", count: 64 - raw.count) + raw
    }

    private static func abiAddressWord(_ address: String) -> String? {
        guard address.count == 42, address.hasPrefix("0x"),
              address.dropFirst(2).allSatisfy(\.isHexDigit) else { return nil }
        return String(repeating: "0", count: 24)
            + String(address.dropFirst(2)).lowercased()
    }

    private static func tokenAddress(_ assetID: String) throws -> String {
        guard let identity = WalletEVMAssetIdentity.parse(assetID),
              identity.standard == .erc20, identity.tokenID == nil else {
            throw WalletUniswapQuoteError.malformedRequest
        }
        return identity.contractAddress
    }

    private static func quoteHash(_ value: String) -> Bool {
        value.count == 66 && value.hasPrefix("0x")
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }
}

extension WalletEVMProviderCoordinator {
    func uniswapQuote(
        request: WalletUniswapQuoteRequest,
        configuration: WalletReviewedUniswapConfiguration,
        now: Date = Date()
    ) async throws -> WalletUniswapQuote {
        guard request.networkID == network.id,
              configuration.networkID == network.id,
              request.universalRouterContractID
                == configuration.universalRouterContractID,
              WalletBaseUnits.normalize(request.amountInBaseUnits)
                == request.amountInBaseUnits,
              request.amountInBaseUnits != "0",
              (0...500).contains(request.slippageBPS),
              request.recipient.count == 42,
              request.recipient.hasPrefix("0x"),
              request.recipient.dropFirst(2).allSatisfy(\.isHexDigit) else {
            throw WalletUniswapQuoteError.malformedRequest
        }
        let allCandidates = WalletUniswapRoutePlanner.candidates(
            configuration: configuration,
            inputAssetID: request.inputAssetID,
            outputAssetID: request.outputAssetID
        )
        let routeRequirementCount = [
            request.requiredProtocolVersion != nil,
            request.requiredPathAssetIDs != nil,
            request.requiredFeeTiers != nil,
        ].filter { $0 }.count
        guard routeRequirementCount == 0 || routeRequirementCount == 3 else {
            throw WalletUniswapQuoteError.malformedRequest
        }
        let candidates: [WalletUniswapRouteCandidate]
        if let version = request.requiredProtocolVersion,
           let path = request.requiredPathAssetIDs,
           let fees = request.requiredFeeTiers {
            candidates = allCandidates.filter {
                $0.protocolVersion == version
                    && $0.pathAssetIDs == path && $0.feeTiers == fees
            }
        } else {
            candidates = allCandidates
        }
        guard !candidates.isEmpty else {
            throw WalletUniswapQuoteError.noReviewedRoute
        }

        let primaryHead = try await primary.latestBlockNumber()
        let commonBlock: UInt64
        let agreeingProviderCount: Int
        if let fallback {
            let fallbackHead = try await fallback.latestBlockNumber()
            commonBlock = min(primaryHead, fallbackHead)
            guard max(primaryHead, fallbackHead) - commonBlock <= 6 else {
                throw WalletUniswapQuoteError.staleBlock
            }
            agreeingProviderCount = 2
        } else {
            commonBlock = primaryHead
            agreeingProviderCount = 1
        }
        let primaryQuotes = try await primary.uniswapQuotes(
            candidates: candidates, configuration: configuration,
            amountInBaseUnits: request.amountInBaseUnits,
            blockNumber: commonBlock
        )
        if let fallback {
            let fallbackQuotes = try await fallback.uniswapQuotes(
                candidates: candidates, configuration: configuration,
                amountInBaseUnits: request.amountInBaseUnits,
                blockNumber: commonBlock
            )
            guard primaryQuotes == fallbackQuotes else {
                throw WalletUniswapQuoteError.providerDisagreement
            }
        }
        guard let best = primaryQuotes.sorted(by: { lhs, rhs in
            let left = lhs.perHopOutputBaseUnits.last ?? "0"
            let right = rhs.perHopOutputBaseUnits.last ?? "0"
            switch WalletBaseUnits.compare(left, right) {
            case .orderedDescending: return true
            case .orderedAscending: return false
            default:
                if lhs.pathAssetIDs.count != rhs.pathAssetIDs.count {
                    return lhs.pathAssetIDs.count < rhs.pathAssetIDs.count
                }
                let lhsKey = "\(lhs.protocolVersion.rawValue):\(lhs.pathAssetIDs.joined(separator: ">")):\(lhs.feeTiers.map(String.init).joined(separator: ","))"
                let rhsKey = "\(rhs.protocolVersion.rawValue):\(rhs.pathAssetIDs.joined(separator: ">")):\(rhs.feeTiers.map(String.init).joined(separator: ","))"
                return lhsKey < rhsKey
            }
        }).first, let quotedOutput = best.perHopOutputBaseUnits.last,
        let minimumOutput = WalletBaseUnits.applyingBasisPointFloor(
            quotedOutput, bpsToKeep: 10_000 - request.slippageBPS
        ), minimumOutput != "0" else {
            throw WalletUniswapQuoteError.malformedQuote
        }

        var priceFloors: [String] = []
        var hopInput = request.amountInBaseUnits
        let scaleX36 = "1" + String(repeating: "0", count: 36)
        for hopOutput in best.perHopOutputBaseUnits {
            guard let scaledOutput = WalletBaseUnits.multiply(hopOutput, scaleX36),
                  let rawPrice = WalletBaseUnits.divide(
                    scaledOutput, by: hopInput
                  )?.quotient,
                  let priceFloor = WalletBaseUnits.applyingBasisPointFloor(
                    rawPrice, bpsToKeep: 10_000 - request.slippageBPS
                  ), priceFloor != "0" else {
                throw WalletUniswapQuoteError.malformedQuote
            }
            priceFloors.append(priceFloor)
            hopInput = hopOutput
        }
        let quotedAt = now
        let expiresAt = now.addingTimeInterval(60)
        let nowSeconds = UInt64(max(0, now.timeIntervalSince1970.rounded(.down)))
        let deadline: UInt64
        if let required = request.requiredDeadlineUnixSeconds {
            guard WalletBaseUnits.normalize(required) == required,
                  let value = UInt64(required), value >= nowSeconds,
                  value <= nowSeconds + 600 else {
                throw WalletUniswapQuoteError.malformedRequest
            }
            deadline = value
        } else {
            deadline = nowSeconds + 600
        }
        let evidence = WalletUniswapQuoteEvidence(
            blockNumber: String(commonBlock), blockHash: best.blockHash,
            quoteContractAddress: best.quoteContractAddress,
            quoteContractRuntimeCodeHash: best.quoteContractRuntimeCodeHash,
            perHopOutputBaseUnits: best.perHopOutputBaseUnits,
            gasEstimate: best.gasEstimate, quotedAt: quotedAt,
            expiresAt: expiresAt, agreeingProviderCount: agreeingProviderCount
        )
        let route = WalletExactInputSwapRoute(
            protocolVersion: best.protocolVersion,
            pathAssetIDs: best.pathAssetIDs, feeTiers: best.feeTiers,
            minimumHopPriceX36: priceFloors,
            quotedOutputBaseUnits: quotedOutput,
            slippageBPS: request.slippageBPS,
            deadlineUnixSeconds: String(deadline), quoteEvidence: evidence
        )
        return WalletUniswapQuote(
            action: .exactInputSwap(
                adapterID: WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
                contractID: configuration.universalRouterContractID,
                inputAssetID: request.inputAssetID,
                outputAssetID: request.outputAssetID,
                amountInBaseUnits: request.amountInBaseUnits,
                minimumOutputBaseUnits: minimumOutput,
                recipient: request.recipient, route: route
            ),
            quotedAt: quotedAt, expiresAt: expiresAt
        )
    }
}
