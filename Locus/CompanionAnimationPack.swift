import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A single JSON document containing pixels and playback metadata. There are
/// no archives, paths, URLs, expressions or scripts to load or execute.
struct CompanionAnimationPack: Codable {
    struct Animation: Codable {
        let row: Int
        let frameCount: Int
        let frameMilliseconds: Int
    }
    let version: Int
    let name: String
    let image: Data
    let animations: [String: Animation]
    static let maximumBytes = 28 * 1024 * 1024
    static let stateRows: [String: CompanionSpriteRow] = [
        "idle": .idle, "greeting": .waving, "working": .working,
        "listening": .listening, "speaking": .speaking, "approval-needed": .waiting,
        "completion": .jumping, "failure": .failed,
    ]
    var assetID: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return "pack-" + SHA256.hash(data: (try? encoder.encode(self)) ?? image)
            .map { String(format: "%02x", $0) }.joined()
    }
    var decodedBytes: Int { imageDimensions.map { $0.width * $0.height * 4 } ?? 0 }
    var imageDimensions: (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? Int,
              let height = values[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "name", "image", "animations"]) else { throw PackError.invalid }
        guard let states = object["animations"] as? [String: [String: Any]],
              states.values.allSatisfy({ Set($0.keys) == Set(["row", "frameCount", "frameMilliseconds"]) }) else {
            throw PackError.invalid
        }
        let pack = try JSONDecoder().decode(Self.self, from: data)
        guard pack.version == 1, (1...80).contains(pack.name.count),
              pack.image.count <= CompanionSpriteAtlas.maximumSourceBytes,
              pack.animations["idle"] != nil,
              Set(pack.animations.keys).isSubset(of: Set(stateRows.keys)),
              let dimensions = pack.imageDimensions,
              dimensions.width == 1_536, dimensions.height > 0,
              dimensions.height % 208 == 0, dimensions.height <= 2_704,
              pack.decodedBytes <= 16 * 1024 * 1024 else { throw PackError.invalid }
        for animation in pack.animations.values {
            guard animation.row >= 0, animation.row < dimensions.height / 208,
                  (1...8).contains(animation.frameCount),
                  (50...2_000).contains(animation.frameMilliseconds) else { throw PackError.invalid }
        }
        _ = try CompanionSpriteAtlas(data: pack.image, pack: pack)
        return pack
    }
    enum PackError: LocalizedError {
        case invalid
        var errorDescription: String? {
            "Choose a version 1 Companion pack: JSON with name, base64 PNG/WebP image, and animation rows. Use 192 × 208 cells, eight columns, up to thirteen rows and 20 MB of image data. Idle is required; missing states use idle."
        }
    }
}

@MainActor
enum CompanionImportedSpriteCatalog {
    private static var cachedID: String?
    private static var cachedData: Data?
    private static var cachedAtlas: CompanionSpriteAtlas?
    static func atlas(assetID: String, data: Data?) -> CompanionSpriteAtlas? {
        guard let data else { return nil }
        if cachedID == assetID, cachedData == data { return cachedAtlas }
        guard let pack = try? CompanionAnimationPack.decode(data),
              let atlas = try? CompanionSpriteAtlas(data: pack.image, pack: pack) else { return nil }
        cachedID = assetID; cachedData = data; cachedAtlas = atlas
        return atlas
    }
}

struct CompanionAnimationPackButton: View {
    @EnvironmentObject private var agents: AgentTeamsModel
    let profileID: UUID
    @State private var importing = false
    @State private var preview: CompanionAnimationPack?
    @State private var error: String?
    var body: some View {
        Button("Import animated character…") { importing = true }
            .accessibilityIdentifier("companion.pack.import")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size > 0, size <= CompanionAnimationPack.maximumBytes else { throw CompanionAnimationPack.PackError.invalid }
                    preview = try CompanionAnimationPack.decode(Data(contentsOf: url, options: .mappedIfSafe))
                } catch CocoaError.userCancelled { }
                catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                if let preview {
                    CompanionAnimationPackPreview(pack: preview) { data in
                        do { try agents.setAgentAnimationPack(data, profileID: profileID); self.preview = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .alert("Couldn’t import character", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

private struct CompanionAnimationPackPreview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pack: CompanionAnimationPack
    let use: (Data) -> Void
    @State private var state = "idle"
    @State private var atlas: CompanionSpriteAtlas?
    private let poses: [String: CompanionCharacterPose] = ["idle": .idle, "greeting": .greeting,
        "working": .working, "listening": .listening, "speaking": .speaking,
        "approval-needed": .needsApproval, "completion": .completed, "failure": .failed]
    var body: some View {
        VStack(spacing: 14) {
            Text(pack.name).font(.title2)
            if let atlas {
                CompanionSpriteView(atlas: atlas, pose: poses[state] ?? .idle, canAnimate: !reduceMotion)
                    .frame(width: 180, height: 180).id(state)
            }
            Picker("Preview state", selection: $state) {
                ForEach(CompanionAnimationPack.stateRows.keys.sorted(), id: \.self) { Text($0).tag($0) }
            }
            if pack.animations[state] == nil { Text("This state uses the idle animation.").font(.caption) }
            Text("\(pack.imageDimensions?.width ?? 0) × \(pack.imageDimensions?.height ?? 0) · \(pack.decodedBytes / 1_048_576) MB decoded · \(pack.image.count / 1_024) KB image")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use this character") { if let data = try? JSONEncoder().encode(pack) { use(data) } }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 380)
            .onAppear { if atlas == nil { atlas = try? CompanionSpriteAtlas(data: pack.image, pack: pack) } }
    }
}
