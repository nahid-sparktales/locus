import Foundation
import XCTest
@testable import Locus

final class AgentSidebarCatalogTests: XCTestCase {
    func testConfiguredAgentAppearsBeforeItsFirstChat() {
        let groups = project([.trigger(trigger())], sessions: [])
        XCTAssertEqual(groups.map(\.name), ["Inbox assistant"])
        XCTAssertEqual(groups.first?.reference, AgentInspectorAgent(kind: .event, agentID: "inbox"))
        XCTAssertEqual(groups.first?.totalChatCount, 0)
    }

    func testAgentNameSearchUsesCurrentDefinitionAndIncludesItsChats() {
        let groups = project([.trigger(trigger())], sessions: [chat("first"), chat("second")], query: "  INBOX  ")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.name, "Inbox assistant")
        XCTAssertEqual(groups.first?.tasks.count, 2)
    }

    func testChatSearchKeepsItsOwnerAndCountsAllVisibleConversations() {
        let groups = project(
            [.trigger(trigger())],
            sessions: [chat("budget", title: "Quarterly budget"), chat("notes", title: "Meeting notes")],
            query: "budget"
        )
        XCTAssertEqual(groups.first?.name, "Inbox assistant")
        XCTAssertEqual(groups.first?.tasks.map(\.id), ["budget"])
        XCTAssertEqual(groups.first?.totalChatCount, 2)
    }

    func testArchiveFilterDoesNotHideTheAgentAndHonorsArchivedSearch() {
        let archived = chat("archived", title: "Old invoice", archived: true)
        let hidden = project([.trigger(trigger())], sessions: [archived])
        XCTAssertEqual(hidden.count, 1)
        XCTAssertEqual(hidden.first?.totalChatCount, 0)
        XCTAssertTrue(project([.trigger(trigger())], sessions: [archived], query: "invoice").isEmpty)
        let visible = project([.trigger(trigger())], sessions: [archived], query: "invoice", showArchived: true)
        XCTAssertEqual(visible.first?.tasks.map(\.id), ["archived"])
    }

    func testScheduleAndEventWithSameIDKeepSeparateChatsAndAccessibleIDs() {
        let groups = project(
            [.trigger(trigger()), .schedule(schedule())],
            sessions: [chat("event", kind: "event"), chat("scheduled", kind: "schedule")]
        )
        XCTAssertEqual(Set(groups.map(\.id)), ["event:inbox", "schedule:inbox"])
        XCTAssertEqual(Set(groups.map(\.accessibilityID)), ["event:inbox", "schedule:inbox"])
        XCTAssertEqual(groups.first { $0.reference?.kind == .event }?.tasks.map(\.id), ["event"])
        XCTAssertEqual(groups.first { $0.reference?.kind == .schedule }?.tasks.map(\.id), ["scheduled"])
    }

    func testDeletedAgentChatsRemainDiscoverableWithoutInventingADefinition() {
        let groups = project([], sessions: [chat("saved")], query: "old name")
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups.first?.definition)
        XCTAssertEqual(groups.first?.tasks.map(\.id), ["saved"])
        XCTAssertEqual(groups.first?.statusTitle, "Needs attention")
    }

    func testRunningStateIncludesConversationsHiddenByTheCurrentSearch() {
        let groups = project(
            [.trigger(trigger())],
            sessions: [chat("running", title: "Background work"), chat("match", title: "Receipt")],
            query: "receipt", running: ["running"]
        )
        XCTAssertEqual(groups.first?.runningChatCount, 1)
        XCTAssertEqual(groups.first?.statusTitle, "Running")
    }

    func testMissingSourceNeedsAttentionOnlyAfterConnectionsHaveLoaded() throws {
        let unknown = try XCTUnwrap(project([.trigger(trigger())], sessions: [], connectionsLoaded: false).first)
        XCTAssertEqual(unknown.statusTitle, "Ready")
        XCTAssertFalse(unknown.needsAttention)
        XCTAssertFalse(AgentSidebarFilter.attention.includes(unknown))

        let missing = try XCTUnwrap(project([.trigger(trigger())], sessions: [], connectionsLoaded: true).first)
        XCTAssertEqual(missing.statusTitle, "Needs attention")
        XCTAssertTrue(missing.sourceNeedsAttention)
        XCTAssertTrue(AgentSidebarFilter.attention.includes(missing))
    }

    func testDisabledOrDisconnectedSourceAppearsInAttentionFilter() throws {
        let sources = [
            connection(enabled: false),
            connection(health: "disconnected"),
            connection(health: "reauth_required"),
        ]
        for source in sources {
            let agent = try XCTUnwrap(project(
                [.trigger(trigger())], sessions: [], connections: [source], connectionsLoaded: true
            ).first)
            XCTAssertEqual(agent.statusTitle, "Needs attention")
            XCTAssertTrue(agent.sourceNeedsAttention)
            XCTAssertTrue(AgentSidebarFilter.attention.includes(agent))
        }
        let knownDisabled = try XCTUnwrap(project(
            [.trigger(trigger())], sessions: [], connections: [connection(enabled: false)], connectionsLoaded: false
        ).first)
        XCTAssertTrue(knownDisabled.sourceNeedsAttention, "An available connection record is already known")
    }

    func testHealthySourcesSchedulesAndPausedAgentsDoNotRaiseSourceWarnings() throws {
        let healthy = try XCTUnwrap(project(
            [.trigger(trigger())], sessions: [], connections: [connection(health: " Connected ")], connectionsLoaded: true
        ).first)
        XCTAssertEqual(healthy.statusTitle, "Ready")
        XCTAssertFalse(healthy.needsAttention)
        let scheduled = try XCTUnwrap(project([.schedule(schedule())], sessions: [], connectionsLoaded: true).first)
        XCTAssertFalse(scheduled.sourceNeedsAttention)

        var paused = trigger()
        paused.enabled = false
        let agent = try XCTUnwrap(project([.trigger(paused)], sessions: [], connectionsLoaded: true).first)
        XCTAssertEqual(agent.statusTitle, "Paused")
        XCTAssertFalse(agent.sourceNeedsAttention)
        XCTAssertTrue(AgentSidebarFilter.paused.includes(agent))
        XCTAssertFalse(AgentSidebarFilter.attention.includes(agent))
    }

    func testRunningStatusTakesPriorityWhileSourceIssueRemainsDiscoverable() throws {
        let agent = try XCTUnwrap(project(
            [.trigger(trigger())], sessions: [chat("running")], running: ["running"], connectionsLoaded: true
        ).first)
        XCTAssertEqual(agent.statusTitle, "Running")
        XCTAssertTrue(agent.sourceNeedsAttention)
        XCTAssertTrue(AgentSidebarFilter.running.includes(agent))
        XCTAssertTrue(AgentSidebarFilter.attention.includes(agent))
    }

    private func connection(enabled: Bool = true, health: String = "connected") -> ConnectorConnection {
        ConnectorConnection(
            id: "gmail", kind: .gmail, displayName: "Inbox", publicConfig: [:], cursor: [:],
            enabled: enabled, health: health, createdAt: 1, updatedAt: 1
        )
    }

    private func project(
        _ definitions: [AgentDefinition], sessions: [SessionSummary], query: String = "",
        showArchived: Bool = false, running: Set<String> = [],
        connections: [ConnectorConnection] = [], connectionsLoaded: Bool = false
    ) -> [AgentSidebarGroupModel] {
        AgentSidebarCatalog.groups(
            definitions: definitions, sessions: sessions, query: query,
            showArchived: showArchived, runningSessionIDs: running,
            connections: connections, connectionsLoaded: connectionsLoaded
        )
    }

    private func chat(
        _ id: String, title: String = "Conversation", archived: Bool = false, kind: String? = "event"
    ) -> SessionSummary {
        SessionSummary(
            id: id, name: "\(id).jsonl", preview: "", mtime: 1_800_000_000, size: 100,
            title: title, archived: archived, agentTriggerID: "inbox", agentKind: kind, agentName: "Old name"
        )
    }

    private func trigger() -> EventTrigger {
        EventTrigger(
            id: "inbox", name: "Inbox assistant", connectionID: "gmail", targetSessionID: "primary",
            instruction: "Summarize new messages", mode: .work, triggerKind: .event,
            filters: EventTriggerFilters(), runtimeState: PriceTriggerState(), actionConnectionIDs: [],
            enabled: true, createdAt: 1_800_000_000, updatedAt: 1_800_000_000
        )
    }

    private func schedule() -> ScheduledTask {
        ScheduledTask(
            id: "inbox", name: "Morning digest", prompt: "Review messages", workspaceRoot: "/tmp/locus",
            mode: .work, executionEnvironment: .local, runner: .solo, provider: "ollama", model: "test",
            timezone: "UTC", rule: ScheduleRule(kind: .daily, hour: 9, minute: 0), enabled: true,
            createdAt: 1_800_000_000, updatedAt: 1_800_000_000
        )
    }
}
