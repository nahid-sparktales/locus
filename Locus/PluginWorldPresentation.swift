import AppKit
import Foundation
import ImageIO

/// Decorative metadata only. Native forms, routing and permissions remain Locus-owned.
struct PluginSurfacePalette: Decodable, Equatable {
    let colors: [String: String]
    static let keys: Set<String> = ["ink", "inkSoft", "paper", "paperDeep", "panel", "white", "line", "lineStrong", "muted", "signal", "signalDeep", "coral", "danger", "blue", "success", "warning", "permissionInk", "permissionMuted", "successSoft", "codeKeyword", "codeType"]
    var native: LocusTheme.Palette {
        let fallback = LocusTheme.darkPalette
        func color(_ key: String, _ base: NSColor) -> NSColor {
            guard let text = colors[key], let hex = UInt32(text.dropFirst(), radix: 16) else { return base }
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return .init(ink: color("ink", fallback.ink), inkSoft: color("inkSoft", fallback.inkSoft), paper: color("paper", fallback.paper), paperDeep: color("paperDeep", fallback.paperDeep), panel: color("panel", fallback.panel), white: color("white", fallback.white), line: color("line", fallback.line), lineStrong: color("lineStrong", fallback.lineStrong), muted: color("muted", fallback.muted), signal: color("signal", fallback.signal), signalDeep: color("signalDeep", fallback.signalDeep), coral: color("coral", fallback.coral), danger: color("danger", fallback.danger), blue: color("blue", fallback.blue), success: color("success", fallback.success), warning: color("warning", fallback.warning), permissionInk: color("permissionInk", fallback.permissionInk), permissionMuted: color("permissionMuted", fallback.permissionMuted), successSoft: color("successSoft", fallback.successSoft), codeKeyword: color("codeKeyword", fallback.codeKeyword), codeType: color("codeType", fallback.codeType))
    }
}

struct PluginWorldPresentation: Decodable, Equatable {
    struct Surface: Decodable, Equatable { let title: String; let backgroundAsset: String; let palette: PluginSurfacePalette? }
    struct Appearance: Decodable, Equatable, Identifiable { let id: String; let title: String; let palette: PluginSurfacePalette }
    struct Style: Decodable, Equatable, Identifiable { let id: String; let name: String; let previewAsset: String }
    let schemaVersion: Int
    let worldID: String
    let name: String
    let defaultPresentationID: String
    let presentations: [String: Surface]
    let mapPalette: PluginSurfacePalette
    let appearances: [Appearance]
    let styles: [Style]
    let labels: [String: String]
    let appearancePreferenceKey: String
    let stylePreferenceKey: String
    let contextEnabledPreferenceKey: String

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 65_536, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(json.keys) == ["schemaVersion", "worldID", "name", "defaultPresentationID", "presentations", "mapPalette", "appearances", "styles", "labels", "appearancePreferenceKey", "stylePreferenceKey", "contextEnabledPreferenceKey"],
              let value = try? JSONDecoder().decode(Self.self, from: data), value.schemaVersion == 1,
              slug(value.worldID), text(value.name), slug(value.defaultPresentationID), value.presentations[value.defaultPresentationID] != nil,
              !value.presentations.isEmpty, value.presentations.count <= 16,
              value.presentations.allSatisfy({ slug($0.key) && text($0.value.title) && PluginScreenFiles.isSafeRelativePath($0.value.backgroundAsset) && ($0.value.palette.map(validPalette) ?? true) }),
              paletteShape(json["mapPalette"]), validPalette(value.mapPalette), value.appearances.count <= 8, Set(value.appearances.map(\.id)).count == value.appearances.count,
              value.appearances.allSatisfy({ slug($0.id) && text($0.title) && validPalette($0.palette) }),
              value.styles.count <= 64, Set(value.styles.map(\.id)).count == value.styles.count,
              value.styles.allSatisfy({ token($0.id) && text($0.name) && PluginScreenFiles.isSafeRelativePath($0.previewAsset) }),
              Set(value.labels.keys).isSubset(of: ["workspace", "style", "contextShortcut", "visit", "appearance", "workHint", "selectionHelp", "placementPrimary", "placementSecondary", "emptyTitle", "welcomeLabel", "welcomeTitle", "emptyWorkspaceTitle", "emptyDescription"]),
              value.labels.values.allSatisfy(text),
              [value.appearancePreferenceKey, value.stylePreferenceKey, value.contextEnabledPreferenceKey].allSatisfy({ $0.range(of: "^[a-z][a-z0-9.-]{0,79}$", options: .regularExpression) != nil }),
              exactRows(json["presentations"], keys: ["title", "backgroundAsset"], optional: ["palette"]),
              exactArray(json["appearances"], keys: ["id", "title", "palette"]),
              exactArray(json["styles"], keys: ["id", "name", "previewAsset"]),
              (json["appearances"] as? [[String: Any]])?.allSatisfy({ paletteShape($0["palette"]) }) == true,
              (json["presentations"] as? [String: [String: Any]])?.values.allSatisfy({ $0["palette"] == nil || paletteShape($0["palette"]) }) == true else { return nil }
        return value
    }
    private static func paletteShape(_ value: Any?) -> Bool {
        guard let row = value as? [String: Any] else { return false }
        return Set(row.keys) == ["colors"]
    }
    private static func slug(_ text: String) -> Bool { text.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil }
    private static func token(_ text: String) -> Bool { text.range(of: "^[a-zA-Z0-9_-]{1,80}$", options: .regularExpression) != nil }
    private static func text(_ text: String) -> Bool { !text.isEmpty && text.unicodeScalars.count <= 160 && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    private static func validPalette(_ palette: PluginSurfacePalette) -> Bool { Set(palette.colors.keys).isSubset(of: PluginSurfacePalette.keys) && palette.colors.values.allSatisfy { $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil } }
    private static func exactRows(_ value: Any?, keys: Set<String>, optional: Set<String> = []) -> Bool {
        guard let rows = value as? [String: [String: Any]] else { return false }
        return rows.values.allSatisfy { keys.isSubset(of: Set($0.keys)) && Set($0.keys).isSubset(of: keys.union(optional)) }
    }
    private static func exactArray(_ value: Any?, keys: Set<String>) -> Bool { (value as? [[String: Any]])?.allSatisfy { Set($0.keys) == keys } ?? false }

    @MainActor private static var cache: [String: PluginWorldPresentation] = [:]
    @MainActor static func load(screen: AgentWorldModel.AvailableScreen?) -> Self? {
        guard let screen, screen.screen.version == 2 else { return nil }
        let key = screen.id + ":" + screen.root + ":" + (screen.digest ?? "")
        if let value = cache[key] { return value }
        let directory = (screen.screen.entrypoint as NSString).deletingLastPathComponent
        let relative = (directory.isEmpty ? "" : directory + "/") + "presentations.json"
        guard let file = try? PluginScreenFiles.file(root: URL(fileURLWithPath: screen.root), path: relative),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let data = try? Data(contentsOf: file), let value = decode(data) else { return nil }
        let resources = value.presentations.values.map(\.backgroundAsset) + value.styles.map(\.previewAsset)
        guard resources.allSatisfy({ path in
            (try? PluginScreenFiles.file(root: URL(fileURLWithPath: screen.root), path: (directory.isEmpty ? "" : directory + "/") + path)) != nil
        }) else { return nil }
        if cache.count >= 8 { cache.removeAll() }
        cache[key] = value; return value
    }
}

extension AgentWorldModel {
    var pluginSurface: PluginWorldPresentation.Surface? {
        guard let presentation = pluginPresentation else { return nil }
        return presentation.presentations[selectedPresentationID ?? presentation.defaultPresentationID]
    }
    var pluginSurfacePalette: PluginSurfacePalette? {
        guard let presentation = pluginPresentation else { return nil }
        if !quartersPresented { return presentation.mapPalette }
        if let selectedPresentationID, let palette = presentation.presentations[selectedPresentationID]?.palette { return palette }
        let appearance = worldPreferences[presentation.appearancePreferenceKey] as? String
        return presentation.appearances.first(where: { $0.id == appearance })?.palette ?? presentation.appearances.first?.palette ?? presentation.mapPalette
    }
    func pluginLabel(_ key: String, fallback: String) -> String { pluginPresentation?.labels[key] ?? fallback }
    func pluginAssetImage(_ path: String) -> NSImage? {
        guard let screen = activeScreen else { return nil }
        return PluginSurfaceImageCache.image(screen: screen, path: path)
    }
}

@MainActor
private enum PluginSurfaceImageCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 24; cache.totalCostLimit = 64 * 1024 * 1024; return cache
    }()
    static func image(screen: AgentWorldModel.AvailableScreen, path: String) -> NSImage? {
        let key = (screen.root + ":" + (screen.digest ?? "") + ":" + path) as NSString
        if let image = images.object(forKey: key) { return image }
        let directory = (screen.screen.entrypoint as NSString).deletingLastPathComponent
        guard ["jpg", "jpeg", "png", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              let file = try? PluginScreenFiles.file(root: URL(fileURLWithPath: screen.root), path: (directory.isEmpty ? "" : directory + "/") + path),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        images.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}
