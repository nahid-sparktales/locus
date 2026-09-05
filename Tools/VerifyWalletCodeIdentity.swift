#!/usr/bin/env swift
import Foundation
import Security

// Compare the installed-code API used by Locus with Apple's command-line
// representation on actual signed code. This is not a Developer ID,
// notarization, provisioning, or release-provenance approval.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("Usage: VerifyWalletCodeIdentity.swift signed-code-path")
}
let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
var code: SecStaticCode?
guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
      let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
    fail("Installed code signature validation failed.")
}
var information: CFDictionary?
guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let values = information as? [CFString: Any],
      let bytes = values[kSecCodeInfoUnique] as? Data, bytes.count == 20 else {
    fail("The installed-code API did not return a 20-byte CDHash.")
}
let apiHash = bytes.map { String(format: "%02x", $0) }.joined()
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
process.arguments = ["--display", "--verbose=4", url.path]
let output = Pipe()
process.standardError = output
process.standardOutput = FileHandle.nullDevice
do { try process.run() } catch { fail("Unable to inspect the code signature.") }
let data = output.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
guard process.terminationStatus == 0, data.count <= 65_536,
      let text = String(data: data, encoding: .utf8) else {
    fail("The command-line signature inspection failed.")
}
let hashes = text.split(separator: "\n").filter { $0.hasPrefix("CDHash=") }
guard hashes.count == 1, String(hashes[0].dropFirst(7)) == apiHash else {
    fail("Installed-code and command-line CDHashes disagree.")
}
let result: [String: Any] = ["schemaVersion": 1, "codeDirectoryHash": apiHash,
    "cdHashBytes": 20, "signatureValid": true, "apiCLIParity": true,
    "releaseApproval": false]
do {
    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(encoded + Data("\n".utf8))
} catch { fail("Unable to encode the identity comparison result.") }
