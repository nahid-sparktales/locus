import CryptoKit
import Darwin
import Foundation
import Security

enum CompanionSecurityError: LocalizedError {
    case randomGeneration
    case keyGeneration(String)
    case publicKey
    case certificate
    case signature(String)
    case keychain(OSStatus)
    case identity(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGeneration: "Secure random data could not be generated."
        case .keyGeneration(let reason): "The mobile-access key could not be created: \(reason)"
        case .publicKey: "The mobile-access public key is unavailable."
        case .certificate: "The mobile-access certificate could not be created."
        case .signature(let reason): "The mobile-access certificate could not be signed: \(reason)"
        case .keychain(let status): "Keychain could not save mobile access (\(status))."
        case .identity(let status): "The mobile-access identity is unavailable (\(status))."
        }
    }
}

enum CompanionCrypto {
    static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw CompanionSecurityError.randomGeneration }
        return data
    }

    static func randomToken() throws -> String {
        base64URL(try randomData(count: 32))
    }

    static func tokenHash(_ token: String, serviceID: String) -> String {
        let data = Data((serviceID + ":" + token).utf8)
        return base64URL(Data(SHA256.hash(data: data)))
    }

    static func fingerprint(_ certificateData: Data) -> String {
        SHA256.hash(data: certificateData).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct CompanionPairingNonceStore {
    private var values: [String: Date] = [:]

    mutating func issue(now: Date = Date()) throws -> (nonce: String, expiresAt: Date) {
        prune(now: now)
        let nonce = try CompanionCrypto.randomToken()
        let expiry = now.addingTimeInterval(CompanionProtocolV1.pairingLifetime)
        values = [nonce: expiry]
        return (nonce, expiry)
    }

    mutating func consume(_ nonce: String, now: Date = Date()) -> Bool {
        prune(now: now)
        guard let expiry = values.removeValue(forKey: nonce), expiry > now else { return false }
        return true
    }

    mutating func revokeAll() {
        values.removeAll()
    }

    private mutating func prune(now: Date) {
        values = values.filter { $0.value > now }
    }
}

struct CompanionDeviceRegistry {
    private(set) var devices: [CompanionPairedDevice]
    let serviceID: String

    init(serviceID: String, devices: [CompanionPairedDevice] = []) {
        self.serviceID = serviceID
        self.devices = devices
    }

    mutating func pair(
        name: String,
        platform: String,
        now: Date = Date()
    ) throws -> (device: CompanionPairedDevice, token: String) {
        let token = try CompanionCrypto.randomToken()
        let device = CompanionPairedDevice(
            id: UUID().uuidString,
            name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)).nilIfEmpty
                ?? "Mobile device",
            platform: String(platform.lowercased().prefix(24)).nilIfEmpty ?? "mobile",
            tokenHash: CompanionCrypto.tokenHash(token, serviceID: serviceID),
            pairedAt: now.timeIntervalSince1970,
            lastSeenAt: now.timeIntervalSince1970
        )
        devices.append(device)
        return (device, token)
    }

    mutating func authenticate(_ token: String, now: Date = Date()) -> CompanionPairedDevice? {
        let hash = CompanionCrypto.tokenHash(token, serviceID: serviceID)
        guard let index = devices.firstIndex(where: { constantTimeEqual($0.tokenHash, hash) })
        else { return nil }
        devices[index].lastSeenAt = now.timeIntervalSince1970
        return devices[index]
    }

    mutating func revoke(deviceID: String) -> Bool {
        let count = devices.count
        devices.removeAll { $0.id == deviceID }
        return devices.count != count
    }

    mutating func revokeAll() {
        devices.removeAll()
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct CompanionTLSMaterial {
    let identity: SecIdentity
    let certificateData: Data
    let fingerprint: String
}

enum CompanionIdentityStore {
    private static let keyTag = Data("io.sparktales.locus.companion.identity".utf8)
    private static let certificateLabel = "Locus Companion TLS"

    static func loadOrCreate() throws -> CompanionTLSMaterial {
        if let certificate = loadCertificate(), let identity = identity(for: certificate) {
            let data = SecCertificateCopyData(certificate) as Data
            return CompanionTLSMaterial(
                identity: identity,
                certificateData: data,
                fingerprint: CompanionCrypto.fingerprint(data)
            )
        }

        let privateKey = try loadOrCreatePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let representation = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { throw CompanionSecurityError.publicKey }
        let certificateData = try CompanionX509.makeCertificate(
            publicKey: representation,
            privateKey: privateKey
        )
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData)
        else { throw CompanionSecurityError.certificate }

        let add: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: certificate,
            kSecAttrLabel: certificateLabel,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw CompanionSecurityError.keychain(status)
        }
        guard let identity = identity(for: certificate) else {
            var result: SecIdentity?
            let identityStatus = SecIdentityCreateWithCertificate(nil, certificate, &result)
            throw CompanionSecurityError.identity(identityStatus)
        }
        return CompanionTLSMaterial(
            identity: identity,
            certificateData: certificateData,
            fingerprint: CompanionCrypto.fingerprint(certificateData)
        )
    }

    static func reset() throws -> CompanionTLSMaterial {
        SecItemDelete([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
        ] as CFDictionary)
        return try loadOrCreate()
    }

    private static func loadCertificate() -> SecCertificate? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certificateLabel,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return (result as! SecCertificate)
    }

    private static func identity(for certificate: SecCertificate) -> SecIdentity? {
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess
        else { return nil }
        return identity
    }

    private static func loadOrCreatePrivateKey() throws -> SecKey {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess {
            return (result as! SecKey)
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: keyTag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw CompanionSecurityError.keyGeneration(
                error?.takeRetainedValue().localizedDescription ?? "unknown error"
            )
        }
        return key
    }
}

