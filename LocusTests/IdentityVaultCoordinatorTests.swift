import XCTest
@testable import Locus

@MainActor
final class IdentityVaultCoordinatorTests: XCTestCase {
    private let provider = IdentityProviderIdentity(accountID: "fixture-account", provider: "remote",
        endpoint: "https://provider.invalid/v1", model: "fixture", label: "Fixture provider")

    private func fixture() async throws -> (IdentityVaultModel, IdentityVaultProfile, BrowserService) {
        let vault = IdentityVaultModel(store: IdentityVaultStore(inMemory: ()))
        let loaded = await vault.ready()
        XCTAssertTrue(loaded)
        let profile = try vault.store.saveProfile(.init(name: "PRIVATE_PROFILE_NAME", kind: .career, fields: [
            .init(key: "email", label: "Email", value: "UNAPPROVED_CONTACT_MARKER", kind: .email),
            .init(key: "skills", label: "Skills", value: "APPROVED_CAREER_MARKER", kind: .multiline),
        ]))
        vault.registerSession("task-a", profileID: profile.id)
        return (vault, profile, BrowserService(autofillVault: BrowserAutofillVault(inMemory: ())))
    }

    private func nextReview(_ vault: IdentityVaultModel) async throws -> IdentityVaultReview {
        for _ in 0..<1_000 {
            if let review = vault.pendingReview { return review }
            await Task.yield()
        }
        return try XCTUnwrap(vault.pendingReview)
    }

