import Foundation

/// Standalone parity/authorization checks; does not replace WebKit/native UI tests.
@main
struct TestAgentWorldBridge {
    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first ?? "ProtocolFixtures/agent-worlds/wire-v2.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vectors = fixture["vectors"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
        }
        for vector in vectors {
            guard let direction = vector["direction"] as? String, let message = vector["message"],
                  let expected = vector["valid"] as? Bool, let id = vector["id"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            let valid = direction == "client" ? AgentWorldBridgeContract.decode(message) != nil : AgentWorldBridgeContract.validHostMessage(message)
            check(valid == expected, id)
        }
        let identity = AgentWorldBridgeSession.Identity(pluginID: "installed-world", digest: "digest", root: "/approved/plugin", workspace: "/approved/project", capabilities: AgentWorldBridgeContract.capabilities)
        let session = AgentWorldBridgeSession(identity: identity)
        let hello = AgentWorldBridgeContract.Hello(requestID: "hello", protocols: [2], runtimeVersion: "0.2.0", sdkVersion: 1,
                                                  required: ["agents.read"], optional: ["agents.interact", "world.preferences"])
        var executed = 0
        let execute: (AgentWorldBridgeContract.Request) throws -> [String: Any] = { _ in executed += 1; return [:] }
        for version in ["0.1.9", "0.3.0", "1.2.0", "00.2.0"] {
            let incompatible = session.handle(.hello(.init(requestID: "incompatible", protocols: [2], runtimeVersion: version, sdkVersion: 1, required: ["agents.read"], optional: [])), current: identity, hostVersion: "1", execute: execute)
            check((incompatible["error"] as? [String: Any])?["code"] as? String == "incompatible" && !session.connected, "runtime range rejects " + version)
        }
        let welcome = session.handle(.hello(hello), current: identity, hostVersion: "1.0.0", execute: execute)
        check(AgentWorldBridgeContract.validHostMessage(welcome) && session.connected, "welcome shape")
        check(executed == 0, "handshake has no mutation")
        func request(_ id: String = "open", command: String = "agents.create", scopeID: String? = nil) -> AgentWorldBridgeContract.Client {
            .request(.init(requestID: id, sessionID: session.sessionID, scopeID: scopeID ?? session.scopeID, command: command, arguments: [:]))
        }
        func error(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
        let first = session.handle(request(), current: identity, hostVersion: "1", execute: execute)
        check(first["ok"] as? Bool == true && executed == 1, "authorized native intent")
        let repeatResult = session.handle(request(), current: identity, hostVersion: "1", execute: execute)
        check(repeatResult["ok"] as? Bool == true && executed == 1, "duplicate does not execute")
        check(error(session.handle(request(command: "selection.clear"), current: identity, hostVersion: "1", execute: execute)) == "invalid_request" && executed == 1, "request identity cannot change")
        check(error(session.handle(request("cross_scope", scopeID: "foreign"), current: identity, hostVersion: "1", execute: execute)) == "stale_session" && executed == 1, "scope must match")
        let changed = AgentWorldBridgeSession.Identity(pluginID: identity.pluginID, digest: "updated", root: identity.root, workspace: identity.workspace, capabilities: identity.capabilities)
        check(error(session.handle(request("stale_digest"), current: changed, hostVersion: "1", execute: execute)) == "stale_session" && executed == 1, "updated plugin cannot use old session")
        check(error(session.handle(request("uninstalled"), current: nil, hostVersion: "1", execute: execute)) == "stale_session" && executed == 1, "uninstalled plugin cannot invoke")
        let cancelled = session.handle(.cancel(requestID: "cancelled", sessionID: session.sessionID, scopeID: session.scopeID), current: identity, hostVersion: "1", execute: execute)
        check(error(cancelled) == "cancelled", "cancel before acceptance")
        check(error(session.handle(request("cancelled"), current: identity, hostVersion: "1", execute: execute)) == "cancelled" && executed == 1, "cancelled mutation cannot replay")
        let oldSession = session.sessionID
        _ = session.handle(.hello(.init(requestID: "new_hello", protocols: [2], runtimeVersion: "0.2.0", sdkVersion: 1, required: ["agents.read"], optional: [])), current: identity, hostVersion: "1", execute: execute)
        check(oldSession != session.sessionID, "new handshake rotates session")
        check(error(session.handle(request("no_grant"), current: identity, hostVersion: "1", execute: execute)) == "denied" && executed == 1, "manifest capability alone is not a session grant")
        session.revoke()
        check(error(session.handle(request("revoked"), current: identity, hostVersion: "1", execute: execute)) == "stale_session" && executed == 1, "revoked connection cannot execute")
        print("Passed \(checks) Swift contract and session checks (\(vectors.count) shared wire fixtures).")
    }
}
