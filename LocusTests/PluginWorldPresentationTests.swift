import XCTest
@testable import Locus

final class PluginWorldPresentationTests: XCTestCase {
    private func sample() -> [String: Any] {
        ["schemaVersion": 1, "worldID": "test-world", "name": "Test World", "defaultPresentationID": "workspace",
         "presentations": ["workspace": ["title": "Workspace", "backgroundAsset": "art/background.webp"]],
         "mapPalette": ["colors": ["paper": "#112233"]],
         "appearances": [["id": "dark", "title": "Dark", "palette": ["colors": ["ink": "#FFFFFF"]]]],
         "styles": [["id": "one", "name": "One", "previewAsset": "art/one.jpg"]],
         "labels": ["workspace": "Workspace"], "appearancePreferenceKey": "appearance", "stylePreferenceKey": "styles", "contextEnabledPreferenceKey": "shortcuts"]
    }
    private func decode(_ value: [String: Any]) throws -> PluginWorldPresentation? {
        PluginWorldPresentation.decode(try JSONSerialization.data(withJSONObject: value))
    }
    func testDecorativeMetadataHasNoWorldOrNativeCodeDependency() throws {
        let value = try XCTUnwrap(decode(sample()))
        XCTAssertEqual(value.worldID, "test-world")
        XCTAssertEqual(value.presentations["workspace"]?.title, "Workspace")
        XCTAssertEqual(value.styles.first?.previewAsset, "art/one.jpg")
        XCTAssertNotNil(value.mapPalette.native.paper.usingColorSpace(.sRGB))
    }
    func testMetadataRejectsPathsUnknownFieldsInvalidColorsAndUnboundedCollections() throws {
        var value = sample(); value["nativeSelector"] = "run:"; XCTAssertNil(try decode(value))
        value = sample(); value["presentations"] = ["workspace": ["title": "Workspace", "backgroundAsset": "../secret.png"]]; XCTAssertNil(try decode(value))
        value = sample(); value["mapPalette"] = ["colors": ["paper": "url(secret)"]]; XCTAssertNil(try decode(value))
        value = sample(); value["mapPalette"] = ["colors": ["paper": "#112233"], "script": "execute"]; XCTAssertNil(try decode(value))
        value = sample(); value["appearancePreferenceKey"] = "../profiles"; XCTAssertNil(try decode(value))
        value = sample(); value["styles"] = Array(repeating: ["id": "one", "name": "One", "previewAsset": "art/one.jpg"], count: 65); XCTAssertNil(try decode(value))
        value = sample(); value["schemaVersion"] = true; XCTAssertNil(try decode(value))
    }
}
