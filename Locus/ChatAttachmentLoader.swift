import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum ChatAttachmentLoader {
    static func readChatAttachments(
        _ selected: [URL],
        excluding existing: Set<URL>
    ) -> ChatAttachmentLoadResult {
        let directImageTypes = [
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "gif": "image/gif",
            "webp": "image/webp",
        ]
        var attachments: [ChatAttachment] = []
        var unsupported = 0
        var oversized = 0
        var unreadable = 0
        var truncatedPDFs = 0
        var totalImageBytes = 0
        var totalTextBytes = 0

        for selectedURL in selected {
            let url = selectedURL.standardizedFileURL
            guard !existing.contains(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else {
                unsupported += 1
                continue
            }
            let size = values?.fileSize ?? 0
            let ext = url.pathExtension.lowercased()

            if ext == "pdf" {
                guard size <= 10_000_000, totalTextBytes < 750_000 else {
                    oversized += 1
                    continue
                }
                guard let document = PDFDocument(url: url),
                      let rawText = document.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawText.isEmpty
                else {
                    unreadable += 1
                    continue
                }
                let remaining = max(750_000 - totalTextBytes, 0)
                let content = String(rawText.prefix(min(500_000, remaining)))
                if content.count < rawText.count { truncatedPDFs += 1 }
                totalTextBytes += content.utf8.count
                attachments.append(
                    ChatAttachment(url: url, kind: .text, textContent: content)
                )
                continue
            }

            let type = UTType(filenameExtension: ext)
            if type?.conforms(to: .image) == true {
                guard size <= 15_000_000, totalImageBytes < 25_000_000 else {
                    oversized += 1
                    continue
                }
                let imageData: Data?
                let mimeType: String?
                if let directMIME = directImageTypes[ext] {
                    imageData = try? Data(contentsOf: url, options: .mappedIfSafe)
                    mimeType = directMIME
                } else if let image = NSImage(contentsOf: url),
                          let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let jpeg = bitmap.representation(
                              using: .jpeg,
                              properties: [.compressionFactor: 0.88]
                          ) {
                    imageData = jpeg
                    mimeType = "image/jpeg"
                } else {
                    imageData = nil
                    mimeType = nil
                }
                guard let imageData, let mimeType,
                      imageData.count <= 15_000_000,
                      totalImageBytes + imageData.count <= 25_000_000
                else {
                    unreadable += 1
                    continue
                }
                totalImageBytes += imageData.count
                attachments.append(
                    ChatAttachment(
                        url: url,
                        kind: .image,
                        imageData: imageData,
                        mimeType: mimeType
                    )
                )
                continue
            }

            if ContextFileTypes.allowedExtensions.contains(ext)
                || type?.conforms(to: .text) == true {
                guard size <= 500_000,
                      totalTextBytes + size <= 750_000
                else {
                    oversized += 1
                    continue
                }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let content = String(data: data, encoding: .utf8),
                      !content.isEmpty
                else {
                    unreadable += 1
                    continue
                }
                totalTextBytes += data.count
                attachments.append(
                    ChatAttachment(url: url, kind: .text, textContent: content)
                )
                continue
            }

            unsupported += 1
        }

        var warnings: [String] = []
        if unsupported > 0 { warnings.append("\(unsupported) unsupported") }
        if oversized > 0 { warnings.append("\(oversized) over the size limit") }
        if unreadable > 0 { warnings.append("\(unreadable) unreadable") }
        if truncatedPDFs > 0 { warnings.append("\(truncatedPDFs) PDF truncated") }
        let notice = warnings.isEmpty ? nil : "Skipped or limited: \(warnings.joined(separator: ", "))."
        return ChatAttachmentLoadResult(attachments: attachments, notice: notice)
    }
}
