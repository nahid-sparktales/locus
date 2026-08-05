import XCTest
@testable import Locus

final class AppModelTests: XCTestCase {
    func testWorkModeInstructionsAreDistinct() {
        XCTAssertEqual(Set(WorkMode.allCases.map(\.instruction)).count, WorkMode.allCases.count)
        XCTAssertTrue(WorkMode.ask.instruction.contains("explicitly attached"))
        XCTAssertTrue(WorkMode.ask.instruction.contains("Do not inspect attachment paths"))
        XCTAssertTrue(WorkMode.plan.instruction.contains("do not modify"))
        XCTAssertTrue(WorkMode.build.instruction.contains("Implement"))
    }

    func testChatAttachmentRepresentsTextAndImageInputs() {
        let text = ChatAttachment(
            url: URL(fileURLWithPath: "/tmp/notes.txt"),
            kind: .text,
            textContent: "A supplied note"
        )
        let image = ChatAttachment(
            url: URL(fileURLWithPath: "/tmp/photo.png"),
            kind: .image,
            imageData: Data([0x89, 0x50, 0x4e, 0x47]),
            mimeType: "image/png"
        )

        XCTAssertTrue(text.isAvailable)
        XCTAssertEqual(text.name, "notes.txt")
        XCTAssertTrue(text.detail.contains("tokens"))
        XCTAssertTrue(image.isAvailable)
        XCTAssertEqual(image.mimeType, "image/png")
    }

    func testContextTokenEstimateUsesReadableMinimum() {
        let file = ContextFile(
            url: URL(fileURLWithPath: "/tmp/example.swift"),
            content: "let answer = 42"
        )
        XCTAssertGreaterThan(file.estimatedTokens, 0)
        XCTAssertEqual(file.name, "example.swift")
    }

    func testContextCheckpointPersistsReferencesWithoutSourceContents() throws {
        let file = ContextFile(
            url: URL(fileURLWithPath: "/tmp/private-source.swift"),
            content: "private let secret = \"never persist this\""
        )

        let data = try JSONEncoder().encode(file)
        let encoded = String(decoding: data, as: UTF8.self)
        let restored = try JSONDecoder().decode(ContextFile.self, from: data)

        XCTAssertFalse(encoded.contains("never persist this"))
        XCTAssertEqual(restored.url, file.url)
        XCTAssertTrue(restored.content.isEmpty)
    }

    func testReconnectBackoffMatchesReliabilitySchedule() {
        XCTAssertEqual((0...6).map(BackendService.reconnectDelay), [1, 2, 4, 8, 15, 15, 15])
    }

    func testHuggingFaceRepositoryURLsAreNormalized() {
        let service = ModelLibraryService()
        XCTAssertEqual(
            service.normalizeRepository("https://huggingface.co/DavidAU/Defiant-GGUF?tab=files"),
            "DavidAU/Defiant-GGUF"
        )
        XCTAssertEqual(
            service.normalizeRepository("hf.co/owner/model/"),
            "owner/model"
        )
    }

    func testGGUFQuantizationAndRecommendationAreRecognized() {
        let file = HuggingFaceModelFile(
            rfilename: "Example-MTP-Q4_K_M.gguf",
            size: 6_979_975_392
        )
        let variant = HuggingFaceVariant(
            quantization: file.quantization ?? "",
            fileName: file.rfilename,
            approximateSize: file.size ?? 0
        )

        XCTAssertEqual(file.quantization, "Q4_K_M")
        XCTAssertTrue(variant.isRecommended)
        XCTAssertFalse(variant.sizeLabel.isEmpty)
    }

    func testMemoryFitClassifiesAgainstTheGivenMachine() {
        let ram32 = UInt64(32) * 1_073_741_824
        // The observed failure: a 22 GB Q4_K_M on a 32 GB Mac loads, but
        // starves the machine and the context window.
        XCTAssertEqual(
            HuggingFaceVariant.fit(bytes: 21_972_752_792, physicalMemory: ram32), .tight
        )
        XCTAssertEqual(
            HuggingFaceVariant.fit(bytes: 7_900_000_000, physicalMemory: ram32), .fits
        )
        XCTAssertEqual(
            HuggingFaceVariant.fit(bytes: 26_000_000_000, physicalMemory: ram32), .exceeds
        )
        XCTAssertEqual(
            HuggingFaceVariant.fit(bytes: 0, physicalMemory: ram32), .fits,
            "an unknown size must not cry wolf"
        )
    }

    func testRecommendedVariantIsRamAwareNotJustQ4KM() {
        let big = HuggingFaceVariant(
            quantization: "Q4_K_M", fileName: "big-Q4_K_M.gguf", approximateSize: 22_000_000_000
        )
        let small = HuggingFaceVariant(
            quantization: "Q3_K_M", fileName: "big-Q3_K_M.gguf", approximateSize: 14_000_000_000
        )
        let ram32 = UInt64(32) * 1_073_741_824

        XCTAssertEqual(
            HuggingFaceVariant.recommendedVariant(in: [big, small], physicalMemory: ram32)?
                .quantization,
            "Q3_K_M",
            "the usual Q4_K_M pick must lose to a quant that actually fits"
        )
        XCTAssertEqual(
            HuggingFaceVariant.recommendedVariant(
                in: [big, small], physicalMemory: UInt64(128) * 1_073_741_824
            )?.quantization,
            "Q4_K_M",
            "with room to spare the quality-priority order stands"
        )
        XCTAssertEqual(
            HuggingFaceVariant.recommendedVariant(
                in: [big], physicalMemory: UInt64(16) * 1_073_741_824
            )?.quantization,
            "Q4_K_M",
            "when nothing fits, the first variant is still offered — warned, not hidden"
        )
    }

    // MARK: - Provider accounts

    /// Adds an account through the real save path, with its key, and cleans up
    /// the keychain entry afterwards.
    @MainActor
    private func seedAccount(
        _ model: AppModel,
        kind: ProviderKind,
        name: String,
        preferredModel: String = "",
        key: String = "sk-test"
    ) -> ProviderAccount {
        let account = ProviderAccount(kind: kind, name: name, preferredModel: preferredModel)
        model.saveProviderAccount(account, apiKey: key)
        addTeardownBlock { CredentialStore.remove(account: account.keychainAccount) }
        return model.providerAccounts.first { $0.id == account.id } ?? account
    }

    @MainActor
    func testSavingAProxyPublishesItBeforeAnythingCanUseIt() {
        let model = AppModel(startImmediately: false)
        XCTAssertNil(ProxyRuntime.shared.current, "a test model starts with no proxy")

        var updated = model.settings
        updated.proxyModeRaw = ProxyMode.manual.rawValue
        updated.proxyHost = "  HTTP://Proxy.Corp:9/  "
        updated.proxyPort = 3128
        model.applySettings(updated)

        // The snapshot is what every session and the relaunched agent read, so
        // it has to be current the moment applySettings returns — not after
        // the restart it kicks off.
        XCTAssertEqual(ProxyRuntime.shared.current?.host, "proxy.corp")
        XCTAssertEqual(ProxyRuntime.shared.current?.port, 3128)
        XCTAssertEqual(model.settings.proxyHost, "  HTTP://Proxy.Corp:9/  ",
                       "normalization is the settings sheet's job, not applySettings'")

        var cleared = model.settings
        cleared.proxyModeRaw = ProxyMode.off.rawValue
        model.applySettings(cleared)
        XCTAssertNil(ProxyRuntime.shared.current, "switching off must not leave a live proxy behind")
    }

