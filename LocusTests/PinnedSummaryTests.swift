import XCTest
@testable import Locus

/// Coverage for the Overview tab's pinned summary: the reducer that records
/// outputs and sources, the pure derivations the card renders from, and the
/// AppModel wiring that folds backend events into them.
final class PinnedSummaryTests: XCTestCase {
    // MARK: - Reducer

    private func base(workspace: String = "/tmp/project") -> SessionState {
        SessionState.empty(workspacePath: workspace, modelID: "gpt-5.6-sol", provider: "openai")
    }

    func testWebsiteOutputsDedupeNormalizeAndOrderNewestFirst() {
        var state = base()
        state = SessionStateReducer.reduce(state, .websiteOutput(url: "http://localhost:3000", at: 10))
        state = SessionStateReducer.reduce(state, .websiteOutput(url: "http://localhost:3000/", at: 20))
        state = SessionStateReducer.reduce(state, .websiteOutput(url: "HTTP://LOCALHOST:3000", at: 30))
        state = SessionStateReducer.reduce(state, .websiteOutput(url: "localhost:5173", at: 25))

        XCTAssertEqual(state.outputs.count, 2)
        XCTAssertEqual(state.outputs.first?.target, "http://localhost:3000")
        XCTAssertEqual(state.outputs.first?.firstSeenAt, 10)
        XCTAssertEqual(state.outputs.first?.lastSeenAt, 30)
        XCTAssertEqual(state.outputs.last?.target, "http://localhost:5173")
        XCTAssertEqual(state.outputs.first?.key, "website:http://localhost:3000")
    }

    func testWebsiteOutputsAreBounded() {
        var state = base()
        for port in 0..<(SessionStateReducer.outputLimit + 5) {
            state = SessionStateReducer.reduce(
                state, .websiteOutput(url: "http://localhost:\(4000 + port)", at: port)
            )
        }
        XCTAssertEqual(state.outputs.count, SessionStateReducer.outputLimit)
        XCTAssertEqual(state.outputs.first?.target, "http://localhost:\(4000 + SessionStateReducer.outputLimit + 4)")
    }

    func testProvidedSourcesTrackLaterFileActivity() {
        var state = base(workspace: "/tmp/p")
        state = SessionStateReducer.reduce(state, .sourceProvided(
            items: [
                SessionProvidedItem(name: "a.md", path: "/tmp/p/a.md", kind: .file),
                SessionProvidedItem(name: "Pasted image 1.png", path: nil, kind: .image),
            ],
            at: 1
        ))
        state = SessionStateReducer.reduce(state, .fileRead(path: "a.md", at: 2))
        state = SessionStateReducer.reduce(state, .fileEdit(path: "a.md", added: 1, removed: 0, at: 3))
        state = SessionStateReducer.reduce(state, .fileCreate(path: "/tmp/p/a.md", at: 4))
        state = SessionStateReducer.reduce(state, .sourceProvided(
            items: [SessionProvidedItem(name: "a.md", path: "/tmp/p/a.md", kind: .file)],
            at: 5
        ))

        let file = state.sources.first { $0.key == "file:/tmp/p/a.md" }
        XCTAssertEqual(file?.activities, [.provided, .read, .updated, .created])
        XCTAssertEqual(file?.count, 2)
        XCTAssertEqual(file?.lastSeenAt, 5)
        let image = state.sources.first { $0.key == "image:Pasted image 1.png" }
        XCTAssertNil(image?.target)
        XCTAssertEqual(image?.activities, [.provided])
        XCTAssertEqual(state.sources.count, 2)
    }

    func testSourceUsedAggregatesURLsToolsAndWebSearch() {
        var state = base()
        state = SessionStateReducer.reduce(state, .sourceUsed(
            kind: .url, label: "", target: "https://docs.swift.org/x/", at: 1
        ))
        state = SessionStateReducer.reduce(state, .sourceUsed(
            kind: .url, label: "docs.swift.org/x", target: "https://docs.swift.org/x", at: 2
        ))
        state = SessionStateReducer.reduce(state, .sourceUsed(kind: .tool, label: "github", target: nil, at: 3))
        for at in 4...6 {
            state = SessionStateReducer.reduce(state, .sourceUsed(kind: .webSearch, label: "Web search", target: nil, at: at))
        }
        state = SessionStateReducer.reduce(state, .sourceUsed(kind: .file, label: "ignored", target: "/x", at: 7))

        let link = state.sources.first { $0.kind == .url }
        XCTAssertEqual(link?.key, "url:https://docs.swift.org/x")
        XCTAssertEqual(link?.count, 2)
        XCTAssertEqual(link?.label, "docs.swift.org/x")
        XCTAssertEqual(link?.activities, [.read])
        XCTAssertEqual(state.sources.first { $0.kind == .tool }?.key, "tool:github")
        XCTAssertEqual(state.sources.first { $0.kind == .webSearch }?.count, 3)
        XCTAssertEqual(state.sources.first { $0.kind == .webSearch }?.key, "web-search")
        XCTAssertFalse(state.sources.contains { $0.kind == .file })
    }