    func testDescribeExposesOnlyScopedMetadata() async throws {
        let (vault, _, browser) = try await fixture()
        let result = await vault.perform(arguments: ["action": "describe"], session: "task-a", provider: provider, browser: browser)
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertTrue(text.contains("profile_ref"))
        XCTAssertFalse(text.contains("MARKER"))
        XCTAssertFalse(text.contains("PRIVATE_PROFILE_NAME"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let ref = try XCTUnwrap(object["profile_ref"] as? String)
        XCTAssertNotNil(vault.resolveProfile(ref, session: "task-a"))
        XCTAssertNil(vault.resolveProfile(ref, session: "task-b"))
    }

    func testSelectedContentTravelsOnlyThroughContextChannel() async throws {
        let (vault, profile, browser) = try await fixture()
        let field = profile.fields[1]
        let task = Task { await vault.perform(arguments: ["action": "request_context", "field_ids": [field.id.uuidString]],
                                             session: "task-a", provider: provider, browser: browser) }
        let review = try await nextReview(vault)
        XCTAssertTrue(review.items.contains { $0.detail == "UNAPPROVED_CONTACT_MARKER" && !$0.selected })
        vault.answerReview(id: review.id, selected: [field.id])
        let result = await task.value
        XCTAssertFalse(String(describing: result).contains("MARKER"))
        let refs = try XCTUnwrap(result["source_refs"] as? [String])
        let context = await vault.resolveSources(refs, session: "task-a", provider: provider)
        let sources = try XCTUnwrap(context["sources"] as? [[String: String]])
        let text = try XCTUnwrap(sources.first?["text"])
        XCTAssertTrue(text.contains("APPROVED_CAREER_MARKER"))
        XCTAssertFalse(text.contains("UNAPPROVED_CONTACT_MARKER"))
        XCTAssertNil(vault.pendingReview)
        XCTAssertEqual(vault.store.disclosures.last?.fieldIDs, [field.id])
    }

    func testDeniedAndChangedProfileReviewsReleaseNothing() async throws {
        let (vault, original, browser) = try await fixture()
        let first = Task { await vault.perform(arguments: ["action": "request_context"], session: "task-a", provider: provider, browser: browser) }
        let denied = try await nextReview(vault)
        vault.answerReview(id: denied.id, selected: nil)
        let deniedResult = await first.value
        XCTAssertNotNil(deniedResult["error"])
        XCTAssertTrue(vault.store.disclosures.isEmpty)

        let second = Task { await vault.perform(arguments: ["action": "request_context"], session: "task-a", provider: provider, browser: browser) }
        let stale = try await nextReview(vault)
        var changed = original
        changed.fields[1].value = "changed"
        _ = try vault.store.saveProfile(changed)
        vault.answerReview(id: stale.id, selected: [original.fields[1].id])
        let staleResult = await second.value
        XCTAssertNotNil(staleResult["error"])
        XCTAssertTrue(vault.store.disclosures.isEmpty)
    }

    func testRestoredSourcesRequireReviewAndCannotCrossTasks() async throws {
        let (vault, _, _) = try await fixture()
        let id = try vault.store.saveSnapshot(text: "RESTORE_MARKER")
        try vault.store.recordDisclosure(.init(taskID: "task-a", recipientID: provider.recipientID,
            recipientLabel: provider.label, kind: .provider, summary: "Fixture source", snapshotID: id))
        let task = Task { await vault.resolveSources([id.uuidString], session: "task-a", provider: provider) }
        let review = try await nextReview(vault)
        XCTAssertEqual(review.title, "Restore private context?")
        vault.answerReview(id: review.id, selected: Set(review.items.map(\.id)))
        let result = await task.value
        XCTAssertNotNil(result["sources"])
        vault.registerSession("task-b")
        let wrongOwner = await vault.resolveSources([id.uuidString], session: "task-b", provider: provider)
        XCTAssertNotNil(wrongOwner["error"])
        XCTAssertNil(vault.pendingReview)

        let other = IdentityProviderIdentity(accountID: "other", provider: "remote", endpoint: provider.endpoint, model: provider.model, label: "Other provider")
        let changed = Task { await vault.resolveSources([id.uuidString], session: "task-a", provider: other) }
        let changedReview = try await nextReview(vault)
        XCTAssertTrue(changedReview.destination.contains("Other provider"))
        vault.answerReview(id: changedReview.id, selected: nil)
        let changedResult = await changed.value
        XCTAssertNotNil(changedResult["error"])
    }

    func testRevocationAndLockInvalidateGrantedSources() async throws {
        let (vault, _, _) = try await fixture()
        let id = try vault.store.saveSnapshot(text: "SECRET")
        let disclosure = try vault.store.recordDisclosure(.init(taskID: "task-a", recipientID: provider.recipientID,
            recipientLabel: provider.label, kind: .provider, summary: "Fixture source", snapshotID: id))
        let ref = vault.rememberSource(snapshotID: id, session: "task-a", provider: provider)
        XCTAssertTrue(vault.sourceIsApproved(ref, session: "task-a", provider: provider))
        vault.revoke(disclosure)
        let revoked = await vault.resolveSources([ref], session: "task-a", provider: provider)
        XCTAssertNotNil(revoked["error"])
        vault.suspend()
        XCTAssertFalse(vault.store.isReady)
        XCTAssertFalse(vault.sourceIsApproved(ref, session: "task-a", provider: provider))
        let loaded = await vault.ready()
        XCTAssertFalse(loaded)
    }

    func testConcurrentReviewOwnershipAndCancellation() async throws {
        let (vault, _, _) = try await fixture()
        let a = IdentityReviewItem(label: "A", detail: "Private A")
        let b = IdentityReviewItem(label: "B", detail: "Private B")
        let first = Task { await vault.review(.init(sessionID: "task-a", title: "A", destination: "Fixture", explanation: "", items: [a])) }
        let firstReview = try await nextReview(vault)
        let second = Task { await vault.review(.init(sessionID: "task-b", title: "B", destination: "Fixture", explanation: "", items: [b])) }
        await Task.yield()
        vault.cancelReviews(sessionID: "task-a")
        let firstResult = await first.value
        XCTAssertNil(firstResult)
        let secondReview = try await nextReview(vault)
        XCTAssertEqual(secondReview.sessionID, "task-b")
        vault.answerReview(id: firstReview.id, selected: [a.id])
        XCTAssertEqual(vault.pendingReview?.id, secondReview.id)
        vault.answerReview(id: secondReview.id, selected: [b.id])
        let secondResult = await second.value
        XCTAssertEqual(secondResult, [b.id])
    }

    func testNativeCaptureGuardBlocksComputerToolsAndAppshots() async throws {
        IdentityPrivacyGuard.shared.visiblePrivateViews += 1
        defer { IdentityPrivacyGuard.shared.visiblePrivateViews -= 1 }
        let computer = ComputerControlService()
        let result = await computer.perform(tool: "computer_get_state", arguments: [:], hostedProvider: nil)
        XCTAssertTrue((result["error"] as? String)?.contains("Identity Vault") == true)
        let context = ApplicationContextService()
        do {
            _ = try await context.captureSnapshot(of: .init(bundleIdentifier: "fixture", processIdentifier: 0,
                name: "Fixture", windowTitle: "", windowIdentifier: nil, iconData: nil))
            XCTFail("A protected surface must not be captured")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Identity Vault")) }
    }

    func testApprovalFollowedImmediatelyByStopCannotGrantContext() async throws {
        let (vault, profile, browser) = try await fixture()
        let task = Task { await vault.perform(arguments: ["action": "request_context"], session: "task-a", provider: provider, browser: browser) }
        let review = try await nextReview(vault)
        vault.answerReview(id: review.id, selected: [profile.fields[1].id])
        vault.cancelReviews(sessionID: "task-a")
        let result = await task.value
        XCTAssertNotNil(result["error"])
        XCTAssertTrue(vault.store.disclosures.isEmpty)
    }

    func testSuspendDismissesPrivateEditorsAndCancelsLocalWork() async throws {
        let (vault, profile, _) = try await fixture()
        vault.isPresented = true
        vault.profileEditor = profile
        let work = Task { while !Task.isCancelled { await Task.yield() } }
        vault.localWork = work
        let generation = vault.lifecycleGeneration
        vault.suspend()
        XCTAssertTrue(work.isCancelled)
        XCTAssertFalse(vault.isPresented)
        XCTAssertNil(vault.profileEditor)
        XCTAssertGreaterThan(vault.lifecycleGeneration, generation)
        await work.value
    }

    func testNativeApplicationFillNeedsNoProviderSnapshot() async throws {
        let (vault, _, browser) = try await fixture()
        defer { browser.closeAllIdentityApplications() }
        let opening = Task { try await browser.openIdentityApplication(sessionID: "task-a", url: URL(string: "http://127.0.0.1:1/application")!) }
        for _ in 0..<1_000 {
            if browser.isIdentityApplication(sessionID: "task-a") { break }
            await Task.yield()
        }
        browser.tab(for: "task-a").webView.loadHTMLString("<body><label>Email <input id='email' type='email'></label><input aria-label='Unknown question'></body>", baseURL: URL(string: "https://fixture.invalid/application"))
        _ = try await opening.value
        let task = Task { await vault.useApplicationLocally(session: "task-a", browser: browser, upload: false) }
        let review = try await nextReview(vault)
        XCTAssertEqual(review.title, "Fill selected fields locally")
        XCTAssertEqual(review.items.count, 1)
        XCTAssertEqual(review.items.first?.detail, "UNAPPROVED_CONTACT_MARKER")
        vault.answerReview(id: review.id, selected: Set(review.items.map(\.id)))
        let result = await task.value
        XCTAssertNil(result["source_refs"])
        XCTAssertFalse(String(describing: result).contains("MARKER"))
        XCTAssertEqual(result["text"] as? String, "Approved fields filled locally.")
        XCTAssertFalse(vault.store.disclosures.contains { $0.kind == .provider })
        let values = try await browser.tab(for: "task-a").webView.evaluateJavaScript("Array.from(document.querySelectorAll('input')).map(x=>x.value)") as? [String]
        XCTAssertEqual(values, ["UNAPPROVED_CONTACT_MARKER", ""])
    }
}
