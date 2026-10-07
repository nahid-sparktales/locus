import AppKit
import XCTest
@testable import Locus

@MainActor
final class CompanionDesktopAndPackTests: XCTestCase {
    func testDesktopSnapsAndRecoversOffscreenFrames() {
        let screen = CGRect(x: -1_200, y: 0, width: 1_200, height: 800)
        let snapped = CompanionDesktopController.snappedFrame(CGRect(x: -1_190, y: 8, width: 220, height: 180), in: screen)
        XCTAssertEqual(snapped.origin, screen.origin)
        let recovered = CompanionDesktopController.snappedFrame(CGRect(x: 2_000, y: 2_000, width: 220, height: 180), in: screen)
        XCTAssertEqual(recovered.maxX, screen.maxX)
        XCTAssertEqual(recovered.maxY, screen.maxY)
    }

    func testImportedPackValidatesGridAndFallsBackWithoutChangingProfile() throws {
        let url = try XCTUnwrap(CompanionSpriteCatalog.resourceURL(for: .pitou))
        let image = try Data(contentsOf: url)
        let pack = CompanionAnimationPack(version: 1, name: "My character", image: image,
            animations: ["idle": .init(row: 0, frameCount: 6, frameMilliseconds: 125),
                         "listening": .init(row: 6, frameCount: 6, frameMilliseconds: 200)])
        let data = try JSONEncoder().encode(pack)
        let decoded = try CompanionAnimationPack.decode(data)
        let atlas = try CompanionSpriteAtlas(data: decoded.image, pack: decoded)
        XCTAssertNotNil(atlas.frame(row: .speaking, index: 0), "Missing states use idle")
        XCTAssertEqual(atlas.frameDurations(for: .listening), Array(repeating: 200, count: 6))
        XCTAssertNil(atlas.lookFrame(for: .init(x: 1, y: 0), pose: .idle, canAnimate: true))
        let suite = "CompanionPackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentTeamsModel(credentialStore: InMemoryCredentialStore())
        store.restore(persistenceEnabled: true, defaults: defaults)
        let profileID = try store.commitCompanion(.init())
        let before = store.agentProfiles
        try store.setAgentAnimationPack(data, profileID: profileID)
        XCTAssertEqual(store.agentProfiles, before)
        XCTAssertEqual(store.agentAppearances[profileID]?.kind, .importedSprite)
        let restored = AgentTeamsModel(credentialStore: InMemoryCredentialStore())
        restored.restore(persistenceEnabled: true, defaults: defaults)
        XCTAssertEqual(restored.primaryCompanionID, profileID)
        XCTAssertEqual(restored.agentAppearances[profileID]?.kind, .importedSprite)
        XCTAssertNotNil(restored.agentAvatarData[profileID])
        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        malformed["script"] = "alert(1)"
        XCTAssertThrowsError(try CompanionAnimationPack.decode(JSONSerialization.data(withJSONObject: malformed)))
        let outOfBounds = CompanionAnimationPack(version: 1, name: "Invalid", image: image,
            animations: ["idle": .init(row: 20, frameCount: 8, frameMilliseconds: 125)])
        XCTAssertThrowsError(try CompanionAnimationPack.decode(JSONEncoder().encode(outOfBounds)))
    }
}
