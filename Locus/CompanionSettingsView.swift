import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct CompanionAccessSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @Binding var enabled: Bool
    @State private var confirmation: Confirmation?

    private enum Confirmation: String, Identifiable {
        case revokeAll
        case resetSecurity
        var id: String { rawValue }
    }

    var body: some View {
        Section("Mobile Access") {
            Toggle("Allow Locus Mobile to connect", isOn: $enabled)
                .accessibilityIdentifier("settings.mobileAccessEnabled")

            Text("Off by default. Connections stay private to your local or Tailscale network, use a pinned certificate, and never expose the local agent port.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if enabled != model.settings.mobileAccessEnabled {
                Label("Save Settings to apply this change", systemImage: "info.circle")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.warning)
            } else if enabled {
                LabeledContent("Status") {
                    Label(
                        model.companionGatewayState.status,
                        systemImage: model.companionGatewayState.running
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(
                        model.companionGatewayState.running
                            ? LocusTheme.success : LocusTheme.warning
                    )
                    .accessibilityIdentifier("settings.mobileAccessStatus")
                }

                Button("Pair a New Device…") { model.beginCompanionPairing() }
                    .disabled(!model.companionGatewayState.running)
                    .accessibilityIdentifier("settings.mobileAccessPair")

                if let payload = model.companionPairingPayload {
                    CompanionPairingCard(payload: payload)
                        .environmentObject(model)
                }
                if let error = model.companionPairingError {
                    Text(error)
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.coral)
                        .accessibilityIdentifier("settings.mobileAccessError")
                }

                if model.companionGatewayState.pairedDevices.isEmpty {
                    Text("No phones are paired.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                } else {
                    ForEach(model.companionGatewayState.pairedDevices) { device in
                        HStack {
                            Image(systemName: device.platform == "ios" ? "iphone" : "smartphone")
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text("Last connected \(Date(timeIntervalSince1970: device.lastSeenAt).formatted(.relative(presentation: .named)))")
                                    .font(.locus(size: 8))
                                    .foregroundStyle(LocusTheme.muted)
                            }
                            Spacer()
                            Button("Revoke") { model.revokeCompanionDevice(device) }
                                .accessibilityIdentifier("settings.mobileAccessRevoke.\(device.id)")
                        }
                    }
                    Button("Revoke All Devices", role: .destructive) {
                        confirmation = .revokeAll
                    }
                    .accessibilityIdentifier("settings.mobileAccessRevokeAll")
                }

                Button("Reset Certificate and Pairings…", role: .destructive) {
                    confirmation = .resetSecurity
                }
                .accessibilityIdentifier("settings.mobileAccessReset")
            }
        }
        .confirmationDialog(
            confirmation == .revokeAll ? "Revoke every paired phone?" : "Reset Mobile Access security?",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if confirmation == .revokeAll {
                Button("Revoke All Devices", role: .destructive) {
                    model.revokeAllCompanionDevices()
                    confirmation = nil
                }
            } else {
                Button("Reset Certificate and Revoke All", role: .destructive) {
                    model.resetCompanionCertificate()
                    confirmation = nil
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(
                confirmation == .revokeAll
                    ? "Every phone must be paired again. Locus chats and schedules are unchanged."
                    : "The pinned certificate and every device token will be replaced. Every phone must be paired again."
            )
        }
    }
}

private struct CompanionPairingCard: View {
    @EnvironmentObject private var model: AppModel
    let payload: CompanionPairingPayload

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let image = Self.qrImage(payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 154, height: 154)
                    .accessibilityLabel("Mobile pairing QR code")
                    .accessibilityIdentifier("settings.mobileAccessQRCode")
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Scan with Locus Mobile")
                    .font(.locus(size: 11, weight: .bold))
                Text("This code works once and expires in five minutes. Check that the certificate fingerprint shown by the phone matches before pairing.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(payload.certificateFingerprint)
                    .font(.locus(size: 8, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .accessibilityIdentifier("settings.mobileAccessFingerprint")
                if let endpoint = payload.endpoints.first {
                    HStack {
                        Text(endpoint)
                            .font(.locus(size: 8, design: .monospaced))
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(endpoint, forType: .string)
                        }
                    }
                }
                HStack {
                    Button("New Code") { model.beginCompanionPairing() }
                    Button("Copy Pairing Details") {
                        guard let data = try? JSONEncoder().encode(payload),
                              let value = String(data: data, encoding: .utf8) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                    Button("Done") { model.dismissCompanionPairing() }
                }
            }
        }
        .padding(12)
        .background(LocusTheme.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(LocusTheme.line) }
    }

    private static func qrImage(_ payload: CompanionPairingPayload) -> NSImage? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