    func testLegacySessionStateDecodesWithoutOutputsOrSources() throws {
        let legacy = """
        {"s1":{"status":"idle","workspace":{"name":"p","path":"/tmp/p"},
        "model":{"provider":"openai","id":"gpt-5.6-sol"},"plan":[],
        "events":[{"fileRead":{"path":"README.md","at":2}}],
        "files":[{"path":"README.md","kind":"read","added":0,"removed":0,"lastTouchedAt":2}],
        "resources":{"tokensUsed":0,"costUsd":0,"messages":0},"suggestions":[]}}
        """
        let states = try JSONDecoder().decode([String: SessionState].self, from: Data(legacy.utf8))
        let state = try XCTUnwrap(states["s1"])
        XCTAssertEqual(state.outputs, [])
        XCTAssertEqual(state.sources, [])
        XCTAssertEqual(state.files.first?.path, "README.md")
        XCTAssertEqual(state.events.count, 1)
    }

    func testSessionStateRoundTripsOutputsAndSources() throws {
        var state = base()
        state = SessionStateReducer.reduce(state, .websiteOutput(url: "http://localhost:3000", at: 1))
        state = SessionStateReducer.reduce(state, .sourceUsed(kind: .tool, label: "github", target: nil, at: 2))
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    @MainActor
    func testEmitterSkipsDuplicateWebsiteOutputEvents() {
        let emitter = SessionStateEmitter()
        emitter.activate(sessionID: "one", initial: base())
        emitter.emit(.websiteOutput(url: "http://localhost:3000", at: 1))
        emitter.emit(.websiteOutput(url: "http://localhost:3000/", at: 2))
        XCTAssertEqual(emitter.state.events.count, 1)
        XCTAssertEqual(emitter.state.outputs.count, 1)
    }

    @MainActor
    func testEmitterRestoreBoundsOutputsAndSources() throws {
        let suiteName = "LocusTests.pinnedSummary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var oversized = base()
        oversized.outputs = (0..<(SessionStateReducer.outputLimit + 3)).map {
            SessionOutput(kind: .website, target: "http://localhost:\(5000 + $0)", firstSeenAt: $0, lastSeenAt: $0)
        }
        oversized.sources = (0..<(SessionStateReducer.sourceLimit + 3)).map {
            SessionSource(
                kind: .tool, key: "tool:t\($0)", label: "t\($0)", target: nil,
                activities: [], count: 1, firstSeenAt: $0, lastSeenAt: $0
            )
        }
        let data = try JSONEncoder().encode(["one": oversized])
        defaults.set(data, forKey: "state")

        let reader = SessionStateEmitter()
        reader.configurePersistence(enabled: true, defaults: defaults, key: "state")
        XCTAssertEqual(reader.states["one"]?.outputs.count, SessionStateReducer.outputLimit)
        XCTAssertEqual(reader.states["one"]?.sources.count, SessionStateReducer.sourceLimit)
        // The newest sources survive the cut.
        XCTAssertTrue(reader.states["one"]?.sources.contains { $0.key == "tool:t\(SessionStateReducer.sourceLimit + 2)" } == true)
    }

    // MARK: - Classifier

    func testSessionSourceClassifierRecognizesToolsAndLoopbackURLs() {
        XCTAssertEqual(SessionSourceClassifier.classify(tool: "web_fetch"), .webFetch)
        XCTAssertEqual(SessionSourceClassifier.classify(tool: "browser_navigate"), .browserNavigate)
        XCTAssertEqual(SessionSourceClassifier.classify(tool: "background_service"), .backgroundService)
        XCTAssertEqual(SessionSourceClassifier.classify(tool: "browser_dev_server"), .backgroundService)
        XCTAssertEqual(
            SessionSourceClassifier.classify(tool: "mcp__github__search_issues"),
            .mcp(server: "github", tool: "search_issues")
        )
        XCTAssertEqual(SessionSourceClassifier.classify(tool: "read_file"), .other)
        XCTAssertEqual(
            SessionSourceClassifier.classify(tool: "mcp__fetch__web_fetch"),
            .mcp(server: "fetch", tool: "web_fetch")
        )
        XCTAssertTrue(SessionSourceClassifier.isWebSearchTool("web_search"))
        XCTAssertTrue(SessionSourceClassifier.isWebSearchTool("brave_web_search"))
        XCTAssertFalse(SessionSourceClassifier.isWebSearchTool("search_issues"))
        XCTAssertEqual(
            SessionSourceClassifier.loopbackURL(
                in: "Started 'vite' (pid 4); port ready — http://localhost:5173. A port accepting"
            )?.absoluteString,
            "http://localhost:5173"
        )
        XCTAssertNil(SessionSourceClassifier.loopbackURL(in: "Started 'vite' — no port was given"))
        XCTAssertNil(SessionSourceClassifier.loopbackURL(in: "see https://example.com/"))
    }

    // MARK: - Derivations

    func testOutputsMergeCreatedFilesAndWebsitesNewestFirst() {
        var state = base()
        state = SessionStateReducer.reduce(state, .fileCreate(path: "notes.md", at: 3))
        state = SessionStateReducer.reduce(state, .fileEdit(path: "lib.swift", added: 1, removed: 0, at: 6))
        state = SessionStateReducer.reduce(state, .websiteOutput(url: "http://localhost:3000", at: 4))
        state = SessionStateReducer.reduce(state, .fileCreate(path: "site/report.html", at: 5))

        let rows = PinnedSummary.outputs(state: state)
        XCTAssertEqual(rows.map(\.label), ["report.html", "Local preview", "notes.md"])
        XCTAssertEqual(rows[0].kind, .localSite)
        XCTAssertEqual(rows[1].kind, .website(loopback: true))
        XCTAssertEqual(rows[1].meta, "localhost:3000")
        XCTAssertEqual(rows[2].kind, .file)
        XCTAssertEqual(rows.map(\.key), ["site/report.html", "website:http://localhost:3000", "notes.md"])
    }

    func testWebsiteLabelsFollowCodex() {
        XCTAssertEqual(PinnedSummary.websiteLabel(target: "http://127.0.0.1:8080/app"), "Local preview")
        XCTAssertEqual(PinnedSummary.websiteLabel(target: "site/index.html"), "index.html")
        XCTAssertEqual(PinnedSummary.websiteLabel(target: "https://www.example.com/docs/"), "example.com/docs")
    }

    func testSourcesOrderProvidedThenLinksThenToolsThenWebSearch() {
        var state = base()
        state = SessionStateReducer.reduce(state, .sourceUsed(kind: .webSearch, label: "Web search", target: nil, at: 1))
        state = SessionStateReducer.reduce(state, .sourceUsed(kind: .tool, label: "zeta", target: nil, at: 2))
        state = SessionStateReducer.reduce(state, .sourceUsed(kind: .tool, label: "alpha", target: nil, at: 3))
        state = SessionStateReducer.reduce(state, .sourceUsed(kind: .url, label: "", target: "https://a.example/one", at: 4))
        state = SessionStateReducer.reduce(state, .sourceProvided(
            items: [SessionProvidedItem(name: "old.md", path: "/tmp/project/old.md", kind: .file)], at: 5
        ))
        state = SessionStateReducer.reduce(state, .sourceProvided(
            items: [SessionProvidedItem(name: "new.md", path: "/tmp/project/new.md", kind: .file)], at: 6
        ))

        let rows = PinnedSummary.sources(state: state)
        XCTAssertEqual(rows.map(\.source.label), ["new.md", "old.md", "a.example/one", "alpha", "zeta", "Web search"])
        XCTAssertEqual(rows.first?.meta, "/tmp/project/new.md")
        XCTAssertEqual(rows.last?.meta, nil)
    }

    func testSourceDetailLines() {
        let attached = SessionSource(
            kind: .image, key: "image:x.png", label: "x.png", target: nil,
            activities: [.provided], count: 1, firstSeenAt: 0, lastSeenAt: 0
        )
        XCTAssertEqual(PinnedSummary.detailLines(for: attached), ["Attached to the conversation"])
        let file = SessionSource(
            kind: .file, key: "file:/a", label: "a", target: "/a",
            activities: [.provided, .read, .updated], count: 1, firstSeenAt: 0, lastSeenAt: 0
        )
        XCTAssertEqual(
            PinnedSummary.detailLines(for: file),
            ["Provided in the conversation", "Read during the chat", "Updated during the chat"]
        )
        let link = SessionSource(
            kind: .url, key: "url:u", label: "u", target: "https://u", activities: [.read],
            count: 1, firstSeenAt: 0, lastSeenAt: 0
        )
        XCTAssertEqual(PinnedSummary.detailLines(for: link), ["Opened once"])
        let tool = SessionSource(
            kind: .tool, key: "tool:github", label: "github", target: nil, activities: [],
            count: 3, firstSeenAt: 0, lastSeenAt: 0
        )
        XCTAssertEqual(PinnedSummary.detailLines(for: tool), ["github 3 times"])
        let web = SessionSource(
            kind: .webSearch, key: "web-search", label: "Web search", target: nil, activities: [],
            count: 2, firstSeenAt: 0, lastSeenAt: 0
        )
        XCTAssertEqual(PinnedSummary.detailLines(for: web), ["Searched 2 times"])
    }

    func testSubagentStatusMappingCoversEveryTeamRunState() {
        for state in TeamRunState.allCases {
            let mapped = PinnedSummary.subagentStatus(state.rawValue)
            switch state {
            case .queued, .dispatching, .waitingPermission, .waitingComputer, .waitingDispatchApproval, .paused:
                XCTAssertEqual(mapped, .waiting, state.rawValue)
            case .running, .reviewing:
                XCTAssertEqual(mapped, .working, state.rawValue)
            case .completed:
                XCTAssertEqual(mapped, .done, state.rawValue)
            case .failed, .interrupted, .cancelled:
                XCTAssertEqual(mapped, .failed, state.rawValue)
            case .discarded:
                XCTAssertNil(mapped)
            }
        }
        XCTAssertFalse(PinnedSummary.autoCollapsesSubagents([]))
        XCTAssertFalse(PinnedSummary.autoCollapsesSubagents([
            .init(id: "a", name: "A", status: .working, runID: nil),
        ]))
        // Codex only auto-collapses when every agent is done; a failure stays.
        XCTAssertFalse(PinnedSummary.autoCollapsesSubagents([
            .init(id: "a", name: "A", status: .done, runID: nil),
            .init(id: "b", name: "B", status: .failed, runID: nil),
        ]))
        XCTAssertTrue(PinnedSummary.autoCollapsesSubagents([
            .init(id: "a", name: "A", status: .done, runID: nil),
            .init(id: "b", name: "B", status: .done, runID: nil),
        ]))
    }

    private func decodeRun(_ json: String) throws -> OrchestrationRun {
        try JSONDecoder().decode(OrchestrationRun.self, from: Data(json.utf8))
    }

    func testSubagentsPreferLiveActivitiesAndFallBackToSessionTeamRuns() throws {
        let teamRun = try decodeRun("""
        {"id":"team-1","session_id":"s","state":"running","request":"Check inventory",
         "team_name":"Checkers","created_at":1,"updated_at":2,"last_seq":0,
         "pinned":false,"legacy":false,"recoverable":false,"run_kind":"team"}
        """)
        // Production stamps `manifest.solo_swarm` on every non-Ask turn, so the
        // fixture must carry it too — eligibility alone stays excluded.
        let soloTurn = try decodeRun("""
        {"id":"solo-1","session_id":"s","state":"running","request":"Fix bug",
         "created_at":1,"updated_at":3,"last_seq":0,"manifest":{"solo_swarm":true},
         "pinned":false,"legacy":false,"recoverable":false,"run_kind":"solo"}
        """)
        let otherSession = try decodeRun("""
        {"id":"team-2","session_id":"other","state":"completed","request":"Elsewhere",
         "created_at":1,"updated_at":4,"last_seq":0,
         "pinned":false,"legacy":false,"recoverable":false,"run_kind":"team"}
        """)
        let delegatedByJobs = try decodeRun("""
        {"id":"solo-2","session_id":"s","state":"completed","request":"Sweep tests",
         "created_at":1,"updated_at":5,"last_seq":0,"manifest":{"solo_swarm":true},
         "job_count":2,"completed_job_count":2,
         "pinned":false,"legacy":false,"recoverable":false,"run_kind":"solo"}
        """)
        let delegatedByAttempts = try decodeRun("""
        {"id":"solo-3","session_id":"s","state":"completed","request":"Audit",
         "created_at":1,"updated_at":6,"last_seq":0,"manifest":{"solo_swarm":true},
         "attempts":[{"run_id":"solo-3","job_id":"worker-1","attempt":1,
                      "attempt_id":"worker-1:1","state":"completed","goal":"Read API"}],
         "pinned":false,"legacy":false,"recoverable":false,"run_kind":"solo"}
        """)
        let fallback = PinnedSummary.subagents(activities: [], runs: [soloTurn, otherSession, teamRun, delegatedByJobs, delegatedByAttempts], sessionID: "s")
        XCTAssertEqual(fallback.map(\.id), ["solo-3", "solo-2", "team-1"])
        XCTAssertEqual(fallback.last?.name, "Checkers")
        XCTAssertEqual(fallback.last?.status, .working)
        XCTAssertEqual(fallback.last?.runID, "team-1")
        XCTAssertEqual(fallback.first?.name, "Solo")

        // Regression: a session of ordinary eligible-but-alone turns must not
        // masquerade as subagents ("Subagents 8" for a chat with zero workers).
        let plainTurns = try (0..<8).map { index in
            try decodeRun("""
            {"id":"plain-\(index)","session_id":"s","state":"completed","request":"Turn \(index)",
             "created_at":1,"updated_at":\(10 + index),"last_seq":0,"manifest":{"solo_swarm":true},
             "pinned":false,"legacy":false,"recoverable":false,"run_kind":"solo"}
            """)
        }
        XCTAssertTrue(PinnedSummary.subagents(activities: [], runs: plainTurns, sessionID: "s").isEmpty)

        let activity = AgentActivity(
            id: "job-1", agentName: "Reader", role: "researcher", provider: "", model: "",
            goal: "Read", state: .completed, output: "", reasoningText: nil, tool: nil,
            evidence: [], startedAt: nil, elapsedMilliseconds: 0, promptTokens: 0, completionTokens: 0
        )
        let live = PinnedSummary.subagents(activities: [activity], runs: [teamRun], sessionID: "s")
        XCTAssertEqual(live.map(\.name), ["Reader"])
        XCTAssertEqual(live.first?.status, .done)
        XCTAssertNil(live.first?.runID)
        XCTAssertTrue(PinnedSummary.subagents(activities: [], runs: [teamRun], sessionID: "").isEmpty)
    }

    func testBackgroundProcessesPlanRowAndCreationPrompts() {
        let running = BackgroundServiceRecord(
            name: "vite", command: "npm run dev", cwd: "/tmp", port: 5173, pid: 1, running: true,
            exitCode: nil, startedAt: "", uptimeSeconds: 1, tail: nil
        )
        let exited = BackgroundServiceRecord(
            name: "old", command: "", cwd: "/tmp", port: nil, pid: nil, running: false,
            exitCode: 0, startedAt: "", uptimeSeconds: 0, tail: nil
        )
        XCTAssertEqual(PinnedSummary.backgroundProcesses([exited, running]).map(\.name), ["vite"])
        XCTAssertEqual(PinnedSummary.processLabel(running), "npm run dev")
        XCTAssertEqual(PinnedSummary.processLabel(exited), "old")

        var state = base()
        XCTAssertNil(PinnedSummary.plan(state: state, document: nil))
        state = SessionStateReducer.reduce(state, .planCreated(
            steps: [SessionPlanStep(id: "a", label: "A", state: .done), SessionPlanStep(id: "b", label: "B", state: .pending)],
            at: 1
        ))
        XCTAssertEqual(PinnedSummary.plan(state: state, document: nil)?.title, "Plan")
        XCTAssertEqual(PinnedSummary.plan(state: state, document: PlanDocument(title: "Ship it"))?.title, "Ship it")
        XCTAssertEqual(PinnedSummary.plan(state: state, document: nil)?.completed, 1)

        let prompts = SummaryCreationKind.allCases.map(\.prompt)
        XCTAssertEqual(Set(prompts).count, prompts.count)
        XCTAssertTrue(prompts.allSatisfy { $0.hasSuffix(" ") })
        XCTAssertEqual(SummaryIcon.symbolName(forPath: "a/b.html"), "globe")
        XCTAssertEqual(SummaryIcon.symbolName(forPath: "shot.PNG"), "photo")
        XCTAssertEqual(SummaryIcon.symbolName(forPath: "data.csv"), "tablecells")
        XCTAssertEqual(SummaryIcon.symbolName(forPath: "Makefile"), "doc.text")
    }

    // MARK: - Activity

    func testActivityCoversOnlyTheCurrentRequestAndSurvivesItsEnd() {
        // The reported failure: the Overview was blank the moment a run
        // finished. Activity is bounded by the request marker, not by the
        // run's lifetime, so a finished request keeps describing itself.
        var state = base()
        state = SessionStateReducer.reduce(state, .requestStarted(at: 10))
        state = SessionStateReducer.reduce(state, .command(cmd: "$ ls", exitCode: 0, at: 11))
        state = SessionStateReducer.reduce(state, .runFinished(
            summary: SessionRunSummary(
                completedSteps: 0, totalSteps: 0, durationMs: 20_000,
                endedAt: 12, summary: "done", outcome: .completed
            ),
            suggestions: nil,
            at: 12
        ))
        XCTAssertEqual(PinnedSummary.activity(state: state).map(\.label), ["$ ls"])

        state = SessionStateReducer.reduce(state, .requestStarted(at: 20))
        XCTAssertEqual(state.requestStartedAt, 20)
        XCTAssertTrue(PinnedSummary.activity(state: state).isEmpty)

        state = SessionStateReducer.reduce(state, .command(cmd: "$ git status", exitCode: 0, at: 21))
        XCTAssertEqual(PinnedSummary.activity(state: state).map(\.label), ["$ git status"])
    }

    func testActivityHasNothingToShowWithoutARequestMarker() {
        // A session persisted before the marker existed must not suddenly
        // present its whole history as "this request".
        var state = base()
        state = SessionStateReducer.reduce(state, .command(cmd: "$ ls", exitCode: 0, at: 1))
        XCTAssertNil(state.requestStartedAt)
        XCTAssertTrue(PinnedSummary.activity(state: state).isEmpty)
    }

    func testActivityCollapsesRepeatsAndKeepsFailuresAndTheStrongestFileEffect() {
        var state = base()
        state = SessionStateReducer.reduce(state, .requestStarted(at: 1))
        state = SessionStateReducer.reduce(state, .command(cmd: "$ pytest", exitCode: 1, at: 2))
        state = SessionStateReducer.reduce(state, .command(cmd: "$ pytest", exitCode: 0, at: 6))
        state = SessionStateReducer.reduce(state, .fileRead(path: "src/app.swift", at: 3))
        state = SessionStateReducer.reduce(state, .fileEdit(path: "src/app.swift", added: 2, removed: 0, at: 4))
        state = SessionStateReducer.reduce(state, .fileRead(path: "src/app.swift", at: 5))

        let rows = PinnedSummary.activity(state: state)
        XCTAssertEqual(rows.map(\.label), ["$ pytest", "app.swift"])
        XCTAssertEqual(rows[0].kind, .command(failed: true))
        XCTAssertEqual(rows[0].meta, "Failed · ×2")
        XCTAssertEqual(rows[1].kind, .file(.edit))
        XCTAssertEqual(rows[1].meta, "Edited")
        XCTAssertEqual(rows[1].target, "src/app.swift")
    }

    // MARK: - AppModel wiring

    private func sessionInfo(id: String, cwd: String = "/tmp") -> [String: Any] {
        [
            "type": "session_info",
            "model": "qwen3:8b",
            "host": "http://localhost:11434",
            "cwd": cwd,
            "session": "/tmp/\(id).jsonl",
            "session_id": id,
            "messages": 1,
            "approx_tokens": 0,
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "max_iterations": 40,
            "has_project_context": false,
            "permissions": ["skip_all": false, "allowed": []],
        ]
    }

    @MainActor
    private func toolCall(
        _ model: AppModel, id: String, tool: String, summary: String, detail: String,
        result: String = "", ok: Bool = true, denied: Bool = false
    ) {
        model.handleEventForTesting([
            "type": "tool_call_proposed", "id": id, "tool": tool,
            "summary": summary, "detail": detail, "auto": true,
        ])
        model.handleEventForTesting([
            "type": "tool_result", "id": id, "tool": tool, "summary": summary,
            "result": result, "ok": ok, "denied": denied,
        ])
    }

    func testFileTouchesAreBoundedAndKeepTheMostRecent() {
        var state = base()
        for index in 0..<(SessionStateReducer.fileLimit + 10) {
            state = SessionStateReducer.reduce(
                state, .fileCreate(path: "generated/file-\(index).txt", at: index)
            )
        }
        XCTAssertEqual(state.files.count, SessionStateReducer.fileLimit)
        XCTAssertEqual(
            state.files.first?.path,
            "generated/file-\(SessionStateReducer.fileLimit + 9).txt"
        )
    }

    func testACreatedFileStaysCreatedAfterLaterEdits() {
        // Outputs is `files.filter { $0.kind == .create }`, so demoting a
        // create would make a produced file disappear from the list the moment
        // the agent revised it.
        var state = base()
        state = SessionStateReducer.reduce(state, .fileCreate(path: "report.pdf", at: 1))
        state = SessionStateReducer.reduce(
            state, .fileEdit(path: "report.pdf", added: 2, removed: 1, at: 2)
        )
        state = SessionStateReducer.reduce(state, .fileRead(path: "report.pdf", at: 3))

        XCTAssertEqual(state.createdFiles.map(\.path), ["report.pdf"])
        XCTAssertEqual(PinnedSummary.outputs(state: state).map(\.label), ["report.pdf"])
    }

    @MainActor
    func testShellProducedFilesReachOutputsThroughReportedFileEffects() throws {
        // The reported failure: a PDF built by a shell command never appeared
        // in Outputs. The shell branch emitted a command event and returned
        // before any file activity was considered, and the fallback scraped
        // prose that never named the file.
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(sessionInfo(id: "effects-session", cwd: workspace.path))
        model.handleEventForTesting([
            "type": "tool_result",
            "id": "b1",
            "tool": "bash",
            "summary": "$ python make_report.py",
            "result": "wrote 1 page",
            "ok": true,
            "denied": false,
            "file_effects": [["path": "report.pdf", "effect": "create"]],
        ])

        let rows = PinnedSummary.outputs(state: model.sessionOverview.state)
        XCTAssertEqual(rows.map(\.label), ["report.pdf"])
        XCTAssertEqual(rows.first?.target, "report.pdf")

        // The command still gets recorded — the effects branch must not swallow it.
        XCTAssertTrue(model.sessionOverview.state.events.contains {
            if case .command(let cmd, _, _) = $0 { return cmd == "$ python make_report.py" }
            return false
        })
    }

    @MainActor
    func testPatchAddsAreCreatesAndOverwritesAreEdits() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(sessionInfo(id: "patch-session", cwd: workspace.path))
        model.handleEventForTesting([
            "type": "tool_result",
            "id": "p1",
            "tool": "apply_patch",
            "summary": "patch 2 file(s)",
            "ok": true,
            "denied": false,
            "file_effects": [
                ["path": "made.md", "effect": "create"],
                ["path": "existing.md", "effect": "edit"],
            ],
        ])

        let state = model.sessionOverview.state
        XCTAssertEqual(state.createdFiles.map(\.path), ["made.md"])
        XCTAssertEqual(
            state.files.first(where: { $0.path == "existing.md" })?.kind,
            .edit,
            "apply_patch used to report every touched file as an edit; now only M does"
        )
    }

