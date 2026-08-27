import Foundation
import SwiftUI

/// Safe, workspace-root-only access for the instruction file edited by the
/// AGENTS.md inspector tab. Keeping this boundary outside the view makes the
/// same traversal and size checks apply to create, read, refresh and save.
enum AgentInstructionsFile {
    static let filename = "AGENTS.md"
    static let maximumByteCount = 256_000

    struct Snapshot: Equatable, Sendable {
        let exists: Bool
        let content: String
        let error: String?
    }

    enum Failure: LocalizedError {
        case workspaceMissing
        case symbolicLink
        case notARegularFile
        case tooLarge
        case notUTF8

        var errorDescription: String? {
            switch self {
            case .workspaceMissing:
                "The selected workspace is not available."
            case .symbolicLink:
                "AGENTS.md is a symbolic link. Locus will not edit a file outside the workspace."
            case .notARegularFile:
                "AGENTS.md is not a regular text file."
            case .tooLarge:
                "AGENTS.md is larger than the 256 KB editor limit."
            case .notUTF8:
                "AGENTS.md is not valid UTF-8 text."
            }
        }
    }

    static func url(for root: String) -> URL {
        URL(fileURLWithPath: root, isDirectory: true)
            .standardizedFileURL
            .appending(path: filename, directoryHint: .notDirectory)
    }

    static func load(from root: String) -> Snapshot {
        let target = url(for: root)
        guard FileManager.default.fileExists(atPath: target.path) else {
            return Snapshot(exists: false, content: "", error: nil)
        }
        do {
            try validate(target: target, root: root, mustExist: true)
            let data = try Data(contentsOf: target, options: .mappedIfSafe)
            guard data.count <= maximumByteCount else { throw Failure.tooLarge }
            guard let content = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
            return Snapshot(exists: true, content: content, error: nil)
        } catch {
            return Snapshot(exists: true, content: "", error: error.localizedDescription)
        }
    }

    static func save(_ content: String, in root: String) throws {
        let data = Data(content.utf8)
        guard data.count <= maximumByteCount else { throw Failure.tooLarge }
        let target = url(for: root)
        try validate(
            target: target,
            root: root,
            mustExist: FileManager.default.fileExists(atPath: target.path)
        )
        try data.write(to: target, options: .atomic)
    }

    private static func validate(target: URL, root: String, mustExist: Bool) throws {
        let manager = FileManager.default
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Failure.workspaceMissing
        }

        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedParent = target.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedParent.path == resolvedRoot.path else { throw Failure.symbolicLink }

        guard mustExist else { return }
        let values = try target.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isRegularFileKey,
            .fileSizeKey,
        ])
        guard values.isSymbolicLink != true else { throw Failure.symbolicLink }
        guard values.isRegularFile == true else { throw Failure.notARegularFile }
        guard (values.fileSize ?? 0) <= maximumByteCount else { throw Failure.tooLarge }
    }
}

/// Small, practical building blocks for people who know what they want from
/// the agent but not how to phrase durable workspace guidance yet. Starters
/// append instead of replacing so choosing one never destroys existing rules.
enum AgentInstructionsStarter: String, CaseIterable, Identifiable {
    case conventions
    case verification
    case boundaries
    case interfaceQuality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conventions: "Project conventions"
        case .verification: "Verification steps"
        case .boundaries: "Safe boundaries"
        case .interfaceQuality: "UI quality checklist"
        }
    }

    var symbol: String {
        switch self {
        case .conventions: "list.bullet.rectangle"
        case .verification: "checkmark.circle"
        case .boundaries: "hand.raised"
        case .interfaceQuality: "macwindow"
        }
    }

    var markdown: String {
        switch self {
        case .conventions:
            """
            ## Project conventions

            - Follow existing patterns and naming before introducing new abstractions.
            - Keep changes scoped to the request and preserve unrelated work.
            """
        case .verification:
            """
            ## Verification

            - Run the smallest relevant tests after each meaningful change.
            - Before finishing, run the broader checks appropriate to the files changed.
            - Report anything you could not verify.
            """
        case .boundaries:
            """
            ## Boundaries

            - Do not edit generated files or vendored dependencies unless explicitly asked.
            - Ask before destructive actions or changes outside this workspace.
            - Never include secrets in code, logs, or commits.
            """
        case .interfaceQuality:
            """
            ## UI changes

            - Match existing components, spacing, typography, and interaction patterns.
            - Check keyboard access, VoiceOver labels, empty states, and reduced motion.
            - Verify the finished flow at compact and expanded window sizes.
            """
        }
    }

    var document: String {
        "# Workspace instructions\n\n\(markdown)\n"
    }

    func appending(to existing: String) -> String {
        let base = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return document }
        return "\(base)\n\n\(markdown)\n"
    }
}

