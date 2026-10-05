import CoreFoundation
import Foundation

/// Pinned Agent Worlds wire protocol 2 / SDK 1. No Locus domain or renderer types.
/// Keep validation aligned with agent-worlds/packages/sdk/src/protocol.ts.
enum AgentWorldBridgeContract {
    static let version = 2
    static let maximumBytes = 524_288
    static let capabilities: Set<String> = ["agents.read", "agents.interact", "world.preferences"]
    static let commandCapabilities = [
        "host.snapshot": "agents.read", "agents.open": "agents.interact", "agents.create": "agents.interact",
        "selection.clear": "agents.interact", "attention.open": "agents.interact", "transfers.open": "agents.interact",
        "chats.openShared": "agents.interact", "navigation.open": "agents.interact", "presentation.open": "agents.interact",
        "preferences.set": "world.preferences", "preferences.reset": "world.preferences", "placements.set": "agents.read",
    ]
    struct Hello {
        let requestID: String
        let protocols: [Int]
        let runtimeVersion: String
        let sdkVersion: Int
        let required: Set<String>
        let optional: Set<String>
    }
    struct Request {
        let requestID: String
        let sessionID: String
        let scopeID: String
        let command: String
        let arguments: [String: Any]
    }
    enum Client {
        case hello(Hello)
        case request(Request)
        case cancel(requestID: String, sessionID: String, scopeID: String)
    }
    struct Failure: Error {
        let code: String
        let message: String
        var json: [String: Any] { ["code": code, "message": String(message.unicodeScalars.prefix(256))] }
    }

