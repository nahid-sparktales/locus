import Foundation
import Security
import Darwin

// A single bounded stdin request; secrets and checkpoint contents never enter logs.
struct GuardError: Error { let message: String }
struct Checkpoint: Codable, Equatable { let generation: Int; let mac: String }
struct Stored: Codable { let version: Int; let token: String; let checkpoint: Checkpoint }
let service = "io.sparktales.locus.memory-guard.v1"
func require(_ condition: Bool) throws { if !condition { throw GuardError(message: "invalid_request") } }
func checkpoint(_ value: Any?) throws -> Checkpoint? {
    guard let value, !(value is NSNull) else { return nil }
    guard let values = value as? [Any], values.count == 2,
          let number = values[0] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue == Double(number.intValue), number.intValue >= 0, number.intValue < Int.max,
          let mac = values[1] as? String, mac.count <= 128,
          // Deletion ledger MACs are the package's 20-byte blind tokens.
          (number.intValue == 0 && mac.isEmpty) || (number.intValue > 0 && mac.count == 40 && mac.allSatisfy({ "0123456789abcdef".contains($0) }))
    else { throw GuardError(message: "invalid_checkpoint") }
    return Checkpoint(generation: number.intValue, mac: mac)
}
func run() throws -> [String: Any] {
    let input = FileHandle.standardInput.readData(ofLength: 65537)
    try require(input.count <= 65536)
    guard let body = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let operation = body["operation"] as? String, ["read", "advance"].contains(operation),
          let account = body["account"] as? String, account.count == 64, account.allSatisfy({ $0.isHexDigit }),
          let token = body["token"] as? String, token.count == 64, token.allSatisfy({ $0.isHexDigit })
    else { throw GuardError(message: "invalid_request") }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let lockRoot = home.appendingPathComponent("Library/Application Support/Locus/MemoryGuard", isDirectory: true)
    try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fd = open(lockRoot.appendingPathComponent(account + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw GuardError(message: "lock_unavailable") }
    defer { flock(fd, LOCK_UN); close(fd) }
    var status = stat()
    try require(fstat(fd, &status) == 0 && status.st_uid == getuid() && (status.st_mode & S_IFMT) == S_IFREG)
    var acquired = false
    for _ in 0..<100 {
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
        usleep(100_000)
    }
    try require(acquired)
    var keychain: SecKeychain?
    let opened = SecKeychainOpen(home.appendingPathComponent("Library/Keychains/login.keychain-db").path, &keychain)
    guard opened == errSecSuccess, let keychain else { throw GuardError(message: "keychain_unavailable") }
    SecKeychainSetUserInteractionAllowed(false)
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                              kSecAttrService as String: service, kSecAttrAccount as String: account,
                              kSecMatchSearchList as String: [keychain]]
    var readQuery = query
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let found = SecItemCopyMatching(readQuery as CFDictionary, &result)
    var stored: Stored?
    if found == errSecSuccess {
        guard let data = result as? Data, data.count <= 4096 else { throw GuardError(message: "corrupt_checkpoint") }
        stored = try JSONDecoder().decode(Stored.self, from: data)
        try require(stored?.version == 1 && stored?.token == token)
        if let saved = stored?.checkpoint {
            _ = try checkpoint([saved.generation, saved.mac])
        }
    } else if found != errSecItemNotFound { throw GuardError(message: "keychain_unavailable") }
    if operation == "advance" {
        let expected = try checkpoint(body["expected"])
        guard let proposed = try checkpoint(body["checkpoint"]) else { throw GuardError(message: "invalid_checkpoint") }
        try require(expected == stored?.checkpoint)
        if let current = stored?.checkpoint {
            try require(proposed.generation > current.generation || proposed == current)
        }
        let next = Stored(version: 1, token: token, checkpoint: proposed)
        let data = try JSONEncoder().encode(next)
        let written: OSStatus
        if stored == nil {
            var add = query
            add.removeValue(forKey: kSecMatchSearchList as String)
            add[kSecUseKeychain as String] = keychain
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Locus memory deletion checkpoint"
            written = SecItemAdd(add as CFDictionary, nil)
        } else {
            written = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard written == errSecSuccess else { throw GuardError(message: "keychain_unavailable") }
        stored = next
    }
    let value: Any = stored.map { [$0.checkpoint.generation, $0.checkpoint.mac] as [Any] } ?? NSNull()
    return ["ok": true, "checkpoint": value]
}
do {
    let result = try run()
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
} catch {
    FileHandle.standardOutput.write(Data("{\"ok\":false,\"error\":\"memory_guard_unavailable\"}".utf8))
    exit(1)
}
