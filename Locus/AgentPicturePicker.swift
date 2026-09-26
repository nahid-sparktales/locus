import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Bundled artwork is copied into the existing avatar store when selected, so
/// custom uploads and presets follow the same persistence and thumbnail rules.
enum AgentPortraitPreset: String, CaseIterable, Identifiable {
    case atlas, nova, kitsune, moss, orbit, sage, tide, pixel, sol, bloom
    case luffy, zoro, nami, chopper, law

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var assetName: String { "AgentPortrait-" + rawValue }
    var isOnePiece: Bool { [.luffy, .zoro, .nami, .chopper, .law].contains(self) }

    @MainActor func imageData() throws -> Data {
        guard let image = NSImage(named: NSImage.Name(assetName)), let data = image.tiffRepresentation else {
            throw AgentAvatarImage.AvatarError.invalidImage
        }
        return try AgentAvatarImage.normalized(data)
    }
}

struct AgentPicturePicker: View {
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @Environment(\.locusViewColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let profile: AgentProfile
    private let originalData: Data?
    @State private var draftData: Data?
    @State private var selectedPreset: AgentPortraitPreset?
    @State private var choiceName: String
    @State private var filter: Collection = .all
    @State private var importing = false
    @State private var errorMessage: String?

    private enum Collection: String, CaseIterable, Identifiable {
        case all = "All pictures", originals = "Originals", onePiece = "One Piece"
        var id: String { rawValue }
    }

    init(profile: AgentProfile, currentData: Data?) {
        self.profile = profile
        originalData = currentData
        _draftData = State(initialValue: currentData)
        _choiceName = State(initialValue: currentData == nil ? "Initials" : "Current picture")
    }

    private var portraits: [AgentPortraitPreset] {
        AgentPortraitPreset.allCases.filter {
            filter == .all || (filter == .onePiece ? $0.isOnePiece : !$0.isOnePiece)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Profile picture").font(.locus(size: 21, weight: .semibold))
                    Text("Give \(profile.name) a face across Locus and Agent World.")
                        .font(.locus(size: 12)).foregroundStyle(colors.muted)
                }
                Spacer()
            }.padding(22)

            HStack(spacing: 14) {
                preview
                VStack(alignment: .leading, spacing: 5) {
                    Text(choiceName).font(.locus(size: 14, weight: .semibold))
                    Text("10 originals · 5 One Piece portraits")
                        .font(.locus(size: 11)).foregroundStyle(colors.muted)
                }
                Spacer()
                Button { importing = true } label: {
                    Label("Upload image…", systemImage: "photo.badge.plus")
                        .font(.locus(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(colors.panel, in: RoundedRectangle(cornerRadius: 9))
                }
                    .buttonStyle(.locus()).accessibilityIdentifier("agentPicture.upload")
            }.padding(16).background(colors.surfaceCard, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 22)

            Picker("Picture collection", selection: $filter) {
                ForEach(Collection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 22).padding(.vertical, 16)
                .accessibilityIdentifier("agentPicture.collection")

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 16) {
                    ForEach(portraits) { preset in portraitButton(preset) }
                }.padding(.horizontal, 22).padding(.bottom, 16)
            }.accessibilityIdentifier("agentPicture.gallery")

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.locus(size: 11)).foregroundStyle(colors.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 22).padding(.bottom, 12)
            }
            Divider().overlay(colors.line)
            HStack {
                Button("Use initials") {
                    draftData = nil; selectedPreset = nil; choiceName = "Initials"; errorMessage = nil
                }.buttonStyle(.locus()).disabled(draftData == nil)
                    .accessibilityIdentifier("agentPicture.initials")
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel").font(.locus(size: 12)).padding(.horizontal, 14).padding(.vertical, 9)
                }.buttonStyle(.locus()).keyboardShortcut(.cancelAction)
                Button { apply() } label: {
                    Text(draftData == nil ? "Use initials" : "Use picture")
                        .font(.locus(size: 12, weight: .semibold)).foregroundStyle(colors.brandInk)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(colors.accentFill, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.locus(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(draftData == originalData).accessibilityIdentifier("agentPicture.apply")
            }.padding(18)
        }
        .foregroundStyle(colors.ink).background(colors.panel)
        .frame(width: 620, height: 650)
        .accessibilityIdentifier("agentPicture.picker")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= AgentAvatarImage.maximumSourceBytes else { throw AgentAvatarImage.AvatarError.tooLarge }
                draftData = try AgentAvatarImage.normalized(Data(contentsOf: url, options: .mappedIfSafe))
                selectedPreset = nil; choiceName = "Custom picture"; errorMessage = nil
            } catch CocoaError.userCancelled { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private var preview: some View {
        Group {
            if let draftData, let image = NSImage(data: draftData) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(String(profile.name.prefix(1)).uppercased())
                    .font(.locus(size: 28, weight: .semibold)).foregroundStyle(colors.accentAction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(colors.accentAction.opacity(0.12))
            }
        }.frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 19))
            .accessibilityLabel("Selected picture: \(choiceName)")
    }

    private func portraitButton(_ preset: AgentPortraitPreset) -> some View {
        Button {
            do {
                draftData = try preset.imageData()
                selectedPreset = preset; choiceName = preset.name; errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        } label: {
            VStack(spacing: 7) {
                Image(preset.assetName).resizable().scaledToFill()
                    .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(selectedPreset == preset ? colors.accentAction : colors.line, lineWidth: selectedPreset == preset ? 3 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if selectedPreset == preset {
                            Image(systemName: "checkmark.circle.fill").font(.locus(size: 19, weight: .semibold))
                                .foregroundStyle(colors.accentAction).background(colors.panel, in: Circle()).padding(5)
                        }
                    }
                Text(preset.name).font(.locus(size: 11, weight: selectedPreset == preset ? .semibold : .regular))
                    .foregroundStyle(selectedPreset == preset ? colors.accentAction : colors.ink)
            }.padding(3).contentShape(Rectangle())
        }
        .buttonStyle(.locus(.card))
        .accessibilityLabel("Choose \(preset.name) profile picture")
        .accessibilityAddTraits(selectedPreset == preset ? .isSelected : [])
        .accessibilityIdentifier("agentPicture.preset.\(preset.id)")
    }

    private func apply() {
        guard agentTeams.agentProfiles.contains(where: { $0.id == profile.id }) else {
            errorMessage = "This agent is no longer available."; return
        }
        agentTeams.setAgentAvatar(draftData, profileID: profile.id)
        dismiss()
    }
}