    static func exact(_ value: [String: Any], _ required: Set<String>, optional: Set<String> = []) -> Bool {
        required.isSubset(of: Set(value.keys)) && Set(value.keys).isSubset(of: required.union(optional))
    }
    static func matches(_ value: Any?, _ pattern: String) -> Bool {
        guard let text = value as? String else { return false }
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    static func isID(_ value: Any?) -> Bool { matches(value, "\\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\z") }
    static func isToken(_ value: Any?) -> Bool { matches(value, "\\A[a-zA-Z0-9_-]{1,80}\\z") }
    static func isText(_ value: Any?, maximum: Int = 256) -> Bool {
        guard let text = value as? String, text.unicodeScalars.count <= maximum else { return false }
        return !text.unicodeScalars.contains { $0.value <= 31 || (127...159).contains($0.value) }
    }
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    static func boundedJSON(_ value: Any, maximum: Int = maximumBytes) -> Bool {
        func visit(_ value: Any, depth: Int) -> Bool {
            guard depth <= 8 else { return false }
            if value is NSNull { return true }
            if let text = value as? String { return text.utf8.count <= maximum }
            if let number = value as? NSNumber { return number.doubleValue.isFinite }
            if let rows = value as? [Any] { return rows.count <= 2048 && rows.allSatisfy { visit($0, depth: depth + 1) } }
            if let object = value as? [String: Any] {
                return object.count <= 1024 && object.allSatisfy { visit($0.key, depth: depth + 1) && visit($0.value, depth: depth + 1) }
            }
            return false
        }
        guard visit(value, depth: 0), let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return false }
        return data.count <= maximum
    }
    static func validPreferences(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any], object.count <= 32,
              object.keys.allSatisfy({ matches($0, "\\A[a-z][a-z0-9.-]{0,79}\\z") }) else { return false }
        return boundedJSON(object, maximum: 32_768)
    }
    static func validArguments(command: String, value: Any?) -> Bool {
        guard let args = value as? [String: Any], boundedJSON(args, maximum: 65_536) else { return false }
        switch command {
        case "host.snapshot", "agents.create", "selection.clear", "chats.openShared", "preferences.reset": return args.isEmpty
        case "agents.open": return exact(args, ["agentID"]) && isID(args["agentID"])
        case "attention.open": return exact(args, ["requestID"]) && isID(args["requestID"])
        case "transfers.open": return exact(args, ["transferID"]) && isID(args["transferID"])
        case "navigation.open":
            return exact(args, ["surface"], optional: ["agentID"])
                && ["agents", "activity", "calendar", "board"].contains(args["surface"] as? String ?? "")
                && (args["agentID"] == nil || isID(args["agentID"]))
        case "presentation.open": return exact(args, ["presentationID"]) && matches(args["presentationID"], "\\A[a-z0-9][a-z0-9-]{0,63}\\z")
        case "preferences.set":
            return exact(args, ["key", "value"]) && matches(args["key"], "\\A[a-z][a-z0-9.-]{0,79}\\z")
                && boundedJSON(args["value"]!, maximum: 32_768)
        case "placements.set":
            guard exact(args, ["placements"]), let rows = args["placements"] as? [[String: Any]], rows.count <= 500 else { return false }
            var ids = Set<String>()
            return rows.allSatisfy { row in
                guard exact(row, ["agentID", "primary", "secondary"]), isID(row["agentID"]),
                      let id = row["agentID"] as? String, ids.insert(id.lowercased()).inserted else { return false }
                return isText(row["primary"], maximum: 100) && isText(row["secondary"], maximum: 100)
            }
        default: return false
        }
    }
    static func validDisplayState(_ body: Any?) -> Bool {
        guard let value = body as? [String: Any], exact(value, ["agents", "projectName", "preferences", "attentionRequests", "transfers", "canCreateAgent", "nativeChrome", "focusRequest", "activityCenterRequest"], optional: ["selectedAgentID"]),
              let agents = value["agents"] as? [[String: Any]], agents.count <= 500,
              isText(value["projectName"]), validPreferences(value["preferences"]), boolean(value["canCreateAgent"]) != nil,
              boolean(value["nativeChrome"]) != nil, integer(value["focusRequest"]) != nil, integer(value["activityCenterRequest"]) != nil else { return false }
        var ids = Set<String>()
        for agent in agents {
            guard exact(agent, ["id", "name", "role", "status"]), isID(agent["id"]), let id = agent["id"] as? String,
                  ids.insert(id.lowercased()).inserted, isText(agent["name"]), isText(agent["role"]),
                  ["idle", "working", "needs_attention", "completed", "failed", "queued"].contains(agent["status"] as? String ?? "") else { return false }
        }
        func member(_ value: Any?) -> Bool { isID(value) && ids.contains((value as? String ?? "").lowercased()) }
        guard value["selectedAgentID"] == nil || member(value["selectedAgentID"]),
              let attention = value["attentionRequests"] as? [[String: Any]], attention.count <= 256,
              let transfers = value["transfers"] as? [[String: Any]], transfers.count <= 128 else { return false }
        var seen = Set<String>()
        for item in attention {
            guard exact(item, ["id", "agentID", "kind", "title"]), isID(item["id"]), let id = item["id"] as? String,
                  seen.insert(id.lowercased()).inserted, member(item["agentID"]), ["approval", "input"].contains(item["kind"] as? String ?? ""), isText(item["title"]) else { return false }
        }
        seen = []
        for item in transfers {
            guard exact(item, ["id", "fromAgentID", "toAgentID", "kind", "title", "occurredAt"]), isID(item["id"]), let id = item["id"] as? String,
                  seen.insert(id.lowercased()).inserted, member(item["fromAgentID"]), member(item["toAgentID"]),
                  (item["fromAgentID"] as? String)?.lowercased() != (item["toAgentID"] as? String)?.lowercased(),
                  ["handoff", "artifact"].contains(item["kind"] as? String ?? ""), isText(item["title"]),
                  let time = item["occurredAt"] as? NSNumber, CFGetTypeID(time) != CFBooleanGetTypeID(),
                  time.doubleValue.isFinite, (0...253402300799).contains(time.doubleValue) else { return false }
        }
        return true
    }
    static func validHostMessage(_ body: Any) -> Bool {
        guard boundedJSON(body), let value = body as? [String: Any], integer(value["version"]) == 2, let type = value["type"] as? String else { return false }
        func error(_ raw: Any?) -> Bool {
            guard let error = raw as? [String: Any] else { return false }
            return exact(error, ["code", "message"]) && ["incompatible", "denied", "stale_session", "invalid_request", "not_found", "unavailable", "timeout", "cancelled", "quota"].contains(error["code"] as? String ?? "") && isText(error["message"])
        }
        if type == "rejected" { return exact(value, ["version", "type", "requestID", "error"]) && isToken(value["requestID"]) && error(value["error"]) }
        guard isToken(value["sessionID"]), isToken(value["scopeID"]) else { return false }
        switch type {
        case "welcome":
            guard exact(value, ["version", "type", "requestID", "protocol", "hostVersion", "capabilities", "sessionID", "scopeID", "streamID"]),
                  isToken(value["requestID"]), integer(value["protocol"]) == 2, isText(value["hostVersion"], maximum: 32), isToken(value["streamID"]),
                  let caps = value["capabilities"] as? [String], caps.count <= 3 else { return false }
            return Set(caps).count == caps.count && Set(caps).isSubset(of: capabilities)
        case "snapshot":
            return exact(value, ["version", "type", "sessionID", "scopeID", "streamID", "sequence", "state"]) && isToken(value["streamID"]) && integer(value["sequence"]) != nil && validDisplayState(value["state"])
        case "event":
            guard exact(value, ["version", "type", "sessionID", "scopeID", "streamID", "sequence", "event"]), isToken(value["streamID"]), integer(value["sequence"]) != nil,
                  let event = value["event"] as? [String: Any], exact(event, ["type", "state"]), event["type"] as? String == "projection.updated" else { return false }
            return validDisplayState(event["state"])
        case "visibility": return exact(value, ["version", "type", "sessionID", "scopeID", "visible"]) && boolean(value["visible"]) != nil
        case "revoked": return exact(value, ["version", "type", "sessionID", "scopeID", "reason"]) && isText(value["reason"])
        case "response":
            guard isToken(value["requestID"]), let ok = boolean(value["ok"]) else { return false }
            if ok {
                guard exact(value, ["version", "type", "sessionID", "scopeID", "requestID", "ok", "result"]), let result = value["result"] as? [String: Any] else { return false }
                return boundedJSON(result, maximum: 32_768)
            }
            return exact(value, ["version", "type", "sessionID", "scopeID", "requestID", "ok", "error"]) && error(value["error"])
        default: return false
        }
    }
    static func decode(_ body: Any) -> Client? {
        guard boundedJSON(body), let value = body as? [String: Any], integer(value["version"]) == version,
              isToken(value["requestID"]), let requestID = value["requestID"] as? String else { return nil }
        if value["type"] as? String == "hello" {
            func caps(_ value: Any?) -> Set<String>? {
                guard let values = value as? [String], values.count <= 3, Set(values).count == values.count,
                      Set(values).isSubset(of: capabilities) else { return nil }
                return Set(values)
            }
            guard exact(value, ["version", "type", "requestID", "protocols", "runtimeVersion", "sdkVersion", "requiredCapabilities", "optionalCapabilities"]),
                  let rawProtocols = value["protocols"] as? [Any], !rawProtocols.isEmpty, rawProtocols.count <= 8,
                  let runtimeVersion = value["runtimeVersion"] as? String, runtimeVersion.count <= 32,
                  matches(runtimeVersion, "\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z"), let sdkVersion = integer(value["sdkVersion"]),
                  let required = caps(value["requiredCapabilities"]), let optional = caps(value["optionalCapabilities"]), required.isDisjoint(with: optional) else { return nil }
            let protocols = rawProtocols.compactMap(integer)
            guard protocols.count == rawProtocols.count, protocols.allSatisfy({ $0 > 0 }), Set(protocols).count == protocols.count else { return nil }
            return .hello(.init(requestID: requestID, protocols: protocols, runtimeVersion: runtimeVersion, sdkVersion: sdkVersion, required: required, optional: optional))
        }
        guard isToken(value["sessionID"]), isToken(value["scopeID"]), let sessionID = value["sessionID"] as? String, let scopeID = value["scopeID"] as? String else { return nil }
        if value["type"] as? String == "cancel" {
            guard exact(value, ["version", "type", "requestID", "sessionID", "scopeID"]) else { return nil }
            return .cancel(requestID: requestID, sessionID: sessionID, scopeID: scopeID)
        }
        guard value["type"] as? String == "request", exact(value, ["version", "type", "requestID", "sessionID", "scopeID", "command", "arguments"]),
              let command = value["command"] as? String, commandCapabilities[command] != nil,
              validArguments(command: command, value: value["arguments"]), let args = value["arguments"] as? [String: Any] else { return nil }
        return .request(.init(requestID: requestID, sessionID: sessionID, scopeID: scopeID, command: command, arguments: args))
    }
}

