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
    private let originalAppearance: CompanionAppearance?
    private let originalAnimations: Bool
    @State private var draftData: Data?
    @State private var draftAppearance: CompanionAppearance?
    @State private var draftAnimations: Bool
    @State private var selectedPreset: AgentPortraitPreset?
    @State private var choiceName: String
    @State private var filter: Collection = .all
    @State private var importing = false
    @State private var creatingCharacter = false
    @State private var errorMessage: String?

    private enum Collection: String, CaseIterable, Identifiable {
        case characters = "Characters", originals = "Originals", all = "All pictures", onePiece = "One Piece"
        var id: String { rawValue }
    }

    init(profile: AgentProfile, currentData: Data?, currentAppearance: CompanionAppearance? = nil,
         animationsEnabled: Bool = true) {
        self.profile = profile
        originalData = currentData
        originalAppearance = currentAppearance
        originalAnimations = animationsEnabled
        _draftData = State(initialValue: currentData)
        _draftAppearance = State(initialValue: currentAppearance)
        _draftAnimations = State(initialValue: animationsEnabled)
        _filter = State(initialValue: currentAppearance?.kind == .bundledSprite ? .characters
            : currentAppearance?.kind == .builtIn ? .originals : .all)
        _choiceName = State(initialValue: currentAppearance?.displayName ?? (currentData == nil ? "Initials" : "Current picture"))
    }

    private var portraits: [AgentPortraitPreset] {
        AgentPortraitPreset.allCases.filter {
            filter == .all || (filter == .onePiece && $0.isOnePiece)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your companion").font(.locus(size: 21, weight: .semibold))
                    Text("Give \(profile.name) a familiar face across Locus.")
                        .font(.locus(size: 12)).foregroundStyle(colors.muted)
                }
                Spacer()
            }.padding(22)

            HStack(spacing: 14) {
                preview
                VStack(alignment: .leading, spacing: 5) {
                    Text(choiceName).font(.locus(size: 14, weight: .semibold))
                    Text("Animated characters · Your own pictures")
                        .font(.locus(size: 11)).foregroundStyle(colors.muted)
                }
                Spacer()
                Button { creatingCharacter = true } label: {
                    Label("Create your own…", systemImage: "paintbrush.pointed")
                        .font(.locus(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(colors.panel, in: RoundedRectangle(cornerRadius: 9))
                }
                    .buttonStyle(.locus()).accessibilityIdentifier("agentPicture.create")
            }.padding(16).background(colors.surfaceCard, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 22)

            Picker("Picture collection", selection: $filter) {
                ForEach(Collection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 22).padding(.vertical, 16)
                .accessibilityIdentifier("agentPicture.collection")

            ScrollView {
                if filter == .characters || filter == .originals {
                    characterGallery
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 16) {
                        ForEach(portraits) { preset in portraitButton(preset) }
                    }.padding(.horizontal, 22).padding(.bottom, 16)
                }
            }.accessibilityIdentifier("agentPicture.gallery")

            Toggle("Animate characters", isOn: $draftAnimations)
                .font(.locus(size: 12)).padding(.horizontal, 22).padding(.bottom, 12)
                .accessibilityIdentifier("agentPicture.animations")

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.locus(size: 11)).foregroundStyle(colors.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 22).padding(.bottom, 12)
            }
            Divider().overlay(colors.line)
            HStack {
                Button("Use initials") {
                    draftData = nil; draftAppearance = nil; selectedPreset = nil; choiceName = "Initials"; errorMessage = nil
                }.buttonStyle(.locus()).disabled(draftData == nil && draftAppearance == nil)
                    .accessibilityIdentifier("agentPicture.initials")
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel").font(.locus(size: 12)).padding(.horizontal, 14).padding(.vertical, 9)
                }.buttonStyle(.locus()).keyboardShortcut(.cancelAction)
                Button { apply() } label: {
                    Text(draftAppearance != nil ? "Use this character" : (draftData == nil ? "Use initials" : "Use picture"))
                        .font(.locus(size: 12, weight: .semibold)).foregroundStyle(colors.brandInk)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(colors.accentFill, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.locus(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(draftData == originalData && draftAppearance == originalAppearance && draftAnimations == originalAnimations)
                    .accessibilityIdentifier("agentPicture.apply")
            }.padding(18)
        }
        .foregroundStyle(colors.ink).background(colors.panel)
        .frame(width: 620, height: 650)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentPicture.picker")
        .locusSheet(isPresented: $creatingCharacter) {
            CompanionCustomCharacterPicker { data in
                draftData = data; draftAppearance = .portrait; selectedPreset = nil
                choiceName = "Custom character"; errorMessage = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: AgentAvatarImage.allowedImportTypes) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= AgentAvatarImage.maximumSourceBytes else { throw AgentAvatarImage.AvatarError.tooLarge }
                draftData = try AgentAvatarImage.normalized(Data(contentsOf: url, options: .mappedIfSafe))
                draftAppearance = .portrait
                selectedPreset = nil; choiceName = "Custom picture"; errorMessage = nil
            } catch CocoaError.userCancelled { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private var preview: some View {
        Group {
            if let draftAppearance {
                CompanionCharacterView(appearance: draftAppearance, size: 90, pose: .greeting,
                    animationsEnabled: draftAnimations, customImageData: draftData)
            } else if let draftData, let image = NSImage(data: draftData) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(String(profile.name.prefix(1)).uppercased())
                    .font(.locus(size: 28, weight: .semibold)).foregroundStyle(colors.accentAction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(colors.accentAction.opacity(0.12))
            }
        }.frame(width: 90, height: 90).clipShape(RoundedRectangle(cornerRadius: 19))
            .accessibilityLabel("Selected picture: \(choiceName)")
    }

    private var characterGallery: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                if filter == .characters {
                    ForEach(CompanionBundledSprite.allCases) { sprite in
                        characterButton(appearance: .init(sprite: sprite), selected: draftAppearance?.bundledSprite == sprite,
                            identifier: "agentPicture.sprite.\(sprite.id)") {
                            chooseCharacter(.init(sprite: sprite))
                        }
                    }
                } else {
                    ForEach(CompanionCharacterKind.allCases) { character in
                        characterButton(appearance: .init(character: character, palette: draftAppearance?.palette ?? .mint),
                            selected: draftAppearance?.builtIn == character,
                            identifier: "agentPicture.character.\(character.id)") {
                            chooseCharacter(CompanionAppearance(character: character,
                                palette: draftAppearance?.palette ?? .mint,
                                accessory: draftAppearance?.accessory ?? .none))
                        }
                    }
                }
            }
            HStack {
                Button("Surprise me") {
                    let selection = CompanionAppearance.surprise(seed: UInt64.random(in: .min ... .max))
                    chooseCharacter(selection)
                    filter = .originals
                }.buttonStyle(.locus()).accessibilityIdentifier("agentPicture.surprise")
                Spacer()
                Button("Import picture…") { importing = true }
                    .buttonStyle(.locus()).accessibilityIdentifier("agentPicture.upload")
            }
            if draftAppearance?.supportsAppearanceControls == true {
                HStack(spacing: 10) {
                    Text("Accent").font(.locus(size: 11))
                    ForEach(CompanionPalette.allCases) { palette in
                        Button { draftAppearance?.palette = palette } label: {
                            Circle().fill(palette.color).frame(width: 21, height: 21)
                                .overlay(Circle().stroke(draftAppearance?.palette == palette ? colors.ink : .clear, lineWidth: 2).padding(-3))
                        }.buttonStyle(.locus(.icon)).accessibilityLabel("\(palette.name) accent")
                            .accessibilityAddTraits(draftAppearance?.palette == palette ? .isSelected : [])
                    }
                    Spacer()
                    Picker("Accessory", selection: Binding(get: { draftAppearance?.accessory ?? .none },
                        set: { draftAppearance?.accessory = $0 })) {
                        ForEach(CompanionAccessory.allCases) { Text($0.name).tag($0) }
                    }.frame(width: 175)
                }.padding(.vertical, 4)
            }
        }.padding(.horizontal, 22).padding(.bottom, 16)
    }

    private func characterButton(appearance: CompanionAppearance, selected: Bool, identifier: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                CompanionCharacterView(appearance: appearance, size: 82, animationsEnabled: false)
                Text(appearance.displayName).font(.locus(size: 11, weight: .medium))
            }.frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(selected ? colors.accentAction.opacity(0.12) : colors.surfaceCard,
                    in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.locus(.card))
            .accessibilityLabel("Choose \(appearance.displayName)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(identifier)
    }

    private func chooseCharacter(_ appearance: CompanionAppearance) {
        draftAppearance = appearance
        draftData = nil
        selectedPreset = nil
        choiceName = appearance.displayName
        errorMessage = nil
    }

    private func portraitButton(_ preset: AgentPortraitPreset) -> some View {
        Button {
            do {
                draftData = try preset.imageData()
                draftAppearance = .portrait
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
        agentTeams.setAgentAppearance(draftAppearance, profileID: profile.id)
        agentTeams.setCompanionAnimationsEnabled(draftAnimations)
        dismiss()
    }
}
