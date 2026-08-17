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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text.fill")
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                Text("WORKSPACE INSTRUCTIONS")
                    .font(.locus(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityIdentifier("agents.content")
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

            Text("AGENTS.md gives the coding agent persistent guidance for this workspace: project conventions, commands, boundaries, and verification steps.")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Text("Locus loads the root file for every Work turn. It is ordinary project text, so keep secrets out and commit it when the guidance should be shared.")
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .lineSpacing(2)
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
            HStack {
                Text("AGENTS.md")
                    .font(.locus(size: 9, weight: .semibold, design: .monospaced))
                Spacer()
                Text(model.agentInstructionsHasUnsavedChanges ? "UNSAVED" : "SAVED")
                    .font(.locus(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(
                        model.agentInstructionsHasUnsavedChanges
                            ? LocusTheme.warning
                            : LocusTheme.muted
                    )
            }
            .padding(.horizontal, 13)
            .frame(height: 34)

            TextEditor(text: $model.agentInstructionsDraft)
                .font(.locus(size: 10, design: .monospaced))
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(LocusTheme.white)
                .overlay {
                    Rectangle().stroke(LocusTheme.line, lineWidth: 1)
                }
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
        }
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
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("agents.empty")
    }
}