    @MainActor
    func testTheSameFileFromDifferentFeedsCollapsesToOneOutputRow() throws {
        // Git reports repository-relative, a tool reports whatever the model
        // wrote, the watcher reports absolute. Without one normalization the
        // same PDF becomes three rows.
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let absolute = workspace.appendingPathComponent("report.pdf")
        try Data("%PDF".utf8).write(to: absolute)

        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(sessionInfo(id: "dedupe-session", cwd: workspace.path))

        for raw in ["report.pdf", "./report.pdf", absolute.path] {
            model.handleEventForTesting([
                "type": "tool_result",
                "id": "w-\(raw)",
                "tool": "write_file",
                "summary": "write report.pdf",
                "ok": true,
                "denied": false,
                "file_effects": [["path": raw, "effect": "create"]],
            ])
        }

        XCTAssertEqual(
            PinnedSummary.outputs(state: model.sessionOverview.state).count,
            1,
            "three spellings of one file are one output"
        )
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("locus-outputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    @MainActor
    func testToolResultsFoldIntoOutputsAndSources() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(sessionInfo(id: "summary-session"))

        toolCall(model, id: "f1", tool: "web_fetch", summary: "fetch https://example.com/docs", detail: "https://example.com/docs")
        toolCall(model, id: "f2", tool: "web_fetch", summary: "fetch https://example.com/docs", detail: "https://example.com/docs")
        toolCall(model, id: "n1", tool: "browser_navigate", summary: "open http://localhost:5173/", detail: "http://localhost:5173/")
        toolCall(model, id: "n2", tool: "browser_navigate", summary: "open https://swift.org/blog", detail: "https://swift.org/blog")
        toolCall(model, id: "n3", tool: "browser_navigate", summary: "browser back", detail: "")
        toolCall(model, id: "m1", tool: "mcp__brave__web_search", summary: "search", detail: "")
        toolCall(
            model, id: "b1", tool: "background_service", summary: "$ npm run dev", detail: "",
            result: "Started 'vite' (pid 4); port ready — http://localhost:5173. Keep going."
        )
        toolCall(model, id: "d1", tool: "web_fetch", summary: "fetch https://denied.example", detail: "https://denied.example", ok: false, denied: true)
        // A tab reset is not a source, and a status listing echoes every
        // managed server in the backend — neither may be recorded.
        toolCall(model, id: "n4", tool: "browser_navigate", summary: "open about:blank", detail: "about:blank")
        toolCall(
            model, id: "b2", tool: "background_service", summary: "$ status", detail: "",
            result: "other-vite: running on port 4321, pid 9, up 30s — $ npm run dev\n  ➜  Local: http://localhost:4321/"
        )
        toolCall(model, id: "m2", tool: "mcp__fetch__web_fetch", summary: "fetch", detail: "{\"url\": \"https://mcp.example\"}")

        let state = model.sessionOverview.state
        XCTAssertEqual(state.outputs.map(\.target), ["http://localhost:5173"])
        XCTAssertFalse(state.sources.contains { $0.label.contains("about:blank") })
        XCTAssertTrue(state.sources.contains { $0.kind == .tool && $0.label == "fetch" })
        let links = state.sources.filter { $0.kind == .url }
        XCTAssertEqual(Set(links.map(\.target)), ["https://example.com/docs", "https://swift.org/blog"])
        XCTAssertEqual(links.first { $0.target == "https://example.com/docs" }?.count, 2)
        XCTAssertEqual(links.first { $0.target == "https://example.com/docs" }?.label, "example.com/docs")
        XCTAssertEqual(state.sources.first { $0.kind == .tool }?.label, "brave")
        XCTAssertEqual(state.sources.first { $0.kind == .webSearch }?.count, 1)
        XCTAssertFalse(state.sources.contains { $0.target == "https://denied.example" })
    }

    @MainActor
    func testSendRecordsAttachmentsAndIncludedContextFilesAsSources() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online
        model.handleEventForTesting(sessionInfo(id: "send-session"))
        model.chatAttachments = [
            ChatAttachment(url: URL(fileURLWithPath: "/tmp/a.txt"), kind: .text, textContent: "hello"),
            ChatAttachment.pasted(imageData: Data([1, 2, 3]), mimeType: "image/png", date: Date(), nameStem: "Pasted image"),
        ]
        model.contextFiles = [
            ContextFile(url: URL(fileURLWithPath: "/tmp/p/inc.md"), content: "c", isIncluded: true),
            ContextFile(url: URL(fileURLWithPath: "/tmp/p/exc.md"), content: "c", isIncluded: false),
        ]

        model.send("hi")

        let sources = model.sessionOverview.state.sources
        XCTAssertTrue(sources.contains { $0.key == "file:/tmp/a.txt" })
        XCTAssertTrue(sources.contains { $0.kind == .image && $0.label.hasPrefix("Pasted image") })
        XCTAssertTrue(sources.contains { $0.key == "file:/tmp/p/inc.md" })
        XCTAssertFalse(sources.contains { $0.key == "file:/tmp/p/exc.md" })
        XCTAssertTrue(model.chatAttachments.isEmpty)
    }

