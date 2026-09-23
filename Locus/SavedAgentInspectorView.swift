import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Downsample before decoding, center-crop, and re-encode only the pixels. This
/// bounds preference storage and leaves source EXIF/location metadata behind.
enum AgentAvatarImage {
    static let maximumStoredBytes = 256 * 1024
    static let maximumSourceBytes = 20 * 1024 * 1024

    static func normalized(_ data: Data) throws -> Data {
        guard data.count <= maximumSourceBytes else { throw AvatarError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 256, height: 256,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AvatarError.invalidImage }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.interpolationQuality = .high
        let scale = 256 / CGFloat(min(image.width, image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (256 - width) / 2, y: (256 - height) / 2, width: width, height: height))
        let output = NSMutableData()
        guard let thumbnail = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw AvatarError.invalidImage }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= maximumStoredBytes else { throw AvatarError.invalidImage }
        return output as Data
    }

    enum AvatarError: LocalizedError {
        case tooLarge, invalidImage
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Choose an image smaller than 20 MB."
            case .invalidImage: "This image couldn’t be opened. Try a JPEG, PNG, or HEIC picture."
            }
        }
    }
}

struct AgentAvatarView: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @Environment(\.locusOceanTheme) private var ocean
    let profileID: UUID
    let name: String
    var size: CGFloat = 40

    var body: some View {
        let accent = AgentWorldPalette(ocean: ocean).warning
        Group {
            if let data = agentTeams.agentAvatarData[profileID], let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.locus(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(ocean ? accent : viewColors.accentAction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background((ocean ? accent : viewColors.accentAction).opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.27))
        .accessibilityHidden(true)
    }
}

/// Native disclosure arrows have a small hit target on macOS. Keep the header
/// as a keyboard-accessible button whose entire row opens the section.
private struct SavedAgentDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let identifier: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : LocusMotion.spatial) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides this section")
            .accessibilityIdentifier(identifier)

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

/// Shared editing controls for the overview and the unsaved profile draft.
/// Linking a project stores its location; it does not move or copy that project.
struct AgentWorkspacePreferencesEditor: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @Environment(\.locusOceanTheme) private var ocean
    @Binding var profile: AgentProfile
    var compact = false
    @State private var showingDetails = false
    @State private var showingProjects = false

    private var selectedPath: String {
        profile.workspacePreferences?.defaultProjectPath ?? model.savedAgentHomePath(profile)
    }

    private var detailColor: Color {
        viewColors.textSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Label("New chats start in", systemImage: "folder")
                    .font(.locus(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Menu {
                    ForEach(model.savedAgentWorkspaceChoices(profile), id: \.path) { choice in
                        Button { select(choice.path) } label: {
                            if choice.path == selectedPath { Label(choice.title, systemImage: "checkmark") }
                            else { Text(choice.title) }
                        }.help(choice.path)
                    }
                    Divider()
                    Button("Add project…") { chooseProject() }
                } label: {
                    Label(model.savedAgentWorkspaceTitle(profile, path: selectedPath),
                          systemImage: selectedPath == model.savedAgentHomePath(profile) ? "house" : "folder")
                        .lineLimit(1).truncationMode(.middle)
                }.accessibilityIdentifier("savedAgent.defaultWorkspace")
            }
            if compact {
                Text(selectedPath == model.savedAgentHomePath(profile)
                     ? "A personal home, with a separate folder for each new chat."
                     : "New chats use this project. Existing chats keep their folders.")
                    .font(.locus(size: 12)).foregroundStyle(detailColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                // The overview links projects from the menu above; the profile
                // draft keeps a visible button.
                if !compact {
                    Button("Add project…") { chooseProject() }.accessibilityIdentifier("savedAgent.linkProject")
                }
                Button("Open home") {
                    model.revealSavedAgentWorkspace(profile, path: model.savedAgentHomePath(profile))
                }.accessibilityIdentifier("savedAgent.openHome")
            }.buttonStyle(.bordered)
            if compact {
                DisclosureGroup("Folder details & linked projects", isExpanded: $showingDetails) {
                    folderDetails.padding(.top, 8)
                }
                .disclosureGroupStyle(SavedAgentDisclosureStyle(identifier: "savedAgent.folderDetails.toggle"))
                .font(.locus(size: 12))
            } else {
                folderDetails
            }
        }
    }

    private var folderDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedPath).font(.locus(size: 11)).foregroundStyle(detailColor)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Home chats get their own task folders. Git projects use separate working copies; other project folders are shared.")
                .font(.locus(size: 12)).foregroundStyle(detailColor).fixedSize(horizontal: false, vertical: true)
            Text("Changes apply to new chats. Existing chats and automations keep their folders.")
                .font(.locus(size: 11)).foregroundStyle(detailColor).fixedSize(horizontal: false, vertical: true)
            if let paths = profile.workspacePreferences?.projectPaths, !paths.isEmpty {
                DisclosureGroup("Linked projects · \(paths.count)", isExpanded: $showingProjects) {
                    ForEach(paths, id: \.self) { path in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.locus(size: 12, weight: .medium))
                                Text(path).font(.locus(size: 11)).foregroundStyle(detailColor)
                                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Unlink") { unlink(path) }
                                .buttonStyle(.locus(.quiet)).help("Unlink project; files and existing chats are kept")
                                .accessibilityLabel("Unlink \(URL(fileURLWithPath: path).lastPathComponent)")
                        }.padding(.top, 8)
                    }
                }
                .disclosureGroupStyle(SavedAgentDisclosureStyle(identifier: "savedAgent.linkedProjects.toggle"))
                .font(.locus(size: 12))
            }
        }
    }

    private func chooseProject() {
        if let path = model.chooseSavedAgentProjectFolder() { select(path) }
    }
    private func select(_ path: String) {
        if path != model.savedAgentHomePath(profile) {
            do { try model.prepareSavedAgentWorkspace(profile, workspace: path) }
            catch { model.showToast(error.localizedDescription); return }
        }
        var preferences = profile.workspacePreferences ?? AgentWorkspacePreferences()
        preferences.defaultProjectPath = path == model.savedAgentHomePath(profile) ? nil : path
        if preferences.defaultProjectPath != nil { preferences.projectPaths.append(path) }
        preferences.normalize()
        profile.workspacePreferences = preferences
    }
    private func unlink(_ path: String) {
        var preferences = profile.workspacePreferences ?? AgentWorkspacePreferences()
        preferences.projectPaths.removeAll { $0 == path }
        if preferences.defaultProjectPath == path { preferences.defaultProjectPath = nil }
        profile.workspacePreferences = preferences
    }
}

