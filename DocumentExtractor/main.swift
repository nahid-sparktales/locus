import AppKit
import CryptoKit
import Darwin
import Foundation
import PDFKit
import Vision

// One process extracts one immutable PDF snapshot. The Python job owner controls
// persistence, cancellation, and global concurrency. No provider or network API
// participates in extraction; stdout contains only versioned protocol records.
private let sourceLimit = 100 * 1024 * 1024
private let textLimit = 5 * 1024 * 1024
private let pageLimit = 500
private let pageTimeout: TimeInterval = 20

private struct Request: Decodable {
    let protocolVersion: Int
    let requestID: String
    let path: String
    let expectedHash: String
    let ocrMode: String
    let ocrLanguages: [String]

    enum CodingKeys: String, CodingKey {
        case path
        case protocolVersion = "protocol_version"
        case requestID = "request_id"
        case expectedHash = "expected_hash"
        case ocrMode = "ocr_mode"
        case ocrLanguages = "ocr_languages"
    }
}

private enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var request: VNRecognizeTextRequest?
    var cancelled: Bool { lock.withLock { value } }
    func use(_ request: VNRecognizeTextRequest?) {
        lock.withLock {
            self.request = request
            if value { request?.cancel() }
        }
    }
    func cancel() {
        lock.withLock {
            value = true
            request?.cancel()
        }
    }
}

private let cancellation = Cancellation()
signal(SIGTERM, SIG_IGN)
let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
signalSource.setEventHandler { cancellation.cancel() }
signalSource.resume()

private func emit(_ fields: [String: Any]) throws {
    var record = fields
    record["protocol_version"] = 1
    var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private final class Collector {
    var textBytes = 0
    var segmentCount = 0
    var truncated = false
    var warnings: [String] = []

    func append(_ text: String, locator: [String: Any], method: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let bytes = Data(clean.utf8)
        let remaining = max(textLimit - textBytes, 0)
        var bounded = clean
        if bytes.count > remaining {
            var prefix = bytes.prefix(remaining)
            while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
                prefix = prefix.dropLast()
            }
            bounded = String(data: prefix, encoding: .utf8) ?? ""
            truncated = true
            warnings.append("Text extraction reached the 5 MB limit.")
        }
        if !bounded.isEmpty {
            try emit(["type": "segment", "text": bounded, "locator": locator, "method": method])
            textBytes += bounded.utf8.count
            segmentCount += 1
        }
    }
}

private final class RecognitionResult: @unchecked Sendable {
    var observations: [VNRecognizedTextObservation] = []
    var failure: Error?
}

private func recognize(_ image: CGImage, languages: [String]) throws -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = languages.isEmpty
    if !languages.isEmpty {
        let supported = try request.supportedRecognitionLanguages()
        let matched = languages.compactMap { requested in
            supported.first { $0.caseInsensitiveCompare(requested) == .orderedSame }
                ?? supported.first { $0.lowercased().hasPrefix(requested.lowercased() + "-") }
        }
        guard matched.count == languages.count else {
            throw Failure.message("One or more OCR languages are not supported by this version of macOS.")
        }
        request.recognitionLanguages = matched
    }
    cancellation.use(request)
    defer { cancellation.use(nil) }
    let result = RecognitionResult()
    let complete = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            result.observations = request.results ?? []
        } catch {
            result.failure = error
        }
        complete.signal()
    }
    let deadline = Date().addingTimeInterval(pageTimeout)
    while complete.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
        if cancellation.cancelled {
            request.cancel()
            throw Failure.message("Document extraction was cancelled.")
        }
        if Date() >= deadline {
            request.cancel()
            throw Failure.message("OCR exceeded the 20-second page limit.")
        }
    }
    if let failure = result.failure { throw failure }
    return result.observations.sorted {
        if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 {
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
        return $0.boundingBox.minX < $1.boundingBox.minX
    }
}

