#if LOCUS_LIBFUZZER
import Darwin
import Foundation
import XCTest
@testable import Locus

private typealias WalletFuzzerCallback = @convention(c) (UnsafePointer<UInt8>?, Int) -> Int32
@_silgen_name("LLVMFuzzerRunDriver")
private func walletFuzzerRunDriver(
    _ argc: UnsafeMutablePointer<Int32>,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>,
    _ callback: WalletFuzzerCallback
) -> Int32

/// App-hosted libFuzzer exercises the shipping Swift implementation, including
/// its dependencies, under ASan. This file has no symbols in ordinary builds.
final class WalletLibFuzzerTests: XCTestCase {
    func testCoverageGuidedWalletBoundary() throws {
        let environment = ProcessInfo.processInfo.environment
        let target = try XCTUnwrap(environment["LOCUS_FUZZ_TARGET"])
        let corpus = try XCTUnwrap(environment["LOCUS_FUZZ_CORPUS"])
        let artifacts = try XCTUnwrap(environment["LOCUS_FUZZ_ARTIFACTS"])
        let seconds = try XCTUnwrap(environment["LOCUS_FUZZ_SECONDS"])
        XCTAssertTrue(WalletLibFuzzer.targets.contains(target))
        WalletLibFuzzer.target = target
        URLProtocol.registerClass(WalletFuzzNoNetwork.self)
        defer { URLProtocol.unregisterClass(WalletFuzzNoNetwork.self) }

        let timeLimit = environment["LOCUS_FUZZ_REPLAY"] == "1" ? "-runs=0" : "-max_total_time=\(seconds)"
        let arguments = ["wallet-\(target)", corpus, timeLimit,
            "-max_len=16384", "-timeout=10", "-rss_limit_mb=4096",
            "-artifact_prefix=\(artifacts)/", "-print_final_stats=1"]
        var strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var count = Int32(strings.count)
        let start = clock()
        let result = strings.withUnsafeMutableBufferPointer { buffer -> Int32 in
            var pointer = buffer.baseAddress
            return walletFuzzerRunDriver(&count, &pointer, walletSwiftFuzzerInput)
        }
        XCTAssertEqual(result, 0)
        if let receipt = environment["LOCUS_FUZZ_RECEIPT"] {
            let payload: [String: Any] = ["target": target,
                "processCPUSeconds": Double(clock() - start) / Double(CLOCKS_PER_SEC),
                "sourceRevision": environment["LOCUS_FUZZ_REVISION"] ?? "unknown",
                "result": result, "iterations": WalletLibFuzzer.iterations]
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: receipt), options: .atomic)
        }
    }
}

private enum WalletLibFuzzer {
    static let targets = Set(["evm_decoder", "solana_decoder", "sui_decoder",
        "connections", "namespaces", "authorization", "metadata", "quote_math"])
    static var target = ""
    static var iterations = 0
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
                      minimumContextSlot: nil), networkID: "solana:devnet", account: solana)
        case "sui_decoder":
            _ = try? await WalletDappTransactionDecoder.sui(
                .init(transactionBase64: data.base64EncodedString(), accountAddress: sui.address),
                networkID: "sui:mainnet", account: sui, reviewedAssets: [])
        case "connections", "metadata":
            if let record = try? decoder.decode(WalletConnectionRecord.self, from: data) {
                let store = try? WalletPublicStore(path: ":memory:")
                try? store?.upsertConnection(record)
                _ = try? store?.loadConnections()
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
    guard count <= 16 * 1024, let bytes else { return 0 }
    let data = Data(bytes: bytes, count: count)
    let completion = DispatchSemaphore(value: 0)
    Task.detached {
        await WalletLibFuzzer.exercise(data)
        completion.signal()
    }
    // Tests are hosted by the app. Pumping its run loop lets async production
    // decoders finish without deadlocking the main actor; libFuzzer owns timeout.
    while completion.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
    }
    WalletLibFuzzer.iterations += 1
    return 0
}

private final class WalletFuzzNoNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
#endif
