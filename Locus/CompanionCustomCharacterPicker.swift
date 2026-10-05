import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CompanionPortraitPreviewResponse: Decodable {
    let pngBase64: String
    enum CodingKeys: String, CodingKey { case pngBase64 = "png_base64" }

    func normalizedImage() throws -> Data {
        guard pngBase64.utf8.count <= (AgentAvatarImage.maximumSourceBytes * 4 / 3 + 8),
              let data = Data(base64Encoded: pngBase64) else { throw AgentAvatarImage.AvatarError.tooLarge }
        return try AgentAvatarImage.normalized(data)
    }
}

extension AppModel {
    /// Only called by the explicit Generate button. Uses the existing image
    /// account/provider handoff and never creates a chat, task or permission.
    func generateCompanionPortrait(prompt: String, accountID: UUID, requestID: UUID) async throws -> Data {
        guard isAgentOnline, backendCapabilities["image_generation_v1"] != false,
              selectedImageAccount?.id == accountID else {
            throw CompanionPortraitError.unavailable
        }
        _ = try await imageGeneration.apply(body: imageProviderRequestBody())
        try Task.checkCancellation()
        guard selectedImageAccount?.id == accountID else { throw CompanionPortraitError.accountChanged }
        let response = try await backend.post("/api/images/portrait", body: [
            "prompt": prompt, "account_id": accountID.uuidString, "request_id": requestID.uuidString,
        ], timeout: 310, as: CompanionPortraitPreviewResponse.self)
        try Task.checkCancellation()
        return try response.normalizedImage()
    }

    func cancelCompanionPortrait(requestID: UUID) async {
        let _: JSONValue? = try? await backend.post("/api/images/portrait/cancel",
            body: ["request_id": requestID.uuidString], as: JSONValue.self)
    }
}

enum CompanionPortraitError: LocalizedError {
    case unavailable, accountChanged
    var errorDescription: String? {
        switch self {
        case .unavailable: "Image generation is unavailable. Connect an image account in Models & Providers, or import a picture."
        case .accountChanged: "The image account changed. Review the account before generating again."
        }
    }
}