    @MainActor
    func testProvidedSourceItemsSkipContextInAskMode() {
        let attachment = ChatAttachment(url: URL(fileURLWithPath: "/tmp/a.txt"), kind: .text, textContent: "hello")
        let context = ContextFile(url: URL(fileURLWithPath: "/tmp/p/inc.md"), content: "c", isIncluded: true)
        let ask = AppModel.providedSourceItems(attachments: [attachment], contextFiles: [context], mode: .ask)
        XCTAssertEqual(ask.map(\.name), ["a.txt"])
        let work = AppModel.providedSourceItems(attachments: [attachment], contextFiles: [context], mode: .work)
        XCTAssertEqual(work.map(\.name), ["a.txt", "inc.md"])
        XCTAssertEqual(work.last?.path, "/tmp/p/inc.md")
    }

    @MainActor
    func testNewChatResetsSummaryOutputsAndSources() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(sessionInfo(id: "first"))
        toolCall(model, id: "n1", tool: "browser_navigate", summary: "open http://localhost:3000", detail: "http://localhost:3000")
        XCTAssertEqual(model.sessionOverview.state.outputs.count, 1)

        var fresh = sessionInfo(id: "fresh")
        fresh.removeValue(forKey: "type")
        _ = model.beginTranscriptTransition(
            source: model.backend, reasons: ["clear_chat"], acceptsSocketAcknowledgement: true
        )
        model.handleEventForTesting(["type": "session_started", "reason": "clear_chat", "session_info": fresh])