/// Shared by the main workspace, inspector and world. Supplied conversation
/// callbacks preserve the world's project and selected resident.
struct SavedAgentInspectorView: View {
    @EnvironmentObject private var model: AppModel
    let profile: AgentProfile
    var workspace: String? = nil
    var newChat: (() -> Void)? = nil
    var openChat: ((SessionSummary) -> Void)? = nil
    var newChatDisabled: Bool? = nil
    var inspectActivity: ((AgentInspectorContext) -> Void)? = nil

    var body: some View {
        SavedAgentOverviewContent(initialProfile: profile, workspace: workspace, newChat: newChat,
            openChat: openChat, newChatDisabled: newChatDisabled, inspectActivity: inspectActivity,
            automation: model.eventAutomations)
    }
}

private struct SavedAgentResultExcerptView: View {
    @Environment(\.locusOceanTheme) private var ocean
    @Environment(\.locusCaptainDeckTheme) private var deck
    private var colors: LocusViewColors { .init(ocean: ocean, deck: deck) }
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(SavedAgentResultExcerpt(blocks: FinishedMarkdownCache.blocks(for: source)).lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if case .list(let marker) = line.kind {
                        Text(marker).foregroundStyle(colors.inkSoft).accessibilityHidden(true)
                    }
                    formatted(line)
                        .font(.locus(size: 13, weight: line.kind == .heading ? .semibold : .regular))
                        .foregroundStyle(line.kind == .heading ? colors.ink : colors.inkSoft)
                        .lineSpacing(4)
                        .lineLimit(line.kind == .heading || line.kind == .code ? 2 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Result preview")
    }

    private func formatted(_ line: SavedAgentResultExcerpt.Line) -> Text {
        line.runs.reduce(Text("")) { text, run in
            var segment = Text(run.text)
            if run.style.contains(.strong) { segment = segment.bold() }
            if run.style.contains(.emphasis) { segment = segment.italic() }
            if run.style.contains(.strikethrough) { segment = segment.strikethrough() }
            if run.style.contains(.code) || line.kind == .code {
                segment = segment.font(.locusExact(size: 12, design: .monospaced))
            }
            return text + segment
        }
    }
}

/// A separate reading surface preserves the overview's position and gives long
/// answers room without turning its card into a nested scroll view.
private struct SavedAgentResultReader: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locusOceanTheme) private var ocean
    @Environment(\.locusCaptainDeckTheme) private var deck
    @State private var copied = false
    private var colors: LocusViewColors { .init(ocean: ocean, deck: deck) }
    let result: SavedAgentOverviewSnapshot.LatestResult
    let workspacePath: String?
    let openSource: () -> Void

    private var source: String { result.fullResponse ?? result.summary }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Agent result", systemImage: "doc.text").font(.locus(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("savedAgent.resultReader.done")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.title).font(.locusExact(size: 26, weight: .semibold)).tracking(-0.5)
                            .textSelection(.enabled)
                        Text(result.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.locus(size: 12)).foregroundStyle(colors.inkSoft)
                    }
                    MarkdownBodyView(text: source, workspacePath: workspacePath)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(28)
            }
            Divider()
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MarkdownPlainTextRenderer.render(source), forType: .string)
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .accessibilityIdentifier("savedAgent.resultReader.copy")
                Spacer()
                if let action = result.action {
                    Button {
                        openSource()
                    } label: {
                        Label(sourceTitle(action), systemImage: "arrow.up.right")
                    }
                    .accessibilityIdentifier("savedAgent.resultReader.open")
                }
            }.buttonStyle(.bordered).padding(20)
        }
        .foregroundStyle(colors.ink).background(colors.surfaceCanvas)
        .frame(width: min(700, (NSScreen.main?.visibleFrame.width ?? 900) - 80),
               height: min(680, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("savedAgent.resultReader")
    }

    private func sourceTitle(_ action: SavedAgentOverviewSnapshot.Action) -> String {
        if case .chat = action { return "Open chat" }
        return "View activity"
    }
}

