import Foundation

/// Narrow, Swift-only BCS reconstruction for the three reviewed Sui transfer
/// shapes. It deliberately has no Move-call or batch encoder.
struct WalletSuiCanonicalTransaction: Equatable, Sendable {
    let transactionBCS: Data
    let transactionDigest: String
    let signingDigest: String

    init(packet: WalletSuiPreparationPacket) throws {
        guard packet.expirationEpoch == packet.currentEpoch,
              packet.gasPriceBaseUnits == packet.referenceGasPriceBaseUnits,
              let sender = Self.address(packet.sender),
              let recipientText = packet.request.action.recipient,
              let recipient = Self.address(recipientText),
              sender != recipient,
              recipient.contains(where: { $0 != 0 }),
              let gasBudget = Self.uint64(packet.gasBudgetBaseUnits), gasBudget > 0,
              let gasPrice = Self.uint64(packet.gasPriceBaseUnits), gasPrice > 0,
              let gasBalance = Self.uint64(packet.gasBalanceBaseUnits),
              gasBudget <= gasBalance,
              let amountText = packet.request.action.amountBaseUnits,
              let amount = Self.uint64(amountText), amount > 0 else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Sui transaction contains invalid roles, amounts, or epoch evidence."
            )
        }
        let gas = try Self.objectReference(packet.gasObject)
        guard gas.id != sender, gas.id != recipient else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Sui gas object overlaps an account role."
            )
        }

        var bytes = Data([0, 0]) // TransactionData::V1, ProgrammableTransaction
        switch packet.request.action.type {
        case .nativeTransfer:
            guard packet.assetID == WalletNetworkCatalog.descriptor(
                    id: packet.request.networkID
                  )?.nativeAssetID,
                  packet.coinType == WalletSuiAssetIdentity.nativeCoinType,
                  packet.coinObject == nil, packet.transferredObject == nil,
                  amount <= gasBalance - gasBudget else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed SUI gas coin cannot cover the transfer and gas ceiling."
                )
            }
            Self.vectorCount(2, into: &bytes)
            Self.pure(Self.littleEndian(amount), into: &bytes)
            Self.pure(recipient, into: &bytes)
            Self.vectorCount(2, into: &bytes)
            Self.split(coin: .gas, amountInput: 0, into: &bytes)
            Self.transfer(object: .nestedResult(0, 0), recipientInput: 1, into: &bytes)
        case .fungibleTokenTransfer:
            guard let identity = WalletSuiAssetIdentity.parse(packet.assetID),
                  identity.networkID == packet.request.networkID,
                  identity.coinType == packet.coinType,
                  identity.coinType != WalletSuiAssetIdentity.nativeCoinType,
                  let coinReference = packet.coinObject,
                  let coinBalanceText = packet.coinBalanceBaseUnits,
                  let coinBalance = Self.uint64(coinBalanceText),
                  amount <= coinBalance,
                  packet.transferredObject == nil else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui Coin evidence is incomplete."
                )
            }
            let coin = try Self.objectReference(coinReference)
            guard coin.id != gas.id, coin.id != sender, coin.id != recipient else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui Coin object overlaps another role."
                )
            }
            Self.vectorCount(3, into: &bytes)
            Self.ownedObject(coin, into: &bytes)
            Self.pure(Self.littleEndian(amount), into: &bytes)
            Self.pure(recipient, into: &bytes)
            Self.vectorCount(2, into: &bytes)
            Self.split(coin: .input(0), amountInput: 1, into: &bytes)
            Self.transfer(object: .nestedResult(0, 0), recipientInput: 2, into: &bytes)
        case .nftTransfer:
            guard amount == 1,
                  let objectReference = packet.transferredObject,
                  packet.objectHasPublicTransfer == true,
                  packet.coinObject == nil,
                  let identity = WalletSuiObjectIdentity.parse(packet.assetID),
                  identity.networkID == packet.request.networkID,
                  identity.objectID == objectReference.objectID,
                  packet.request.action.tokenID == identity.objectID,
                  WalletSuiAssetIdentity.isCanonicalCoinType(objectReference.type) else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui object is not a narrow public-transfer object."
                )
            }
            let object = try Self.objectReference(objectReference)
            guard object.id != gas.id, object.id != sender, object.id != recipient else {
                throw WalletGateway.Error.invalidArguments(
                    "The reviewed Sui object overlaps another role."
                )
            }
            Self.vectorCount(2, into: &bytes)
            Self.ownedObject(object, into: &bytes)
            Self.pure(recipient, into: &bytes)
            Self.vectorCount(1, into: &bytes)
            Self.transfer(object: .input(0), recipientInput: 1, into: &bytes)
        default:
            throw WalletGateway.Error.invalidArguments(
                "The Sui transaction is outside the reviewed transfer subset."
            )
        }
        bytes.append(sender)
        Self.vectorCount(1, into: &bytes)
        Self.objectReference(gas, into: &bytes)
        bytes.append(sender)
        bytes.append(Self.littleEndian(gasPrice))
        bytes.append(Self.littleEndian(gasBudget))
        bytes.append(1) // TransactionExpiration::Epoch
        bytes.append(Self.littleEndian(packet.expirationEpoch))
        guard bytes.count <= 8 * 1_024 else {
            throw WalletGateway.Error.invalidArguments("The Sui transaction is too large.")
        }
        transactionBCS = bytes
        transactionDigest = WalletSolanaBase58.encode(
            WalletBlake2b256.hash(Data("TransactionData::".utf8) + bytes)
        )
        signingDigest = "blake2b256:" + WalletBlake2b256.hash(Data([0, 0, 0]) + bytes)
            .map { String(format: "%02x", $0) }.joined()
    }

    private struct ObjectReference {
        let id: Data
        let version: UInt64
        let digest: Data
    }

    private enum Argument {
        case gas
        case input(UInt16)
        case nestedResult(UInt16, UInt16)
    }

    private static func address(_ value: String) -> Data? {
        guard value.count == 66, value.hasPrefix("0x"),
              value.dropFirst(2).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return nil
        }
        var result = Data()
        var index = value.index(value.startIndex, offsetBy: 2)
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result.count == 32 ? result : nil
    }

    private static func uint64(_ value: String) -> UInt64? {
        guard let parsed = UInt64(value), String(parsed) == value else { return nil }
        return parsed
    }

    private static func objectReference(
        _ value: WalletSuiObjectReference
    ) throws -> ObjectReference {
        guard let id = address(value.objectID), value.version > 0,
              let digest = WalletSolanaBase58.decode(value.digest, exactLength: 32) else {
            throw WalletGateway.Error.invalidArguments(
                "The reviewed Sui object reference is malformed."
            )
        }
        return ObjectReference(id: id, version: value.version, digest: digest)
    }

    private static func vectorCount(_ value: UInt64, into data: inout Data) {
        uleb128(value, into: &data)
    }

    private static func pure(_ value: Data, into data: inout Data) {
        data.append(0)
        uleb128(UInt64(value.count), into: &data)
        data.append(value)
    }

    private static func ownedObject(_ value: ObjectReference, into data: inout Data) {
        data.append(contentsOf: [1, 0]) // CallArg::Object, ObjectArg::ImmutableOrOwned
        objectReference(value, into: &data)
    }

    private static func objectReference(_ value: ObjectReference, into data: inout Data) {
        data.append(value.id)
        data.append(littleEndian(value.version))
        uleb128(UInt64(value.digest.count), into: &data)
        data.append(value.digest)
    }

    private static func split(
        coin: Argument, amountInput: UInt16, into data: inout Data
    ) {
        data.append(2) // Command::SplitCoins
        argument(coin, into: &data)
        vectorCount(1, into: &data)
        argument(.input(amountInput), into: &data)
    }

    private static func transfer(
        object: Argument, recipientInput: UInt16, into data: inout Data
    ) {
        data.append(1) // Command::TransferObjects
        vectorCount(1, into: &data)
        argument(object, into: &data)
        argument(.input(recipientInput), into: &data)
    }

    private static func argument(_ value: Argument, into data: inout Data) {
        switch value {
        case .gas:
            data.append(0)
        case .input(let index):
            data.append(1)
            data.append(littleEndian(index))
        case .nestedResult(let command, let result):
            data.append(3)
            data.append(littleEndian(command))
            data.append(littleEndian(result))
        }
    }

    private static func uleb128(_ value: UInt64, into data: inout Data) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var encoded = value.littleEndian
        return Swift.withUnsafeBytes(of: &encoded) { Data($0) }
    }
}