    @MainActor
    func testProviderRequestBodyCarriesTheAccountCredentials() {
        let model = AppModel(startImmediately: false)
        let account = seedAccount(
            model,
            kind: .claude,
            name: "Work",
            preferredModel: "claude-sonnet-4-5",
            key: "sk-ant-secret"
        )

        // Local until an account is chosen.
        XCTAssertEqual(model.providerRequestBody()["provider"] as? String, "ollama")
        XCTAssertNil(model.providerRequestBody()["api_key"])

        model.settings.activeAccountID = account.id.uuidString
        let body = model.providerRequestBody()

        XCTAssertEqual(body["provider"] as? String, "remote")
        XCTAssertEqual(body["base_url"] as? String, "https://api.anthropic.com/v1")
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-5")
        XCTAssertEqual(body["api_key"] as? String, "sk-ant-secret")
        XCTAssertEqual(body["auth_style"] as? String, "anthropic")
        XCTAssertEqual(body["account_label"] as? String, "Claude — Work")
    }

    @MainActor
    func testProviderRequestBodySendsTheUsersWindowAndThePublishedOneSeparately() {
        // The regression test for the bug at the layer that caused it. These two
        // facts used to be collapsed into one field, so our own table's figure
        // reached the agent looking like a number the user had pinned — and a
        // stale entry could then outrank what the endpoint reported about itself.
        let model = AppModel(startImmediately: false)
        let account = seedAccount(
            model,
            kind: .claude,
            name: "Work",
            preferredModel: "claude-sonnet-5"
        )
        model.settings.activeAccountID = account.id.uuidString

        var body = model.providerRequestBody()
        XCTAssertEqual(body["context_window"] as? Int, 0, "the user pinned nothing")
        XCTAssertEqual(body["published_context_window"] as? Int, 1_000_000)

        var withWindow = account
        withWindow.contextWindow = 64_000
        model.saveProviderAccount(withWindow, apiKey: nil)
        body = model.providerRequestBody()

        XCTAssertEqual(body["context_window"] as? Int, 64_000)
        XCTAssertEqual(
            body["published_context_window"] as? Int, 1_000_000,
            "both travel: the agent clamps one by the other"
        )
    }

    @MainActor
    func testSwitchingAccountsMidTurnIsHeldUntilTheTurnFinishes() {
        let model = AppModel(startImmediately: false)
        let account = seedAccount(model, kind: .kimi, name: "", preferredModel: "kimi-k2")
        model.isBusy = true

        model.selectModel(account: account, model: "kimi-k2")

        // The agent refuses to swap its client mid-turn, so nothing moves yet.
        XCTAssertNil(model.settings.activeAccountID)
        XCTAssertEqual(model.settings.provider, .ollama)

        model.isBusy = false
        model.applyPendingProviderSwitchIfNeeded()

        XCTAssertEqual(model.settings.activeAccountID, account.id.uuidString)
        XCTAssertEqual(model.settings.provider, .remote)
    }

    @MainActor
    func testChoosingAnAccountWithNoKeyOpensSettingsInsteadOfSwitching() {
        let model = AppModel(startImmediately: false)
        let account = ProviderAccount(kind: .codex, name: "Unconfigured")
        model.saveProviderAccount(account, apiKey: nil)

        model.selectModel(account: account, model: "gpt-5")

        XCTAssertNil(model.settings.activeAccountID, "an account with no key cannot be used")
        XCTAssertTrue(model.settingsPresented)
    }

    @MainActor
    func testRemovingTheActiveAccountFallsBackToLocalOllama() {
        let model = AppModel(startImmediately: false)
        let account = seedAccount(model, kind: .claude, name: "Personal")
        model.settings.activeAccountID = account.id.uuidString
        model.settings.provider = .remote

        model.removeProviderAccount(account)

        XCTAssertFalse(model.providerAccounts.contains { $0.id == account.id })
        XCTAssertNil(model.settings.activeAccountID)
        XCTAssertEqual(model.settings.provider, .ollama)
        XCTAssertNil(CredentialStore.get(account: account.keychainAccount), "the key goes with it")
    }

    @MainActor
    func testTheCurrentRouteDistinguishesAccountsOfferingTheSameModel() {
        let model = AppModel(startImmediately: false)
        let work = seedAccount(model, kind: .claude, name: "Work")
        let personal = seedAccount(model, kind: .claude, name: "Personal")
        model.settings.activeAccountID = work.id.uuidString
        model.sessionInfo = nil
        model.models = [
            ModelInfo(name: "claude-sonnet-4-5", size: 0, parameterSize: "", contextLength: 0)
        ]

        XCTAssertTrue(model.isCurrentRoute(account: work, model: "claude-sonnet-4-5"))
        XCTAssertFalse(model.isCurrentRoute(account: personal, model: "claude-sonnet-4-5"))
        XCTAssertFalse(model.isCurrentRoute(account: nil, model: "claude-sonnet-4-5"))
        XCTAssertEqual(model.modelPickerLabel, "Work · claude-sonnet-4-5")
    }

    @MainActor
    func testDuplicateAccountNamesAreResolvedOnSave() {
        let model = AppModel(startImmediately: false)
        _ = seedAccount(model, kind: .claude, name: "Work")
        let second = seedAccount(model, kind: .claude, name: "Work")

        XCTAssertEqual(model.providerAccounts.count, 2)
        XCTAssertEqual(second.name, "Work 2")
        XCTAssertEqual(Set(model.providerAccounts.map(\.displayName)).count, 2)
    }

    @MainActor
    func testProviderLabelNamesTheAccountInUse() {
        let model = AppModel(startImmediately: false)
        model.modelRuntimePhase = .online
        XCTAssertEqual(model.providerLabel, "Ollama ready")

        let account = seedAccount(model, kind: .claude, name: "Work")
        model.settings.activeAccountID = account.id.uuidString
        XCTAssertEqual(model.providerLabel, "Claude ready")
    }

    @MainActor
    func testSessionFilteringFindsPreviewText() {
        let model = AppModel(startImmediately: false)
        model.sessions = [
            SessionSummary(
                id: "one",
                name: "one.json",
                preview: "Fix authentication redirect",
                mtime: 1,
                size: 10
            ),
            SessionSummary(
                id: "two",
                name: "two.json",
                preview: "Polish onboarding",
                mtime: 2,
                size: 20
            ),
        ]

        model.searchQuery = "auth"
        XCTAssertEqual(model.filteredSessions.map(\.id), ["one"])
    }

    @MainActor
    func testCheckpointCapturesCurrentSessionState() {
        let previousCheckpoints = UserDefaults.standard.data(forKey: "Locus.checkpoints")
        defer {
            if let previousCheckpoints {
                UserDefaults.standard.set(previousCheckpoints, forKey: "Locus.checkpoints")
            } else {
                UserDefaults.standard.removeObject(forKey: "Locus.checkpoints")
            }
        }
        UserDefaults.standard.removeObject(forKey: "Locus.checkpoints")
        let model = AppModel(startImmediately: false)
        model.blocks = [ChatBlock(kind: .user, text: "Make the header calmer")]
        model.todos = [TodoItem(content: "Audit header", status: .pending)]

        model.createCheckpoint(title: "Before header pass")

        XCTAssertEqual(model.checkpoints.first?.title, "Before header pass")
        XCTAssertEqual(model.checkpoints.first?.blocks.count, 1)
        XCTAssertEqual(model.checkpoints.first?.todos.count, 1)
    }

