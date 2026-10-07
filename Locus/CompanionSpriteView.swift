import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Locus's sprite-style timing and pose grid. This is a presentation choice,
/// not a playback contract inferred from another application's artwork.
enum CompanionSteppedMotion {
    static let frameMilliseconds = 125  // Eight distinct poses per second.

    static func snapped(_ value: CGFloat) -> CGFloat {
        value.isFinite ? value.rounded() : 0
    }
}

/// The approved atlas geometry is fixed. In particular, work is row 7;
/// directional running is reserved for an actual directional interaction.
enum CompanionSpriteRow: Int, CaseIterable {
    case idle = 0, runningRight, runningLeft, waving, jumping, failed, waiting, working, review
    case lookFirst, lookSecond, listening, speaking

    var frameCount: Int {
        switch self {
        case .idle, .waiting, .working, .review, .listening, .speaking: 6
        case .runningRight, .runningLeft, .failed, .lookFirst, .lookSecond: 8
        case .waving: 4
        case .jumping: 5
        }
    }

    /// Whole 8fps ticks with deliberate holds instead of eased in-between poses.
    /// Idle rests keep a decorative character distinct from active work.
    /// The atlas contains pixels, not an embedded production playback clock.
    var frameDurations: [Int] {
        let ticks: [Int]
        switch self {
        case .idle: ticks = [16, 1, 1, 16, 1, 1]
        case .runningRight, .runningLeft, .failed: ticks = [1, 1, 1, 1, 1, 1, 1, 2]
        case .waving: ticks = [1, 1, 1, 2]
        case .jumping: ticks = [1, 1, 1, 1, 2]
        case .waiting, .review, .listening, .speaking: ticks = [2, 2, 2, 2, 2, 3]
        case .working: ticks = [1, 1, 1, 1, 1, 2]
        case .lookFirst, .lookSecond: ticks = Array(repeating: 1, count: 8)
        }
        return ticks.map { $0 * CompanionSteppedMotion.frameMilliseconds }
    }

    static func row(for pose: CompanionCharacterPose) -> CompanionSpriteRow {
        switch pose {
        case .idle, .queued, .paused, .unavailable: .idle
        case .greeting: .waving
        case .working: .working
        case .listening: .listening
        case .speaking: .speaking
        case .needsApproval: .waiting
        case .completed: .jumping
        case .failed: .failed
        }
    }
}

/// One transform for the whole atlas, measured from its actual artwork rather
/// than the transparent cell. Never normalize individual animation frames:
/// a jump, bow, or turn must retain its original change in pose and position.
struct CompanionSpriteLayout {
    static let restingHeightFraction: CGFloat = 0.78
    static let safetyInsetFraction: CGFloat = 0.04
    let referenceBounds: CGRect
    let contentBounds: CGRect
    private let scale: CGFloat
    private let origin: CGPoint

    init(referenceBounds: CGRect, contentBounds: CGRect) {
        self.referenceBounds = referenceBounds
        self.contentBounds = contentBounds
        let available = 1 - 2 * Self.safetyInsetFraction
        scale = min(Self.restingHeightFraction / referenceBounds.height,
                    available / contentBounds.width, available / contentBounds.height)
        // Align resting feet, then reserve room for every state, accessory,
        // faint shadow, and directional look pose without cropping artwork.
        let desired = CGPoint(x: 0.5 - referenceBounds.midX * scale,
                              y: 0.88 - referenceBounds.maxY * scale)
        origin = CGPoint(
            x: min(max(desired.x, Self.safetyInsetFraction - contentBounds.minX * scale),
                   1 - Self.safetyInsetFraction - contentBounds.maxX * scale),
            y: min(max(desired.y, Self.safetyInsetFraction - contentBounds.minY * scale),
                   1 - Self.safetyInsetFraction - contentBounds.maxY * scale))
    }

