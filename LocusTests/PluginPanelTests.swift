import Foundation
import XCTest
@testable import Locus

@MainActor
final class PluginPanelTests: XCTestCase {
    private let panel = ExtensionPluginPanel(
        id: "workflows", title: "Workflows", entrypoint: "ui/index.html", version: 1,
        capabilities: ["plugin.settings", "plugin.tools", "chat.compose"], tools: ["workflow_decide"])

    func testPanelsAreSupportedOnlyWithKnownCapabilitiesAndLocalHTML() {
        XCTAssertTrue(panel.isSupported)
        let variants = [
            ExtensionPluginPanel(id: "w", title: "W", entrypoint: "ui/index.html", version: 1, capabilities: ["agents.interact"]),
            ExtensionPluginPanel(id: "w", title: "W", entrypoint: "ui/index.html", version: 1, capabilities: [], tools: ["x"]),
            ExtensionPluginPanel(id: "w", title: "W", entrypoint: "../index.html", version: 1, capabilities: []),
            ExtensionPluginPanel(id: "w", title: "W", entrypoint: "ui/app.js", version: 1, capabilities: []),
            ExtensionPluginPanel(id: "w", title: "W", entrypoint: "ui/index.html", version: 2, capabilities: []),
        ]
        for variant in variants { XCTAssertFalse(variant.isSupported, "\(variant)") }
        XCTAssertTrue(panel.capabilityDescription.contains("never an agent: workflow_decide"))
    }

