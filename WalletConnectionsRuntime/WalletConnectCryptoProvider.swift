import Foundation
import WalletConnectSign

enum WalletConnectCryptoProviderError: Error {
    case unsupportedRecovery
}

/// Reown Sign requires a CryptoProvider for optional authentication APIs.
/// Locus does not expose those APIs: canonical SIWE/SIWS is parsed and signed
/// by its own v3 signer protocol. Keccak remains implemented correctly for
/// SDK-internal identity hashing, while public-key recovery fails closed.
struct WalletConnectCryptoProvider: CryptoProvider {
    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
        _ = signature
        _ = message
        throw WalletConnectCryptoProviderError.unsupportedRecovery
    }

    func keccak256(_ data: Data) -> Data {
        WalletKeccak256.hash(data)
    }
}

enum WalletKeccak256 {
    private static let rate = 136
    private static let rotations: [UInt64] = [
        0, 1, 62, 28, 27,
        36, 44, 6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21, 8,
        18, 2, 61, 56, 14,
    ]
    private static let constants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082,
        0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001,
        0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088,
        0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b,
        0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080,
        0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080,
        0x0000000080000001, 0x8000000080008008,
    ]

    static func hash(_ message: Data) -> Data {
        var padded = message
        padded.append(0x01)
        while padded.count % rate != rate - 1 { padded.append(0) }
        padded.append(0x80)
        var state = [UInt64](repeating: 0, count: 25)
        for offset in stride(from: 0, to: padded.count, by: rate) {
            for lane in 0..<(rate / 8) {
                var value: UInt64 = 0
                for byte in 0..<8 {
                    value |= UInt64(padded[offset + lane * 8 + byte]) << UInt64(byte * 8)
                }
                state[lane] ^= value
            }
            permute(&state)
        }
        var output = Data()
        for lane in state.prefix(4) {
            var value = lane.littleEndian
            Swift.withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
        }
        return output
    }

    private static func permute(_ state: inout [UInt64]) {
        for constant in constants {
            var columns = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                columns[x] = state[x] ^ state[x + 5] ^ state[x + 10]
                    ^ state[x + 15] ^ state[x + 20]
            }
            for x in 0..<5 {
                let delta = columns[(x + 4) % 5] ^ rotate(columns[(x + 1) % 5], by: 1)
                for y in 0..<5 { state[x + 5 * y] ^= delta }
            }
            var moved = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    moved[y + 5 * ((2 * x + 3 * y) % 5)] = rotate(
                        state[x + 5 * y], by: rotations[x + 5 * y]
                    )
                }
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] = moved[x + 5 * y]
                        ^ ((~moved[(x + 1) % 5 + 5 * y])
                            & moved[(x + 2) % 5 + 5 * y])
                }
            }
            state[0] ^= constant
        }
    }

    private static func rotate(_ value: UInt64, by amount: UInt64) -> UInt64 {
        guard amount != 0 else { return value }
        return (value << amount) | (value >> (64 - amount))
    }
}