private func extract(_ request: Request) throws {
    guard request.protocolVersion == 1 else { throw Failure.message("Unsupported document protocol.") }
    guard request.ocrMode == "auto" || request.ocrMode == "always" else { throw Failure.message("Invalid OCR mode.") }
    let url = URL(fileURLWithPath: request.path)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.size] as? NSNumber)?.intValue ?? (sourceLimit + 1) <= sourceLimit
    else { throw Failure.message("PDF must be a regular file no larger than 100 MB.") }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count <= sourceLimit else { throw Failure.message("PDF exceeds the 100 MB limit.") }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == request.expectedHash else { throw Failure.message("PDF snapshot changed before extraction.") }
    guard let document = PDFDocument(data: data) else { throw Failure.message("The PDF is damaged or unreadable.") }
    guard !document.isLocked else { throw Failure.message("Unlock this password-protected PDF before importing it.") }
    let output = Collector()
    let count = min(document.pageCount, pageLimit)
    if document.pageCount > pageLimit {
        output.truncated = true
        output.warnings.append("Only the first 500 PDF pages were indexed.")
    }
    for index in 0..<count {
        if cancellation.cancelled { throw Failure.message("Document extraction was cancelled.") }
        if output.textBytes >= textLimit { break }
        guard let page = document.page(at: index) else { continue }
        try autoreleasepool {
            let locator: [String: Any] = ["kind": "pdf", "page": index + 1, "page_index": index]
            let embedded = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let letterCount = embedded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
            if request.ocrMode != "always", letterCount >= 20 {
                try output.append(embedded, locator: locator, method: "embedded")
            } else {
                // PDFKit owns crop-box and rotation transforms for both the
                // thumbnail and the in-app preview. Vision bounds use the
                // rendered upright page, normalized with a bottom-left origin.
                let bounds = page.bounds(for: .cropBox)
                let rotated = abs(page.rotation % 180) == 90
                let width = rotated ? bounds.height : bounds.width
                let height = rotated ? bounds.width : bounds.height
                guard width > 0, height > 0, width.isFinite, height.isFinite else {
                    throw Failure.message("PDF page has invalid dimensions.")
                }
                let scale = min(2.8, sqrt(4_000_000 / (width * height)))
                let thumbnail = page.thumbnail(of: NSSize(width: max(1, width * scale), height: max(1, height * scale)), for: .cropBox)
                guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw Failure.message("PDF page could not be rendered for OCR.")
                }
                do {
                    let observations = try recognize(image, languages: request.ocrLanguages)
                    for observation in observations {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let box = observation.boundingBox
                        var location = locator
                        location["bounds"] = ["x": box.minX, "y": box.minY, "width": box.width, "height": box.height]
                        try output.append(candidate.string, locator: location, method: "ocr")
                        if output.textBytes >= textLimit { break }
                    }
                    if observations.isEmpty {
                        if !embedded.isEmpty {
                            try output.append(embedded, locator: locator, method: "embedded")
                        } else {
                            output.warnings.append("No readable text was found on page \(index + 1).")
                        }
                    }
                } catch {
                    if cancellation.cancelled { throw error }
                    // A timed-out Vision request may still be unwinding. End
                    // this process instead of starting another page beside it.
                    output.truncated = true
                    output.warnings.append("Page \(index + 1): \(error.localizedDescription)")
                    try emit(["type": "result", "ok": true, "truncated": true, "warnings": output.warnings])
                    exit(0)
                }
            }
            try emit(["type": "progress", "progress": index + 1, "total": count])
        }
    }
    if output.segmentCount == 0 { output.warnings.append("No searchable text was found in this PDF.") }
    try emit(["type": "result", "ok": true, "truncated": output.truncated, "warnings": output.warnings])
}

do {
    guard let line = readLine(), line.utf8.count <= 65_536,
          let data = line.data(using: .utf8)
    else { throw Failure.message("Document helper request is missing or too large.") }
    let request = try JSONDecoder().decode(Request.self, from: data)
    try extract(request)
} catch {
    try? emit(["type": "result", "ok": false, "error": error.localizedDescription])
    exit(1)
}