    func displayBounds(for sourceBounds: CGRect, in size: CGSize) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let edge = min(size.width, size.height)
        return CGRect(x: (size.width - edge) / 2 + (origin.x + sourceBounds.minX * scale) * edge,
                      y: (size.height - edge) / 2 + (origin.y + sourceBounds.minY * scale) * edge,
                      width: sourceBounds.width * scale * edge, height: sourceBounds.height * scale * edge)
    }

    func imageFrame(in size: CGSize) -> CGRect {
        displayBounds(for: CGRect(x: 0, y: 0, width: CompanionSpriteAtlas.cellWidth,
                                  height: CompanionSpriteAtlas.cellHeight), in: size)
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
    let layout: CompanionSpriteLayout
    private let frames: [CompanionSpriteRow: [CGImage]]
    private var timings: [CompanionSpriteRow: [Int]] = [:]

    enum ValidationError: Error { case invalidType, invalidDimensions, invalidTransparency, invalidFrame }

    init(data: Data, pack: CompanionAnimationPack? = nil) throws {
        guard !data.isEmpty, data.count <= Self.maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.webP.identifier].contains(sourceType),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ValidationError.invalidType }
        guard width == 1_536,
              pack == nil ? (height == 1_872 || height == 2_288)
                : (height > 0 && height <= 2_704 && height % Self.cellHeight == 0) else { throw ValidationError.invalidDimensions }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              [.premultipliedLast, .premultipliedFirst, .last, .first].contains(image.alphaInfo) else {
            throw ValidationError.invalidTransparency
        }
        version = height == 2_288 ? 2 : 1
        pixelWidth = width; pixelHeight = height
        var cells: [CompanionSpriteRow: [CGImage]] = [:]
        var referenceBounds: CGRect?
        var contentBounds = CGRect.null
        let rows: [(CompanionSpriteRow, Int, Int, [Int])]
        if let pack {
            rows = pack.animations.compactMap { name, animation in
                guard let row = CompanionAnimationPack.stateRows[name] else { return nil }
                return (row, animation.row, animation.frameCount,
                        Array(repeating: animation.frameMilliseconds, count: animation.frameCount))
            }
        } else {
            rows = CompanionSpriteRow.allCases.filter { $0.rawValue < height / Self.cellHeight }
                .map { ($0, $0.rawValue, $0.frameCount, $0.frameDurations) }
        }
        for (row, sourceRow, count, durations) in rows {
            guard sourceRow >= 0, sourceRow < height / Self.cellHeight, (1...8).contains(count) else { throw ValidationError.invalidFrame }
            timings[row] = durations
            cells[row] = try (0..<count).map { column in
                let rect = CGRect(x: column * Self.cellWidth, y: sourceRow * Self.cellHeight,
                    width: Self.cellWidth, height: Self.cellHeight)
                guard let cell = image.cropping(to: rect), let bounds = Self.alphaBounds(in: cell) else {
                    throw ValidationError.invalidFrame
                }
                if row == .idle, column == 0 { referenceBounds = bounds.art }
                contentBounds = contentBounds.union(bounds.content)
                return cell
            }
        }
        guard let referenceBounds else { throw ValidationError.invalidFrame }
        frames = cells
        layout = CompanionSpriteLayout(referenceBounds: referenceBounds, contentBounds: contentBounds)
    }

    private static func alphaBounds(in image: CGImage) -> (art: CGRect, content: CGRect)? {
        // Decode into an explicit byte layout once per cached cell, rather than
        // depending on ImageIO's source color space or premultiplication format.
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var art = CGRect.null
            var content = CGRect.null
            for y in 0..<image.height {
                var firstContent = image.width, lastContent = -1
                var firstArt = image.width, lastArt = -1
                for x in 0..<image.width {
                    let alpha = bytes[(y * image.width + x) * 4 + 3]
                    if alpha > 0 { firstContent = min(firstContent, x); lastContent = x }
                    if alpha > 32 { firstArt = min(firstArt, x); lastArt = x }
                }
                if lastContent >= firstContent {
                    content = content.union(CGRect(x: firstContent, y: y, width: lastContent - firstContent + 1, height: 1))
                }
                if lastArt >= firstArt {
                    art = art.union(CGRect(x: firstArt, y: y, width: lastArt - firstArt + 1, height: 1))
                }
            }
            guard !art.isNull else { return nil }
            return (art, content)
        }
    }

    func frame(row: CompanionSpriteRow, index: Int) -> CGImage? {
        if (row == .lookFirst || row == .lookSecond), frames[row] == nil { return nil }
        let rowFrames = frames[row] ?? frames[.idle] ?? []
        guard rowFrames.indices.contains(index) else { return nil }
        return rowFrames[index]
    }

    func frameDurations(for row: CompanionSpriteRow) -> [Int] {
        timings[row] ?? timings[.idle] ?? [2_000]
    }
    var frameCount: Int { frames.values.reduce(0) { $0 + $1.count } }

    func lookFrame(for pointer: CompanionPointerResponse, pose: CompanionCharacterPose,
                   canAnimate: Bool) -> (row: CompanionSpriteRow, index: Int)? {
        guard version == 2, frames[.lookFirst] != nil, frames[.lookSecond] != nil, CompanionPointerResponse.allowsReaction(canAnimate: canAnimate, pose: pose),
              let direction = pointer.directionIndex else { return nil }
        return (direction < 8 ? .lookFirst : .lookSecond, direction % 8)
    }
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
/// Directional v2 cells are held poses selected by the pointer, never an animation loop.
struct CompanionSpriteView: View {
    let atlas: CompanionSpriteAtlas
    let pose: CompanionCharacterPose
    let canAnimate: Bool
    var pointer: CompanionPointerResponse = .neutral
    var onGreetingCompleted: () -> Void = {}
    @State private var activeRow: CompanionSpriteRow = .idle
    @State private var frameIndex = 0
    @State private var activeKey: String?