struct InspectorAgentsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.isLoadingAgentInstructions {
                ProgressView("Loading AGENTS.md…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.agentInstructionsExists {
                editor
            } else {
                missingState
            }
        }
        .task(id: model.workspacePath) {
            model.refreshAgentInstructions()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "doc.text.fill")
                    .font(.locus(size: 13, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 28, height: 28)
                    .background(LocusTheme.signal.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("AGENTS.md")
                        .font(.locus(size: 12, weight: .bold, design: .monospaced))
                    Text("Workspace instructions")
                        .font(.locus(size: 8, weight: .medium))
                        .foregroundStyle(LocusTheme.muted)
                        .accessibilityIdentifier("agents.content")
                }
                Spacer(minLength: 4)
                Button {
                    model.refreshAgentInstructions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.locus())
                .foregroundStyle(LocusTheme.muted)
                .disabled(model.isLoadingAgentInstructions || model.isSavingAgentInstructions)
                .help("Reload AGENTS.md from disk")
                .accessibilityLabel("Reload AGENTS.md from disk")
                .accessibilityIdentifier("agents.refresh")
                if model.agentInstructionsExists {
                    Button {
                        model.revealAgentInstructionsInFinder()
                    } label: {
                        Image(systemName: "folder")
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.locus())
                    .foregroundStyle(LocusTheme.muted)
                    .help("Reveal AGENTS.md in Finder")
                    .accessibilityLabel("Reveal AGENTS.md in Finder")
                    .accessibilityIdentifier("agents.reveal")
                }
            }

            Text("Give the coding agent durable project conventions, commands, boundaries, and verification steps.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Label("Every Work turn", systemImage: "arrow.triangle.2.circlepath")
                Label("Project file", systemImage: "person.2")
                Spacer(minLength: 0)
            }
            .font(.locus(size: 8, weight: .medium))
            .foregroundStyle(LocusTheme.muted)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loaded for every Work turn and stored as a project file")

            Text("Keep secrets out. Commit the file when teammates should receive the same guidance.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement()
                .accessibilityLabel("How AGENTS.md works")
                .accessibilityIdentifier("agents.explanation")

            if let error = model.agentInstructionsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.locus(size: 8, weight: .medium))
                    .foregroundStyle(LocusTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agents.error")
            }
        }
        .padding(14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                starterMenu
                Spacer()
                Label(
                    model.agentInstructionsHasUnsavedChanges ? "Unsaved" : "Saved",
                    systemImage: model.agentInstructionsHasUnsavedChanges
                        ? "circle.fill" : "checkmark.circle.fill"
                )
                .font(.locus(size: 8, weight: .semibold))
                .foregroundStyle(
                    model.agentInstructionsHasUnsavedChanges
                        ? LocusTheme.warning
                        : LocusTheme.success
                )
                .accessibilityIdentifier("agents.saveState")
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(LocusTheme.paperDeep.opacity(0.42))
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            TextEditor(text: $model.agentInstructionsDraft)
                .font(.locus(size: 10, design: .monospaced))
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(LocusTheme.white)
                .accessibilityLabel("AGENTS.md contents")
                .accessibilityIdentifier("agents.editor")

            HStack(spacing: 10) {
                Text(model.isBusy ? "Available after the current run" : "Applies to the next Work turn")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                Spacer(minLength: 4)
                Button("Revert") {
                    model.revertAgentInstructions()
                }
                .buttonStyle(.locus())
                .font(.locus(size: 9, weight: .semibold))
                .disabled(!model.agentInstructionsHasUnsavedChanges || model.isSavingAgentInstructions)
                .accessibilityIdentifier("agents.revert")
                Button {
                    model.saveAgentInstructions()
                } label: {
                    if model.isSavingAgentInstructions {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .controlSize(.small)
                .disabled(
                    !model.agentInstructionsHasUnsavedChanges
                        || model.isSavingAgentInstructions
                        || model.isBusy
                        || model.hasPendingPermission
                )
                .accessibilityIdentifier("agents.save")
            }
            .padding(.horizontal, 13)
            .frame(height: 46)
            .background(LocusTheme.paperDeep.opacity(0.42))
            .overlay(alignment: .top) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }
        }
    }

    private var starterMenu: some View {
        Menu {
            Section("Append sample guidance") {
                ForEach(AgentInstructionsStarter.allCases) { starter in
                    Button {
                        model.agentInstructionsDraft = starter.appending(
                            to: model.agentInstructionsDraft
                        )
                    } label: {
                        Label(starter.title, systemImage: starter.symbol)
                    }
                    .accessibilityIdentifier("agents.starter.\(starter.rawValue)")
                }
            }
        } label: {
            Label("Starter prompts", systemImage: "plus.circle")
                .font(.locus(size: 9, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Append sample guidance to AGENTS.md")
        .accessibilityLabel("Starter prompts for AGENTS.md")
        .accessibilityIdentifier("agents.starters")
    }

    private var missingState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.locus(size: 26))
                .foregroundStyle(LocusTheme.muted)
            Text("No AGENTS.md in this workspace")
                .font(.locus(size: 11, weight: .bold))
            Text("Create one at the workspace root, then add the instructions the agent should follow while planning, editing, and verifying work.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.createAgentInstructions()
            } label: {
                Label("Create AGENTS.md", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(LocusTheme.ink)
            .controlSize(.small)
            .disabled(model.isBusy || model.hasPendingPermission || model.isSavingAgentInstructions)
            .accessibilityIdentifier("agents.create")

            Menu {
                ForEach(AgentInstructionsStarter.allCases) { starter in
                    Button {
                        model.agentInstructionsDraft = starter.document
                        model.saveAgentInstructions()
                    } label: {
                        Label(starter.title, systemImage: starter.symbol)
                    }
                    .accessibilityIdentifier("agents.createStarter.\(starter.rawValue)")
                }
            } label: {
                Text("Create from a starter")
                    .font(.locus(size: 9, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isBusy || model.hasPendingPermission || model.isSavingAgentInstructions)
            .accessibilityIdentifier("agents.createFromStarter")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("agents.empty")
    }
}