    @MainActor
    func testClearAcknowledgementChangesSessionAndClearsTransientUI() {
        let model = AppModel(startImmediately: false)
        model.blocks = [ChatBlock(kind: .user, text: "old conversation")]
        model.todos = [TodoItem(content: "old task", status: .pending)]

        model.handleEventForTesting([
            "type": "session_started",
            "reason": "clear_chat",
            "session_info": sessionInfo(id: "fresh-session"),
        ])

        XCTAssertEqual(model.currentSessionID, "fresh-session")
        XCTAssertTrue(model.blocks.isEmpty)
        XCTAssertTrue(model.todos.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testRetryAcknowledgementBranchesAtLatestUserMessage() {
        let model = AppModel(startImmediately: false)
        model.blocks = [
            ChatBlock(kind: .user, text: "first"),
            ChatBlock(kind: .assistant, text: "one"),
            ChatBlock(kind: .user, text: "second"),
            ChatBlock(kind: .assistant, text: "two"),
        ]

        model.handleEventForTesting([
            "type": "session_started",
            "reason": "retry",
            "session_info": sessionInfo(id: "retry-branch"),
        ])

        XCTAssertEqual(model.currentSessionID, "retry-branch")
        XCTAssertEqual(model.blocks.map(\.text), ["first", "one", "second"])
        XCTAssertTrue(model.isBusy)
    }

    @MainActor
    func testPromptHistoryNavigatesSubmittedPrompts() {
        let model = AppModel(startImmediately: false)
        model.promptHistory = ["newest", "older"]

        model.previousPrompt()
        XCTAssertEqual(model.draftText, "newest")
        model.previousPrompt()
        XCTAssertEqual(model.draftText, "older")
        model.nextPrompt()
        XCTAssertEqual(model.draftText, "newest")
        model.nextPrompt()
        XCTAssertTrue(model.draftText.isEmpty)
    }

    @MainActor
    func testTwoThousandStreamTokensAreBuffered() async throws {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "message_start"])

        for _ in 0..<2_000 {
            model.handleEventForTesting(["type": "token", "text": "x"])
        }
        XCTAssertEqual(model.streamRevision, 0)

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertLessThanOrEqual(model.streamRevision, 2)
        model.handleEventForTesting(["type": "message_end"])
        XCTAssertEqual(model.blocks.last?.text.count, 2_000)
        XCTAssertLessThanOrEqual(model.streamRevision, 3)
    }