enum WalletBlake2b256 {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]
    private static let sigma: [[Int]] = [
        [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
        [14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3],
        [11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4],
        [7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8],
        [9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13],
        [2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9],
        [12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11],
        [13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10],
        [6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5],
        [10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0],
    ]

    static func hash(_ data: Data) -> Data {
        var h = iv
        h[0] ^= 0x0101_0020
        let bytes = [UInt8](data)
        let count = max(1, (bytes.count + 127) / 128)
        var processed: UInt64 = 0
        for blockIndex in 0..<count {
            let start = blockIndex * 128
            let end = min(start + 128, bytes.count)
            var block = [UInt8](repeating: 0, count: 128)
            if start < end { block.replaceSubrange(0..<(end - start), with: bytes[start..<end]) }
            processed &+= UInt64(end - start)
            compress(&h, block: block, counter: processed, isLast: blockIndex == count - 1)
        }
        var output = Data()
        for word in h.prefix(4) {
            var value = word.littleEndian
            Swift.withUnsafeBytes(of: &value) { output.append(contentsOf: $0) }
        }
        return output
    }

    private static func compress(
        _ h: inout [UInt64], block: [UInt8], counter: UInt64, isLast: Bool
    ) {
        var m = [UInt64](repeating: 0, count: 16)
        for index in 0..<16 {
            for offset in 0..<8 {
                m[index] |= UInt64(block[index * 8 + offset]) << UInt64(offset * 8)
            }
        }
        var v = h + iv
        v[12] ^= counter
        if isLast { v[14] = ~v[14] }
        for round in 0..<12 {
            let s = sigma[round % 10]
            g(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            g(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            g(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            g(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            g(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            g(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            g(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            g(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for index in 0..<8 { h[index] ^= v[index] ^ v[index + 8] }
    }

    private static func g(
        _ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int,
        _ x: UInt64, _ y: UInt64
    ) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = (v[d] ^ v[a]).rotatedRight(32)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotatedRight(24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = (v[d] ^ v[a]).rotatedRight(16)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotatedRight(63)
    }
}

private extension UInt64 {
    func rotatedRight(_ amount: UInt64) -> UInt64 {
        (self >> amount) | (self << (64 - amount))
    }
}
