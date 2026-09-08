import AppKit
import Foundation

@MainActor
final class ChatExportAccessoryView: NSView {
    let reasoning = NSButton(checkboxWithTitle: "Include reasoning", target: nil, action: nil)
    let tools = NSButton(checkboxWithTitle: "Include full tool details", target: nil, action: nil)
    let attachments = NSButton(checkboxWithTitle: "Include attachments", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        attachments.state = .on
        let stack = NSStackView(views: [attachments, reasoning, tools])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        frame.size = NSSize(width: 260, height: 80)
    }

    required init?(coder: NSCoder) { nil }

    var options: ChatExportOptions {
        ChatExportOptions(
            includeReasoning: reasoning.state == .on,
            includeToolDetails: tools.state == .on,
            includeAttachments: attachments.state == .on
        )
    }
}

@MainActor
enum ChatExportRenderer {
    private static let exportedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func write(_ document: ChatExportDocument, format: ChatExportFormat, to url: URL) throws {
        switch format {
        case .markdown:
            try writeMarkdown(document, to: url)
        case .plainText:
            try plainText(document).write(to: url, atomically: true, encoding: .utf8)
        case .pdf:
            try writePDF(document, to: url)
        }
    }

    private static func writeMarkdown(_ document: ChatExportDocument, to url: URL) throws {
        let fileManager = FileManager.default
        var assetDirectory: URL?
        var assetDirectoryName: String?
        let attachments = document.messages.flatMap { $0.attachments ?? [] }
        let hasParts = document.messages.contains {
            !ResponseExportProjection.imageParts($0).isEmpty || !ResponseExportProjection.interactiveParts($0).isEmpty
        }
        if !attachments.isEmpty || hasParts {
            let candidate = try makeAssetDirectory(for: url)
            assetDirectory = candidate
            assetDirectoryName = candidate.lastPathComponent
        }

        do {
            var lines = metadataLines(document, markdown: true)
            var attachmentIndex = 0
            for message in document.messages {
                lines.append(markdownHeading(for: message))
                lines.append("")
                var content = message.content
                var trailing: [String] = []
                // Typed parts first: an image replaces the backend's exact
                // fallback link in place so the reader sees the sidecar copy
                // where the picture was, and anything unmatched follows the
                // prose the way attachments do.
                for part in ResponseExportProjection.imageParts(message) {
                    attachmentIndex += 1
                    let replacement: String
                    if let source = ResponseExportProjection.imageFileURL(for: part),
                       let data = try? Data(contentsOf: source),
                       let assetDirectory, let assetDirectoryName {
                        let name = uniqueAttachmentName(source.lastPathComponent,
                            mimeType: "image/\(part.format ?? "png")", index: attachmentIndex)
                        try data.write(to: assetDirectory.appendingPathComponent(name), options: .atomic)
                        replacement = "![\(ResponseExportProjection.markdownLabel(ResponseExportProjection.imageLabel(for: part)))](\(assetDirectoryName)/\(name))"
                    } else {
                        replacement = ResponseExportProjection.unavailableImageLine(for: part)
                    }
                    let link = ResponseExportProjection.fallbackImageLink(for: part)
                    if content.contains(link) {
                        content = content.replacingOccurrences(of: link, with: replacement)
                    } else {
                        trailing.append(replacement)
                    }
                }
                for part in ResponseExportProjection.interactiveParts(message) {
                    guard let assetDirectory, let assetDirectoryName else { continue }
                    attachmentIndex += 1
                    let name = ResponseExportProjection.interactiveFileName(for: part, index: attachmentIndex)
                    try ResponseExportProjection.interactiveDocument(for: part)
                        .write(to: assetDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                    trailing.append(ResponseExportProjection.interactiveLink(for: part, directory: assetDirectoryName, name: name))
                }
                if message.role == "tool" {
                    lines.append("```")
                    lines.append(content)
                    lines.append("```")
                } else {
                    lines.append(content)
                }
                for line in trailing {
                    lines.append("")
                    lines.append(line)
                }
                if let reasoning = resolvedReasoning(for: message) {
                    lines.append("")
                    lines.append("<details><summary>Reasoning</summary>")
                    lines.append("")
                    lines.append(reasoning)
                    lines.append("")
                    lines.append("</details>")
                }
                for attachment in message.attachments ?? [] {
                    attachmentIndex += 1
                    guard let data = decodedAttachmentData(attachment.data),
                          let assetDirectory, let assetDirectoryName
                    else { continue }
                    let name = uniqueAttachmentName(
                        attachment.name,
                        mimeType: attachment.mimeType,
                        index: attachmentIndex
                    )
                    try data.write(to: assetDirectory.appendingPathComponent(name), options: .atomic)
                    lines.append("")
                    lines.append("![\(markdownEscaped(attachment.name))](\(assetDirectoryName)/\(name))")
                }
                lines.append("")
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            if let assetDirectory {
                try? fileManager.removeItem(at: assetDirectory)
            }
            throw error
        }
    }

    /// The sidecar folder beside an export that carries its binary assets.
    /// Never reuses an existing folder, so a repeated export cannot mix files.
    private static func makeAssetDirectory(for url: URL) throws -> URL {
        let fileManager = FileManager.default
        let base = url.deletingPathExtension().lastPathComponent + "-assets"
        let parent = url.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    private static func plainText(_ document: ChatExportDocument) -> String {
        var lines = metadataLines(document, markdown: false)
        for message in document.messages {
            lines.append(textHeading(for: message))
            lines.append(plainContent(for: message))
            if let reasoning = resolvedReasoning(for: message) {
                lines.append("Reasoning:")
                lines.append(reasoning)
            }
            for attachment in message.attachments ?? [] {
                lines.append("[Attachment: \(attachment.name) — \(attachment.mimeType)]")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Message text for the text-only formats: the backend's image link is
    /// replaced by a readable line, and an image the prose never mentioned is
    /// listed after it. Interactive parts already appear as title + summary.
    private static func plainContent(for message: ChatExportMessage) -> String {
        var content = message.content
        var trailing: [String] = []
        for part in ResponseExportProjection.imageParts(message) {
            let link = ResponseExportProjection.fallbackImageLink(for: part)
            let line = ResponseExportProjection.plainTextImageLine(for: part)
            if content.contains(link) {
                content = content.replacingOccurrences(of: link, with: line)
            } else {
                trailing.append(line)
            }
        }
        return ([content] + trailing).joined(separator: "\n\n")
    }

    private static func writePDF(_ document: ChatExportDocument, to url: URL) throws {
        let contentWidth: CGFloat = 504
        let storage = NSTextStorage(attributedString: attributedDocument(document, width: contentWidth))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 1), textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = max(1, layoutManager.usedRect(for: container).height + 12)
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: height)

        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobDisposition] = NSPrintInfo.JobDisposition.save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func attributedDocument(_ document: ChatExportDocument, width: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let title = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let heading = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let body = NSFont.systemFont(ofSize: 11)
        let detail = NSFont.systemFont(ofSize: 9.5)
        let mono = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        // Exported pages are light paper even when the workspace is dark.
        let secondary = LocusTheme.lightPalette.muted

        func append(_ value: String, font: NSFont, color: NSColor = LocusTheme.lightPalette.inkSoft, spacing: CGFloat = 5) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = spacing
            paragraph.lineSpacing = 2
            result.append(NSAttributedString(string: value, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]))
        }

        func appendImage(_ image: NSImage, name: String, width: CGFloat) {
            let attachmentCell = NSTextAttachmentCell(imageCell: image)
            let original = image.size
            let scale = min(1, width / max(original.width, 1), 320 / max(original.height, 1))
            attachmentCell.image?.size = NSSize(width: original.width * scale, height: original.height * scale)
            let textAttachment = NSTextAttachment()
            textAttachment.attachmentCell = attachmentCell
            result.append(NSAttributedString(attachment: textAttachment))
            append("\n\(name)\n", font: detail, color: secondary, spacing: 9)
        }

        append(document.title + "\n", font: title, spacing: 10)
        let metadata = metadataLines(document, markdown: false).dropFirst(2).joined(separator: "\n")
        append(metadata + "\n\n", font: detail, color: secondary, spacing: 9)
        for message in document.messages {
            append(textHeading(for: message) + "\n", font: heading, spacing: 3)
            append(plainContent(for: message) + "\n", font: message.role == "tool" ? mono : body, spacing: 8)
            if let reasoning = resolvedReasoning(for: message) {
                append("Reasoning\n", font: heading, color: secondary, spacing: 2)
                append(reasoning + "\n", font: detail, color: secondary, spacing: 8)
            }
            for part in ResponseExportProjection.imageParts(message) {
                guard let source = ResponseExportProjection.imageFileURL(for: part),
                      let image = NSImage(contentsOf: source)
                else {
                    append(ResponseExportProjection.unavailableImageLine(for: part) + "\n", font: detail, color: secondary)
                    continue
                }
                appendImage(image, name: part.imageTitle, width: width)
            }
            for attachment in message.attachments ?? [] {
                guard let data = decodedAttachmentData(attachment.data),
                      let image = NSImage(data: data)
                else {
                    append("[Attachment: \(attachment.name)]\n", font: detail, color: secondary)
                    continue
                }
                appendImage(image, name: attachment.name, width: width)
            }
            append("\n", font: body, spacing: 4)
        }
        return result
    }

    private static func metadataLines(_ document: ChatExportDocument, markdown: Bool) -> [String] {
        let titlePrefix = markdown ? "# " : ""
        let bullet = markdown ? "- " : ""
        return [
            titlePrefix + document.title,
            "",
            bullet + "Exported: \(exportedAtFormatter.string(from: Date()))",
            bullet + "Started: \(document.started?.nilIfEmpty ?? "Unknown")",
            bullet + "Model: \(document.model?.nilIfEmpty ?? "Unknown")",
            bullet + "Provider: \(document.provider?.nilIfEmpty ?? "Unknown")",
            bullet + "Workspace: \(document.cwd?.nilIfEmpty ?? "Unknown")",
            bullet + "Session: \(document.id)",
            "",
        ]
    }

    private static func markdownHeading(for message: ChatExportMessage) -> String {
        switch message.role {
        case "user": "## You"
        case "assistant": message.phase == .commentary ? "## Locus — Commentary" : "## Locus"
        case "tool": "### Tool: \(message.name?.nilIfEmpty ?? "tool")"
        default: "## \(message.role.capitalized)"
        }
    }

    private static func textHeading(for message: ChatExportMessage) -> String {
        switch message.role {
        case "user": "YOU"
        case "assistant": message.phase == .commentary ? "LOCUS — COMMENTARY" : "LOCUS"
        case "tool": "TOOL — \(message.name?.nilIfEmpty ?? "tool")"
        default: message.role.uppercased()
        }
    }

    private static func resolvedReasoning(for message: ChatExportMessage) -> String? {
        let sections = (message.reasoningSections ?? []).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !sections.isEmpty { return sections.joined(separator: "\n\n") }
        return message.reasoning?.nilIfEmpty
    }

    private static func decodedAttachmentData(_ value: String) -> Data? {
        let payload = value.range(of: ",").map { String(value[$0.upperBound...]) } ?? value
        return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
    }

    private static func uniqueAttachmentName(_ value: String, mimeType: String, index: Int) -> String {
        let fallbackExtension: String = switch mimeType {
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "png"
        }
        let input = URL(fileURLWithPath: value)
        let stem = input.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"[^a-zA-Z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let ext = input.pathExtension.nilIfEmpty ?? fallbackExtension
        return String(format: "%03d-%@.%@", index, stem.nilIfEmpty ?? "attachment", ext)
    }

    private static func markdownEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}
