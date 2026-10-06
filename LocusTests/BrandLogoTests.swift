import AppKit
import XCTest
@testable import Locus

@MainActor
final class BrandLogoTests: XCTestCase {
    func testEveryRegisteredBrandAndNativePluginHasBundledArtwork() throws {
        for brand in ThirdPartyProviderID.allCases where brand != .custom {
            let name = try XCTUnwrap(brand.assetName)
            let image = try XCTUnwrap(NSImage(named: name), name)
            XCTAssertGreaterThan(image.size.width, 0, name)
            XCTAssertGreaterThan(image.size.height, 0, name)
            XCTAssertNotNil(image.tiffRepresentation, name)
        }
        for plugin in ["agent-world", "langgraph-workflow"] {
            let name = try XCTUnwrap(PluginLogo.bundledAsset(for: plugin))
            XCTAssertNotNil(NSImage(named: name)?.tiffRepresentation, name)
        }
    }

    func testBrandAliasesAndProviderNamesBeatHostingURLs() {
        XCTAssertEqual(ProviderBrandIdentity.resolve(name: "Hugging Face").id, .huggingFace)
        XCTAssertEqual(ProviderBrandIdentity.resolve(name: "Anthropic").id, .anthropic)
        XCTAssertEqual(ProviderBrandIdentity.resolve(name: "Claude plan", presetID: "claude_plan").id, .claude)
        XCTAssertEqual(ProviderBrandIdentity.resolve(name: "ChatGPT plan", presetID: "chatgpt").id, .openAI)
        XCTAssertEqual(ProviderBrandIdentity.resolve(name: "Supabase", url: "https://github.com/supabase").id, .supabase)
        XCTAssertEqual(ProviderBrandIdentity.resolve(name: "HF Endpoint", url: "https://abc.endpoints.huggingface.cloud").id, .huggingFace)
        XCTAssertEqual(ProviderBrandIdentity.resolve(name: "NotOllamaCo").id, .custom)
    }

    func testPluginArtworkDecodesAndRejectsInvalidOrOversizedPayloads() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertNotNil(PluginLogo.image(from: data.base64EncodedString()))
        let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><circle cx="16" cy="16" r="12" fill="#123456"/></svg>"##.utf8)
        XCTAssertNotNil(PluginLogo.image(from: svg.base64EncodedString()))
        XCTAssertNil(PluginLogo.image(from: "not base64"))
        XCTAssertNil(PluginLogo.image(from: Data(repeating: 0, count: 300_000).base64EncodedString()))
    }
}