        XCTAssertTrue(model.sessionOverview.state.outputs.isEmpty)
        XCTAssertTrue(model.sessionOverview.state.sources.isEmpty)
        XCTAssertEqual(model.sessionOverview.states["first"]?.outputs.count, 1)
    }

    @MainActor
    func testPrefillComposerFromSummaryKeepsInspectorOpen() async {
        let model = AppModel(startImmediately: false)
        model.inspectorCollapsed = false
        let token = model.composerFocusToken
        model.insertCreationPrompt(.document)
        // The prefill re-applies after one main-actor turn; a fixed yield
        // count raced it on slow CI runners, so poll with a bound instead.
        var attempts = 0
        while model.composerFocusToken == token, attempts < 500 {
            attempts += 1
            await Task.yield()
        }
        XCTAssertEqual(model.draftText, SummaryCreationKind.document.prompt)
        XCTAssertFalse(model.inspectorCollapsed)
        XCTAssertNotEqual(model.composerFocusToken, token)
    }

    @MainActor
    func testStopAllBackgroundServicesDropsRunningRowsOptimistically() {
        let model = AppModel(startImmediately: false)
        model.backgroundServicesModel.applyBackgroundServicesForTesting([
            BackgroundServiceRecord(
                name: "vite", command: "npm run dev", cwd: "/tmp", port: 5173, pid: 1, running: true,
                exitCode: nil, startedAt: "", uptimeSeconds: 1, tail: nil
            ),
            BackgroundServiceRecord(
                name: "old", command: "", cwd: "/tmp", port: nil, pid: nil, running: false,
                exitCode: 0, startedAt: "", uptimeSeconds: 0, tail: nil
            ),
        ])
        model.backgroundServicesModel.stopAllBackgroundServices()
        XCTAssertEqual(model.backgroundServicesModel.backgroundServices.map(\.name), ["old"])
    }
}