/// One installed, scoped WebView connection. All actions complete synchronously by
/// opening native surfaces; no execution requests or uncertain mutation replay.
final class AgentWorldBridgeSession {
    struct Identity: Equatable {
        let pluginID: String
        let digest: String?
        let root: String
        let workspace: String
        let capabilities: Set<String>
    }
    let identity: Identity
    private(set) var sessionID = UUID().uuidString
    private(set) var scopeID = UUID().uuidString
    private(set) var streamID = UUID().uuidString
    private(set) var granted = Set<String>()
    private(set) var connected = false
    private(set) var revoked = false
    private var replies: [String: (Data?, [String: Any])] = [:]
    private var helloID: String?
    private var welcome: [String: Any]?
    private(set) var sequence = 0
    init(identity: Identity) { self.identity = identity }

    func revoke() { revoked = true; connected = false; replies.removeAll(); welcome = nil }
    func scope(_ type: String) -> [String: Any] { ["version": 2, "type": type, "sessionID": sessionID, "scopeID": scopeID] }
    func failure(_ requestID: String, code: String, message: String, scoped: Bool = true) -> [String: Any] {
        var result = scoped ? scope("response") : ["version": 2, "type": "rejected"]
        result["requestID"] = requestID
        if scoped { result["ok"] = false }
        result["error"] = AgentWorldBridgeContract.Failure(code: code, message: message).json
        return result
    }
    func handle(_ client: AgentWorldBridgeContract.Client, current: Identity?, hostVersion: String,
                execute: (AgentWorldBridgeContract.Request) throws -> [String: Any]) -> [String: Any] {
        if case .hello(let hello) = client {
            guard !revoked, current == identity else { return failure(hello.requestID, code: "stale_session", message: "This plugin connection is no longer current.", scoped: false) }
            guard hello.protocols.contains(2), hello.sdkVersion == 1 else { return failure(hello.requestID, code: "incompatible", message: "This world requires a different host contract.", scoped: false) }
            guard hello.required.isSubset(of: identity.capabilities) else { return failure(hello.requestID, code: "denied", message: "A required world capability is unavailable.", scoped: false) }
            if helloID == hello.requestID, let welcome { return welcome }
            sessionID = UUID().uuidString; scopeID = UUID().uuidString; streamID = UUID().uuidString; sequence = 0
            granted = hello.required.union(hello.optional).intersection(identity.capabilities)
            connected = true; replies.removeAll(); helloID = hello.requestID
            var value = scope("welcome")
            value.merge(["requestID": hello.requestID, "protocol": 2, "hostVersion": hostVersion, "capabilities": granted.sorted(), "streamID": streamID]) { _, new in new }
            welcome = value; return value
        }
        let requestID: String, incomingSession: String, incomingScope: String
        switch client {
        case .request(let request): requestID = request.requestID; incomingSession = request.sessionID; incomingScope = request.scopeID
        case .cancel(let id, let session, let scope): requestID = id; incomingSession = session; incomingScope = scope
        case .hello: preconditionFailure("handled above")
        }
        guard !revoked, connected, current == identity, incomingSession == sessionID, incomingScope == scopeID else {
            return failure(requestID, code: "stale_session", message: "This plugin connection is no longer current.")
        }
        if case .cancel = client {
            if let prior = replies[requestID] { return prior.1 }
            let response = failure(requestID, code: "cancelled", message: "The request was cancelled before it was accepted.")
            if replies.count < 1024 { replies[requestID] = (nil, response) }
            return response
        }
        guard case .request(let request) = client else { preconditionFailure() }
        guard let capability = AgentWorldBridgeContract.commandCapabilities[request.command], granted.contains(capability) else {
            return failure(requestID, code: "denied", message: "This command is not authorized for the connection.")
        }
        let fingerprint = try? JSONSerialization.data(withJSONObject: ["command": request.command, "arguments": request.arguments], options: [.sortedKeys])
        if let prior = replies[requestID] {
            guard prior.0 == nil || prior.0 == fingerprint else { return failure(requestID, code: "invalid_request", message: "A request ID cannot be reused for a different command.") }
            return prior.1
        }
        guard replies.count < 1024 else { return failure(requestID, code: "quota", message: "Reconnect the world before making more requests.") }
        let response: [String: Any]
        do {
            let result = try execute(request)
            guard AgentWorldBridgeContract.boundedJSON(result, maximum: 32_768) else { throw AgentWorldBridgeContract.Failure(code: "quota", message: "The command result exceeded its limit.") }
            var value = scope("response"); value["requestID"] = requestID; value["ok"] = true; value["result"] = result
            response = value
        } catch let error as AgentWorldBridgeContract.Failure {
            response = failure(requestID, code: error.code, message: error.message)
        } catch {
            response = failure(requestID, code: "unavailable", message: "The native action could not be completed.")
        }
        replies[requestID] = (fingerprint, response)
        return response
    }
    func projection(_ state: [String: Any], initial: Bool) -> [String: Any] {
        sequence += 1
        var value = scope(initial ? "snapshot" : "event")
        value["streamID"] = streamID; value["sequence"] = sequence
        if initial { value["state"] = state }
        else { value["event"] = ["type": "projection.updated", "state": state] }
        return value
    }
}
