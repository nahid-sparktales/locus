import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Private document work never enters DocumentStore, a workspace, or the agent's chat transport.
enum IdentityVaultDocuments {
    static let maximumSourceBytes = 100 * 1_024 * 1_024
    static let maximumTextBytes = 5 * 1_024 * 1_024
    private static let maximumWireBytes = 150 * 1_024 * 1_024

    static func importDocument(url: URL, runtimeRoot: String = "") async throws -> IdentityVaultImportedDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard properties.isRegularFile == true, (properties.fileSize ?? maximumSourceBytes + 1) <= maximumSourceBytes else {
            throw IdentityVaultError.tooLarge
        }
        let data = try Data(contentsOf: url)
        return try await extract(data: data, name: url.lastPathComponent, runtimeRoot: runtimeRoot)
    }

    static func extract(data: Data, name: String, runtimeRoot: String = "") async throws -> IdentityVaultImportedDocument {
        guard !data.isEmpty, data.count <= maximumSourceBytes else { throw IdentityVaultError.tooLarge }
        try Task.checkCancellation()
        let ext = (name as NSString).pathExtension.lowercased()
        let mimeType: String
        let text: String
        switch ext {
        case "pdf":
            mimeType = "application/pdf"
            text = try await localExtraction { try extractPDF(data) }
        case "docx":
            mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            let result = try await runHelper(
                ["protocol_version": 1, "action": "extract_docx", "data_base64": data.base64EncodedString()],
                runtimeRoot: runtimeRoot
            )
            guard let value = result["text"] as? String else { throw IdentityVaultError.extractionFailed }
            text = value
        case "txt", "text":
            mimeType = "text/plain"
            guard let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw IdentityVaultError.extractionFailed
            }
            text = value
        case "png", "jpg", "jpeg", "heic", "heif":
            mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/jpeg"
            text = try await localExtraction { try recognizeImage(data) }
        default: throw IdentityVaultError.unsupportedDocument
        }
        try Task.checkCancellation()
        guard text.utf8.count <= maximumTextBytes else { throw IdentityVaultError.tooLarge }
        return .init(name: name, mimeType: mimeType, data: data, extractedText: text)
    }

    /// Suggestions are intentionally small and deterministic; a person reviews them before profile changes.
    static func suggestedFields(from text: String) -> [IdentityVaultField] {
        let text = String(text.prefix(100_000))
        var fields: [IdentityVaultField] = []
        if let firstLine = text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let candidate = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = candidate.split(whereSeparator: \.isWhitespace)
            if (2...5).contains(words.count), candidate.count <= 100,
               candidate.rangeOfCharacter(from: .decimalDigits) == nil,
               !candidate.contains("@"), !candidate.contains(":"),
               !["resume", "résumé", "curriculum", "summary", "experience"].contains(where: { candidate.lowercased().contains($0) }) {
                fields.append(.init(key: "full_name", label: "Full name", value: candidate))
            }
        }
        func firstMatch(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
        if let email = firstMatch("[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}") {
            fields.append(.init(key: "email", label: "Email", value: email, kind: .email))
        }
        if let phone = firstMatch("(?<![0-9])(?:\\+?[0-9]{1,3}[ .-]?)?(?:\\([0-9]{3}\\)|[0-9]{3})[ .-]?[0-9]{3}[ .-]?[0-9]{4}(?![0-9])") {
            fields.append(.init(key: "phone", label: "Phone", value: phone, kind: .phone))
        }
        if let linkedIn = firstMatch("(?:https?://)?(?:www\\.)?linkedin\\.com/in/[A-Z0-9_-]+/?") {
            fields.append(.init(key: "linkedin", label: "LinkedIn", value: linkedIn, kind: .url))
        }
        let headingKeys: [(String, String, String)] = [
            ("summary|professional summary|profile|objective", "professional_summary", "Professional summary"),
            ("skills|technical skills|core competencies", "skills", "Skills"),
            ("experience|work experience|employment|professional experience", "employment_1", "Employment 1"),
            ("education|academic background", "education_1", "Education 1"),
            ("certifications|licenses and certifications", "certifications", "Certifications"),
        ]
        let lines = text.components(separatedBy: .newlines)
        var current: (key: String, label: String)?
        var content: [String] = []
        func flush() {
            guard let current else { return }
            let value = content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !fields.contains(where: { $0.key == current.key }) else { return }
            fields.append(.init(key: current.key, label: current.label, value: value, kind: .multiline))
        }
        for line in lines {
            let heading = line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if let match = headingKeys.first(where: { heading.range(of: "^(?:\($0.0))$", options: [.regularExpression, .caseInsensitive]) != nil }) {
                flush()
                current = (match.1, match.2)
                content = []
            } else if current != nil { content.append(line) }
        }
        flush()
        return fields
    }

    /// Creates real paginated PDF bytes in memory; no print spool or temporary plaintext PDF.
    @MainActor
    static func generatePDF(
        title: String, sections: [IdentityVaultDocumentSection], signatureData: Data? = nil
    ) throws -> Data {
        try validateGeneration(title: title, sections: sections)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 9
        paragraph.lineSpacing = 2
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
        ]
        let attributed = NSMutableAttributedString(string: title + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.black,
        ])
        for section in sections {
            if !section.heading.isEmpty {
                attributed.append(NSAttributedString(string: section.heading + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black,
                ]))
            }
            attributed.append(NSAttributedString(string: section.text + "\n\n", attributes: body))
        }
        var signature: CGImage?
        if let signatureData {
            guard signatureData.count <= maximumSourceBytes,
                  let source = CGImageSourceCreateWithData(signatureData as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { throw IdentityVaultError.extractionFailed }
            signature = image
        }
        let bytes = NSMutableData()
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData) else { throw IdentityVaultError.extractionFailed }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw IdentityVaultError.extractionFailed }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let bottom: CGFloat = signature == nil ? 54 : 145
        let textBox = CGRect(x: 54, y: bottom, width: 504, height: 792 - bottom - 54)
        var offset = 0
        var pages = 0
        while offset < attributed.length {
            guard pages < 500 else { throw IdentityVaultError.tooLarge }
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), CGPath(rect: textBox, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw IdentityVaultError.extractionFailed }
            CTFrameDraw(frame, context)
            offset += visible.length
            if offset >= attributed.length, let signature {
                let scale = min(220 / CGFloat(signature.width), 72 / CGFloat(signature.height))
                context.draw(signature, in: CGRect(x: 54, y: 54, width: CGFloat(signature.width) * scale, height: CGFloat(signature.height) * scale))
            }
            context.endPDFPage()
            pages += 1
        }
        context.closePDF()
        guard bytes.length <= maximumSourceBytes else { throw IdentityVaultError.tooLarge }
        return bytes as Data
    }

    static func generateDOCX(title: String, sections: [IdentityVaultDocumentSection], runtimeRoot: String = "") async throws -> Data {
        try validateGeneration(title: title, sections: sections)
        let result = try await runHelper([
            "protocol_version": 1, "action": "generate_docx", "title": title,
            "sections": sections.map { ["heading": $0.heading, "text": $0.text] },
        ], runtimeRoot: runtimeRoot)
        guard let encoded = result["data_base64"] as? String, let data = Data(base64Encoded: encoded),
              !data.isEmpty, data.count <= maximumSourceBytes else { throw IdentityVaultError.extractionFailed }
        return data
    }

    private static func validateGeneration(title: String, sections: [IdentityVaultDocumentSection]) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 255 else { throw IdentityVaultError.invalidRecord }
        guard sections.count <= 500,
              title.utf8.count + sections.reduce(0, { $0 + $1.heading.utf8.count + $1.text.utf8.count }) <= maximumTextBytes else { throw IdentityVaultError.tooLarge }
    }

    private static func extractPDF(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount <= 500 else {
            throw IdentityVaultError.extractionFailed
        }
        var pages: [String] = []
        var size = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, let pageRef = page.pageRef {
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw IdentityVaultError.extractionFailed }
                let scale = min(2, 2400 / max(bounds.width, bounds.height))
                let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
                guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw IdentityVaultError.extractionFailed }
                let target = CGRect(x: 0, y: 0, width: width, height: height)
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(target)
                bitmap.concatenate(pageRef.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
                bitmap.drawPDFPage(pageRef)
                if let image = bitmap.makeImage() { text = try recognize(image) }
            }
            size += text.utf8.count + 2
            guard size <= maximumTextBytes else { throw IdentityVaultError.tooLarge }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }

    private static func recognizeImage(_ data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { throw IdentityVaultError.extractionFailed }
        return try recognize(image)
    }

    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image).perform([request]) }
        catch { throw IdentityVaultError.extractionFailed }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard text.utf8.count <= maximumTextBytes else { throw IdentityVaultError.tooLarge }
        return text
    }

    private static func localExtraction(_ operation: @escaping @Sendable () throws -> String) async throws -> String {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func runHelper(_ request: [String: Any], runtimeRoot: String) async throws -> [String: Any] {
        guard let runtime = BackendProcess.resolvedRuntime(root: runtimeRoot, resources: Bundle.main.resourceURL) else { throw IdentityVaultError.helperUnavailable }
        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard requestData.count <= maximumWireBytes else { throw IdentityVaultError.tooLarge }
        let state = IdentityVaultHelperProcess()
        let task = Task.detached(priority: .userInitiated) { () throws -> Data in
            let process = Process()
            process.executableURL = runtime.python
            process.arguments = ["-B", "-m", "ollama_code.identity_documents"]
            process.currentDirectoryURL = runtime.source
            var pythonPath = [runtime.source.path]
            if let packages = runtime.packages { pythonPath.append(packages.path) }
            // No provider keys, inherited PYTHONPATH, startup modules, or agent transport environment.
            process.environment = [
                "PYTHONPATH": pythonPath.joined(separator: ":"), "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONNOUSERSITE": "1", "PYTHONUTF8": "1", "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
            ]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try state.start(process)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 30)
            timer.setEventHandler { state.cancel() }
            timer.resume()
            defer {
                timer.cancel()
                try? input.fileHandleForWriting.close()
                try? output.fileHandleForReading.close()
                state.cancel()
            }
            DispatchQueue.global(qos: .utility).async {
                do { try input.fileHandleForWriting.write(contentsOf: requestData) } catch { state.cancel() }
                try? input.fileHandleForWriting.close()
            }
            var bytes = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                guard bytes.count + chunk.count <= maximumWireBytes else { state.cancel(); throw IdentityVaultError.tooLarge }
                bytes.append(chunk)
            }
            process.waitUntilExit()
            guard !state.isCancelled else { throw IdentityVaultError.cancelled }
            guard process.terminationStatus == 0 else { throw IdentityVaultError.extractionFailed }
            return bytes
        }
        let bytes = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            state.cancel()
        }
        try Task.checkCancellation()
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              result["protocol_version"] as? Int == 1, result["ok"] as? Bool == true else { throw IdentityVaultError.extractionFailed }
        return result
    }
}

private final class IdentityVaultHelperProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw IdentityVaultError.cancelled }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}
