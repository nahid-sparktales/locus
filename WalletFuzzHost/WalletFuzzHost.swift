#if !DEBUG || !LOCUS_WALLET_FUZZ_HOST
#error("WalletFuzzHost is a Debug-only verification executable, never a distribution product.")
#endif

import CryptoKit
import Darwin
import Foundation

private typealias WalletFuzzerCallback = @convention(c) (UnsafePointer<UInt8>?, Int) -> Int32
@_silgen_name("LLVMFuzzerRunDriver")
private func walletFuzzerRunDriver(
    _ argc: UnsafeMutablePointer<Int32>,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>,
    _ callback: WalletFuzzerCallback
) -> Int32

/// libFuzzer owns this dedicated process. No XCTest host or application model
/// is started, and the reviewed libFuzzer runtime is linked without patches.
@main
private enum WalletFuzzHost {
    static func main() {
        do {
            let configuration = try WalletFuzzConfiguration(ProcessInfo.processInfo.environment)
            WalletFuzzMetrics.configuration = configuration
            WalletLibFuzzer.target = configuration.target
            guard atexit(walletFuzzWriteProvisionalMetrics) == 0 else {
                throw WalletFuzzConfiguration.Error.invalid
            }
            URLProtocol.registerClass(WalletFuzzNoNetwork.self)
            let selfTest = Array(CommandLine.arguments.dropFirst())
            if !selfTest.isEmpty {
                guard selfTest.count == 2, selfTest[0] == "--self-test" else {
                    throw WalletFuzzConfiguration.Error.invalid
                }
                if selfTest[1] == "fixtures" {
                    guard let path = ProcessInfo.processInfo.environment["LOCUS_FUZZ_FIXTURE_RECEIPT"], path.hasPrefix("/") else {
                        throw WalletFuzzConfiguration.Error.invalid
                    }
                    let completion = DispatchSemaphore(value: 0)
                    let outcome = WalletFuzzFixtureOutcome()
                    Task.detached {
                        do { outcome.result = .success(try await WalletFuzzDecoderFixtures.verifySuccessBranches()) }
                        catch { outcome.result = .failure(error) }
                        completion.signal()
                    }
                    while completion.wait(timeout: .now()) == .timedOut {
                        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
                    }
                    guard let result = outcome.result else { throw WalletFuzzConfiguration.Error.invalid }
                    let verified = try result.get()
                    let payload: [String: Any] = [
                        "schemaVersion": 1, "runID": configuration.runID, "chunkID": configuration.chunkID,
                        "sourceRevision": configuration.sourceRevision,
                        "processID": ProcessInfo.processInfo.processIdentifier,
                        "passedBranches": verified.passedBranches, "readCounts": verified.readCounts,
                    ]
                    try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                        .write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                    exit(EXIT_SUCCESS)
                }
                WalletFuzzMetrics.startedAt = clock()
                switch selfTest[1] {
                case "early-exit": exit(EXIT_SUCCESS)
                case "crash": abort()
                case "sanitizer":
                    walletFuzzSanitizerNegativeControl(offset: max(1, CommandLine.arguments.count))
                    exit(EXIT_SUCCESS)
                case "hang": while true { pause() }
                case "missing-metrics":
                    WalletFuzzMetrics.configuration = nil
                    exit(EXIT_SUCCESS)
                default: throw WalletFuzzConfiguration.Error.invalid
                }
            }

            let timeLimit = configuration.phase == "replay" ? "-runs=0" : "-max_total_time=\(configuration.seconds)"
            let arguments = ["wallet-\(configuration.target)", configuration.corpus.path, timeLimit,
                "-max_len=16384", "-timeout=10", "-rss_limit_mb=4096",
                "-artifact_prefix=\(configuration.artifacts.path)/", "-print_final_stats=1"]
            var strings = arguments.map { strdup($0) }
            guard strings.allSatisfy({ $0 != nil }) else { throw WalletFuzzConfiguration.Error.invalid }
            var count = Int32(strings.count)
            WalletFuzzMetrics.startedAt = clock()
            let result = strings.withUnsafeMutableBufferPointer { buffer -> Int32 in
                var pointer = buffer.baseAddress
                return walletFuzzerRunDriver(&count, &pointer, walletSwiftFuzzerInput)
            }
            // Some driver modes return; others call exit themselves. Both use
            // ordinary process cleanup, and neither supplies a pass verdict.
            exit(result)
        } catch {
            fputs("WalletFuzzHost rejected its harness configuration.\n", stderr)
            exit(EX_USAGE)
        }
    }
}

