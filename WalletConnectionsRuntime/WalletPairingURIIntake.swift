import AppKit
@preconcurrency import AVFoundation
import CryptoKit
import Vision

enum WalletPairingURIIntakeError: LocalizedError, Equatable {
    case malformed
    case oversized
    case expired
    case duplicateField
    case noQRCode
    case cameraUnavailable
    case canceled

    var errorDescription: String? {
        switch self {
        case .malformed: "The WalletConnect pairing code is malformed."
        case .oversized: "The WalletConnect pairing code is too large."
        case .expired: "The WalletConnect pairing code has expired."
        case .duplicateField: "The WalletConnect pairing code contains duplicate fields."
        case .noQRCode: "No WalletConnect QR code was found in that image."
        case .cameraUnavailable: "Camera access is unavailable."
        case .canceled: "QR scanning was canceled."
        }
    }
}

/// Direct-build-only intake for transient WalletConnect pairings. The raw URI
/// is never logged or persisted by this type; callers retain only its digest
/// for replay defense after handing it to Reown.
enum WalletPairingURIIntake {
    static let maximumBytes = 2_048

    static func validated(_ candidate: String, now: Date = Date()) throws -> String {
        guard candidate.utf8.count <= maximumBytes else {
            throw WalletPairingURIIntakeError.oversized
        }
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw WalletPairingURIIntakeError.malformed }
        guard value.utf8.count <= maximumBytes else {
            throw WalletPairingURIIntakeError.oversized
        }
        guard value.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }), let components = URLComponents(string: value),
        components.scheme?.lowercased() == "wc",
        components.host == nil,
        components.user == nil, components.password == nil,
        components.fragment == nil else {
            throw WalletPairingURIIntakeError.malformed
        }
        let target = components.path.isEmpty ? (components.host ?? "") : components.path
        let segments = target.split(separator: "@", omittingEmptySubsequences: false)
        guard segments.count == 2, segments[0].count == 64,
              segments[0].utf8.allSatisfy(Self.isLowercaseHex),
              segments[1] == "2" else {
            throw WalletPairingURIIntakeError.malformed
        }
        let items = components.queryItems ?? []
        let grouped = Dictionary(grouping: items, by: \.name)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw WalletPairingURIIntakeError.duplicateField
        }
        guard Set(grouped.keys).isSubset(of: ["relay-protocol", "symKey", "expiryTimestamp"])
        else { throw WalletPairingURIIntakeError.malformed }
        guard grouped["relay-protocol"]?.first?.value == "irn",
              let symmetricKey = grouped["symKey"]?.first?.value,
              symmetricKey.count == 64,
              symmetricKey.utf8.allSatisfy(Self.isLowercaseHex) else {
            throw WalletPairingURIIntakeError.malformed
        }
        if let expiryText = grouped["expiryTimestamp"]?.first?.value {
            guard !expiryText.isEmpty, expiryText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let expiry = TimeInterval(expiryText), expiry.isFinite else {
                throw WalletPairingURIIntakeError.malformed
            }
            guard Date(timeIntervalSince1970: expiry) > now else {
                throw WalletPairingURIIntakeError.expired
            }
        }
        return value
    }

    static func pairingURI(fromDeepLink url: URL, now: Date = Date()) throws -> String {
        guard url.absoluteString.utf8.count <= maximumBytes * 3 else {
            throw WalletPairingURIIntakeError.oversized
        }
        if url.scheme?.lowercased() == "wc" {
            return try validated(url.absoluteString, now: now)
        }
        guard url.scheme?.lowercased() == "locus-wallet",
              url.host?.lowercased() == "wc",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.path.isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.count == 1,
              items[0].name == "uri", let value = items[0].value
        else { throw WalletPairingURIIntakeError.malformed }
        return try validated(value, now: now)
    }

    static func digest(_ validatedURI: String) -> String {
        // The topic is the pairing's identity. Reordered query parameters or
        // alternate percent encoding must not create a fresh replay key.
        let topic = URLComponents(string: validatedURI)?.path.split(separator: "@").first
        return SHA256.hash(data: Data((topic.map(String.init) ?? validatedURI).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func decodeImage(_ image: NSImage, now: Date = Date()) throws -> String {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { throw WalletPairingURIIntakeError.noQRCode }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let candidates = (request.results ?? []).compactMap(\.payloadStringValue)
        for candidate in candidates {
            if let validated = try? validated(candidate, now: now) { return validated }
        }
        throw WalletPairingURIIntakeError.noQRCode
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

@MainActor
final class WalletQRCodeCameraScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate,
    NSWindowDelegate {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "io.sparktales.locus.wallet-qr")
    private var continuation: CheckedContinuation<String, Error>?
    private var panel: NSPanel?

    func scan() async throws -> String {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined:
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard allowed, let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            throw WalletPairingURIIntakeError.cameraUnavailable
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            throw WalletPairingURIIntakeError.cameraUnavailable
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            throw WalletPairingURIIntakeError.cameraUnavailable
        }
        output.metadataObjectTypes = [.qr]

        let preview = WalletCameraPreviewView(session: session)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 390),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Scan WalletConnect QR Code"
        panel.contentView = preview
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation = $0
                captureQueue.async { [session] in session.startRunning() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(WalletPairingURIIntakeError.canceled))
            }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        _ = output
        _ = connection
        guard let value = metadataObjects.compactMap({
            ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue
        }).first else { return }
        Task { @MainActor in
            guard let validated = try? WalletPairingURIIntake.validated(value) else { return }
            finish(.success(validated))
        }
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        finish(.failure(WalletPairingURIIntakeError.canceled))
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let session = self.session
        captureQueue.async { session.stopRunning() }
        panel?.delegate = nil
        panel?.close()
        panel = nil
        continuation.resume(with: result)
    }
}

private final class WalletCameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