    private var lookFrame: (row: CompanionSpriteRow, index: Int)? {
        atlas.lookFrame(for: pointer, pose: pose, canAnimate: canAnimate)
    }
    private var playbackKey: String { "\(pose.rawValue)-\(canAnimate)-\(lookFrame != nil)" }
    private var requestedRow: CompanionSpriteRow { .row(for: pose) }
    private var displayedRow: CompanionSpriteRow { lookFrame?.row ?? (activeKey == playbackKey ? activeRow : requestedRow) }
    private var displayedFrame: Int { lookFrame?.index ?? (activeKey == playbackKey ? frameIndex : 0) }

    var body: some View {
        GeometryReader { geometry in
            if let frame = atlas.frame(row: displayedRow, index: displayedFrame) {
                let imageFrame = atlas.layout.imageFrame(in: geometry.size)
                Image(decorative: frame, scale: 1).resizable().interpolation(.high)
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
            }
        }
        // Source cells change discretely even if surrounding navigation uses
        // an animated SwiftUI transaction. The original raster art stays intact.
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
        .task(id: playbackKey) { await play() }
    }

    @MainActor private func play() async {
        activeKey = playbackKey
        activeRow = requestedRow
        frameIndex = 0
        guard canAnimate, lookFrame == nil else { return }
        do {
            if pose == .greeting || pose == .completed || pose == .failed {
                try await playOnce(requestedRow)
                if pose == .greeting { onGreetingCompleted() }
                if pose == .failed { return }
                activeRow = .idle
            }
            while !Task.isCancelled { try await playOnce(activeRow) }
        } catch { /* Visibility, state, and disappearance cancel the view task. */ }
    }

    @MainActor private func playOnce(_ row: CompanionSpriteRow) async throws {
        activeRow = row
        for (index, duration) in atlas.frameDurations(for: row).enumerated() {
            try Task.checkCancellation()
            frameIndex = index
            try await Task.sleep(for: .milliseconds(duration))
        }
    }
}
