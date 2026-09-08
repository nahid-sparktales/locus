import AppKit
import ImageIO
import os
import SwiftUI

private let artifactThumbnailSignposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "io.sparktales.locus",
    category: "Artifact Thumbnails"
)

@MainActor
final class ArtifactThumbnailStore {
    static let shared = ArtifactThumbnailStore()
    static let cacheItemLimit = 128
    static let cacheCostLimit = 128 * 1_024 * 1_024

    private struct DecodedThumbnail: @unchecked Sendable {
        let image: NSImage
        let cost: Int
    }

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = cacheItemLimit
        cache.totalCostLimit = cacheCostLimit
        return cache
    }()
    private var inFlight: [String: Task<DecodedThumbnail?, Never>] = [:]
    private(set) var decodeCountForTesting = 0

    func resetForTesting() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        cache.removeAllObjects()
        decodeCountForTesting = 0
    }

    func image(
        for sourceURL: URL,
        maximumDisplaySize: CGSize = CGSize(width: 620, height: 420),
        displayScale: CGFloat
    ) async -> NSImage? {
        let descriptor = await Task.detached(priority: .utility) {
            let url = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            let scale = max(displayScale, 1)
            let maximumPixelSize = Int(
                ceil(max(maximumDisplaySize.width, maximumDisplaySize.height) * scale)
            )
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let key = "\(url.path)|\(values?.fileSize ?? -1)|\(modified)|\(scale)|\(maximumPixelSize)"
            return (url, key, maximumPixelSize)
        }.value

        let cacheKey = descriptor.1 as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let task: Task<DecodedThumbnail?, Never>
        if let existing = inFlight[descriptor.1] {
            task = existing
        } else {
            let url = descriptor.0
            let maximumPixelSize = descriptor.2
            decodeCountForTesting += 1
            task = Task.detached(priority: .userInitiated) {
                let signpostID = artifactThumbnailSignposter.makeSignpostID()
                let interval = artifactThumbnailSignposter.beginInterval(
                    "Decode Thumbnail",
                    id: signpostID
                )
                defer {
                    artifactThumbnailSignposter.endInterval("Decode Thumbnail", interval)
                }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    return nil
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options as CFDictionary
                ) else { return nil }
                return DecodedThumbnail(
                    image: NSImage(cgImage: image, size: .zero),
                    cost: image.bytesPerRow * image.height
                )
            }
            inFlight[descriptor.1] = task
        }
        let decoded = await task.value
        inFlight.removeValue(forKey: descriptor.1)
        guard let decoded, !Task.isCancelled else { return nil }
        cache.setObject(decoded.image, forKey: cacheKey, cost: decoded.cost)
        return decoded.image
    }
}

/// An extra control a host places beside the standard Open and Reveal
/// actions of an inline workspace image. `items` turns the entry into an
/// overflow menu instead of a single button.
struct WorkspaceImageAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var items: [WorkspaceImageAction]? = nil
    var action: () -> Void = {}
}

struct AsyncWorkspaceImageArtifactView: View {
    @Environment(\.displayScale) private var displayScale
    let reference: WorkspaceArtifactReference
    let caption: String
    let selectionStore: TranscriptSelectionStore?
    let selectionSpan: TranscriptSelectionSpan?
    let onOpen: () -> Void
    var additionalActions: [WorkspaceImageAction] = []
    /// When set, every control is identifiable as `<prefix>.<action>` so a
    /// host card can be exercised without exposing its internals.
    var accessibilityIdentifierPrefix: String? = nil
    @State private var image: NSImage?
    @State private var imageLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: onOpen) {
            Group {
                if let image {
                    SwiftUI.Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ZStack {
                        LocusTheme.paperDeep
                        if imageLoaded {
                            Label("Open image preview", systemImage: "photo")
                                .foregroundStyle(LocusTheme.textSecondary)
                        } else { ProgressView().controlSize(.small) }
                    }
                    .frame(height: 160)
                }
            }
            .frame(maxWidth: 620, maxHeight: 420, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.line.opacity(0.8), lineWidth: 1)
            }
            }.buttonStyle(.locus())
                .help("Open a larger image with zoom controls")
                .accessibilityLabel("Preview image, \(reference.relativePath)")
                .accessibilityIdentifier(identifier("preview"))

            HStack(spacing: 8) {
                if let selectionStore, let selectionSpan {
                    ResponseSelectableText(
                        attributedText: MarkdownNativeText.plain(
                            caption,
                            font: .systemFont(ofSize: 11, weight: .medium),
                            color: NSColor(LocusTheme.muted),
                            lineSpacing: 0
                        ),
                        span: selectionSpan,
                        store: selectionStore
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } else if !caption.isEmpty {
                    Text(caption)
                        .font(.locus(size: 11, weight: .medium))
                        .foregroundStyle(LocusTheme.muted)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                ForEach(additionalActions) { entry in
                    if let items = entry.items {
                        Menu {
                            ForEach(items) { item in
                                Button(item.title, action: item.action)
                                    .accessibilityIdentifier(identifier(item.id))
                            }
                        } label: {
                            Label(entry.title, systemImage: entry.symbol)
                                .font(.locus(size: 11, weight: .semibold))
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityLabel("\(entry.title) \(reference.relativePath)")
                        .accessibilityIdentifier(identifier(entry.id))
                    } else {
                        artifactAction(entry.title, symbol: entry.symbol, id: entry.id, action: entry.action)
                    }
                }
                artifactAction("Open", symbol: "arrow.up.forward.app", id: "open", action: onOpen)
                artifactAction("Reveal", symbol: "folder", id: "reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([reference.url])
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image artifact, \(reference.relativePath)")
        .task(id: "\(reference.url.path)|\(displayScale)") {
            image = nil
            imageLoaded = false
            let loaded = await ArtifactThumbnailStore.shared.image(
                for: reference.url,
                displayScale: displayScale
            )
            guard !Task.isCancelled else { return }
            image = loaded
            imageLoaded = true
        }
    }

    private func artifactAction(
        _ title: String,
        symbol: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.locus(size: 11, weight: .semibold))
        }
        .buttonStyle(.locus())
        .foregroundStyle(LocusTheme.muted)
        .accessibilityLabel("\(title) \(reference.relativePath)")
        .accessibilityIdentifier(identifier(id))
    }

    /// Identifiers only exist for a host that asked for them; the Markdown
    /// path keeps its anonymous controls.
    private func identifier(_ suffix: String) -> String {
        accessibilityIdentifierPrefix.map { "\($0).\(suffix)" } ?? ""
    }
}
