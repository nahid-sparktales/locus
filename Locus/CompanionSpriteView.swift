import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The approved atlas geometry is fixed. In particular, work is row 7;
/// directional running is reserved for an actual directional interaction.
enum CompanionSpriteRow: Int, CaseIterable {
    case idle = 0, runningRight, runningLeft, waving, jumping, failed, waiting, working, review
    case lookFirst, lookSecond

    var frameCount: Int {
        switch self {
        case .idle, .waiting, .working, .review: 6
        case .runningRight, .runningLeft, .failed, .lookFirst, .lookSecond: 8
        case .waving: 4
        case .jumping: 5
        }
    }

    /// Locus playback timings; idle includes longer rests for occasional blinks.
    /// The atlas contains pixels, not an embedded production playback clock.
    var frameDurations: [Int] {
        switch self {
        case .idle: [2_100, 120, 1_400, 2_100, 120, 1_400]
        case .runningRight, .runningLeft: [120, 120, 120, 120, 120, 120, 120, 220]
        case .waving: [140, 140, 140, 280]
        case .jumping: [140, 140, 140, 140, 280]
        case .failed: [140, 140, 140, 140, 140, 140, 140, 240]
        case .waiting: [150, 150, 150, 150, 150, 260]
        case .working: [120, 120, 120, 120, 120, 220]
        case .review: [150, 150, 150, 150, 150, 280]
        case .lookFirst, .lookSecond: Array(repeating: 140, count: 8)
        }
    }

    static func row(for pose: CompanionCharacterPose) -> CompanionSpriteRow {
        switch pose {
        case .idle, .queued, .paused, .unavailable: .idle
        case .greeting: .waving
        case .working: .working
        case .needsApproval: .waiting
        case .completed: .jumping
        case .failed: .failed
        }
    }
}

/// One decoded atlas and its immutable cell crops are shared by every visible
/// instance. There is no separate image store and no frame decoding during playback.
final class CompanionSpriteAtlas {
    static let columns = 8
    static let cellWidth = 192
    static let cellHeight = 208
    static let maximumSourceBytes = 20 * 1024 * 1024
    let version: Int
    let pixelWidth: Int
    let pixelHeight: Int
    private let frames: [CompanionSpriteRow: [CGImage]]

    enum ValidationError: Error { case invalidType, invalidDimensions, invalidTransparency, invalidFrame }

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.webP.identifier].contains(sourceType),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ValidationError.invalidType }
        guard width == 1_536, height == 1_872 || height == 2_288 else { throw ValidationError.invalidDimensions }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              [.premultipliedLast, .premultipliedFirst, .last, .first].contains(image.alphaInfo) else {
            throw ValidationError.invalidTransparency
        }
        version = height == 2_288 ? 2 : 1
        pixelWidth = width; pixelHeight = height
        var cells: [CompanionSpriteRow: [CGImage]] = [:]
        for row in CompanionSpriteRow.allCases where row.rawValue < height / Self.cellHeight {
            cells[row] = try (0..<row.frameCount).map { column in
                let rect = CGRect(x: column * Self.cellWidth, y: row.rawValue * Self.cellHeight,
                    width: Self.cellWidth, height: Self.cellHeight)
                guard let cell = image.cropping(to: rect) else { throw ValidationError.invalidFrame }
                return cell
            }
        }
        frames = cells
    }

    func frame(row: CompanionSpriteRow, index: Int) -> CGImage? {
        guard let rowFrames = frames[row], rowFrames.indices.contains(index) else { return nil }
        return rowFrames[index]
    }

    var frameCount: Int { frames.values.reduce(0) { $0 + $1.count } }
}

@MainActor
enum CompanionSpriteCatalog {
    private static var cached: [CompanionBundledSprite: CompanionSpriteAtlas] = [:]
    private static var unavailable: Set<CompanionBundledSprite> = []

    static func resourceURL(for sprite: CompanionBundledSprite, bundle: Bundle = .main) -> URL? {
        // Xcode resource groups may flatten the source folder when copying.
        bundle.url(forResource: sprite.resourceName, withExtension: "png", subdirectory: "Companions")
            ?? bundle.url(forResource: sprite.resourceName, withExtension: "png")
    }

    static func atlas(for sprite: CompanionBundledSprite) -> CompanionSpriteAtlas? {
        if let atlas = cached[sprite] { return atlas }
        guard !unavailable.contains(sprite), let url = resourceURL(for: sprite),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= CompanionSpriteAtlas.maximumSourceBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let atlas = try? CompanionSpriteAtlas(data: data) else {
            unavailable.insert(sprite)
            return nil
        }
        cached[sprite] = atlas
        return atlas
    }
}

/// Plays only the approved source frames, without tinting, warping, redrawing,
/// artificial limb motion, or added breathing. Its owner supplies visibility.
struct CompanionSpriteView: View {
    let atlas: CompanionSpriteAtlas
    let pose: CompanionCharacterPose
    let canAnimate: Bool
    @State private var activeRow: CompanionSpriteRow = .idle
    @State private var frameIndex = 0
    @State private var activeKey: String?

    private var playbackKey: String { "\(pose.rawValue)-\(canAnimate)" }
    private var requestedRow: CompanionSpriteRow { .row(for: pose) }
    private var displayedRow: CompanionSpriteRow { activeKey == playbackKey ? activeRow : requestedRow }
    private var displayedFrame: Int { activeKey == playbackKey ? frameIndex : 0 }

    var body: some View {
        Group {
            if let frame = atlas.frame(row: displayedRow, index: displayedFrame) {
                Image(decorative: frame, scale: 1).resizable().interpolation(.high).scaledToFit()
            }
        }
        .accessibilityHidden(true)
        .task(id: playbackKey) { await play() }
    }

    @MainActor private func play() async {
        activeKey = playbackKey
        activeRow = requestedRow
        frameIndex = 0
        guard canAnimate else { return }
        do {
            if pose == .greeting || pose == .completed || pose == .failed {
                try await playOnce(requestedRow)
                if pose == .failed { return }
                activeRow = .idle
            }
            while !Task.isCancelled { try await playOnce(activeRow) }
        } catch { /* Visibility, state, and disappearance cancel the view task. */ }
    }

    @MainActor private func playOnce(_ row: CompanionSpriteRow) async throws {
        activeRow = row
        for (index, duration) in row.frameDurations.enumerated() {
            try Task.checkCancellation()
            frameIndex = index
            try await Task.sleep(for: .milliseconds(duration))
        }
    }
}