/// Instrumentation negative control, not a fuzz target or release code. The
/// runtime-derived index is intentionally outside this one-byte allocation.
@inline(never)
private func walletFuzzSanitizerNegativeControl(offset: Int) {
    let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    pointer.initialize(to: 0)
    pointer.advanced(by: offset).pointee = 0x55
    pointer.deinitialize(count: 1)
    pointer.deallocate()
}

/// The semaphore in the synchronous main routine establishes the handoff;
/// this box is not read until the asynchronous fixture task has completed.
private final class WalletFuzzFixtureOutcome: @unchecked Sendable {
    var result: Result<WalletFuzzDecoderFixtures.SuccessReport, Swift.Error>?
}

private struct WalletFuzzConfiguration {
    enum Error: Swift.Error { case invalid }
    let target: String
    let corpus: URL
    let artifacts: URL
    let seconds: Int
    let runID: String
    let chunkID: String
    let phase: String
    let receipt: URL
    let sourceRevision: String
    let seedSHA256: Set<String>

    init(_ environment: [String: String]) throws {
        func required(_ key: String) throws -> String {
            guard let value = environment[key], !value.isEmpty else { throw Error.invalid }
            return value
        }
        func absoluteURL(_ key: String) throws -> URL {
            let value = try required(key)
            guard value.hasPrefix("/") else { throw Error.invalid }
            return URL(fileURLWithPath: value)
        }
        target = try required("LOCUS_FUZZ_TARGET")
        corpus = try absoluteURL("LOCUS_FUZZ_CORPUS")
        artifacts = try absoluteURL("LOCUS_FUZZ_ARTIFACTS")
        receipt = try absoluteURL("LOCUS_FUZZ_RECEIPT")
        runID = try required("LOCUS_FUZZ_RUN_ID")
        chunkID = try required("LOCUS_FUZZ_CHUNK_ID")
        phase = try required("LOCUS_FUZZ_PHASE")
        sourceRevision = try required("LOCUS_FUZZ_REVISION")
        guard let seconds = Int(try required("LOCUS_FUZZ_SECONDS")), (1...86_400).contains(seconds),
              WalletLibFuzzer.targets.contains(target), UUID(uuidString: runID) != nil,
              UUID(uuidString: chunkID) != nil, ["replay", "fuzz"].contains(phase),
              phase == (environment["LOCUS_FUZZ_REPLAY"] == "1" ? "replay" : "fuzz"),
              sourceRevision.count == 40,
              sourceRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !FileManager.default.fileExists(atPath: receipt.path) else { throw Error.invalid }
        self.seconds = seconds
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: Array(keys))
        guard !files.isEmpty, files.count <= 2_048 else { throw Error.invalid }
        var hashes: Set<String> = []
        for file in files {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, (0...16_384).contains(size) else { throw Error.invalid }
            hashes.insert(walletFuzzSHA256(try Data(contentsOf: file)))
        }
        seedSHA256 = hashes
    }
}

private enum WalletFuzzMetrics {
    static var configuration: WalletFuzzConfiguration?
    static var startedAt: clock_t?
    static var iterations: UInt64 = 0
    static var observedSeedSHA256: Set<String> = []
}

private func walletFuzzSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func walletFuzzWriteProvisionalMetrics() {
    guard let configuration = WalletFuzzMetrics.configuration,
          let startedAt = WalletFuzzMetrics.startedAt else { return }
    let payload: [String: Any] = [
        "schemaVersion": 1, "target": configuration.target,
        "runID": configuration.runID, "chunkID": configuration.chunkID,
        "phase": configuration.phase, "sourceRevision": configuration.sourceRevision,
        "processID": ProcessInfo.processInfo.processIdentifier,
        "processCPUSeconds": Double(clock() - startedAt) / Double(CLOCKS_PER_SEC),
        "iterations": WalletFuzzMetrics.iterations,
        "observedSeedSHA256": WalletFuzzMetrics.observedSeedSHA256.sorted(),
    ]
    do {
        // Provisional observations only. The parent must independently validate
        // termination, final statistics, complete replay and matching identities.
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: configuration.receipt, options: .withoutOverwriting)
    } catch {
        fputs("WalletFuzzHost could not preserve provisional metrics.\n", stderr)
    }
}