    @MainActor
    func testErrorEventFinalizesStreamingBlock() {
        let model = AppModel(startImmediately: false)
        model.isBusy = true
        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "token", "text": "partial"])
        model.handleEventForTesting(["type": "error", "message": "model crashed"])

        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.blocks.contains(where: \.isStreaming))
        XCTAssertEqual(model.blocks.last?.kind, .error)

        model.handleEventForTesting(["type": "turn_done", "reason": "error"])
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testCommandErrorDoesNotEndTheActiveTurn() {
        let model = AppModel(startImmediately: false)
        model.isBusy = true
        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "token", "text": "still streaming"])

        model.handleEventForTesting([
            "type": "command_error",
            "operation": "set_model",
            "message": "Agent is busy",
        ])

        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.blocks.contains(where: \.isStreaming))
        XCTAssertEqual(model.blocks.last?.kind, .error)
    }

    @MainActor
    func testTurnDoneWithoutMessageEndFinalizesStreamingBlock() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "token", "text": "partial"])
        model.handleEventForTesting(["type": "turn_done"])

        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.blocks.contains(where: \.isStreaming))
        XCTAssertEqual(model.blocks.last?.text, "partial")
    }

    @MainActor
    func testTokensWithoutMessageStartCreateAssistantBlock() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "token", "text": "orphan"])
        model.handleEventForTesting(["type": "turn_done"])

        XCTAssertEqual(model.blocks.last?.kind, .assistant)
        XCTAssertEqual(model.blocks.last?.text, "orphan")
    }

    @MainActor
    func testSendWhileBusyQueuesInsteadOfDropping() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online
        model.isBusy = true

        model.send("follow-up request")

        XCTAssertEqual(model.queuedMessages, ["follow-up request"])
        model.removeQueuedMessage(at: 0)
        XCTAssertTrue(model.queuedMessages.isEmpty)
    }

    @MainActor
    func testQueueDrainsAfterTurnDone() async throws {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online
        model.isBusy = true
        model.send("queued message")
        XCTAssertEqual(model.queuedMessages.count, 1)

        model.draftText = "typed while waiting"
        model.handleEventForTesting(["type": "turn_done"])
        try await Task.sleep(for: .milliseconds(200))

        // With no live socket the drained message returns to the queue —
        // writing it into the draft would destroy what the user typed since.
        XCTAssertEqual(model.queuedMessages, ["queued message"])
        XCTAssertEqual(model.draftText, "typed while waiting")
    }

    @MainActor
    func testHistoryRecallPreservesUnsentDraft() {
        let model = AppModel(startImmediately: false)
        model.promptHistory = ["older prompt"]
        model.draftText = "work in progress"

        model.previousPrompt()
        XCTAssertEqual(model.draftText, "older prompt")
        XCTAssertTrue(model.isBrowsingPromptHistory)

        model.nextPrompt()
        XCTAssertEqual(model.draftText, "work in progress")
        XCTAssertFalse(model.isBrowsingPromptHistory)
    }

    @MainActor
    func testHistoryCursorResetsWhenDraftEdited() {
        let model = AppModel(startImmediately: false)
        model.promptHistory = ["first", "second"]

        model.previousPrompt()
        XCTAssertEqual(model.draftText, "first")
        model.draftText = "first edited"
        XCTAssertFalse(model.isBrowsingPromptHistory)

        model.previousPrompt()
        XCTAssertEqual(model.draftText, "first")
    }

    @MainActor
    func testLocalSlashCommandExecutesWithoutSending() {
        let model = AppModel(startImmediately: false)
        model.draftText = "/plan"

        model.send("/plan")

        XCTAssertEqual(model.selectedMode, .plan)
        XCTAssertTrue(model.blocks.isEmpty)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.draftText.isEmpty)
    }

    @MainActor
    func testPermissionRequestWithoutProposalStillShowsCard() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "permission_request",
            "id": "tool-1",
            "tool": "write_file",
            "request_id": "req-9",
        ])

        XCTAssertTrue(model.hasPendingPermission)
        XCTAssertEqual(model.blocks.last?.tool?.requestID, "req-9")
        XCTAssertEqual(model.activePermissionRequest?.requestID, "req-9")
    }

    @MainActor
    func testPermissionRequestWithoutRequestIDDoesNotLockTheUI() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "permission_request",
            "id": "tool-x",
            "tool": "bash",
        ])

        XCTAssertFalse(
            model.hasPendingPermission,
            "an unanswerable request must not arm the state that disables send and clear"
        )
        XCTAssertNil(model.activePermissionRequest)
        XCTAssertEqual(model.blocks.last?.kind, .error)
    }

    @MainActor
    func testPermissionRequestAttachesToTheNewestMatchingCard() {
        let model = AppModel(startImmediately: false)
        for _ in 0..<2 {
            model.handleEventForTesting([
                "type": "tool_call_proposed",
                "id": "t-dup",
                "tool": "bash",
                "summary": "$ ls",
                "auto": true,
            ])
        }

        model.handleEventForTesting([
            "type": "permission_request",
            "id": "t-dup",
            "tool": "bash",
            "request_id": "req-2",
        ])

        XCTAssertNil(model.blocks[0].tool?.requestID)
        XCTAssertEqual(model.blocks[1].tool?.requestID, "req-2")
    }

    @MainActor
    func testPermissionRequestUpgradeScrollsTheConversation() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "tool_call_proposed",
            "id": "t-1",
            "tool": "bash",
            "summary": "$ make",
            "auto": false,
        ])
        let revisionBefore = model.streamRevision

        model.handleEventForTesting([
            "type": "permission_request",
            "id": "t-1",
            "tool": "bash",
            "request_id": "req-1",
        ])

        XCTAssertGreaterThan(
            model.streamRevision, revisionBefore,
            "an in-place upgrade must still trigger the auto-scroll"
        )
    }

    @MainActor
    func testPermissionRequestReadsNestedPreviewFallback() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "permission_request",
            "id": "tool-p",
            "tool": "bash",
            "request_id": "req-p",
            "preview": ["summary": "$ ls", "detail": "ls -la"],
        ])

        XCTAssertEqual(model.blocks.last?.tool?.summary, "$ ls")
        XCTAssertEqual(model.blocks.last?.tool?.detail, "ls -la")
    }

    @MainActor
    func testActivePermissionRequestAdvancesOldestFirst() {
        let model = AppModel(startImmediately: false)
        model.blocks = [
            ChatBlock(kind: .tool, tool: ToolPayload(
                toolID: "t1", tool: "bash", summary: "$ a", detail: "",
                status: .awaitingPermission, requestID: "req-1"
            )),
            ChatBlock(kind: .tool, tool: ToolPayload(
                toolID: "t2", tool: "bash", summary: "$ b", detail: "",
                status: .awaitingPermission, requestID: "req-2"
            )),
        ]

        XCTAssertEqual(model.activePermissionRequest?.requestID, "req-1")

        model.blocks[0].tool?.status = .running
        XCTAssertEqual(model.activePermissionRequest?.requestID, "req-2")

        model.blocks[1].tool?.status = .denied
        XCTAssertNil(model.activePermissionRequest)
    }

    @MainActor
    func testClearChatConfirmedRefusesWhilePermissionPending() {
        let model = AppModel(startImmediately: false)
        model.blocks = [ChatBlock(kind: .user, text: "hello")]
        model.handleEventForTesting([
            "type": "permission_request",
            "id": "tool-1",
            "tool": "bash",
            "request_id": "req-1",
        ])

        model.clearChatConfirmed()

        XCTAssertTrue(model.hasPendingPermission)
        XCTAssertEqual(model.blocks.first?.text, "hello", "the transcript must survive")
        XCTAssertNotNil(model.toastMessage)
    }

    @MainActor
    func testTurnDoneResolvesDanglingPermissionCards() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "permission_request",
            "id": "tool-1",
            "tool": "bash",
            "request_id": "req-1",
        ])
        XCTAssertTrue(model.hasPendingPermission)

        model.handleEventForTesting(["type": "turn_done"])

        XCTAssertFalse(model.hasPendingPermission, "no card may stay awaiting after the turn ends")
        XCTAssertEqual(model.blocks.last?.tool?.status, .error)
    }

    @MainActor
    func testTodoUpdateBadgesTheTabInsteadOfSwitchingToIt() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.terminal)

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])

        XCTAssertEqual(model.inspectorTab, .terminal, "a run must not yank the panel")
        XCTAssertTrue(model.planHasUnseenUpdate)

        model.selectInspectorTab(.plan)
        XCTAssertFalse(model.planHasUnseenUpdate, "opening the tab clears the badge")
    }

    func testChangesBadgeOnlyLightsForPathsTheUserHasNotSeen() {
        let seen = GitChange(path: "Locus/AppModel.swift", status: .modified)
        let fresh = GitChange(path: "README.md", status: .modified)

        XCTAssertFalse(
            AppModel.changesAreUnseen(
                previous: ["Locus/AppModel.swift"],
                current: [seen, fresh],
                changesTabVisible: true
            ),
            "nothing is unseen while the user is looking straight at it"
        )
        XCTAssertTrue(
            AppModel.changesAreUnseen(
                previous: ["Locus/AppModel.swift"],
                current: [seen, fresh],
                changesTabVisible: false
            )
        )
        XCTAssertFalse(
            AppModel.changesAreUnseen(
                previous: ["Locus/AppModel.swift"],
                current: [seen],
                changesTabVisible: false
            ),
            "re-editing a file you already know about must not re-badge"
        )
    }

    @MainActor
    func testProposedToolNoLongerHijacksTheInspector() {
        let model = AppModel(startImmediately: false)
        model.selectInspectorTab(.files)

        model.handleEventForTesting([
            "type": "tool_call_proposed",
            "id": "t1",
            "tool": "write_file",
            "summary": "write a.txt",
            "auto": true,
        ])

        XCTAssertEqual(model.inspectorTab, .files)
    }

    @MainActor
    func testSelectingATabExpandsACollapsedInspector() {
        let model = AppModel(startImmediately: false)
        model.inspectorCollapsed = true

        model.selectInspectorTab(.changes)

        XCTAssertFalse(model.inspectorCollapsed)
        XCTAssertEqual(model.inspectorTab, .changes)
        XCTAssertEqual(model.settings.inspectorLastTab, "changes")
    }

    @MainActor
    func testInspectorWidthPersistsOnlyWhenCommitted() {
        let model = AppModel(startImmediately: false)
        let original = model.settings.inspectorWidth

        model.setInspectorWidth(700)
        XCTAssertEqual(model.inspectorWidth, 520, "clamped to the maximum")
        XCTAssertEqual(model.settings.inspectorWidth, original, "a drag must not persist per frame")

        model.commitInspectorWidth()
        XCTAssertEqual(model.settings.inspectorWidth, 520)
    }

    @MainActor
    func testBackendNoteEventsBecomeVisibleBlocks() {
        let model = AppModel(startImmediately: false)

        model.handleEventForTesting([
            "type": "note",
            "text": "Context is nearly full — compacting the conversation.",
        ])
        model.handleEventForTesting(["type": "note", "text": "went wrong", "error": true])
        model.handleEventForTesting(["type": "note", "text": "   "])

        XCTAssertEqual(model.blocks.count, 2, "blank notes must not create blocks")
        XCTAssertEqual(model.blocks.first?.kind, .note)
        XCTAssertEqual(model.blocks.last?.kind, .error)
    }

    @MainActor
    func testThinkingEventDoesNotDisturbTheTranscript() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "thinking", "text": "weighing options"])
        model.handleEventForTesting(["type": "token", "text": "answer"])
        model.handleEventForTesting(["type": "message_end"])

        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.blocks.first?.text, "answer")
    }

    @MainActor
    func testPreviewURLRequiresARealHost() {
        let model = AppModel(startImmediately: false)
        model.settings.previewURL = ""
        XCTAssertNil(model.normalizedPreviewURL)
        model.settings.previewURL = "localhost:3000"
        XCTAssertEqual(model.normalizedPreviewURL?.host, "localhost")
    }

    func testSessionPreviewStripsPromptDecoration() {
        XCTAssertEqual(
            SessionSummary.cleanPreview(
                "[Locus mode: Build]\nImplement the request.\n\nUser request:\nFix the login flow"
            ),
            "Fix the login flow"
        )
        XCTAssertEqual(SessionSummary.cleanPreview("Plain preview"), "Plain preview")
        XCTAssertEqual(SessionSummary.cleanPreview("[Locus mode: Build]\nImplement the requ"), "")
    }

    @MainActor
    func testPinnedSessionsSortFirst() {
        let model = AppModel(startImmediately: false)
        model.sessions = [
            SessionSummary(id: "new", name: "n", preview: "p", mtime: 100, size: 1),
            SessionSummary(id: "pinned-old", name: "n", preview: "p", mtime: 1, size: 1, pinned: true),
        ]
        XCTAssertEqual(model.filteredSessions.map(\.id), ["pinned-old", "new"])
    }

    // MARK: - Correctness fixes

    @MainActor
    func testCompactCommandDoesNotRecurse() {
        // /compact used to be re-sent through send(), which re-matched the
        // slash command and recursed until the stack overflowed.
        let model = AppModel(startImmediately: false)
        model.send("/compact")

        XCTAssertTrue(model.blocks.isEmpty, "not connected, so nothing was sent")
        XCTAssertFalse(model.isBusy)
        XCTAssertNotNil(model.toastMessage)
    }

    @MainActor
    func testStopWithoutConnectionKeepsBusyStateForRecovery() {
        let model = AppModel(startImmediately: false)
        model.isBusy = true

        model.stop()

        XCTAssertTrue(
            model.isBusy,
            "an undeliverable interrupt leaves cleanup to recoverFromLostConnection"
        )
        XCTAssertNotNil(model.toastMessage)
    }

    @MainActor
    func testOrphanToolResultBecomesAVisibleCard() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting([
            "type": "tool_result",
            "id": "never-proposed",
            "ok": true,
            "result": "42 files checked",
        ])

        XCTAssertEqual(model.blocks.last?.tool?.status, .done)
        XCTAssertEqual(model.blocks.last?.tool?.result, "42 files checked")
    }

    @MainActor
    func testGitRefreshFailureKeepsTheLastKnownChanges() throws {
        let model = AppModel(startImmediately: false)
        let response = try JSONDecoder().decode(
            GitStatusResponse.self,
            from: Data(#"{"is_repo": true, "branch": "main", "files": [{"path": "a.swift"}]}"#.utf8)
        )
        model.applyGitStatus(response)
        XCTAssertEqual(model.gitChanges.map(\.path), ["a.swift"])
        XCTAssertFalse(model.lastGitRefreshFailed)

        model.applyGitStatusFailure()
        XCTAssertEqual(model.gitChanges.map(\.path), ["a.swift"], "a transient failure must not wipe the list")
        XCTAssertTrue(model.lastGitRefreshFailed)

        model.applyGitStatus(response)
        XCTAssertFalse(model.lastGitRefreshFailed, "a successful refresh clears the stale flag")
    }

    func testRemoteEndpointBaseURLNormalization() {
        XCTAssertEqual(
            RemoteEndpointTester.normalizeBaseURL("https://x.aws.endpoints.huggingface.cloud"),
            "https://x.aws.endpoints.huggingface.cloud/v1"
        )
        XCTAssertEqual(RemoteEndpointTester.normalizeBaseURL("example.com/v1/"), "https://example.com/v1")
        XCTAssertEqual(
            RemoteEndpointTester.normalizeBaseURL("https://example.com/v1/chat/completions"),
            "https://example.com/v1"
        )
        XCTAssertEqual(
            RemoteEndpointTester.normalizeBaseURL("https://api.anthropic.com/v1/messages"),
            "https://api.anthropic.com/v1"
        )
        XCTAssertEqual(RemoteEndpointTester.normalizeBaseURL("   "), "")
    }

    func testProviderCredentialsRequireHTTPSExceptOnLoopback() {
        XCTAssertNotNil(
            RemoteEndpointTester.securityError(
                baseURL: "http://provider.example/v1",
                apiKey: "secret"
            )
        )
        XCTAssertNil(
            RemoteEndpointTester.securityError(
                baseURL: "http://127.0.0.1:8000/v1",
                apiKey: "secret"
            )
        )
        XCTAssertNotNil(
            RemoteEndpointTester.securityError(
                baseURL: "http://127.attacker.example/v1",
                apiKey: "secret"
            )
        )
        XCTAssertNil(
            RemoteEndpointTester.securityError(
                baseURL: "https://provider.example/v1",
                apiKey: "secret"
            )
        )
        XCTAssertNotNil(
            RemoteEndpointTester.securityError(
                baseURL: "https://name:secret@provider.example/v1",
                apiKey: ""
            )
        )
    }

    func testLocalBackendCapabilityIsFreshAndHeaderSafe() {
        XCTAssertEqual(BackendSecurity.header, "X-Locus-Token")
        XCTAssertEqual(BackendSecurity.launchToken.count, 32)
        XCTAssertNil(BackendSecurity.launchToken.range(of: "[^A-Fa-f0-9]", options: .regularExpression))
    }

    func testQueryValuesEncodeCharactersStarletteWouldMangle() {
        XCTAssertEqual(BackendService.encodeQueryValue("a&b+c=d?e"), "a%26b%2Bc%3Dd%3Fe")
        XCTAssertEqual(BackendService.encodeQueryValue("Sub dir/héllo.swift"), "Sub%20dir/h%C3%A9llo.swift")
        XCTAssertEqual(BackendService.encodeQueryValue("plain.swift"), "plain.swift")
    }

    @MainActor
    func testTerminalRecoversWhenTheConnectionDrops() {
        let session = TerminalSession()
        session.handle(["type": "terminal_started", "run_id": "run-1"])
        XCTAssertTrue(session.isRunning)

        session.connectionLost()

        XCTAssertFalse(session.isRunning, "no exit event is coming after a drop")
        XCTAssertEqual(session.lines.last?.kind, .status)

        session.connectionLost()
        XCTAssertEqual(
            session.lines.filter { $0.kind == .status }.count, 1,
            "a second drop with nothing running must not repeat the notice"
        )
    }

    // MARK: - Git quick actions

    func testGitClientRoundTripsARealRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "locus-gitclient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GitClient(workspaceRoot: root.path)

        try await client.run(["init", "-q"])
        try await client.run(["config", "user.email", "tests@example.invalid"])
        try await client.run(["config", "user.name", "Locus Tests"])
        // A hostile-ish filename: the space and ampersand exercise the
        // literal-pathspec handling end to end.
        try "hello\n".write(
            to: root.appending(path: "a & b.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await client.run(["add", "--", "a & b.txt"])
        let staged = try await client.run(["status", "--porcelain"])
        XCTAssertTrue(staged.stdout.contains("a & b.txt"), "unexpected status: \(staged.stdout)")

        try await client.run(["commit", "-q", "-m", "Add a & b"])
        let clean = try await client.run(["status", "--porcelain"])
        XCTAssertTrue(clean.stdout.isEmpty)
    }

    func testGitClientThrowsStderrForFailedCommands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "locus-gitclient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = GitClient(workspaceRoot: root.path)

        do {
            try await client.run(["status"])  // not a repository
            XCTFail("expected a failure outside a repository")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("not a git repository"))
        }
    }

    func testCommitDraftSanitizerStripsReasoningAndFences() {
        let raw = "<think>weighing the diff</think>\n```\nFix the login redirect\n```"
        XCTAssertEqual(CommitMessageDrafter.sanitize(raw), "Fix the login redirect")
        XCTAssertNil(CommitMessageDrafter.sanitize("<think>only thoughts</think>"))
        XCTAssertEqual(CommitMessageDrafter.sanitize("\"Quoted subject\""), "Quoted subject")

        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(CommitMessageDrafter.sanitize(long)?.count, 72, "the subject line is capped")
    }

    func testCommitTemplateSummarizesStagedChanges() {
        XCTAssertEqual(CommitMessageDrafter.template(for: []), "")

        let single = [GitChange(path: "Locus/AppModel.swift", status: .modified, staged: true)]
        XCTAssertEqual(CommitMessageDrafter.template(for: single), "Update AppModel.swift")

        let multiple = [
            GitChange(path: "a.swift", status: .modified, staged: true, additions: 3, deletions: 1),
            GitChange(path: "b.swift", status: .modified, staged: true, additions: 2, deletions: 0),
        ]
        let message = CommitMessageDrafter.template(for: multiple)
        XCTAssertTrue(message.hasPrefix("Update 2 files (+5 −1)"), "got: \(message)")
        XCTAssertTrue(message.contains("- a.swift"))
    }

    // MARK: - Transcript search

    @MainActor
    func testTranscriptSearchMatchesBlocksCaseInsensitivelyAndSkipsTools() {
        let model = AppModel(startImmediately: false)
        let userID = UUID()
        let assistantID = UUID()
        model.blocks = [
            ChatBlock(id: userID, kind: .user, text: "Fix the Login flow"),
            ChatBlock(id: assistantID, kind: .assistant, text: "The login bug is in AuthService."),
            ChatBlock(kind: .tool, tool: ToolPayload(
                toolID: "t1", tool: "bash", summary: "$ grep -r login", detail: "",
                status: .done
            )),
        ]
        model.transcriptSearchPresented = true
        model.transcriptSearchQuery = "LOGIN"

        XCTAssertEqual(model.transcriptSearchMatches, [userID, assistantID])
        XCTAssertEqual(model.currentTranscriptMatch, userID)
        XCTAssertEqual(model.transcriptMatchStyle(for: userID), .current)
        XCTAssertEqual(model.transcriptMatchStyle(for: assistantID), .other)
    }

    @MainActor
    func testTranscriptSearchWrapsInBothDirections() {
        let model = AppModel(startImmediately: false)
        model.blocks = [
            ChatBlock(kind: .user, text: "alpha"),
            ChatBlock(kind: .assistant, text: "alpha again"),
        ]
        model.transcriptSearchPresented = true
        model.transcriptSearchQuery = "alpha"

        model.advanceTranscriptSearch(1)
        XCTAssertEqual(model.transcriptSearchSelection, 1)
        model.advanceTranscriptSearch(1)
        XCTAssertEqual(model.transcriptSearchSelection, 0, "forward wraps to the first match")
        model.advanceTranscriptSearch(-1)
        XCTAssertEqual(model.transcriptSearchSelection, 1, "backward wraps to the last match")
    }

    @MainActor
    func testTranscriptSearchSelectionSurvivesShrinkingResults() {
        let model = AppModel(startImmediately: false)
        model.blocks = [
            ChatBlock(kind: .user, text: "match one"),
            ChatBlock(kind: .assistant, text: "match two"),
        ]
        model.transcriptSearchPresented = true
        model.transcriptSearchQuery = "match"
        model.advanceTranscriptSearch(1)

        // The transcript was cleared out from under an active search.
        model.blocks = [ChatBlock(kind: .user, text: "match one")]

        XCTAssertNotNil(model.currentTranscriptMatch, "a stale selection must clamp, not crash")
        model.advanceTranscriptSearch(1)
        XCTAssertEqual(model.transcriptSearchSelection, 0)

        model.closeTranscriptSearch()
        XCTAssertTrue(model.transcriptSearchQuery.isEmpty)
        XCTAssertNil(model.transcriptMatchStyle(for: model.blocks[0].id))
    }

    // MARK: - Thinking visibility

    func testThinkingSegmentsAreFilteredOnlyInHiddenMode() {
        let text = "<think>weighing options</think>The answer is 42."
        let hidden = AssistantSegment.rendered(from: text, mode: .hidden)
        XCTAssertEqual(hidden, [.visible("The answer is 42.")])

        for mode in [ThinkingVisibility.collapsed, .expanded] {
            XCTAssertEqual(
                AssistantSegment.rendered(from: text, mode: mode),
                AssistantSegment.parse(text),
                "only Hidden changes what renders — \(mode.rawValue) is presentation"
            )
        }
    }

    @MainActor
    func testThinkingSlashCommandSetsAndPersistsTheMode() {
        let model = AppModel(startImmediately: false)
        // Not asserted from a fresh model: AppModel(startImmediately: false)
        // still loads the machine's real stored settings, so the initial mode
        // is whatever the developer last used. Pin a baseline instead.
        model.thinkingVisibility = .collapsed
        XCTAssertEqual(model.thinkingVisibility, .collapsed)

        model.send("/thinking expanded")

        XCTAssertEqual(model.thinkingVisibility, .expanded)
        XCTAssertEqual(model.settings.thinkingVisibilityRaw, "expanded")
        XCTAssertTrue(model.blocks.isEmpty, "a local command must not send anything")

        model.send("/thinking sideways")
        XCTAssertEqual(model.thinkingVisibility, .expanded, "an unknown mode changes nothing")

        model.send("/thinking")
        XCTAssertEqual(model.blocks.last?.kind, .note, "no argument lists the modes")
    }

    func testUnknownStoredThinkingVisibilityFallsBackToCollapsed() throws {
        let future = #"{"thinkingVisibilityRaw": "telepathic"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(future.utf8))
        XCTAssertEqual(restored.resolvedThinkingVisibility, .collapsed)
    }

    // MARK: - Context window

    @MainActor
    func testContextWindowPrefersBackendContextLimit() {
        let model = AppModel(startImmediately: false)
        model.models = [
            ModelInfo(name: "qwen3:8b", size: 1, parameterSize: "8B", contextLength: 8_192),
        ]

        var event = sessionInfo(id: "ctx")
        event["type"] = "session_info"
        event["context_limit"] = 40_960
        model.handleEventForTesting(event)

        XCTAssertEqual(model.contextWindowTokens, 40_960, "the backend's limit is authoritative")
    }

    @MainActor
    func testContextWindowFallsBackToModelListThenUnknown() {
        let model = AppModel(startImmediately: false)
        var event = sessionInfo(id: "ctx")
        event["type"] = "session_info"
        model.handleEventForTesting(event)

        model.models = [
            ModelInfo(name: "qwen3:8b", size: 1, parameterSize: "8B", contextLength: 8_192),
        ]
        XCTAssertEqual(model.contextWindowTokens, 8_192)

        model.models = []
        XCTAssertNil(model.contextWindowTokens, "no invented 32k window")
        XCTAssertNil(model.contextWindowUsageFraction)
        XCTAssertEqual(
            model.contextBudgetTokens,
            Int(Double(AppModel.assumedContextWindowTokens) * 0.60),
            "the pack budget still needs a cap when the window is unknown"
        )
    }

    @MainActor
    func testContextUsageDoesNotDoubleCountTheContextPack() {
        let model = AppModel(startImmediately: false)
        var event = sessionInfo(id: "ctx")
        event["type"] = "session_info"
        event["approx_tokens"] = 1_000
        event["context_limit"] = 10_000
        model.handleEventForTesting(event)
        model.contextFiles = [
            ContextFile(
                url: URL(fileURLWithPath: "/tmp/pack.swift"),
                content: String(repeating: "x", count: 4_000)
            ),
        ]

        // The pack is embedded into user messages, so the backend's
        // approx_tokens already contains it — adding it again over-reads.
        XCTAssertEqual(model.contextUsedTokens, 1_000)
        XCTAssertEqual(model.contextWindowUsageFraction, 0.1)
    }

    @MainActor
    func testStreamingMovesTheContextMeterAndTurnDoneResetsIt() {
        let model = AppModel(startImmediately: false)
        var event = sessionInfo(id: "ctx")
        event["type"] = "session_info"
        event["approx_tokens"] = 1_000
        event["context_limit"] = 10_000
        model.handleEventForTesting(event)

        model.handleEventForTesting(["type": "message_start"])
        model.handleEventForTesting(["type": "token", "text": String(repeating: "y", count: 400)])
        model.handleEventForTesting(["type": "message_end"])

        XCTAssertEqual(model.contextUsedTokens, 1_100, "the streamed reply is estimated at chars/4")

        model.handleEventForTesting(["type": "turn_done"])
        XCTAssertEqual(model.contextUsedTokens, 1_000, "the real count takes over at the boundary")
    }

    @MainActor
    func testSessionInfoWithMissingFieldsStillDecodes() {
        let model = AppModel(startImmediately: false)
        model.handleEventForTesting(["type": "session_info", "session_id": "partial"])

        XCTAssertNotNil(model.sessionInfo, "one missing field must not silently disable the app")
        XCTAssertEqual(model.currentSessionID, "partial")
        XCTAssertEqual(model.sessionInfo?.contextLimit, 0)
    }

    func testModelInfoDecodesWithoutOptionalMetadata() throws {
        let data = Data(#"{"name": "hf.co/owner/repo:Q4_K_M"}"#.utf8)
        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        XCTAssertEqual(info.name, "hf.co/owner/repo:Q4_K_M")
        XCTAssertEqual(info.contextLength, 0)
        XCTAssertEqual(info.trainedContextLength, 0)
    }

    func testModelPickerDetailComparesModelsByTrainedWindow() throws {
        // The agent reports the window in use (0 for a model that is not
        // loaded) separately from the trained maximum. The picker compares
        // models, so it shows the trained one; an older agent only sends
        // context_length, which fills in.
        let data = Data(#"""
        {"name": "qwen3:8b", "parameter_size": "8B",
         "context_length": 0, "trained_context_length": 262144}
        """#.utf8)
        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        XCTAssertEqual(info.detail, "8B · 256k ctx")

        let legacy = ModelInfo(name: "old", size: 1, parameterSize: "3B", contextLength: 32_768)
        XCTAssertEqual(legacy.detail, "3B · 32k ctx")
    }

    func testHistoryMessageToleratesNullContent() throws {
        let data = Data(#"[{"role": "tool", "content": null, "name": "bash"}]"#.utf8)
        let messages = try JSONDecoder().decode([HistoryMessage].self, from: data)
        XCTAssertEqual(messages.first?.content, "")
        XCTAssertEqual(messages.first?.role, "tool")
    }

    // MARK: - Plan approval

    @MainActor
    func testJustChatToggleReturnsToThePreviousAgenticMode() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.selectInspectorTab(.files)
        XCTAssertFalse(model.inspectorCollapsed)

        model.setJustChatEnabled(true)
        XCTAssertTrue(model.justChatEnabled)
        XCTAssertEqual(model.selectedMode, .ask)
        XCTAssertTrue(model.inspectorCollapsed, "Just Chat closes the workspace inspector")

        model.selectInspectorTab(.changes)
        XCTAssertEqual(model.inspectorTab, .files, "inspector shortcuts stay inert in Just Chat")
        XCTAssertTrue(model.inspectorCollapsed)

        model.setJustChatEnabled(false)
        XCTAssertFalse(model.justChatEnabled)
        XCTAssertEqual(model.selectedMode, .plan)
        XCTAssertFalse(model.inspectorCollapsed, "leaving Just Chat restores the previously open inspector")
        XCTAssertEqual(model.inspectorTab, .files)
    }

    @MainActor
    func testJustChatKeepsInspectorClosedWhenItWasAlreadyClosed() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .build
        model.inspectorCollapsed = true

        model.setJustChatEnabled(true)
        XCTAssertTrue(model.inspectorCollapsed)

        model.setJustChatEnabled(false)
        XCTAssertEqual(model.selectedMode, .build)
        XCTAssertTrue(model.inspectorCollapsed, "leaving Just Chat preserves a previously closed inspector")
    }

    @MainActor
    func testCompletedBuildTurnAddsTimingMarkerAndFinishesTheActivePlanStep() {
        let model = AppModel(startImmediately: false)
        model.turnDispatchedMode = .build
        model.todos = [
            TodoItem(content: "Inspect the sidebar", status: .completed),
            TodoItem(content: "Add the completion cue", status: .inProgress),
            TodoItem(content: "Optional follow-up", status: .pending),
        ]

        model.handleEventForTesting([
            "type": "turn_done",
            "reason": "complete",
            "duration_ms": 84_000,
        ])

        XCTAssertEqual(model.todos.map(\.status), [.completed, .completed, .pending])
        let completion = model.blocks.last?.completion
        XCTAssertEqual(completion?.title, "Task finished")
        XCTAssertEqual(completion?.durationText, "1m 24s")
        XCTAssertEqual(completion?.outcome, .complete)
    }

    @MainActor
    func testInterruptedBuildTurnDoesNotClaimTheActivePlanStepFinished() {
        let model = AppModel(startImmediately: false)
        model.turnDispatchedMode = .build
        model.todos = [TodoItem(content: "Verify the app", status: .inProgress)]

        model.handleEventForTesting([
            "type": "turn_done",
            "reason": "interrupted",
            "duration_ms": 2_400,
        ])

        XCTAssertEqual(model.todos.first?.status, .inProgress)
        XCTAssertEqual(model.blocks.last?.completion?.title, "Stopped")
    }

    @MainActor
    func testCompletedPlanTurnOffersToImplementThePlan() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        XCTAssertTrue(model.planApprovalPending, "a finished plan is a decision point")
    }

    @MainActor
    func testStalePlanDoesNotReOfferAfterAChatTurn() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.todos = [TodoItem(content: "Left over from an earlier run", status: .pending)]

        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertFalse(model.planApprovalPending, "only turns that wrote the plan may offer it")
    }

    @MainActor
    func testBuildTurnDoesNotOfferApprovalEvenAfterAMidRunSwitchToPlan() {
        let model = AppModel(startImmediately: false)
        // What send() latches when a turn is dispatched in Build mode.
        model.selectedMode = .build
        model.turnDispatchedInPlanMode = false

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Implement the header", "status": "in_progress"]],
        ])
        // Flipping the picker to Plan while the Build run streams must not
        // turn its todo bookkeeping into an "implement this plan?" offer.
        model.selectedMode = .plan
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertFalse(model.planApprovalPending, "the offer keys off the dispatch mode, not the picker")
    }

    @MainActor
    func testPlanModeDispatchLatchesTheTurnMode() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online

        model.selectedMode = .plan
        model.send("Sketch the work")
        XCTAssertTrue(model.turnDispatchedInPlanMode)
    }

    @MainActor
    func testForwardedSlashTurnIsNeverAPlanDispatch() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online
        model.selectedMode = .plan

        model.send("/init")

        XCTAssertFalse(
            model.turnDispatchedInPlanMode,
            "agent-side slash commands are housekeeping, not plans to offer"
        )
    }

    @MainActor
    func testInterruptedPlanTurnDoesNotOfferApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done", "reason": "interrupted"])

        XCTAssertFalse(model.planApprovalPending, "a stopped run was already a decision")
    }

    @MainActor
    func testMaxIterationsPlanTurnDoesNotOfferApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done", "reason": "max_iterations"])

        XCTAssertFalse(model.planApprovalPending, "an exhausted turn's plan is unfinished")
    }

    @MainActor
    func testTurnDoneWithoutAReasonStillOffersApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done"])

        XCTAssertTrue(model.planApprovalPending, "an agent that omits the reason completed normally")
    }

    @MainActor
    func testPlanEmptiedMidTurnDoesNotOfferApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "todo_update", "todos": [[String: Any]]()])
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertFalse(model.planApprovalPending, "there is no zero-step plan to implement")
    }

    @MainActor
    func testEmptyTodoUpdateWithdrawsAPendingOffer() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        model.handleEventForTesting(["type": "todo_update", "todos": [[String: Any]]()])

        XCTAssertFalse(model.planApprovalPending, "emptying the list withdraws the plan")
    }

    @MainActor
    func testQueuedMessageSuppressesPlanApproval() {
        let model = AppModel(startImmediately: false)
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.queuedMessages = ["and then do the follow-up"]

        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])

        XCTAssertFalse(model.planApprovalPending, "the queued message already decided what happens next")
    }

    @MainActor
    func testKeepPlanningDismissesThePromptAndStaysInPlanMode() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        model.resolvePlanApproval(.keepPlanning)

        XCTAssertFalse(model.planApprovalPending)
        XCTAssertEqual(model.selectedMode, .plan)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testImplementingThePlanSwitchesToBuildMode() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online
        armPlanApproval(model)

        model.resolvePlanApproval(.implementReviewing)

        XCTAssertFalse(model.planApprovalPending)
        XCTAssertEqual(model.selectedMode, .build, "implementation happens in Build mode")
    }

    @MainActor
    func testImplementingWhileDisconnectedKeepsThePromptPending() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .unavailable("gone")
        armPlanApproval(model)

        model.resolvePlanApproval(.implementReviewing)

        XCTAssertTrue(model.planApprovalPending, "the decision must survive a reconnect")
        XCTAssertEqual(model.selectedMode, .plan)
    }

    @MainActor
    func testSwitchingModesDismissesThePlanApprovalPrompt() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        model.selectedMode = .ask

        XCTAssertFalse(model.planApprovalPending, "changing modes is already an answer")
    }

    @MainActor
    func testAgentErrorClearsThePlanApprovalPrompt() {
        let model = AppModel(startImmediately: false)
        armPlanApproval(model)

        model.handleEventForTesting(["type": "error", "message": "agent crashed"])

        XCTAssertFalse(model.planApprovalPending)
    }

    /// Drives the model through the real wire sequence that ends a Plan-mode
    /// turn with a plan on the board: dispatch latch, todo_update, turn_done.
    @MainActor
    private func armPlanApproval(_ model: AppModel) {
        model.selectedMode = .plan
        model.turnDispatchedInPlanMode = true
        model.handleEventForTesting([
            "type": "todo_update",
            "todos": [["content": "Audit the sidebar", "status": "pending"]],
        ])
        model.handleEventForTesting(["type": "turn_done", "reason": "complete"])
    }

    @MainActor
    func testExtensionSnapshotDecodesPluginSkillAndOAuthServer() throws {
        let data = #"""
        {
          "capabilities": {"streamable_http":true,"stdio":false,"oauth":true,"mcp_apps":false,"hooks":false,"sandboxed":true},
          "marketplaces": [{"id":"local","name":"Local","kind":"local","source":"/tmp/market","error":null,"workspace_discovered":false}],
          "plugins": [{
            "id":"local/demo","name":"demo","display_name":"Demo","description":"A demo","version":"1.0.0","author":"Locus",
            "digest":"abc","enabled_global":true,"enabled_workspaces":[],"disabled_workspaces":[],"previous_versions":[],
            "skills":[],"mcp_servers":[],"scripts":[],"unsupported":[],"error":null
          }],
          "skills": [{
            "id":"demo:review","name":"review","display_name":"Review","description":"Review changes","source":"plugin",
            "plugin_id":"local/demo","allow_implicit_invocation":true,"enabled":true,"error":null
          }],
          "mcp_servers": [{
            "id":"plugin:demo:remote","name":"remote","transport":"streamable_http","url":"https://example.com/mcp","command":"",
            "origin":"plugin","plugin_id":"local/demo","active":true,"enabled":true,"enabled_global":true,"enabled_workspaces":[],
            "disabled_workspaces":[],"state":"connected","error":null,"tool_count":2,"has_credentials":true,"approval_mode":"annotations",
            "auth":"oauth","oauth":{"authorization_endpoint":"https://example.com/authorize","token_endpoint":"https://example.com/token","client_id":"client","scopes":["tools"],"redirect_uri":"locus://mcp/oauth"}
          }],
          "errors":[],"pending_updates":0
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(ExtensionsResponse.self, from: data)

        XCTAssertEqual(response.plugins.first?.displayName, "Demo")
        XCTAssertEqual(response.skills.first?.id, "demo:review")
        XCTAssertEqual(response.mcpServers.first?.oauth?.clientID, "client")
        XCTAssertFalse(response.capabilities.stdio)
    }

    private func sessionInfo(id: String) -> [String: Any] {
        [
            "model": "qwen3:8b",
            "host": "http://localhost:11434",
            "cwd": "/tmp",
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
}
