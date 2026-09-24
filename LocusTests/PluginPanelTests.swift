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
            ExtensionPluginPanel(id: "w", title: "W", entrypoint: "ui/index.html", version: 1, capabilities: ["agents.read"]),
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

    func testBridgeConvertsBackendJSONForThePage() {
        let value = JSONValue.object(["values": .object(["n": .number(2), "on": .bool(true)]),
                                      "list": .array([.string("a"), .null])])
        let converted = PluginPanelBridge.foundation(value) as? [String: Any]
        XCTAssertEqual((converted?["values"] as? [String: Any])?["n"] as? Double, 2)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(converted ?? [:]))
    }
}