private enum WalletLibFuzzer {
    static let targets = Set(["evm_decoder", "solana_decoder", "sui_decoder",
        "connections", "namespaces", "authorization", "metadata", "quote_math"])
    static var target = ""
    static let readOnlyEvidence = WalletFuzzDecoderFixtures.evidence()
    static let evm = WalletAccount(id: "fixture-evm", chain: .evm,
        address: "0x1111111111111111111111111111111111111111",
        label: "Fixture", networkIDs: ["eip155:11155111"])
    static let solana = WalletAccount(id: "fixture-solana", chain: .solana,
        address: "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx",
        label: "Fixture", networkIDs: ["solana:devnet"])
    static let sui = WalletAccount(id: "fixture-sui", chain: .sui,
        address: "0xf967e21c16a4757daafec13ee79c0dc5c5329199be5d70c86fd07b8e75db892c",
        label: "Fixture", networkIDs: ["sui:mainnet"])

    static func exercise(_ data: Data) async {
        let text = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch target {
        case "evm_decoder":
            let request = WalletConnectorDappRequest.EVMTransaction(
                from: evm.address, to: "0x3333333333333333333333333333333333333333",
                valueHex: "0x0", dataHex: "0x" + data.map { String(format: "%02x", $0) }.joined())
            _ = try? WalletDappTransactionDecoder.evm(request, networkID: "eip155:11155111", account: evm)
        case "solana_decoder":
            _ = try? await WalletDappTransactionDecoder.solana(
                .init(transactionBase64: data.base64EncodedString(), accountAddress: solana.address,
                      minimumContextSlot: nil), networkID: "solana:devnet", account: solana,
                evidence: readOnlyEvidence)
        case "sui_decoder":
            _ = try? await WalletDappTransactionDecoder.sui(
                .init(transactionBase64: data.base64EncodedString(), accountAddress: sui.address),
                networkID: "sui:mainnet", account: sui,
                reviewedAssets: WalletFuzzDecoderFixtures.reviewedAssets, evidence: readOnlyEvidence)
        case "connections":
            if let record = try? decoder.decode(WalletConnectionRecord.self, from: data) {
                let store = try? WalletPublicStore(path: ":memory:")
                try? store?.upsertConnection(record)
                _ = try? store?.loadConnections()
            }
        case "metadata":
            if let asset = try? decoder.decode(WalletAsset.self, from: data) {
                let store = try? WalletPublicStore(path: ":memory:")
                try? store?.upsertAsset(asset)
                _ = try? store?.loadAssets()
            }
        case "namespaces":
            if let proposals = try? decoder.decode([WalletConnectionNamespaceProposal].self, from: data) {
                _ = try? WalletConnectionNamespaceValidator.validate(proposals,
                    connector: .walletConnect, direction: .locusVaultToDapp)
            }
        case "authorization":
            for (format, account, network) in [(WalletStructuredAuthorizationFormat.siwe, evm, "eip155:11155111"),
                (.siws, solana, "solana:devnet")] {
                _ = try? WalletStructuredAuthorization.parseCanonicalMessage(text, format: format,
                    origin: "https://app.example", networkID: network, account: account,
                    now: Date(timeIntervalSince1970: 2_000_000_000))
            }
        case "quote_math":
            // Bound operand size before quadratic arithmetic, as production quotes do.
            let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            let lhs = String(parts.first?.prefix(256) ?? "")
            let rhs = parts.count > 1 ? String(parts[1].prefix(256)) : "10000"
            if let result = WalletBaseUnits.divide(lhs, by: rhs),
               let product = WalletBaseUnits.multiply(result.quotient, rhs),
               let reconstructed = WalletBaseUnits.add(product, result.remainder) {
                precondition(reconstructed == WalletBaseUnits.normalize(lhs))
                precondition(WalletBaseUnits.compare(result.remainder, rhs) == .orderedAscending)
            }
            _ = WalletBaseUnits.applyingBasisPointFloor(lhs, bpsToKeep: Int(data.first ?? 0) * 41)
        default: preconditionFailure("Unknown fuzz target")
        }
    }
}

private func walletSwiftFuzzerInput(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> Int32 {
    guard (0...16_384).contains(count), bytes != nil || count == 0 else { return 0 }
    let data = bytes.map { Data(bytes: $0, count: count) } ?? Data()
    let completion = DispatchSemaphore(value: 0)
    Task.detached {
        await WalletLibFuzzer.exercise(data)
        completion.signal()
    }
    // There is no application startup. Await the complete production operation;
    // pumping the run loop also permits any explicit main-actor continuation.
    while completion.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
    }
    WalletFuzzMetrics.iterations += 1
    let hash = walletFuzzSHA256(data)
    if WalletFuzzMetrics.configuration?.seedSHA256.contains(hash) == true {
        WalletFuzzMetrics.observedSeedSHA256.insert(hash)
    }
    return 0
}

private final class WalletFuzzNoNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