private struct SavedAgentOverviewContent: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    private var viewColors: LocusViewColors { .init(ocean: usesWorldTheme, deck: usesDeckTheme) }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    @EnvironmentObject private var schedule: ScheduleModel
    @EnvironmentObject private var accounts: ProviderAccountsModel
    @EnvironmentObject private var activity: ActivityCenterModel
    @Environment(\.locusOceanTheme) private var ocean
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let initialProfile: AgentProfile
    let workspace: String?
    let newChat: (() -> Void)?
    let openChat: ((SessionSummary) -> Void)?
    let newChatDisabled: Bool?
    let inspectActivity: ((AgentInspectorContext) -> Void)?
    @ObservedObject var automation: EventAutomationModel
    /// Only an explicit refresh shows progress. The periodic refresh keeps its
    /// own guard so it never overlaps itself or flickers the button.
    @State private var manualRefreshing = false
    @State private var backgroundRefreshing = false
    @State private var showAllChats = false
    @State private var showInstructions = false
    @State private var showTaskFolders = false
    @State private var accountToReview: ProviderAccount?
    @State private var recoveryPresented = false
    @State private var resultTranscript: SavedAgentOverviewSnapshot.ResultTranscript?
    @State private var resultLoading = false
    @State private var resultError: String?
    @State private var readingResult: SavedAgentOverviewSnapshot.LatestResult?
    @State private var activeResultRequest: ResultRequest?
    @State private var choosingPicture = false
    @State private var pictureError: String?

    private var profile: AgentProfile {
        agentTeams.agentProfiles.first { $0.id == initialProfile.id } ?? initialProfile
    }

    private struct ResultRequest: Hashable {
        let profileID: UUID
        let sessionID: String
        let modifiedAt: Double
        let runID: String?
    }

    private var overview: SavedAgentOverviewSnapshot {
        SavedAgentOverviewSnapshot.resolve(profile: profile,
            sessions: sessionCatalog.snapshot.sessions, definitions: model.agentDefinitions,
            connections: automation.connections, deliveries: automation.deliveries,
            occurrences: schedule.occurrencesBySchedule.values.flatMap { $0 },
            runs: activity.activityRuns, accounts: accounts.providerAccounts,
            readyAccountIDs: Set(accounts.accountStatus.compactMap { id, state in state.isHealthy ? id : nil }),
            accountModels: accounts.accountModels, accountStatuses: accounts.accountStatus,
            localModels: accounts.localModels.map(\.name),
            runningSessionIDs: model.runningChatSessionIDs,
            attentionSessionIDs: [], attentionItems: activity.attentionItems, workspace: workspace,
            resultTranscript: resultTranscript ?? model.savedAgentResultFixture(profileID: profile.id))
    }
    private var resultRequest: ResultRequest? {
        guard let id = overview.resultSessionID,
              let session = sessionCatalog.snapshot.sessionsByID[id],
              session.savedAgentProfileID == profile.id else { return nil }
        var modified = session.mtime
        for run in activity.activityRuns where run.sessionID == id { modified = max(modified, run.updatedAt) }
        for delivery in automation.deliveries where delivery.conversationSessionID == id { modified = max(modified, delivery.updatedAt) }
        for occurrences in schedule.occurrencesBySchedule.values {
            for occurrence in occurrences where occurrence.sessionID == id { modified = max(modified, occurrence.updatedAt) }
        }
        return ResultRequest(profileID: profile.id, sessionID: id, modifiedAt: modified, runID: overview.latestResult?.runID)
    }
    private var ink: Color { viewColors.ink }
    private var secondary: Color { viewColors.inkSoft }
    private var muted: Color { viewColors.muted }
    private var accent: Color { viewColors.accentAction }
    private var canvas: Color { viewColors.surfaceCanvas }
    private var newChatIsDisabled: Bool {
        newChatDisabled ?? (model.chatNavigationDisabled || model.creatingSavedAgentChatIDs.contains(profile.id))
    }

    var body: some View {
        let snapshot = overview
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(snapshot)
                    if showsReadiness(snapshot) { readiness(snapshot) }
                    if let error = automation.lastError ?? schedule.lastLoadError {
                        Label("Some information couldn’t be refreshed. \(error)", systemImage: "arrow.clockwise.circle")
                            .font(.locus(size: 12)).foregroundStyle(viewColors.warning).textSelection(.enabled)
                    }
                    if wide {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 24) {
                                latestResult(snapshot)
                                automations(snapshot)
                                chats(snapshot)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            VStack(alignment: .leading, spacing: 24) {
                                connectionHealth(snapshot)
                                instructionsPreview
                                workspaceSection
                            }
                            .frame(width: 300, alignment: .topLeading)
                        }
                    } else {
                        latestResult(snapshot)
                        automations(snapshot)
                        chats(snapshot)
                        connectionHealth(snapshot)
                        instructionsPreview
                        workspaceSection
                    }
                }
                .frame(maxWidth: 1080, alignment: .leading)
                .padding(wide ? 36 : 20)
                .frame(maxWidth: .infinity, alignment: .top)
            }.background(canvas)
        }
        .foregroundStyle(ink)
        .accessibilityIdentifier("savedAgent.overview")
        .fileImporter(isPresented: $choosingPicture, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= AgentAvatarImage.maximumSourceBytes else { throw AgentAvatarImage.AvatarError.tooLarge }
                let data = try AgentAvatarImage.normalized(Data(contentsOf: url, options: .mappedIfSafe))
                agentTeams.setAgentAvatar(data, profileID: profile.id)
            } catch { pictureError = error.localizedDescription }
        }
        .alert("Couldn’t change the picture", isPresented: Binding(
            get: { pictureError != nil }, set: { if !$0 { pictureError = nil } }
        )) { Button("OK") { pictureError = nil } } message: { Text(pictureError ?? "") }
        .task(id: profile.id) {
            guard model.persistenceEnabled, !model.isUITesting else { return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await refresh()
            }
        }
        .locusSheet(item: $accountToReview) { account in
            AccountEditorView(account: account, isNew: false)
                .appFeatureEnvironment(from: model)
        }
        .locusSheet(isPresented: $recoveryPresented) {
            ActivityCenterView()
                .appFeatureEnvironment(from: model)
                .frame(width: min(1120, (NSScreen.main?.visibleFrame.width ?? 1200) - 80),
                       height: min(780, (NSScreen.main?.visibleFrame.height ?? 900) - 100))
        }
        .locusSheet(item: $readingResult) { result in
            SavedAgentResultReader(result: result, workspacePath: resultWorkspace(result)) {
                readingResult = nil
                if let action = result.action { perform(action) }
            }
        }
        .onChange(of: activity.activityCenterPresented) {
            if !activity.activityCenterPresented { recoveryPresented = false }
        }
        .task(id: resultRequest) {
            guard model.persistenceEnabled, !model.isUITesting else { return }
            guard let request = resultRequest else { resultLoading = false; activeResultRequest = nil; return }
            await loadResult(request)
        }
        .onChange(of: profile.id) {
            showAllChats = false; showInstructions = false
            resultTranscript = nil; resultError = nil; resultLoading = false; activeResultRequest = nil
            readingResult = nil
        }
    }

    // MARK: Identity

    private func header(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                Button { choosingPicture = true } label: {
                    AgentAvatarView(profileID: profile.id, name: profile.name, size: 64)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill").font(.locus(size: 10))
                                .foregroundStyle(ink).padding(5).background(canvas, in: Circle())
                        }
                }
                .buttonStyle(.locus(.card)).fixedSize()
                .contextMenu {
                    Button("Choose picture…") { choosingPicture = true }
                    if agentTeams.agentAvatarData[profile.id] != nil {
                        Button("Remove picture") { agentTeams.setAgentAvatar(nil, profileID: profile.id) }
                    }
                }
                .help("Change \(profile.name)’s profile picture")
                .accessibilityLabel("Change profile picture for \(profile.name)")
                .accessibilityIdentifier("savedAgent.avatar")
                VStack(alignment: .leading, spacing: 5) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 10) { nameText; statusChip(snapshot) }
                        VStack(alignment: .leading, spacing: 6) { nameText; statusChip(snapshot) }
                    }
                    Text(headerSubtitle).font(.locus(size: 13)).foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("savedAgent.subtitle")
                }
                Spacer(minLength: 8)
                Button { Task { await refresh(manual: true) } } label: {
                    if manualRefreshing { ProgressView().controlSize(.small).frame(width: 24, height: 24) }
                    else { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                }
                .buttonStyle(.locus(.icon)).disabled(manualRefreshing)
                .help("Refresh this agent’s status").accessibilityLabel("Refresh agent status")
                .accessibilityIdentifier("savedAgent.refresh")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    facts(snapshot)
                    Spacer(minLength: 12)
                    HStack(spacing: 10) { primaryActions }.fixedSize()
                }
                VStack(alignment: .leading, spacing: 16) {
                    facts(snapshot)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { primaryActions }
                        VStack(alignment: .leading, spacing: 10) { primaryActions }
                    }
                }
            }
        }
    }

    private var nameText: some View {
        Text(profile.name).font(.locusExact(size: 30, weight: .semibold)).tracking(-0.7)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("savedAgent.name")
    }

    private var headerSubtitle: String {
        let path = workspace ?? profile.workspacePreferences?.defaultProjectPath ?? model.savedAgentHomePath(profile)
        let title = model.savedAgentWorkspaceTitle(profile, path: path)
        return "\(profile.specialtyTitle) · " + (workspace == nil ? "New chats start in \(title)" : "Working in \(title)")
    }

    private func statusChip(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        let color = readinessColor(snapshot)
        return HStack(spacing: 5) {
            Image(systemName: readinessSymbol(snapshot)).foregroundStyle(color).accessibilityHidden(true)
            Text(snapshot.statusTitle).foregroundStyle(snapshot.needsAttention ? viewColors.warning : secondary)
                .lineLimit(1)
        }
        .font(.locus(size: 12, weight: .semibold))
        .padding(.horizontal, 9).frame(height: 24)
        .background(color.opacity(0.10), in: Capsule())
        // Compress with truncation in the narrowest inspector instead of
        // pushing the refresh button out of the header.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(snapshot.statusTitle)")
        .accessibilityIdentifier("savedAgent.status")
    }

    private func facts(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        AgentFlowLayout(spacing: 16) {
            factChip(profile.accessCeiling.title, symbol: accessSymbol)
                .accessibilityLabel("Access: \(profile.accessCeiling.title)")
            factChip(automationSummary(snapshot), symbol: "bolt")
            factChip(chatSummary(snapshot), symbol: "bubble.left.and.bubble.right")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("savedAgent.facts")
    }

    private func factChip(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.locus(size: 11, weight: .medium))
                .accessibilityHidden(true)
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .font(.locus(size: 12)).foregroundStyle(secondary)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var accessSymbol: String {
        switch profile.accessCeiling {
        case .readOnly: "eye"
        case .workspaceWrite: "pencil"
        case .computerControl: "cursorarrow.click.2"
        }
    }

    private func automationSummary(_ snapshot: SavedAgentOverviewSnapshot) -> String {
        let count = snapshot.automations.count
        guard count > 0 else { return "No automations" }
        let summary = "\(count) \(count == 1 ? "automation" : "automations")"
        guard let next = snapshot.automations.compactMap(\.nextRunAt).min() else { return summary }
        let upcoming = AgentOverviewFormatting.upcoming(next)
        return summary + " · " + (upcoming == "overdue" ? "next run due" : "next \(upcoming)")
    }

    private func chatSummary(_ snapshot: SavedAgentOverviewSnapshot) -> String {
        let scope = workspace == nil ? "" : " in this project"
        return snapshot.chats.isEmpty ? "No chats\(scope) yet" : AgentOverviewFormatting.chatCount(snapshot.chats.count) + scope
    }

    /// Persistent setup stays together, leaving the agent's work in focus.
    private var instructionsPreview: some View {
        let text = profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let long = text.count > 120 || text.contains("\n")
        return card {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionTitle("Instructions", symbol: "text.alignleft")
                Spacer(minLength: 8)
                if !text.isEmpty {
                    Button("Edit") { model.presentSavedAgentEditor(profile) }
                        .buttonStyle(.locus()).foregroundStyle(accent).font(.locus(size: 12, weight: .medium))
                        .accessibilityLabel("Edit instructions")
                        .accessibilityIdentifier("savedAgent.instructions.edit")
                }
            }
            if text.isEmpty {
                Text("No custom instructions — follows the \(profile.specialtyTitle) defaults.")
                    .font(.locus(size: 13)).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("savedAgent.instructions.content")
                Button("Add instructions") { model.presentSavedAgentEditor(profile) }
                    .buttonStyle(.locus()).foregroundStyle(accent).font(.locus(size: 12, weight: .medium))
                    .accessibilityIdentifier("savedAgent.instructions.edit")
            } else {
                Text(text).font(.locus(size: 13)).foregroundStyle(secondary)
                    .lineSpacing(4)
                    .lineLimit(long && !showInstructions ? 4 : nil)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("savedAgent.instructions.content")
                if long {
                    Button(showInstructions ? "Show less" : "Show more") {
                        withAnimation(reduceMotion ? nil : LocusMotion.spatial) { showInstructions.toggle() }
                    }
                    .buttonStyle(.locus()).foregroundStyle(accent).font(.locus(size: 12, weight: .medium))
                    .accessibilityValue(showInstructions ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("savedAgent.instructions.toggle")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("savedAgent.instructions")
    }

    @ViewBuilder private var primaryActions: some View {
        HStack(spacing: 4) {
            Button { startChat() } label: { Label("New chat", systemImage: "plus.bubble") }
                .buttonStyle(.borderedProminent).tint(accent)
                .disabled(newChatIsDisabled)
                .accessibilityIdentifier("savedAgent.newChat")
            if newChat == nil {
                Menu {
                    ForEach(model.savedAgentWorkspaceChoices(profile), id: \.path) { choice in
                        Button(choice.title) { model.newSavedAgentChat(profile, workspace: choice.path) }
                            .help(choice.path)
                    }
                    Divider()
                    Button("Choose another project…") {
                        if let path = model.chooseSavedAgentProjectFolder() {
                            model.newSavedAgentChat(profile, workspace: path)
                        }
                    }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(model.chatNavigationDisabled || model.creatingSavedAgentChatIDs.contains(profile.id))
                .help("Choose a workspace for this new chat")
                .accessibilityLabel("New chat in workspace")
                .accessibilityIdentifier("savedAgent.newChatWorkspace")
            }
        }
        Menu { newAutomationItems } label: { Label("New automation", systemImage: "bolt") }
            .menuStyle(.button).buttonStyle(.bordered).fixedSize()
            .accessibilityLabel("New automation")
            .accessibilityIdentifier("savedAgent.newAutomation")
        Button { model.presentSavedAgentEditor(profile) } label: { Label("Edit agent", systemImage: "slider.horizontal.3") }
            .buttonStyle(.bordered).accessibilityIdentifier("savedAgent.edit")
    }

    /// Shared by the header and the Automations card so both start the same
    /// owner-bound editors.
    @ViewBuilder private var newAutomationItems: some View {
        ForEach(AgentConfigurationKind.allCases) { kind in
            Button { model.newSavedAgentAutomation(kind, profile: profile, workspace: workspace) } label: {
                Label(newAutomationTitle(kind), systemImage: kind.symbol)
            }
            .accessibilityIdentifier("savedAgent.newAutomation.\(kind.rawValue)")
        }
        Divider()
        Button("Manage automations…") { model.manageSavedAgent(profile, workspace: workspace) }
            .accessibilityIdentifier("savedAgent.manageAutomations")
    }

    private func newAutomationTitle(_ kind: AgentConfigurationKind) -> String {
        switch kind {
        case .schedule: "Schedule…"
        case .event: "Incoming event…"
        case .price: "Price alert…"
        }
    }

    // MARK: Sections

    private var workspaceSection: some View {
        card {
            if let workspace {
                sectionTitle("Working in", symbol: "folder")
                Text(model.savedAgentWorkspaceTitle(profile, path: workspace))
                    .font(.locus(size: 14, weight: .medium))
                Text(workspace).font(.locus(size: 11)).foregroundStyle(secondary).textSelection(.enabled)
                Text("New chats and automations opened from this map use this project.")
                    .font(.locus(size: 12)).foregroundStyle(secondary)
            } else {
                AgentWorkspacePreferencesEditor(profile: Binding(
                    get: { agentTeams.agentProfiles.first { $0.id == profile.id } ?? profile },
                    set: { agentTeams.saveAgentProfile($0) }), compact: true)
            }
            if let chat = currentWorkspaceChat,
               let root = chat.workspacePath {
                Divider()
                let execution = chat.executionPath ?? chat.cwd ?? root
                DisclosureGroup(isExpanded: $showTaskFolders) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(execution).font(.locus(size: 11)).foregroundStyle(secondary).textSelection(.enabled)
                        HStack(spacing: 12) {
                            Button("Open task folder") { NSWorkspace.shared.open(URL(fileURLWithPath: execution)) }
                                .disabled(!FileManager.default.fileExists(atPath: execution))
                            if let output = chat.environment?["output_directory"] {
                                Button("Open outputs") { NSWorkspace.shared.open(URL(fileURLWithPath: output)) }
                                    .disabled(!FileManager.default.fileExists(atPath: output))
                            }
                        }.buttonStyle(.bordered)
                    }.padding(.top, 8)
                } label: {
                    Text("\(chat.id == model.currentSessionID ? "This chat" : "Latest chat"): \(model.savedAgentWorkspaceTitle(profile, path: root))")
                        .font(.locus(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                .disclosureGroupStyle(SavedAgentDisclosureStyle(identifier: "savedAgent.taskFolders.toggle"))
            }
        }.accessibilityIdentifier("savedAgent.workspaces")
    }

    private var currentWorkspaceChat: SessionSummary? {
        let owned = model.savedAgentChats(profile.id).filter { chat in workspace.map(chat.belongsToWorkspace) ?? true }
        if model.savedAgentOverviewProfile == nil,
           let current = owned.first(where: { $0.id == model.currentSessionID }) { return current }
        return owned.first
    }

    /// The header chip already says "Ready"; the card explains anything else.
    private func showsReadiness(_ snapshot: SavedAgentOverviewSnapshot) -> Bool {
        !snapshot.issues.isEmpty || snapshot.status != .ready
    }

    private func readiness(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The header chip already names the status, and its detail repeats
            // the first issue. With concrete issues, list only those.
            if snapshot.issues.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: readinessSymbol(snapshot))
                        .font(.locus(size: 18, weight: .medium))
                        .foregroundStyle(readinessColor(snapshot))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot.statusTitle).font(.locus(size: 16, weight: .semibold))
                        Text(snapshot.detail).font(.locus(size: 13)).foregroundStyle(secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(Array(snapshot.issues.enumerated()), id: \.element.id) { index, issue in
                if index > 0 { Divider() }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        issueDescription(issue, snapshot: snapshot)
                        Spacer(minLength: 8)
                        issueAction(issue).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        issueDescription(issue, snapshot: snapshot)
                        issueAction(issue).padding(.leading, 28)
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background((snapshot.needsAttention ? viewColors.warning : accent).opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke((snapshot.needsAttention ? viewColors.warning : accent).opacity(0.22), lineWidth: 1))
        .accessibilityIdentifier("savedAgent.readiness")
    }

    private func issueDescription(_ issue: SavedAgentOverviewSnapshot.Issue,
                                  snapshot: SavedAgentOverviewSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: readinessSymbol(snapshot))
                .font(.locus(size: 15, weight: .medium))
                .foregroundStyle(readinessColor(snapshot)).padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).font(.locus(size: 13, weight: .semibold))
                Text(issue.detail).font(.locus(size: 12)).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func issueAction(_ issue: SavedAgentOverviewSnapshot.Issue) -> some View {
        if let action = issue.action {
            Button(actionTitle(action)) { perform(action) }.buttonStyle(.bordered)
                .accessibilityIdentifier("savedAgent.recovery.\(issue.id)")
        }
    }

    private func connectionHealth(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        card {
            sectionTitle("Connections", symbol: "point.3.connected.trianglepath.dotted")
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "cpu").foregroundStyle(secondary)
                        .frame(width: 28, height: 28)
                        .background(secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.route.title).font(.locus(size: 13, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if !snapshot.route.model.isEmpty {
                            Text(snapshot.route.model).font(.locus(size: 12)).foregroundStyle(secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: snapshot.route.issue != nil ? "exclamationmark.circle.fill" :
                            snapshot.route.isVerified ? "checkmark.circle" : "questionmark.circle")
                        .foregroundStyle(snapshot.route.issue != nil ? viewColors.warning :
                                            snapshot.route.isVerified ? viewColors.success : muted)
                        .help(snapshot.route.issue ?? snapshot.route.detail)
                        .accessibilityLabel(snapshot.route.issue ?? snapshot.route.detail)
                }
                // Account errors already have a recovery banner above the work.
                if snapshot.route.issue == nil {
                    Text(snapshot.route.detail).font(.locus(size: 12)).foregroundStyle(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(snapshot.route.accountID == nil ? "Model settings" : "Account settings") {
                    reviewAccount(snapshot.route.accountID)
                }
                    .buttonStyle(.locus()).foregroundStyle(accent).font(.locus(size: 12, weight: .medium))
            }
            if !snapshot.connections.isEmpty {
                Divider()
                ForEach(snapshot.connections) { connection in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: connection.isHealthy ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(connection.isHealthy ? viewColors.success : viewColors.warning)
                            .frame(width: 18).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.title).font(.locus(size: 13, weight: .medium))
                            Text(connection.detail).font(.locus(size: 12)).foregroundStyle(secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
                Button("Review connections") { reviewConnections() }
                    .buttonStyle(.locus()).foregroundStyle(accent).font(.locus(size: 12, weight: .medium))
            } else {
                Text("Event sources appear here when you add an automation.")
                    .font(.locus(size: 12)).foregroundStyle(secondary)
            }
        }.accessibilityIdentifier("savedAgent.connections")
    }

    private func latestResult(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        card(prominent: true) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Latest result", symbol: "text.bubble")
                Spacer(minLength: 8)
                if let result = snapshot.latestResult {
                    Text(AgentOverviewFormatting.relative(result.timestamp))
                        .font(.locus(size: 12)).foregroundStyle(secondary)
                        .help(result.timestamp.formatted(date: .complete, time: .shortened))
                }
            }
            if let result = snapshot.latestResult {
                VStack(alignment: .leading, spacing: 10) {
                    Text(result.title).font(.locusExact(size: 22, weight: .semibold)).tracking(-0.35)
                        .fixedSize(horizontal: false, vertical: true)
                    resultStatus(result)
                }.padding(.vertical, 4)
                Divider()
                if resultLoading && result.fullResponse == nil {
                    resultLoadingRow
                } else {
                    SavedAgentResultExcerptView(source: result.fullResponse ?? result.summary)
                        .accessibilityIdentifier("savedAgent.latestResult.preview")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { resultActions(result) }
                    VStack(alignment: .leading, spacing: 12) { resultActions(result) }
                }
                .padding(.top, 6)
            } else if resultLoading {
                resultLoadingRow
            } else {
                Image(systemName: "text.bubble").font(.system(size: 28, weight: .light))
                    .foregroundStyle(accent).padding(.top, 12).accessibilityHidden(true)
                Text("Ready for the first result")
                    .font(.locusExact(size: 20, weight: .semibold)).tracking(-0.3)
                Text("Start a chat or add an automation. \(profile.name)’s latest response will be waiting here.")
                    .font(.locus(size: 13)).foregroundStyle(secondary)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
            }
            if let resultError {
                Text(resultError).font(.locus(size: 12)).foregroundStyle(viewColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                if let request = resultRequest {
                    Button("Try again") { Task { await loadResult(request) } }
                        .buttonStyle(.bordered).disabled(resultLoading)
                }
            }
        }.accessibilityIdentifier("savedAgent.latestResult")
    }

    private func resultStatus(_ result: SavedAgentOverviewSnapshot.LatestResult) -> some View {
        Label(result.state == "completed" ? "Run completed" : result.statusTitle,
              systemImage: result.needsAttention ? "exclamationmark.circle" :
                result.isInProgress ? "circle.dotted" : result.state == "completed" ? "checkmark.circle" : "text.bubble")
            .font(.locus(size: 12, weight: .medium))
            .foregroundStyle(result.needsAttention ? viewColors.warning : secondary)
            .accessibilityIdentifier("savedAgent.latestResult.status")
    }

    @ViewBuilder private func resultActions(_ result: SavedAgentOverviewSnapshot.LatestResult) -> some View {
        if result.fullResponse != nil {
            Button { readingResult = result } label: {
                Label("Read full result", systemImage: "doc.text")
            }
            .buttonStyle(.bordered).controlSize(.large)
            .accessibilityIdentifier("savedAgent.latestResult.read")
        }
        if let action = result.action {
            Button { perform(action) } label: {
                HStack(spacing: 6) {
                    Text(resultActionTitle(action))
                    Image(systemName: "arrow.up.right").font(.locus(size: 10, weight: .medium))
                }
            }
            .buttonStyle(.locus()).foregroundStyle(accent).font(.locus(size: 12, weight: .medium))
            .accessibilityIdentifier("savedAgent.latestResult.open")
        }
    }

    private func resultActionTitle(_ action: SavedAgentOverviewSnapshot.Action) -> String {
        if case .activity = action { return "View activity" }
        return actionTitle(action)
    }

    private func resultWorkspace(_ result: SavedAgentOverviewSnapshot.LatestResult) -> String? {
        result.sessionID.flatMap { sessionCatalog.snapshot.sessionsByID[$0]?.workspacePath }
    }

    private var resultLoadingRow: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text("Loading saved response…").font(.locus(size: 12)).foregroundStyle(secondary)
        }
    }

    private func automations(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        card {
            HStack {
                sectionTitle("Automations", symbol: "bolt")
                Spacer(minLength: 8)
                Menu { newAutomationItems } label: { Label("Add", systemImage: "plus") }
                    .menuStyle(.button).buttonStyle(.bordered).fixedSize()
                    .accessibilityLabel("Add automation")
                    .accessibilityIdentifier("savedAgent.addAutomation")
            }
            if snapshot.automations.isEmpty {
                Text("Choose what starts this agent.").font(.locus(size: 14, weight: .medium))
                Text("Set a schedule, respond to an incoming event, or watch a price.")
                    .font(.locus(size: 13)).foregroundStyle(secondary)
            } else {
                ForEach(Array(snapshot.automations.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.vertical, 3) }
                    automationRow(item)
                }
            }
            Label("Automatic work runs on this Mac while Locus is open.", systemImage: "desktopcomputer")
                .font(.locus(size: 12)).foregroundStyle(secondary).padding(.top, 4)
        }.accessibilityIdentifier("savedAgent.automations")
    }

    private func automationRow(_ item: SavedAgentOverviewSnapshot.Automation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.definition.isSchedule ? "calendar.badge.clock" : "bolt")
                    .foregroundStyle(accent).frame(width: 20, height: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.definition.name).font(.locus(size: 14, weight: .semibold))
                    Text(item.definition.kindTitle).font(.locus(size: 12)).foregroundStyle(secondary)
                }
                Spacer(minLength: 8)
                stateBadge(item.statusTitle, warning: item.needsAttention, busy: item.isBusy)
            }
            Text(item.detail).font(.locus(size: 13)).foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let next = item.nextRunAt {
                Label { Text("Next · \(next.formatted(date: .abbreviated, time: .shortened))") } icon: { Image(systemName: "clock") }
                    .font(.locus(size: 12)).foregroundStyle(secondary)
            }
            if let latest = item.latestActivity {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Last · \(latest.statusTitle)").font(.locus(size: 12, weight: .medium))
                        .foregroundStyle(latest.needsAttention ? viewColors.warning : secondary)
                    Text(Date(timeIntervalSince1970: latest.timestamp), style: .relative)
                        .font(.locus(size: 12)).foregroundStyle(secondary)
                }
                if let error = latest.error, !error.isEmpty {
                    Text(error).font(.locus(size: 12)).foregroundStyle(secondary).lineLimit(3).textSelection(.enabled)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { automationActions(item) }
                VStack(alignment: .leading, spacing: 10) { automationActions(item) }
            }
        }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("savedAgent.automation.\(item.id)")
    }

    @ViewBuilder private func automationActions(_ item: SavedAgentOverviewSnapshot.Automation) -> some View {
        Button(item.needsAttention ? "Review setup" : "Edit") { model.editAgent(item.definition) }
            .buttonStyle(.bordered)
        if item.enabled {
            Button("Pause") { model.setAgentEnabled(item.definition, enabled: false) }
                .buttonStyle(.bordered).disabled(model.isChangingAgentEnabled(item.definition))
                .help("Pause future automatic starts; work already running is not stopped")
                .accessibilityLabel("Pause \(item.definition.name)")
                .accessibilityIdentifier("savedAgent.automation.\(item.id).pause")
        } else {
            Button("Resume") { model.setAgentEnabled(item.definition, enabled: true) }
                .buttonStyle(.bordered).disabled(model.isChangingAgentEnabled(item.definition))
                .help("Resume future automatic starts; this does not retry past work")
                .accessibilityLabel("Resume \(item.definition.name)")
                .accessibilityIdentifier("savedAgent.automation.\(item.id).resume")
        }
        if let latest = item.latestActivity {
            Button("View activity") { inspect(latest.context) }
                .buttonStyle(.locus()).foregroundStyle(accent)
        }
    }

    private func chats(_ snapshot: SavedAgentOverviewSnapshot) -> some View {
        card {
            sectionTitle(workspace == nil ? "Chats" : "Chats in this project", symbol: "bubble.left.and.bubble.right")
            if snapshot.chats.isEmpty {
                Text(workspace == nil ? "No chats yet." : "No chats in this project yet.")
                    .font(.locus(size: 13)).foregroundStyle(secondary)
                Button { startChat() } label: { Label("Start a chat", systemImage: "plus.bubble") }
                    .buttonStyle(.bordered).disabled(newChatIsDisabled)
                    .accessibilityIdentifier("savedAgent.chats.start")
            } else {
                ForEach(showAllChats ? snapshot.chats : Array(snapshot.chats.prefix(4))) { session in
                    Button { open(session) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: session.isAgentEventChat ? "bolt" : "bubble.left")
                                .foregroundStyle(muted).frame(width: 20, height: 22).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.displayTitle).font(.locus(size: 13, weight: .medium))
                                    .foregroundStyle(ink).lineLimit(1)
                                Text(session.isAgentEventChat ? "Receives automatic work" : "Conversation")
                                    .font(.locus(size: 12)).foregroundStyle(secondary)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right").font(.locus(size: 11, weight: .medium)).foregroundStyle(muted)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.locus()).disabled(model.chatNavigationDisabled && openChat == nil)
                    .accessibilityIdentifier("savedAgent.chat.\(session.id)")
                }
                if snapshot.chats.count > 4 {
                    Button(showAllChats ? "Show recent chats" : "Show all \(snapshot.chats.count) chats") { showAllChats.toggle() }
                        .buttonStyle(.locus()).foregroundStyle(accent).font(.locus(size: 12, weight: .medium))
                }
            }
        }.accessibilityIdentifier("savedAgent.chats")
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.locus(size: 14, weight: .semibold)).foregroundStyle(ink)
    }
    private func card<Content: View>(prominent: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: prominent ? 18 : 16, content: content)
            .padding(prominent ? 24 : 20).frame(maxWidth: .infinity, alignment: .leading)
            .locusSurface(.floating, radius: 18)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(viewColors.line.opacity(0.55), lineWidth: 1)
                .allowsHitTesting(false).accessibilityHidden(true))
            .accessibilityElement(children: .contain)
    }
    private func stateBadge(_ title: String, warning: Bool, busy: Bool) -> some View {
        Text(title).font(.locus(size: 11, weight: .medium))
            .foregroundStyle(warning ? viewColors.warning : busy ? accent : secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((warning ? viewColors.warning : busy ? accent : muted).opacity(0.08), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
    private func readinessSymbol(_ snapshot: SavedAgentOverviewSnapshot) -> String {
        if snapshot.needsAttention { return "exclamationmark.circle.fill" }
        if snapshot.isBusy { return "circle.dotted" }
        if snapshot.status == .unverified { return "questionmark.circle" }
        if snapshot.status == .paused { return "pause.circle" }
        return "checkmark.circle.fill"
    }
    private func readinessColor(_ snapshot: SavedAgentOverviewSnapshot) -> Color {
        if snapshot.needsAttention { return viewColors.warning }
        if snapshot.isBusy { return accent }
        if snapshot.status == .unverified || snapshot.status == .paused { return muted }
        return viewColors.success
    }
    private func startChat() { if let newChat { newChat() } else { model.newSavedAgentChat(profile) } }
    private func open(_ session: SessionSummary) {
        if let openChat { openChat(session); return }
        guard !model.chatNavigationDisabled else {
            model.showToast("Finish the current conversation change before opening another chat.")
            return
        }
        model.resume(session)
    }
    private func reviewConnections() {
        model.manageSavedAgent(profile, workspace: workspace)
        model.configureAgentTab = .sources
    }
    private func inspect(_ context: AgentInspectorContext) {
        if let inspectActivity { inspectActivity(context); return }
        model.agentInspector.show(context)
        model.selectInspectorTab(.agent)
    }
    private func reviewAccount(_ id: UUID?) {
        if let id, let account = accounts.providerAccounts.first(where: { $0.id == id }) {
            accountToReview = account
        } else {
            model.presentSavedAgentEditor(profile)
        }
    }
    private func actionTitle(_ action: SavedAgentOverviewSnapshot.Action) -> String {
        switch action {
        case .editAgent: "Review agent settings"
        case .manageAccount: "Review account"
        case .connections: "Review connections"
        case .automation: "Review automation"
        case .activity: "Review activity"
        case .attention: "Review recovery"
        case .chat: "Open chat"
        }
    }
    private func perform(_ action: SavedAgentOverviewSnapshot.Action) {
        switch action {
        case .editAgent: model.presentSavedAgentEditor(profile)
        case .manageAccount(let id): reviewAccount(id)
        case .connections: reviewConnections()
        case .automation(let reference):
            if let definition = model.inspectorAgentDefinition(reference) { model.editAgent(definition) }
        case .activity(let context): inspect(context)
        case .attention(let focus):
            activity.openActivityCenter(focus: focus)
            if inspectActivity != nil { recoveryPresented = true }
        case .chat(let id):
            if let session = sessionCatalog.snapshot.sessionsByID[id] { open(session) }
            else { model.showToast("This chat is no longer available. Its saved activity is still shown here.") }
        }
    }

    /// A manual refresh also forces the account catalogs. The periodic refresh
    /// skips a turn while any refresh is still running.
    @MainActor private func refresh(manual: Bool = false) async {
        if manual {
            guard !manualRefreshing else { return }
            manualRefreshing = true
        } else {
            guard !backgroundRefreshing, !manualRefreshing else { return }
            backgroundRefreshing = true
        }
        defer { if manual { manualRefreshing = false } else { backgroundRefreshing = false } }
        async let catalog: Void = accounts.refreshAccountCatalogs(force: manual)
        async let events: Void = automation.refresh(announceFailure: false)
        async let schedules: Void = schedule.refreshScheduledTasks(announceFailure: false)
        async let runs: Void = activity.refreshActivityRuns(announceFailure: false)
        _ = await (catalog, events, schedules, runs)
        for task in overview.automations.compactMap({ $0.definition.schedule }) {
            guard !Task.isCancelled else { return }
            await schedule.refreshOccurrences(for: task, announceFailure: false)
        }
    }

    @MainActor private func loadResult(_ request: ResultRequest) async {
        guard activeResultRequest != request else { return }
        activeResultRequest = request
        resultLoading = true
        resultError = nil
        defer {
            if activeResultRequest == request { resultLoading = false; activeResultRequest = nil }
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard let segment = request.sessionID.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
        do {
            let response = try await model.backend.get("/api/sessions/\(segment)",
                as: SavedAgentOverviewSnapshot.ResultTranscript.self)
            guard !Task.isCancelled, resultRequest == request, profile.id == request.profileID else { return }
            // The pure projection also verifies response ownership and the exact
            // run before it uses a final assistant answer as this agent's result.
            resultTranscript = response
        } catch {
            guard !Task.isCancelled, resultRequest == request else { return }
            resultError = "The saved response couldn’t be loaded. Open its activity for details."
        }
    }
}