enum CompanionX509 {
    static func makeCertificate(publicKey: Data, privateKey: SecKey) throws -> Data {
        let algorithm = DER.sequence([DER.oid("1.2.840.10045.4.3.2")])
        let commonName = DER.sequence([
            DER.set([DER.sequence([DER.oid("2.5.4.3"), DER.utf8("Locus Companion")])]),
        ])
        let now = Date()
        let validity = DER.sequence([
            DER.generalizedTime(now.addingTimeInterval(-86_400)),
            DER.generalizedTime(now.addingTimeInterval(10 * 365 * 86_400)),
        ])
        let publicKeyAlgorithm = DER.sequence([
            DER.oid("1.2.840.10045.2.1"),
            DER.oid("1.2.840.10045.3.1.7"),
        ])
        let subjectPublicKey = DER.sequence([publicKeyAlgorithm, DER.bitString(publicKey)])
        let extensions = DER.context(3, DER.sequence([
            DER.sequence([
                DER.oid("2.5.29.19"), DER.boolean(true), DER.octetString(DER.sequence([])),
            ]),
            DER.sequence([
                DER.oid("2.5.29.37"),
                DER.octetString(DER.sequence([DER.oid("1.3.6.1.5.5.7.3.1")])),
            ]),
        ]))
        let tbs = DER.sequence([
            DER.context(0, DER.integer(Data([2]))),
            DER.integer(try CompanionCrypto.randomData(count: 16)),
            algorithm,
            commonName,
            validity,
            commonName,
            subjectPublicKey,
            extensions,
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbs as CFData,
            &error
        ) as Data? else {
            throw CompanionSecurityError.signature(
                error?.takeRetainedValue().localizedDescription ?? "unknown error"
            )
        }
        return DER.sequence([tbs, algorithm, DER.bitString(signature)])
    }
}

private enum DER {
    static func sequence(_ values: [Data]) -> Data { tagged(0x30, values.reduce(Data(), +)) }
    static func set(_ values: [Data]) -> Data { tagged(0x31, values.reduce(Data(), +)) }
    static func context(_ number: UInt8, _ value: Data) -> Data { tagged(0xA0 | number, value) }
    static func utf8(_ value: String) -> Data { tagged(0x0C, Data(value.utf8)) }
    static func octetString(_ value: Data) -> Data { tagged(0x04, value) }
    static func boolean(_ value: Bool) -> Data { tagged(0x01, Data([value ? 0xFF : 0x00])) }
    static func bitString(_ value: Data) -> Data { tagged(0x03, Data([0]) + value) }

    static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value.first! & 0x80 != 0 { value.insert(0, at: 0) }
        return tagged(0x02, value)
    }

    static func oid(_ string: String) -> Data {
        let parts = string.split(separator: ".").compactMap { UInt64($0) }
        precondition(parts.count >= 2)
        var body = base128(parts[0] * 40 + parts[1])
        for value in parts.dropFirst(2) { body.append(contentsOf: base128(value)) }
        return tagged(0x06, Data(body))
    }

    static func generalizedTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tagged(0x18, Data(formatter.string(from: date).utf8))
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        return bytes
    }

    private static func tagged(_ tag: UInt8, _ body: Data) -> Data {
        Data([tag]) + length(body.count) + body
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

enum CompanionEndpointResolver {
    static func endpoints(port: UInt16) -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var result: Set<String> = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = String(cString: entry.pointee.ifa_name)
            guard interface != "lo0", let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(
                address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            var value = String(cString: host)
            if let percent = value.firstIndex(of: "%") { value = String(value[..<percent]) }
            guard value != "127.0.0.1", value != "::1", !value.hasPrefix("fe80:") else { continue }
            result.insert(family == AF_INET6 ? "wss://[\(value)]:\(port)" : "wss://\(value):\(port)")
        }
        return result.sorted()
    }
}
