import Foundation
import Security

private final class WalletSignerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private static let hostBundleIdentifier = "io.sparktales.locus"
    private static let hostTeamIdentifier = "4X4RJA7GMD"

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard Self.isTrustedHost(connection) else { return false }
        let service = WalletSignerService()
        connection.exportedInterface = NSXPCInterface(with: WalletSignerXPCProtocol.self)
        connection.exportedObject = service
        connection.interruptionHandler = { service.invalidateConnection() }
        connection.invalidationHandler = { service.invalidateConnection() }
        connection.resume()
        return true
    }

    private static func isTrustedHost(_ connection: NSXPCConnection) -> Bool {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier),
        ] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInformation
        ) == errSecSuccess,
              let information = rawInformation as? [String: Any],
              information[kSecCodeInfoIdentifier as String] as? String == hostBundleIdentifier else {
            return false
        }
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String
        #if DEBUG
        return team == nil || team == hostTeamIdentifier
        #else
        return team == hostTeamIdentifier
        #endif
    }
}

private let delegate = WalletSignerListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