/// Preview only. The caller owns the choice, and receives pixels solely when
/// Use this character is pressed. Dismissal and cancellation keep it intact.
struct CompanionCustomCharacterPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locusViewColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let onUse: (Data) -> Void
    @State private var prompt = ""
    @State private var preview: Data?
    @State private var importing = false
    @State private var requestID: UUID?
    @State private var generationTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showingImageSettings = false

    private var account: ProviderAccount? { model.selectedImageAccount }
    private var canGenerate: Bool {
        account != nil && model.isAgentOnline && model.backendCapabilities["image_generation_v1"] != false
            && (1...2_000).contains(prompt.trimmingCharacters(in: .whitespacesAndNewlines).count)
            && requestID == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create your own").font(.locus(size: 24, weight: .semibold))
            Text("Describe a little character, or choose a picture from your Mac.")
                .font(.locus(size: 13)).foregroundStyle(colors.muted)
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 8) {
                    Group {
                        if let preview, let image = NSImage(data: preview) {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "photo").font(.locus(size: 32))
                                Text("Your preview appears here").font(.locus(size: 11))
                            }.foregroundStyle(colors.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.frame(width: 184, height: 184)
                        .background(colors.surfaceCard, in: RoundedRectangle(cornerRadius: 24))
                        .accessibilityLabel(preview == nil ? "No custom character selected" : "Custom character preview")
                    Text("Custom pictures use gentle whole-image motion and a status badge.")
                        .font(.locus(size: 10)).foregroundStyle(colors.muted)
                        .fixedSize(horizontal: false, vertical: true).frame(width: 184)
                }
                VStack(alignment: .leading, spacing: 12) {
                    TextField("A tiny sleepy purple robot with glasses and a yellow scarf", text: $prompt, axis: .vertical)
                        .lineLimit(4...6).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Character description").accessibilityIdentifier("companion.custom.prompt")
                    if prompt.count > 2_000 {
                        Text("Use 2,000 characters or fewer.").font(.locus(size: 11)).foregroundStyle(colors.warning)
                    }
                    if let account {
                        Text("Sent to \(account.displayName) · \(account.kind == .chatGPT ? "chatgpt.com" : (URL(string: account.resolvedBaseURL)?.host ?? account.kind.rawValue))")
                            .font(.locus(size: 11, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(account.kind == .chatGPT
                            ? "Uses this account’s configured image capability and usage allowance. Availability depends on the account."
                            : "Generation may incur provider charges. Your description is sent only when you choose Generate.")
                            .font(.locus(size: 11)).foregroundStyle(colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Choose an image account in Settings → Models & Providers to generate. Bundled characters and image import work offline.")
                            .font(.locus(size: 11)).foregroundStyle(colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.isAgentOnline || model.backendCapabilities["image_generation_v1"] == false {
                        Text("Image generation is currently unavailable. You can still import a picture.")
                            .font(.locus(size: 11)).foregroundStyle(colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if requestID != nil {
                            ProgressView().controlSize(.small)
                            Button("Cancel generation") { cancelGeneration() }.buttonStyle(.locus())
                        } else {
                            Button("Generate") { generate() }.buttonStyle(.locus(.primary))
                                .disabled(!canGenerate).accessibilityIdentifier("companion.custom.generate")
                        }
                        Button("Import image…") { importing = true }.buttonStyle(.locus())
                            .disabled(requestID != nil).accessibilityIdentifier("companion.custom.import")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.locus(size: 12)).foregroundStyle(colors.warning)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("companion.custom.error")
            }
            Text("Transparency depends on the provider. Nothing is saved until you choose Use this character.")
                .font(.locus(size: 11)).foregroundStyle(colors.muted)
            HStack {
                Button("Image settings…") {
                    cancelGeneration(); model.settingsPage = .accounts; showingImageSettings = true
                }.buttonStyle(.locus())
                Spacer()
                Button("Cancel") { cancelGeneration(); dismiss() }
                    .buttonStyle(.locus()).keyboardShortcut(.cancelAction)
                Button("Use this character") {
                    guard let preview else { return }
                    onUse(preview); dismiss()
                }.buttonStyle(.locus(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || requestID != nil).accessibilityIdentifier("companion.custom.use")
            }
        }.padding(24).frame(width: 620).foregroundStyle(colors.ink).background(colors.panel)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("companion.custom.picker")
            .onDisappear { cancelGeneration() }
            .sheet(isPresented: $showingImageSettings) {
                SettingsView(presentationContext: .sheet).appFeatureEnvironment(from: model)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: AgentAvatarImage.allowedImportTypes) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= AgentAvatarImage.maximumSourceBytes else { throw AgentAvatarImage.AvatarError.tooLarge }
                    let approved = try AgentAvatarImage.normalized(Data(contentsOf: url, options: .mappedIfSafe))
                    preview = approved; errorMessage = nil
                } catch CocoaError.userCancelled { }
                catch { errorMessage = error.localizedDescription }
            }
    }

    private func generate() {
        guard canGenerate, let account else { return }
        let id = UUID()
        requestID = id; errorMessage = nil
        generationTask = Task { @MainActor in
            defer { if requestID == id { requestID = nil; generationTask = nil } }
            do {
                let data = try await model.generateCompanionPortrait(prompt: prompt, accountID: account.id, requestID: id)
                guard !Task.isCancelled, requestID == id else { return }
                preview = data
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, requestID == id else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelGeneration() {
        guard let id = requestID else { return }
        generationTask?.cancel(); generationTask = nil; requestID = nil
        errorMessage = "Generation cancelled. The provider may charge for work already started. Your previous choice is unchanged."
        Task { await model.cancelCompanionPortrait(requestID: id) }
    }
}
