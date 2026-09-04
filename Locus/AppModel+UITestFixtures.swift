import AppKit
import Foundation

extension AppModel {
    func seedUITestState() {
        // A fixed path so UI tests see a deterministic workspace name ("tmp")
        // regardless of the runner's TMPDIR.
        let workspace = "/tmp"
        agentRuntimePhase = .online
        modelRuntimePhase = .online
        settings.automaticInspectorPresentationRaw = AutomaticInspectorPresentation.never.rawValue
        settings.soloPlanPresentationRaw = AutomaticInspectorPresentation.never.rawValue
        settings.teamRunsPresentationRaw = AutomaticInspectorPresentation.never.rawValue
        if let rawMode = ProcessInfo.processInfo.environment[
            "LOCUS_UI_TESTING_TOOL_ACTIVITY_MODE"
        ], ToolActivityVisibility(rawValue: rawMode) != nil {
            settings.toolActivityVisibilityRaw = rawMode
        }
        if let rawMode = ProcessInfo.processInfo.environment[
            "LOCUS_UI_TESTING_THINKING_MODE"
        ], ThinkingVisibility(rawValue: rawMode) != nil {
            settings.thinkingVisibilityRaw = rawMode
        }
        // The suite's inspector tests assume the panel starts open; the
        // collapsed default is covered by a settings unit test instead.
        openInspectorTabs = [.plan]
        inspectorTab = .plan
        inspectorCollapsed = false
        // Section collapse state lives in @AppStorage, which UI tests share
        // across launches; start each launch expanded unless a test opts in.
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_PRESERVE_SUMMARY_SECTIONS"] != "1" {
            for key in SummarySectionKey.allCases {
                UserDefaults.standard.removeObject(forKey: key.storageKey)
            }
        }
        models = [
            ModelInfo(
                name: "qwen3:8b",
                size: 8_000_000_000,
                parameterSize: "8B",
                contextLength: 32_768
            ),
        ]
        // The picker reads the local list, which a live refresh would normally
        // fill in.
        installedLocalModels = models
        localModels = models
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_LONG_MODEL"] == "1" {
            let account = ProviderAccount(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
                kind: .custom,
                name: "Long vLLM route",
                baseURLOverride: "https://example.invalid/v1",
                preferredModel: "/repository/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-NEO-MTP-Q8_0.gguf"
            )
            providerAccounts = [account]
            accountModels[account.id] = [account.preferredModel]
            accountStatus[account.id] = .connected(models: 1)
        }
        sessionInfo = SessionInfo(
            model: "qwen3:8b",
            host: "http://localhost:11434",
            cwd: workspace,
            session: "\(workspace)/seed-current.jsonl",
            sessionID: "seed-current",
            messages: 3,
            approxTokens: 42,
            promptTokens: 20,
            completionTokens: 22,
            contextLimit: 32_768,
            maxIterations: 40,
            hasProjectContext: false,
            provider: "ollama",
            permissions: SessionPermissions(skipAll: false, allowed: [])
        )
        currentSessionID = "seed-current"
        if let voiceState = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_VOICE_STATE"] {
            voiceControl.seedUITestState(voiceState, sessionID: currentSessionID)
        }
        sessions = [
            SessionSummary(
                id: "seed-current",
                name: "seed-current.jsonl",
                preview: "Review the workspace",
                mtime: Date().timeIntervalSince1970,
                size: 400,
                title: "Workspace review",
                pinned: true,
                cwd: workspace
            ),
            SessionSummary(
                id: "seed-archived",
                name: "seed-archived.jsonl",
                preview: "Archived design pass",
                mtime: Date().addingTimeInterval(-600).timeIntervalSince1970,
                size: 300,
                archived: true,
                cwd: workspace
            ),
        ]
        expandedWorkspaceIDs = [SessionSummary.canonicalWorkspacePath(workspace)]
        blocks = [
            ChatBlock(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                kind: .user,
                text: "Review the workspace"
            ),
            ChatBlock(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                kind: .assistant,
                text: "The workspace is ready for a focused review."
            ),
            ChatBlock(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
                kind: .note,
                completion: TurnCompletion(
                    outcome: .complete,
                    mode: .work,
                    durationMilliseconds: 84_000
                )
            ),
        ]
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_TEXT_OUTPUT"] == "1" {
            let code = (1...25).map { "line \($0)" }.joined(separator: "\n")
            let tableRows = (1...11).map { "| Row \($0) | Value \($0) |" }
                .joined(separator: "\n")
            let response = """
            <think>private fixture reasoning</think>
            # Copy formats

            Read **the [complete guide](https://example.com/guide)**.

            ```swift
            \(code)
            ```

            | Name | Value |
            | --- | --- |
            \(tableRows)

            Complete response suffix.
            """
            blocks = [
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000109")!,
                    kind: .user,
                    text: "Show the text-output fixture"
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000110")!,
                    kind: .assistant,
                    text: response
                ),
            ]
        }
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_SELECTION"] == "1" {
            blocks = [
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000119")!,
                    kind: .user,
                    text: "Select the response"
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000120")!,
                    kind: .assistant,
                    text: """
                    Drag start paragraph.

                    - First bullet
                    - Second bullet

                    Drag end paragraph.

                    QuoteMeSelectionTarget
                    """
                ),
            ]
            draftText = "Existing draft"
        }
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_SCROLL"] == "1" {
            blocks = [blocks[0]]
            for index in 0..<12 {
                blocks.append(ChatBlock(
                    kind: .assistant,
                    text: "Result \(index): The transcript should move continuously across selectable text, reasoning, and tool activity without snapping or stopping.",
                    reasoningText: "Reviewed section \(index) and verified the surrounding output before continuing to the next tool call."
                ))
            }
            for index in 0..<12 {
                blocks.append(ChatBlock(
                    id: UUID(uuidString: String(
                        format: "00000000-0000-0000-0000-%012X",
                        0x401 + index
                    ))!,
                    kind: .tool,
                    tool: ToolPayload(
                        toolID: "scroll-tool-\(index)",
                        tool: "read_file",
                        summary: "Reviewed section \(index)",
                        detail: String(repeating: "Selectable tool output for section \(index). ", count: 12),
                        status: .done,
                        result: "Completed section \(index)"
                    )
                ))
            }
        }
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_THINKING_FIXTURE"] == "1" {
            blocks = [
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                    kind: .user,
                    text: "Audit the workspace"
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                    kind: .assistant,
                    reasoningText: "Inspect the remaining files."
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                    kind: .assistant,
                    text: "The first audit pass is complete."
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000206")!,
                    kind: .tool,
                    tool: ToolPayload(
                        toolID: "thinking-fixture-tool",
                        tool: "read_file",
                        summary: "Read remaining files",
                        detail: "",
                        status: .done,
                        result: "Files inspected"
                    )
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
                    kind: .assistant,
                    text: "<thinking>Confirm the remaining modules.</thinking>"
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!,
                    kind: .assistant,
                    text: "The workspace audit is complete.",
                    reasoningText: "Prepare the final audit response."
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!,
                    kind: .note,
                    completion: TurnCompletion(
                        outcome: .complete,
                        mode: .work,
                        durationMilliseconds: 1_000
                    )
                ),
            ]
        }
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_CODEX_TRANSCRIPT_FIXTURE"] == "1" {
            blocks = [
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                    kind: .user,
                    text: "Check Austin and Jerusalem"
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
                    kind: .assistant,
                    sourceItemID: "reason-fixture",
                    reasoningText: "**Planning data retrieval**\n\n**Checking forecast parsing**",
                    reasoningSections: [
                        "**Planning data retrieval**",
                        "**Checking forecast parsing**",
                    ]
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
                    kind: .assistant,
                    text: "I’ll check both locations now.",
                    assistantPhase: .commentary,
                    sourceItemID: "commentary-fixture"
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000306")!,
                    kind: .tool,
                    tool: ToolPayload(
                        toolID: "codex-read",
                        tool: "read_file",
                        summary: "Read forecast data",
                        detail: "Austin and Jerusalem forecast sources",
                        status: .done,
                        result: "Forecast data loaded"
                    )
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000307")!,
                    kind: .tool,
                    tool: ToolPayload(
                        toolID: "codex-command",
                        tool: "bash",
                        summary: "Normalize forecast output",
                        detail: "normalize forecasts",
                        status: .done,
                        result: "Forecasts normalized"
                    )
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000308")!,
                    kind: .assistant,
                    text: "The source data is ready.",
                    assistantPhase: .commentary,
                    sourceItemID: "commentary-fixture-2"
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000309")!,
                    kind: .assistant,
                    text: "<think>Compare the two forecasts</think>Both locations have clear conditions.",
                    assistantPhase: .commentary,
                    sourceItemID: "commentary-fixture-3"
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000310")!,
                    kind: .tool,
                    tool: ToolPayload(
                        toolID: "codex-browser",
                        tool: "browser",
                        summary: "Verify forecast page",
                        detail: "Open forecast page",
                        status: .done,
                        result: "Forecast verified"
                    )
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
                    kind: .assistant,
                    text: "- **Austin:** Sunny and hot.\n- **Jerusalem:** Warm and dry.",
                    assistantPhase: .finalAnswer,
                    sourceItemID: "final-fixture"
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000305")!,
                    kind: .note,
                    completion: TurnCompletion(
                        outcome: .complete,
                        mode: .work,
                        durationMilliseconds: 1_000
                    )
                ),
            ]
        }
        if ProcessInfo.processInfo.environment[
            "LOCUS_UI_TESTING_PERFORMANCE_TRANSCRIPT"
        ] == "1" {
            let imagePath = "/tmp/locus-performance-fixture.png"
            writePerformanceFixtureImage(to: imagePath)
            let prose = (0..<12).map { index in
                """
                ## Performance section \(index + 1)

                This deterministic paragraph is deliberately long enough to wrap at several \
                nearby widths while the window is resized. It exercises headings, emphasis, \
                links, and the selectable native text leaf without depending on a network.

                - A first list item with **strong text** and `inline code`
                - A second list item whose wrapping changes with the conversation width

                | Metric | Value | Status |
                | --- | ---: | :---: |
                | Frame budget | 8.3 ms | Target |
                | Width bucket | 4 pt | Active |

                ```swift
                let section = \(index)
                let bucket = floor(width / 4) * 4
                ```
                """
            }.joined(separator: "\n\n")
            let streamID = UUID(uuidString: "00000000-0000-0000-0000-000000000904")!
            blocks = [
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
                    kind: .user,
                    text: "Render the deterministic performance transcript"
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
                    kind: .assistant,
                    reasoningText: "Measure layout buckets\n\nVerify incremental Markdown",
                    reasoningSections: [
                        "Measure layout buckets",
                        "Verify incremental Markdown",
                    ]
                ),
                ChatBlock(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000903")!,
                    kind: .assistant,
                    text: prose + "\n\n![Performance image](\(imagePath))",
                    assistantPhase: .finalAnswer
                ),
                ChatBlock(
                    id: streamID,
                    kind: .assistant,
                    assistantPhase: .commentary,
                    isStreaming: true
                ),
            ]
            streamingAssistantID = streamID
            streamingReply.resetTurn()
            streamingReply.begin(id: streamID)
            streamingReply.append(
                text: "### Streaming tail\n\nNew text is visible immediately while **formatting",
                reasoning: "Keep ordered reasoning chunks. ",
                reasoningSections: [0: "Inspect the mutable tail."]
            )
            isBusy = true
        }
        extensionsModel.extensions = ExtensionsResponse(
            capabilities: ExtensionCapabilities(),
            marketplaces: [],
            plugins: [],
            skills: [],
            mcpServers: [],
            mcpPresets: [
                ExtensionMCPPreset(
                    id: "github",
                    name: "github",
                    displayName: "GitHub",
                    description: "Search repositories and work with issues and pull requests.",
                    url: "https://api.githubcopilot.com/mcp/",
                    sourceURL: nil,
                    auth: "oauth",
                    oauthStrategy: "github_device",
                    fallback: nil,
                    fallbackHeader: nil,
                    optionalHeader: nil,
                    scopes: [],
                    warning: "Review requested permissions before connecting.",
                    requiresProjectRef: false,
                    installed: false,
                    serverID: nil,
                    defaultToolsApprovalMode: "annotations",
                    resourcesDiscoverable: true,
                    promptsEnabled: false,
                    catalogVersion: 2
                ),
            ],
            errors: [],
            pendingUpdates: 0
        )
        promptHistory = ["Audit the current changes", "Review the workspace"]

        // The three newest inspector tabs read from state the agent normally
        // fills in. Without seeds they render their empty states and nothing
        // about them is assertable.
        gitWorkspace.isGitRepository = true
        gitWorkspace.gitBranch = "main"
        gitWorkspace.gitUpstream = "origin/main"
        gitWorkspace.gitAhead = 2
        gitWorkspace.gitBehind = 1
        gitWorkspace.gitHasCommits = true
        gitWorkspace.localBranches = ["main", "ship-test"]
        // Remote features stay hidden in the seeded run unless a UI test asks
        // for them, so the suite also covers the sandboxed layout.
        gitWorkspace.originIsGitHub =
            ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_GITHUB_ORIGIN"] == "1"
        gitWorkspace.gitChanges = [
            GitChange(
                path: "Locus/AppModel.swift",
                status: .modified,
                staged: false,
                unstaged: true,
                additions: 12,
                deletions: 3
            ),
            GitChange(
                path: "Locus/InspectorView.swift",
                status: .modified,
                staged: true,
                unstaged: false,
                additions: 40,
                deletions: 120
            ),
            GitChange(
                path: "docs/terminal.md",
                status: .untracked,
                staged: false,
                unstaged: true
            ),
        ]
        if ProcessInfo.processInfo.environment[
            "LOCUS_UI_TESTING_PREFILL_RECOMMENDATION"
        ] == "1" {
            gitWorkspace.gitChanges = []
        }
        let seededWorkspaceFiles = [
            "README.md",
            "Locus/AppModel.swift",
            "Locus/InspectorView.swift",
            "Locus/TerminalSession.swift",
            "docs/terminal.md",
        ].map { URL(fileURLWithPath: workspace).appending(path: $0) }
        workspaceFiles.seed(seededWorkspaceFiles, workspacePath: workspace)
        agentInstructions.agentInstructionsExists = true
        agentInstructions.savedAgentInstructions = "# Workspace instructions\n\n- Keep changes focused.\n"
        agentInstructions.agentInstructionsDraft = agentInstructions.savedAgentInstructions
        workspaceProfiles = [
            WorkspaceProfile(
                path: workspace,
                lastOpened: Date(),
                model: "qwen3:8b",
                accountID: nil,
                mode: .work,
                previewURL: "http://localhost:3000",
                contextFiles: [],
                draft: ""
            ),
        ]
        if let width = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_INSPECTOR_WIDTH"],
           let value = Double(width) {
            inspectorWidth = CGFloat(AppSettings.clampInspectorWidth(value))
        }
        if let appearance = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_APPEARANCE"],
           AppAppearance(rawValue: appearance) != nil {
            settings.appearanceRaw = appearance
        }
        if let variant = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_AGENT_FIXTURE"],
           !variant.isEmpty {
            seedAgentFixture(workspace: workspace, selectsAgentChat: variant != "fleet")
            // "schedule" lands on the scheduled agent's chat so its panel shows.
            if variant == "schedule" { currentSessionID = "seed-schedule-chat" }
        }
        seedSessionOverviewUITest(workspace: workspace)
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_LANDING"] == "1" {
            activeTaskRecord = TaskRecord(
                id: "seed-task",
                workspaceRoot: workspace,
                executionPath: "/tmp/locus-seed-worktree",
                baselineTree: "1111111111111111111111111111111111111111",
                state: .completed,
                sessionID: currentSessionID,
                startingRef: "main"
            )
            landingFlow.taskHasChanges = true
            landingFlow.taskPatchBytes = 184
            landingFlow.landingPreflight = LandingPreflight(
                ok: true,
                tree: "2222222222222222222222222222222222222222",
                baseTree: "1111111111111111111111111111111111111111",
                paths: ["Locus/AppModel.swift"],
                patchBytes: 184,
                canApplyLocal: true,
                conflict: "",
                branch: nil
            )
            landingFlow.landingPatch = """
            diff --git a/Locus/AppModel.swift b/Locus/AppModel.swift
            --- a/Locus/AppModel.swift
            +++ b/Locus/AppModel.swift
            @@ -1 +1 @@
            -let status = "old"
            +let status = "reviewed"
            """
            workspaceProfiles[0].landingCheckCommands = ["swift test"]
        }

        // Opt-in, not part of the base fixture: a pending permission disables
        // send and clear-chat globally, which would break every other UI test.
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_PERMISSION"] == "1" {
            blocks.append(ChatBlock(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                kind: .tool,
                tool: ToolPayload(
                    toolID: "seed-tool-permission",
                    tool: "bash",
                    summary: "$ rm -rf build",
                    detail: "rm -rf build",
                    status: .awaitingPermission,
                    requestID: "req-ui-1"
                )
            ))
        }
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_PLAN_APPROVAL"] == "1" {
            selectedMode = .plan
            activePlan = PlanDocument(
                id: "seed-plan-approval",
                title: "Improve retry reliability",
                summary: "Make retries bounded, observable, and covered by tests.",
                steps: [
                    "Extract the retry policy",
                    "Add bounded exponential backoff",
                    "Add integration tests for timeout paths",
                ],
                tests: ["Run the retry integration suite"]
            )
            todos = activePlan?.steps.map { TodoItem(content: $0, status: .pending) } ?? []
            planApprovalPending = true
        }
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_QUESTION_PROMPT"] == "1" {
            selectedMode = .grill
            pendingUserQuestion = UserQuestion(
                id: "seed-question-prompt",
                title: "Retry backoff shape",
                question: "Should retries back off exponentially or on a fixed interval?",
                options: [
                    UserQuestionOption(
                        label: "Exponential with jitter",
                        detail: "Spreads thundering herds"
                    ),
                    UserQuestionOption(
                        label: "Fixed interval",
                        detail: "Predictable, simpler to reason about"
                    ),
                ],
                recommended: "Exponential with jitter"
            )
        }
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_BLOCKING_QUESTION"] == "1" {
            selectedMode = .grill
            pendingBlockingQuestion = AgentQuestionRequest(
                id: "seed-blocking-question",
                toolID: "seed-tool-question",
                questions: [
                    AgentQuestion(
                        id: "q1",
                        header: "Storage",
                        question: "Where should the response cache live?",
                        options: [
                            AgentQuestionOption(
                                label: "In-memory",
                                description: "Fastest, but lost on restart."
                            ),
                            AgentQuestionOption(
                                label: "SQLite",
                                description: "Durable, with a small storage cost."
                            ),
                        ]
                    ),
                    AgentQuestion(
                        id: "q2",
                        header: "Naming",
                        question: "What should the public API call this?"
                    ),
                ]
            )
        }
        seedUITestRunFixtureIfNeeded()

        if let simulatorFixture = ProcessInfo.processInfo.environment[
            "LOCUS_UI_TESTING_SIMULATOR"
        ] {
            simulatorControl.installUITestFixture(
                sessionID: currentSessionID,
                attached: simulatorFixture == "attached"
            )
            openInspectorTabs = [.simulator]
            inspectorTab = .simulator
            inspectorCollapsed = false
        }

        // Documentation captures use the same deterministic app state as UI
        // tests, but start at the calm empty workspace shown to new users.
        // This is test-only state and never runs in a normal app launch.
        if let documentationSurface = ProcessInfo.processInfo.environment[
            "LOCUS_UI_TESTING_DOCUMENTATION_SURFACE"
        ] {
            blocks = []
            selectedMode = .plan
            inspectorCollapsed = false
            inspectorZoomed = documentationSurface == "files"
            let tab: InspectorTab = documentationSurface == "plan" ? .plan : .files
            openInspectorTabs = [tab]
            inspectorTab = tab
        }
    }

    /// One Gmail agent with two chats and two deliveries plus a fired price
    /// alert with no chats yet, opened in Agents mode. `selectsAgentChat`
    /// lands on the Gmail agent's newest chat; otherwise the current chat
    /// stays the ordinary one so the tab shows the fleet.
    private func seedAgentFixture(workspace: String, selectsAgentChat: Bool) {
        let now = Date().timeIntervalSince1970
        let triggerID = "seed-agent"
        let newestChat = SessionSummary(
            id: "seed-agent-chat",
            name: "seed-agent-chat.jsonl",
            preview: "Triage the inbox",
            mtime: now - 120,
            size: 320,
            title: "Chat 2",
            cwd: workspace,
            agentTriggerID: triggerID,
            agentName: "Inbox Triage",
            agentPrimary: true,
            model: "qwen3:8b",
            provider: "ollama"
        )
        let olderChat = SessionSummary(
            id: "seed-agent-chat-older",
            name: "seed-agent-chat-older.jsonl",
            preview: "Summarize the invoice",
            mtime: now - 7_200,
            size: 640,
            title: "Chat 1",
            cwd: workspace,
            agentTriggerID: triggerID,
            agentName: "Inbox Triage"
        )
        sessions.append(contentsOf: [newestChat, olderChat])
        if selectsAgentChat {
            currentSessionID = newestChat.id
        }
        if selectsAgentChat { sessionInfo = SessionInfo(
            model: "qwen3:8b",
            host: "http://localhost:11434",
            cwd: workspace,
            session: "\(workspace)/seed-agent-chat.jsonl",
            sessionID: newestChat.id,
            messages: 2,
            approxTokens: 30,
            promptTokens: 14,
            completionTokens: 16,
            contextLimit: 32_768,
            maxIterations: 40,
            hasProjectContext: false,
            provider: "ollama",
            permissions: SessionPermissions(skipAll: false, allowed: [])
        ) }

        let connection = ConnectorConnection(
            id: "seed-gmail",
            kind: .gmail,
            displayName: "Work Gmail",
            publicConfig: [:],
            cursor: [:],
            enabled: true,
            health: "connected",
            lastError: nil,
            lastPolledAt: now - 45,
            createdAt: now - 86_400,
            updatedAt: now - 45
        )
        var filters = EventTriggerFilters()
        filters.senders = ["boss@example.com"]
        filters.subjectContains = ["invoice"]
        let trigger = EventTrigger(
            id: triggerID,
            name: "Inbox Triage",
            connectionID: connection.id,
            targetSessionID: newestChat.id,
            instruction: "Summarize each matching email, extract the amount due, and draft a reply for review before anything is sent.",
            mode: .work,
            triggerKind: .event,
            filters: filters,
            runtimeState: PriceTriggerState(),
            actionConnectionIDs: [connection.id],
            enabled: true,
            createdAt: now - 86_400,
            updatedAt: now - 120,
            lastEventAt: now - 120,
            lastRunID: nil,
            lastError: nil
        )
        func event(_ id: String, subject: String, at: Double) -> InboundEvent {
            InboundEvent(
                source: .gmail,
                sourceEventID: id,
                eventType: "email.received",
                occurredAt: at,
                actor: ["email": .string("boss@example.com")],
                subject: subject,
                text: "Please review the attached invoice.",
                recipients: ["me@example.com"],
                labels: ["INBOX"],
                attachments: [],
                data: [:]
            )
        }
        let deliveries = [
            EventDelivery(
                id: "seed-delivery-pending",
                triggerID: triggerID,
                sourceEventID: "msg-3",
                source: .gmail,
                receivedAt: now - 30,
                occurredAt: now - 35,
                event: event("msg-3", subject: "Locus ab invoice burst", at: now - 35),
                state: "pending",
                runState: nil,
                attempt: 0,
                sessionID: nil,
                runID: nil,
                error: nil,
                createdAt: now - 30,
                updatedAt: now - 30,
                targetSessionID: newestChat.id,
                matchedTriggerCount: 2
            ),
            EventDelivery(
                id: "seed-delivery-done",
                triggerID: triggerID,
                sourceEventID: "msg-2",
                source: .gmail,
                receivedAt: now - 120,
                occurredAt: now - 130,
                event: event("msg-2", subject: "Invoice #1042 ready", at: now - 130),
                state: "completed",
                runState: "completed",
                attempt: 1,
                sessionID: newestChat.id,
                runID: nil,
                error: nil,
                createdAt: now - 120,
                updatedAt: now - 60
            ),
            EventDelivery(
                id: "seed-delivery-failed",
                triggerID: triggerID,
                sourceEventID: "msg-1",
                source: .gmail,
                receivedAt: now - 7_200,
                occurredAt: now - 7_260,
                event: event("msg-1", subject: "Invoice #1041 overdue", at: now - 7_260),
                state: "failed",
                runState: nil,
                attempt: 2,
                sessionID: olderChat.id,
                runID: nil,
                error: "The model route was unavailable.",
                createdAt: now - 7_200,
                updatedAt: now - 7_100
            ),
        ]
        var priceFilters = EventTriggerFilters()
        var condition = PriceCondition()
        condition.providerSymbol = "BTCUSDT"
        condition.displaySymbol = "BTC/USD"
        condition.comparison = .crossesAbove
        condition.threshold = "65000"
        condition.lifecycle = .once
        priceFilters.priceCondition = condition
        var priceState = PriceTriggerState()
        priceState.lastPrice = "65240.10"
        priceState.lastSide = "above"
        priceState.lastQuoteAt = now - 300
        priceState.fired = true
        priceState.lastFiredAt = now - 3_600
        let priceFeed = ConnectorConnection(
            id: "seed-price-feed",
            kind: .priceFeed,
            displayName: "Coinbase spot",
            publicConfig: [:],
            cursor: [:],
            enabled: true,
            health: "connected",
            lastError: nil,
            lastPolledAt: now - 300,
            createdAt: now - 172_800,
            updatedAt: now - 300
        )
        let priceAlert = EventTrigger(
            id: "seed-price-alert",
            name: "BTC breakout",
            connectionID: priceFeed.id,
            targetSessionID: "seed-current",
            instruction: "When Bitcoin crosses the threshold, summarize the market context and suggest whether to rebalance.",
            mode: .plan,
            triggerKind: .price,
            filters: priceFilters,
            runtimeState: priceState,
            actionConnectionIDs: [],
            enabled: true,
            createdAt: now - 172_800,
            updatedAt: now - 3_600,
            lastEventAt: now - 3_600,
            lastRunID: nil,
            lastError: nil
        )
        // A third agent Locus switched off itself after a dispatch failure, so
        // the stopped state and its recovery are visible and assertable.
        let stoppedChat = SessionSummary(
            id: "seed-stopped-chat",
            name: "seed-stopped-chat.jsonl",
            preview: "Watch the deploy channel",
            mtime: now - 21_600,
            size: 210,
            title: "Deploy Watch",
            cwd: workspace,
            agentTriggerID: "seed-stopped-agent",
            agentName: "Deploy Watch"
        )
        sessions.append(stoppedChat)
        var stoppedFilters = EventTriggerFilters()
        stoppedFilters.commandPrefixes = ["/deploy"]
        let stoppedAgent = EventTrigger(
            id: "seed-stopped-agent",
            name: "Deploy Watch",
            connectionID: connection.id,
            targetSessionID: stoppedChat.id,
            instruction: "Summarize each deploy notice and flag failed steps.",
            mode: .work,
            triggerKind: .event,
            filters: stoppedFilters,
            runtimeState: PriceTriggerState(),
            actionConnectionIDs: [],
            enabled: false,
            createdAt: now - 259_200,
            updatedAt: now - 21_600,
            lastEventAt: now - 21_600,
            lastRunID: nil,
            lastError: "the target chat model is unavailable"
        )
        eventAutomations.seedForUITesting(
            connections: [connection, priceFeed],
            triggers: [trigger, priceAlert, stoppedAgent],
            deliveries: deliveries
        )

        // A scheduled agent: one dedicated chat its runs continue, plus the
        // occurrences that reached it, so the schedule kind is on screen.
        let scheduleID = "seed-schedule"
        let scheduleChat = SessionSummary(
            id: "seed-schedule-chat",
            name: "seed-schedule-chat.jsonl",
            preview: "Review the workspace and summarize what changed.",
            mtime: now - 3_600,
            size: 900,
            title: "Morning Review",
            cwd: workspace,
            agentTriggerID: scheduleID,
            agentName: "Morning Review",
            agentPrimary: true,
            model: "qwen3:8b",
            provider: "ollama"
        )
        sessions.append(scheduleChat)
        let morningReview = ScheduledTask(
            id: scheduleID,
            name: "Morning Review",
            prompt: "Review the workspace and summarize what changed since yesterday.",
            workspaceRoot: workspace,
            mode: .work,
            executionEnvironment: .local,
            runner: .solo,
            teamID: nil,
            teamName: nil,
            provider: "ollama",
            providerAccountID: nil,
            model: "qwen3:8b",
            timezone: TimeZone.current.identifier,
            rule: ScheduleRule(kind: .weekdays, hour: 9, minute: 0),
            enabled: true,
            nextRunAt: now + 43_200,
            createdAt: now - 604_800,
            updatedAt: now - 3_600,
            lastRunAt: now - 3_600,
            lastRunID: "seed-schedule-run-2",
            lastError: nil
        )
        let occurrences = [
            ScheduleOccurrence(
                id: "seed-schedule-occurrence-2",
                scheduleID: scheduleID,
                scheduleName: "Morning Review",
                scheduledFor: now - 3_600,
                trigger: "due",
                state: "queued",
                sessionID: scheduleChat.id,
                runID: "seed-schedule-run-2",
                error: nil,
                createdAt: now - 3_600,
                updatedAt: now - 3_500
            ),
            ScheduleOccurrence(
                id: "seed-schedule-occurrence-1",
                scheduleID: scheduleID,
                scheduleName: "Morning Review",
                scheduledFor: now - 90_000,
                trigger: "due",
                state: "skipped",
                sessionID: scheduleChat.id,
                runID: nil,
                error: "Skipped: the previous run in this agent's chat was still in progress.",
                createdAt: now - 90_000,
                updatedAt: now - 89_900
            ),
        ]
        schedule.seedForUITesting(
            tasks: [morningReview],
            occurrences: [scheduleID: occurrences]
        )
        // Set last: the destination change is what swaps the open Overview
        // for the Agent tab, exactly as choosing Agents in the sidebar does.
        sidebarDestination = .agents
    }

    private func seedSessionOverviewUITest(workspace: String) {
        let now = Self.sessionTimestamp
        var initial = SessionState.empty(
            workspacePath: workspace,
            modelID: "qwen3:8b",
            provider: "ollama"
        )
        initial.workspace = sessionOverviewWorkspace
        initial.model.contextWindow = 64_000
        initial.resources = SessionResources(tokensUsed: 24_100, costUsd: 0.42, messages: 4)
        sessionOverview.reset(sessionID: currentSessionID, initial: initial)

        let environment = ProcessInfo.processInfo.environment
        // The README's Overview screenshot should show a populated summary.
        let fixture = environment["LOCUS_UI_TESTING_PLAN_OVERVIEW"]
            ?? (environment["LOCUS_UI_TESTING_DOCUMENTATION_SURFACE"] == "plan" ? "running" : "idle")
        if fixture == "running" || fixture == "error" {
            let steps = [
                SessionPlanStep(id: "scan", label: "Scan checkout flow for parsing bugs", state: .pending),
                SessionPlanStep(id: "map", label: "Map retry paths in scraper module", state: .pending),
                SessionPlanStep(id: "refactor", label: "Refactor retry logic with backoff", state: .pending),
                SessionPlanStep(id: "tests", label: "Add unit tests and run lint", state: .pending),
            ]
            sessionOverview.emit(.planCreated(steps: steps, at: now - 190_000))
            sessionOverview.emit(.stepState(stepID: "scan", state: .running, at: now - 190_000))
            sessionOverview.emit(.stepState(stepID: "scan", state: .done, at: now - 170_000))
            sessionOverview.emit(.stepState(stepID: "map", state: .running, at: now - 165_000))
            sessionOverview.emit(.stepState(stepID: "map", state: .done, at: now - 120_000))
            sessionOverview.emit(.stepState(stepID: "refactor", state: .running, at: now - 84_000))
            sessionOverview.emit(.fileRead(path: "checkout/parser.ts", at: now - 120_000))
            sessionOverview.emit(.command(cmd: "npm test", exitCode: 3, at: now - 60_000))
            sessionOverview.emit(.fileEdit(
                path: "scraper/retry.ts",
                added: 42,
                removed: 11,
                at: now - 12_000
            ))
            sessionOverview.emit(.status(status: .running, reason: nil, at: now - 190_000))
            // Outputs: seven created files plus one dev server — eight rows,
            // so the pinned summary shows six and offers "Show 2 more".
            let createdFiles = [
                "notes/retry.txt", "site/index.html", "assets/backoff-curve.png",
                "scripts/run-retries.sh", "reports/retry-metrics.csv", "docs/retry-plan.md",
                "scraper/retry.ts",
            ]
            for (offset, path) in createdFiles.enumerated() {
                sessionOverview.emit(.fileCreate(path: path, at: now - 100_000 + offset * 5_000))
            }
            sessionOverview.emit(.websiteOutput(url: "http://localhost:5173", at: now - 40_000))
            // Sources: two provided files, one link, one MCP server, web search —
            // five rows, so the summary shows three and "View all".
            sessionOverview.emit(.sourceProvided(
                items: [
                    SessionProvidedItem(name: "README.md", path: workspace + "/README.md", kind: .file),
                    SessionProvidedItem(name: "spec.md", path: workspace + "/checkout/spec.md", kind: .file),
                ],
                at: now - 180_000
            ))
            sessionOverview.emit(.fileRead(path: "checkout/spec.md", at: now - 150_000))
            sessionOverview.emit(.sourceUsed(
                kind: .url,
                label: "developer.mozilla.org/en-US/docs/Web/API/fetch",
                target: "https://developer.mozilla.org/en-US/docs/Web/API/fetch",
                at: now - 140_000
            ))
            sessionOverview.emit(.sourceUsed(kind: .tool, label: "context7", target: nil, at: now - 130_000))
            sessionOverview.emit(.sourceUsed(kind: .tool, label: "context7", target: nil, at: now - 125_000))
            sessionOverview.emit(.sourceUsed(kind: .webSearch, label: "Web search", target: nil, at: now - 120_000))
            sessionOverview.emit(.sourceUsed(kind: .webSearch, label: "Web search", target: nil, at: now - 110_000))
            backgroundServicesModel.applyBackgroundServicesForTesting([
                BackgroundServiceRecord(
                    name: "vite",
                    command: "npm run dev",
                    cwd: workspace,
                    port: 5173,
                    pid: 4242,
                    running: true,
                    exitCode: nil,
                    startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-42)),
                    uptimeSeconds: 42,
                    tail: nil
                ),
            ])
            activity.activityRuns.append(OrchestrationRun(
                id: "seed-subagent",
                sessionID: currentSessionID,
                teamID: "seed-team",
                teamName: "Inventory checkers",
                workerID: "seed-worker",
                workspaceRoot: workspace,
                executionPath: workspace,
                taskID: nil,
                state: TeamRunState.running.rawValue,
                request: "Verify the inventory API contract",
                createdAt: Date().addingTimeInterval(-90).timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970,
                completedAt: nil,
                lastSequence: 12,
                pinned: false,
                legacy: false,
                recoverable: false,
                recoveryReason: nil,
                checkpoint: nil,
                attempts: nil,
                plan: nil,
                usage: ["model_calls": .number(3)],
                manifest: nil,
                jobCount: 2,
                completedJobCount: 1,
                runKind: "team",
                traceID: nil,
                contentPolicy: "metadata",
                executionEnvironment: "local",
                exportState: "pending",
                exportAttempts: 0
            ))
            if fixture == "error" {
                sessionOverview.emit(.stepState(stepID: "refactor", state: .failed, at: now))
                sessionOverview.emit(.status(
                    status: .error,
                    reason: "The model endpoint rejected the request. Check the account connection, then retry.",
                    at: now
                ))
            }
        } else {
            let summary = SessionRunSummary(
                completedSteps: 4,
                totalSteps: 4,
                durationMs: 372_000,
                endedAt: now - 372_000,
                summary: "Refactored retry logic with backoff; tests passing.",
                outcome: .completed
            )
            sessionOverview.emit(.runFinished(
                summary: summary,
                suggestions: [
                    "Add integration tests for retry paths",
                    "Review diff before committing",
                ],
                at: now - 372_000
            ))
        }
    }

    /// The tool trail of a Solo turn that wrote code and ran it: two files, two
    /// commands, one of which failed. Everything the Overview's file list and
    /// the Activity timeline read comes from events shaped exactly like these.
    private func soloWorkFixtureEvents(runID: String, start: Double) -> [[String: Any]] {
        [
            [
                "event_id": "seed-work-1", "run_id": runID, "seq": 3,
                "occurred_at": start + 12,
                "type": "tool_result", "id": "call-1", "tool": "write_file",
                "summary": "write stock_checker.py (77 lines)",
                "result": "Wrote /tmp/stock_checker.py (2210 chars, 78 lines).",
                "ok": true, "denied": false,
                "file_effects": [["path": "stock_checker.py", "effect": "create"]],
            ],
            [
                "event_id": "seed-work-2", "run_id": runID, "seq": 4,
                "occurred_at": start + 31,
                "type": "tool_result", "id": "call-2", "tool": "bash",
                "summary": "$ python3 -m unittest test_stock_checker.py",
                "result": "[stderr]\nImportError: no module named stock_checker\n\n[exit code 1]",
                "ok": false, "denied": false,
            ],
            [
                "event_id": "seed-work-3", "run_id": runID, "seq": 5,
                "occurred_at": start + 48,
                "type": "tool_result", "id": "call-3", "tool": "multi_edit",
                "summary": "edit stock_checker.py (5 changes)",
                "result": "Edited /tmp/stock_checker.py: applied 5 edit(s).",
                "ok": true, "denied": false,
                "file_effects": [
                    ["path": "stock_checker.py", "effect": "edit"],
                    ["path": "test_stock_checker.py", "effect": "create"],
                ],
            ],
            [
                "event_id": "seed-work-4", "run_id": runID, "seq": 6,
                "occurred_at": start + 96,
                "type": "tool_result", "id": "call-4", "tool": "bash",
                "summary": "$ python3 -m unittest test_stock_checker.py",
                "result": "Ran 4 tests in 0.01s\n\nOK",
                "ok": true, "denied": false,
            ],
        ]
    }

    private func seedUITestRunFixtureIfNeeded() {
        guard let fixture = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_RUN_FIXTURE"],
              [
                "completed", "recoverable", "dispatcher-repair", "dispatch-plan",
                "activity", "orphaned-activity", "swarm-live", "swarm-recoverable",
                "solo-swarm-live", "solo-swarm-completed", "solo-swarm-empty",
                "solo-swarm-work",
              ].contains(fixture)
        else { return }
        let isSoloSwarmFixture = fixture.hasPrefix("solo-swarm-")
        // A Solo turn that did real work by itself: no workers, but files
        // written and commands run. The panel's most common case, and the one
        // that used to render as an empty Activity list and a single model call.
        let soloWithoutWorkers = ["solo-swarm-empty", "solo-swarm-work"].contains(fixture)
        let state: TeamRunState = switch fixture {
        case "completed", "solo-swarm-completed", "solo-swarm-empty", "solo-swarm-work":
            .completed
        case "recoverable", "swarm-recoverable": .interrupted
        case "dispatch-plan": .waitingDispatchApproval
        case "activity", "orphaned-activity": .failed
        case "swarm-live", "solo-swarm-live": .running
        default: .dispatching
        }
        let lastSequence = ["dispatcher-repair", "dispatch-plan"].contains(fixture) ? 1 : 1_200
        let swarmAttempts: [AgentJobAttempt]? = if isSoloSwarmFixture && !soloWithoutWorkers {
            [
                AgentJobAttempt(
                    runID: "seed-run",
                    jobID: "inventory-api",
                    attempt: 1,
                    attemptID: "seed-run:inventory-api:1",
                    agentID: "inventory-api",
                    agentName: "Inventory API reader",
                    role: "researcher",
                    provider: "OpenAI API",
                    model: "gpt-5.6",
                    nodeID: "/root/inventory-api",
                    parentNodeID: "/root",
                    depth: 1,
                    executionEngine: "openai_responses",
                    state: fixture == "solo-swarm-live" ? "running" : "completed",
                    goal: "Verify the inventory API contract",
                    result: fixture == "solo-swarm-live" ? nil : [
                        "output": .string("The endpoint returns stock by store and SKU."),
                        "evidence": .array([.string("InventoryService.swift:42")]),
                        "uncertainties": .array([.string("Rate-limit headers are undocumented.")]),
                        "model_calls": .number(2),
                        "prompt_tokens": .number(180),
                        "completion_tokens": .number(60),
                    ],
                    startedAt: Date().addingTimeInterval(-18).timeIntervalSince1970,
                    completedAt: fixture == "solo-swarm-live"
                        ? nil : Date().addingTimeInterval(-5).timeIntervalSince1970
                ),
            ]
        } else if fixture.hasPrefix("swarm-") {
            [
                AgentJobAttempt(
                    runID: "seed-run",
                    jobID: "inspect",
                    attempt: 1,
                    attemptID: "seed-run:inspect:1",
                    agentID: "seed-dispatcher",
                    agentName: "Research lead",
                    role: "researcher",
                    provider: "OpenAI API",
                    model: "gpt-5.6",
                    nodeID: "inspect",
                    parentNodeID: nil,
                    depth: 0,
                    executionEngine: "locus_managed",
                    state: "completed",
                    goal: "Inspect the stock-checking flow",
                    result: [
                        "output": .string("Located the inventory boundary."),
                        "evidence": .array([.string("InventoryService.swift:42")]),
                        "model_calls": .number(2),
                    ],
                    startedAt: Date().addingTimeInterval(-30).timeIntervalSince1970,
                    completedAt: Date().addingTimeInterval(-20).timeIntervalSince1970
                ),
                AgentJobAttempt(
                    runID: "seed-run",
                    jobID: "inspect.1",
                    attempt: 1,
                    attemptID: "seed-run:inspect.1:1",
                    agentID: "seed-child",
                    agentName: "API specialist",
                    role: "researcher",
                    provider: "OpenAI API",
                    model: "gpt-5.6",
                    nodeID: "inspect.1",
                    parentNodeID: "inspect",
                    depth: 1,
                    executionEngine: "locus_managed",
                    state: fixture == "swarm-live" ? "running" : "stopped",
                    goal: "Verify the inventory API contract",
                    result: fixture == "swarm-live" ? nil : [
                        "error": .string("Branch stopped before it finished."),
                        "model_calls": .number(1),
                    ],
                    startedAt: Date().addingTimeInterval(-12).timeIntervalSince1970,
                    completedAt: fixture == "swarm-live"
                        ? nil : Date().addingTimeInterval(-2).timeIntervalSince1970
                ),
            ]
        } else {
            nil
        }
        let run = OrchestrationRun(
            id: "seed-run",
            sessionID: fixture == "orphaned-activity" ? "deleted-chat" : "seed-current",
            teamID: isSoloSwarmFixture ? nil : "seed-team",
            teamName: isSoloSwarmFixture ? nil : "Codex Team",
            workerID: "seed-worker",
            workspaceRoot: "/tmp",
            executionPath: "/tmp",
            taskID: nil,
            state: state.rawValue,
            request: "Build a Pokémon Center stock checker",
            createdAt: Date().addingTimeInterval(-300).timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            completedAt: state == .completed ? Date().timeIntervalSince1970 : nil,
            lastSequence: lastSequence,
            pinned: false,
            legacy: false,
            recoverable: ["recoverable", "swarm-recoverable"].contains(fixture),
            recoveryReason: ["recoverable", "swarm-recoverable"].contains(fixture)
                ? "Saved checkpoint available" : nil,
            checkpoint: nil,
            attempts: swarmAttempts,
            plan: nil,
            usage: isSoloSwarmFixture ? [
                "model_calls": .number(3),
                "root_prompt_tokens": .number(260),
                "root_completion_tokens": .number(90),
                "worker_prompt_tokens": .number(soloWithoutWorkers ? 0 : 180),
                "worker_completion_tokens": .number(soloWithoutWorkers ? 0 : 60),
                "worker_model_calls": .number(soloWithoutWorkers ? 0 : 2),
                "metered_tokens": .number(22_901),
                "tool_steps": .number(fixture == "solo-swarm-work" ? 4 : 0),
            ] : ["model_calls": .number(12)],
            manifest: isSoloSwarmFixture ? ["solo_swarm": .bool(true)] : nil,
            jobCount: isSoloSwarmFixture ? (swarmAttempts?.count ?? 0) : 4,
            completedJobCount: isSoloSwarmFixture
                ? (fixture == "solo-swarm-completed" ? (swarmAttempts?.count ?? 0) : 0)
                : (fixture == "completed" ? 4 : 2),
            runKind: isSoloSwarmFixture ? "solo" : "team",
            traceID: nil,
            contentPolicy: "metadata",
            executionEnvironment: "local",
            exportState: "pending",
            exportAttempts: 0
        )
        if let requestIndex = blocks.firstIndex(where: { $0.kind == .user }) {
            updateTranscriptBlocks {
                $0[requestIndex].text = run.request
                $0[requestIndex].runID = run.id
            }
        }
        orchestrationRuns = [run]
        selectedOrchestrationRun = run
        orchestrationRunID = run.id
        orchestrationState = state
        if fixture == "swarm-live" || fixture == "solo-swarm-live" { isBusy = true }
        if ["activity", "orphaned-activity", "swarm-live", "solo-swarm-live"].contains(fixture) {
            activity.activityRuns = [run]
        }
        if ["activity", "orphaned-activity"].contains(fixture) {
            return
        }
        var rawEvents: [[String: Any]]
        if isSoloSwarmFixture {
            rawEvents = [
                [
                    "event_id": "seed-event-1",
                    "run_id": run.id,
                    "seq": 1,
                    "type": "run_started",
                    "solo_swarm": true,
                    "state": "running",
                ],
                [
                    "event_id": "seed-event-2",
                    "run_id": run.id,
                    "seq": 2,
                    "type": soloWithoutWorkers ? "turn_done" : "agent_spawned",
                    "node_id": "/root/inventory-api",
                    "parent_node_id": "/root",
                    "depth": 1,
                    // Worker identity belongs only to a run that spawned one;
                    // carrying it on a turn_done made the terminal row describe
                    // a worker that never existed.
                    "agent_name": soloWithoutWorkers ? "" : "Inventory API reader",
                    "goal": soloWithoutWorkers ? "" : "Verify the inventory API contract",
                    "reason": soloWithoutWorkers ? "complete" : "",
                ],
            ]
            if fixture == "solo-swarm-work" {
                rawEvents += soloWorkFixtureEvents(runID: run.id, start: run.createdAt)
            }
        } else if fixture.hasPrefix("swarm-") {
            rawEvents = [[
                "event_id": "seed-event-1",
                "run_id": run.id,
                "seq": 1,
                "type": "agent_spawned",
                "node_id": "inspect.1",
                "parent_node_id": "inspect",
                "depth": 1,
            ]]
        } else if ["dispatcher-repair", "dispatch-plan"].contains(fixture) {
            let dispatcherID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
            let writerID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
            let teamID = UUID(uuidString: "00000000-0000-0000-0000-000000000503")!
            let uiWriterID = UUID(uuidString: "00000000-0000-0000-0000-000000000504")!
            agentProfiles = [
                AgentProfile(
                    id: dispatcherID,
                    name: "Qwen Dispatcher",
                    model: "qwen3:8b",
                    role: .dispatcher
                ),
                AgentProfile(
                    id: writerID,
                    name: "Kimi Backend",
                    model: "qwen3:8b",
                    role: .implementer,
                    accessCeiling: .workspaceWrite
                ),
                AgentProfile(
                    id: uiWriterID,
                    name: "Kimi UI",
                    model: "qwen3:8b",
                    role: .implementer,
                    accessCeiling: .computerControl
                ),
            ]
            agentTeams = [AgentTeam(
                id: teamID,
                name: "Codex Team",
                dispatcherID: dispatcherID,
                fallbackDispatcherID: nil,
                memberIDs: [dispatcherID, writerID, uiWriterID],
                defaultWriterID: writerID
            )]
            selectedAgentTeamID = teamID
            // Header progress is optional in the real app. These fixtures
            // explicitly exercise that control, so opt in deterministically.
            showTeamProgressInHeader = true
            isBusy = true
            if fixture == "dispatcher-repair" {
                dispatcherActivity = AgentActivity(
                    id: "dispatcher-seed-run",
                    agentName: "Qwen Dispatcher",
                    role: AgentRole.dispatcher.rawValue,
                    provider: "vLLM",
                    model: "qwen3:8b",
                    goal: "Creating the team plan",
                    state: .running,
                    output: "Correcting dispatcher plan…",
                    reasoningText: nil,
                    tool: nil,
                    evidence: [],
                    startedAt: Date().addingTimeInterval(-5),
                    elapsedMilliseconds: 0,
                    promptTokens: 0,
                    completionTokens: 0
                )
                dispatcherValidationReason = "dispatcher plan has no jobs"
                rawEvents = [[
                    "event_id": "seed-event-1",
                    "run_id": run.id,
                    "seq": 1,
                    "type": "dispatcher_plan_rejected",
                    "stage": "initial",
                    "message": "Correcting dispatcher plan…",
                    "reason": "dispatcher plan has no jobs",
                    "will_retry": true,
                ]]
            } else {
                dispatcherActivity = AgentActivity(
                    id: "dispatcher-seed-run",
                    agentName: "Qwen Dispatcher",
                    role: AgentRole.dispatcher.rawValue,
                    provider: "vLLM",
                    model: "qwen3:8b",
                    goal: "Creating the team plan",
                    state: .completed,
                    output: "Dispatch plan ready",
                    reasoningText: nil,
                    tool: nil,
                    evidence: [],
                    startedAt: Date().addingTimeInterval(-5),
                    elapsedMilliseconds: 5_000,
                    promptTokens: 1_000,
                    completionTokens: 250
                )
                pendingDispatchPlan = DispatchPlan(
                    summary: "Inspect the checker, implement the fix, and review it.",
                    jobs: [
                        DispatchJob(
                            id: "inspect",
                            agentID: dispatcherID.uuidString,
                            goal: "Inspect the current implementation and constraints",
                            dependencies: [],
                            kind: "specialist"
                        ),
                        DispatchJob(
                            id: "backend",
                            agentID: writerID.uuidString,
                            goal: "Implement and verify the stock-checking backend",
                            dependencies: ["inspect"],
                            kind: "writer"
                        ),
                        DispatchJob(
                            id: "ui",
                            agentID: uiWriterID.uuidString,
                            goal: "Build the UI against the completed backend contract",
                            dependencies: ["backend"],
                            kind: "writer"
                        ),
                    ],
                    budget: OrchestrationBudget(),
                    maximumEstimatedCost: nil
                )
                rawEvents = [[
                    "event_id": "seed-event-1",
                    "run_id": run.id,
                    "seq": 1,
                    "type": "dispatch_plan_ready",
                    "state": "waiting_dispatch_approval",
                ]]
            }
        } else {
            rawEvents = (1...1_200).map { sequence in
                [
                    "event_id": "seed-event-\(sequence)",
                    "run_id": run.id,
                    "seq": sequence,
                    "type": sequence == 1_200 ? "orchestration_completed" : "agent_job_completed",
                    "summary": sequence == 1_200 ? "Team run completed" : "Durable result \(sequence)",
                    "detail": String(repeating: "Verified output. ", count: 12),
                ]
            }
        }
        orchestrationEvents = rawEvents.compactMap {
            decode(OrchestrationEvent.self, from: $0)
        }
        orchestrationEventIDs = Set(orchestrationEvents.map(\.id))
        if !openInspectorTabs.contains(.runs) {
            openInspectorTabs.append(.runs)
        }
        inspectorTab = .runs
        inspectorCollapsed = false
        runsNavigationRequest = RunsNavigationRequest(runID: run.id)
        if fixture == "completed",
           ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_STALE_QUIT_STATE"] == "1"
        {
            taskConversationStates[currentSessionID] = TaskConversationState(
                sessionID: currentSessionID,
                taskID: "seed-task",
                teamID: "seed-team",
                workerID: "seed-worker",
                runID: run.id,
                state: .running,
                updatedAt: Date().addingTimeInterval(-1)
            )
        }
        if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_UNCLEAN_RECOVERY"] == "1" {
            lifecycleRecoveryMessage = fixture == "completed"
                ? "Locus was force quit after the team run completed. Its results were restored."
                : "Locus closed unexpectedly. This team run can be resumed from its saved checkpoint."
        }
    }

    private func writePerformanceFixtureImage(to path: String) {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 320,
            pixelsHigh: 180,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.98, green: 0.24, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 180)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