    func testMessagesDecodeOnlyWithTheirCapability() throws {
        XCTAssertEqual(PluginPanelMessage.decode(["version": 1, "type": "ready"], panel: panel), .ready)
        XCTAssertEqual(PluginPanelMessage.decode(["version": 1, "type": "getSettings", "requestID": "r-1"], panel: panel),
                       .getSettings(requestID: "r-1"))
        guard case .saveSettings("r2", let values, "abc")? = PluginPanelMessage.decode(
            ["version": 1, "type": "saveSettings", "requestID": "r2", "values": ["plan_approval": true], "revision": "abc"],
            panel: panel) else { return XCTFail("saveSettings") }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: values) as? [String: Bool], ["plan_approval": true])
        guard case .callTool("r3", "workflow_overview", _)? = PluginPanelMessage.decode(
            ["version": 1, "type": "callTool", "requestID": "r3", "tool": "workflow_overview", "arguments": [:]],
            panel: panel) else { return XCTFail("callTool") }
        XCTAssertEqual(PluginPanelMessage.decode(["version": 1, "type": "composeChat", "text": "Start a workflow"], panel: panel),
                       .composeChat("Start a workflow"))

        let settingsOnly = ExtensionPluginPanel(id: "s", title: "S", entrypoint: "ui/index.html", version: 1,
                                                capabilities: ["plugin.settings"])
        XCTAssertNil(PluginPanelMessage.decode(["version": 1, "type": "callTool", "requestID": "r", "tool": "x",
                                                "arguments": [:]], panel: settingsOnly))
        XCTAssertNil(PluginPanelMessage.decode(["version": 1, "type": "composeChat", "text": "hi"], panel: settingsOnly))
    }

    func testMalformedMessagesAreRejected() {
        let rejected: [[String: Any]] = [
            ["version": 2, "type": "ready"],
            ["version": true, "type": "ready"],
            ["version": 1, "type": "ready", "extra": 1],
            ["version": 1, "type": "getSettings"],
            ["version": 1, "type": "getSettings", "requestID": "bad id!"],
            ["version": 1, "type": "callTool", "requestID": "r", "tool": "rm -rf", "arguments": [:]],
            ["version": 1, "type": "callTool", "requestID": "r", "tool": "x", "arguments": "nope"],
            ["version": 1, "type": "saveSettings", "requestID": "r", "values": ["x": 1], "revision": String(repeating: "a", count: 200)],
            ["version": 1, "type": "composeChat", "text": "   "],
            ["version": 1, "type": "composeChat", "text": String(repeating: "a", count: 16_001)],
            ["version": 1, "type": "openAgentControls"],
        ]
        for body in rejected { XCTAssertNil(PluginPanelMessage.decode(body, panel: panel), "\(body)") }
        let huge = ["blob": String(repeating: "x", count: 300_000)]
        XCTAssertNil(PluginPanelMessage.decode(["version": 1, "type": "callTool", "requestID": "r", "tool": "x",
                                                "arguments": huge], panel: panel))
    }

    func testPanelsDecodeTolerantlyFromOlderAndNewerBackends() throws {
        let legacy = Data(#"{"id":"p","name":"p","enabled_global":true,"enabled_workspaces":[],"disabled_workspaces":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ExtensionPlugin.self, from: legacy).panels)
        XCTAssertNil(try JSONDecoder().decode(
            ExtensionCapabilities.self, from: Data(#"""
            {"streamable_http":true,"stdio":true,"oauth":true,"mcp_apps":false,"hooks":false,"sandboxed":false}
            """#.utf8)
        ).pluginPanels)
        let current = Data(#"""
        {"id":"m/p","name":"p","enabled_global":true,"enabled_workspaces":[],"disabled_workspaces":[],
         "panels":[{"id":"workflows","title":"Workflows","entrypoint":"ui/index.html","version":1,
                    "capabilities":["plugin.settings"],"tools":[],"settings_schema":{"type":"object"}},
                   {"id":7,"title":null}]}
        """#.utf8)
        let panels = try XCTUnwrap(try JSONDecoder().decode(ExtensionPlugin.self, from: current).panels)
        XCTAssertEqual(panels.map(\.isSupported), [true, false])  // malformed one is disabled, not fatal
    }

    func testAgentMessagesNeedTheirCapabilitiesAndStrictShapes() {
        let agents = ExtensionPluginPanel(id: "a", title: "A", entrypoint: "ui/index.html", version: 1,
                                          capabilities: ["agents.read", "agents.dispatch"])
        let nova = UUID(), kai = UUID()
        XCTAssertTrue(agents.isSupported)
        XCTAssertEqual(PluginPanelMessage.decode(["version": 1, "type": "listAgents", "requestID": "r1"], panel: agents),
                       .listAgents(requestID: "r1"))
        XCTAssertNil(PluginPanelMessage.decode(["version": 1, "type": "listAgents", "requestID": "r1"], panel: panel))

        let steps: [[String: Any]] = [["title": "Plan", "agentID": nova.uuidString, "access": "read"],
                                      ["title": "Build", "agentID": kai.uuidString, "access": "write"]]
        XCTAssertEqual(PluginPanelMessage.decode(["version": 1, "type": "confirmRun", "requestID": "r2",
                                                  "runID": "lgw-abc-1", "title": "Plan, build", "steps": steps], panel: agents),
                       .confirmRun(requestID: "r2", runID: "lgw-abc-1", title: "Plan, build",
                                   steps: [.init(title: "Plan", agentID: nova, edits: false),
                                           .init(title: "Build", agentID: kai, edits: true)]))
        let job: [String: Any] = ["version": 1, "type": "dispatchJob", "requestID": "r3", "runID": "lgw-abc-1",
                                  "agentID": kai.uuidString, "operationID": "lgw-abc-1/build-1", "title": "Build",
                                  "text": "Make the change", "access": "write"]
        XCTAssertEqual(PluginPanelMessage.decode(job, panel: agents), .dispatchJob(requestID: "r3", job: .init(
            runID: "lgw-abc-1", agentID: kai, operationID: "lgw-abc-1/build-1", title: "Build",
            text: "Make the change", edits: true)))
        XCTAssertEqual(PluginPanelMessage.decode(["version": 1, "type": "openAgentChat", "runID": "lgw-abc-1",
                                                  "agentID": kai.uuidString], panel: agents),
                       .openAgentChat(runID: "lgw-abc-1", agentID: kai))

        let rejected: [[String: Any]] = [
            job.merging(["agentID": "not-a-uuid"]) { $1 },
            job.merging(["operationID": "has space"]) { $1 },
            job.merging(["access": "admin"]) { $1 },
            job.merging(["text": String(repeating: "a", count: 16_001)]) { $1 },
            job.merging(["extra": true]) { $1 },
            ["version": 1, "type": "confirmRun", "requestID": "r", "runID": "x", "title": "T", "steps": [[String: Any]]()],
            ["version": 1, "type": "confirmRun", "requestID": "r", "runID": "x", "title": "Line\u{7}bell", "steps": steps],
            ["version": 1, "type": "confirmRun", "requestID": "r", "runID": "x", "title": "T",
             "steps": Array(repeating: steps[0], count: 41)],
        ]
        for body in rejected { XCTAssertNil(PluginPanelMessage.decode(body, panel: agents), "\(body)") }
        XCTAssertNil(PluginPanelMessage.decode(job, panel: panel))  // no agents.dispatch
    }

    func testHandOffsNeedTheRunToBeAllowedForThatAgent() throws {
        let handoffs = PluginPanelHandoffs()
        let nova = UUID(), kai = UUID()
        let job = PluginPanelMessage.Handoff(runID: "run-1", agentID: kai, operationID: "run-1/build-1",
                                             title: "Build", text: "Do it", edits: true)
        XCTAssertThrowsError(try handoffs.check(job))
        handoffs.allow("run-1", agents: [nova])
        XCTAssertThrowsError(try handoffs.check(job))  // allowed agents are per run and per agent
        handoffs.allow("run-1", agents: [kai])
        XCTAssertNoThrow(try handoffs.check(job))
        XCTAssertThrowsError(try handoffs.check(.init(runID: "run-2", agentID: kai, operationID: "run-2/x",
                                                      title: "X", text: "Y", edits: false)))
        XCTAssertNil(handoffs.session(run: "run-1", agent: kai))
        handoffs.bind(run: "run-1", agent: kai, session: "s-1")
        XCTAssertEqual(handoffs.session(run: "run-1", agent: kai), "s-1")
        XCTAssertNil(handoffs.session(run: "run-1", agent: nova))
    }

    func testBridgeConvertsBackendJSONForThePage() {
        let value = JSONValue.object(["values": .object(["n": .number(2), "on": .bool(true)]),
                                      "list": .array([.string("a"), .null])])
        let converted = PluginPanelBridge.foundation(value) as? [String: Any]
        XCTAssertEqual((converted?["values"] as? [String: Any])?["n"] as? Double, 2)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(converted ?? [:]))
    }
}
