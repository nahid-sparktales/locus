import XCTest
@testable import Locus

@MainActor
final class CompanionToolsTests: XCTestCase {
    func testQuietHoursCrossMidnightAndSnoozeExpiresWithoutChangingSources() throws {
        var policy = CompanionNotificationPolicy()
        policy.quietHoursEnabled = true
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let midnight = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(policy.isQuiet(at: midnight, calendar: calendar))
        XCTAssertTrue(policy.isQuiet(at: midnight.addingTimeInterval(23 * 3600), calendar: calendar))
        XCTAssertFalse(policy.isQuiet(at: midnight.addingTimeInterval(12 * 3600), calendar: calendar))
        policy.snoozedUntil["run"] = midnight.addingTimeInterval(100)
        XCTAssertTrue(policy.isSnoozed("run", at: midnight))
        XCTAssertFalse(policy.isSnoozed("run", at: midnight.addingTimeInterval(100)))
        XCTAssertTrue(policy.includes(.chat))
        policy.enabledSources.remove(ActivityFilter.Kind.chat.rawValue)
        XCTAssertFalse(policy.includes(.chat))
        XCTAssertTrue(policy.includes(.schedule))
    }

    func testNotificationPreferencesPersistWithoutReadingOrDismissingRuns() throws {
        let name = "CompanionToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let activity = ActivityCenterModel()
        activity.restore(persistenceEnabled: true, defaults: defaults)
        activity.snoozeCompanionActivity("approval", until: .now.addingTimeInterval(3600))
        let restored = ActivityCenterModel()
        restored.restore(persistenceEnabled: true, defaults: defaults)
        XCTAssertTrue(restored.companionNotificationPolicy.isSnoozed("approval"))
        XCTAssertTrue(restored.activitySeenUpdates.isEmpty)
        XCTAssertTrue(restored.dismissedActivityRunIDs.isEmpty)
    }

    func testFocusTimerUsesSavedTimeAndPausedTimeDoesNotAdvance() throws {
        let data = Data(#"{"mode":"learning","minutes":30,"steps":[{"title":"Try an example","evidence":"","completed":false}],"state":"running","started_at":1000,"elapsed_seconds":100}"#.utf8)
        let session = try JSONDecoder().decode(CompanionFocusSession.self, from: data)
        XCTAssertEqual(session.remaining(at: Date(timeIntervalSince1970: 1100)), 1600)
        XCTAssertEqual(session.remaining(at: Date(timeIntervalSince1970: 4000)), 0)
        let pausedData = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "running", with: "paused").utf8)
        let paused = try JSONDecoder().decode(CompanionFocusSession.self, from: pausedData)
        XCTAssertEqual(paused.remaining(at: Date(timeIntervalSince1970: 4000)), 1700)
        let prompt = session.prompt("Give a hint", objective: "Understand checkpoints")
        XCTAssertTrue(prompt.contains("wait for my attempt"))
        XCTAssertTrue(prompt.contains("hints before solutions"))
        XCTAssertTrue(prompt.contains("Do not begin autonomous continuation"))
    }

    func testStoppedGuidanceCannotHighlightOrGrantAnything() {
        let guide = CompanionGuidanceModel()
        guide.topic = .mcp
        guide.point(to: "extensions.add", instruction: "Choose Add server")
        XCTAssertEqual(guide.target, "extensions.add")
        guide.stop()
        guide.point(to: "extensions.add", instruction: "Stale update")
        XCTAssertNil(guide.target)
        XCTAssertNil(guide.topic)
        XCTAssertTrue(guide.instruction.isEmpty)
    }

    func testHandoffProjectionRejectsForeignRunAndKeepsLatestAttempt() throws {
        let json = #"{"id":"run","state":"running","request":"Review","created_at":1,"updated_at":2,"last_seq":1,"pinned":false,"legacy":false,"recoverable":false,"attempts":[{"run_id":"run","job_id":"job","attempt":1,"attempt_id":"first","state":"failed","goal":"Review"},{"run_id":"run","job_id":"job","attempt":2,"attempt_id":"second","state":"running","goal":"Review"},{"run_id":"foreign","job_id":"other","attempt":1,"attempt_id":"foreign","state":"completed","goal":"Other"}]}"#
        let run = try JSONDecoder().decode(OrchestrationRun.self, from: Data(json.utf8))
        XCTAssertEqual(CompanionHandoffProjection.latestAttempts(run).map(\.id), ["second"])
    }
}
