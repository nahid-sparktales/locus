import AppKit
import SwiftUI

/// Search-first browser over the workspace file index. Flat rather than a
/// tree: the index is already flat and path-sorted, and at this width
/// indentation is the scarcest thing on screen.
struct InspectorFilesTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var workspaceFiles: WorkspaceFileModel

    private var files: [URL] { workspaceFiles.filteredFiles }

    var body: some View {
        VStack(spacing: 0) {
            header

            if files.isEmpty {
                InspectorPlaceholder(
                    symbol: "folder",
                    title: workspaceFiles.query.isEmpty
                        ? "No files indexed" : "No matching files",
                    message: workspaceFiles.query.isEmpty
                        ? "Locus indexes the text files in your workspace so you can attach them without leaving the conversation."
                        : "Nothing in this workspace matches that search.",
                    identifier: "files.empty"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(files.enumerated()), id: \.element) { index, url in
                            WorkspaceFileRow(
                                workspaceFiles: workspaceFiles,
                                url: url,
                                index: index
                            )
                                .environmentObject(model)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }

            if let path = workspaceFiles.previewedPath {
                filePeek(path)
            }
        }
        .task(id: model.workspacePath) {
            workspaceFiles.refresh()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.locus(size: 10))
                    .foregroundStyle(LocusTheme.muted)
                TextField("Search files", text: $workspaceFiles.query)
                    .textFieldStyle(.plain)
                    .font(.locus(size: 11))
                    .accessibilityIdentifier("files.search")
                if !workspaceFiles.query.isEmpty {
                    Button {
                        workspaceFiles.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.locus())
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityLabel("Clear file search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(LocusTheme.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }

            HStack(spacing: 8) {
                Text("\(files.count) of \(workspaceFiles.files.count) files")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityIdentifier("files.count")
                Spacer()
                Button {
                    workspaceFiles.refresh(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.locus())
                .foregroundStyle(LocusTheme.muted)
                .help("Rescan the workspace")
                .accessibilityLabel("Rescan workspace")
                .accessibilityIdentifier("files.refresh")

                Button {
                    model.openWorkspaceInFinder()
                } label: {
                    Image(systemName: "folder")
                        .accessibilityHidden(true)
                }
                .buttonStyle(.locus())
                .foregroundStyle(LocusTheme.muted)
                .help("Reveal workspace in Finder")
                .accessibilityLabel("Reveal workspace in Finder")
                .accessibilityIdentifier("files.reveal")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private func filePeek(_ path: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(path)
                    .font(.locus(size: 9, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                if let location = workspaceFiles.previewedLocation {
                    Text(
                        location.column.map { "Line \(location.line), col \($0)" }
                            ?? "Line \(location.line)"
                    )
                    .font(.locus(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(LocusTheme.signalDeep.opacity(0.12))
                    .clipShape(Capsule())
                }
                Spacer()
                Button {
                    model.openFileViewer(
                        path: path,
                        location: workspaceFiles.previewedLocation
                    )
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.locus(size: 9, weight: .semibold))
                }
                .buttonStyle(.locus())
                .foregroundStyle(LocusTheme.muted)
                .help("Open in the file viewer")
                .accessibilityLabel("Open \(path) in the file viewer")
                .accessibilityIdentifier("files.preview.expand")
                Button {
                    workspaceFiles.closePreview()
                } label: {
                    Image(systemName: "xmark")
                        .font(.locus(size: 9, weight: .semibold))
                }
                .buttonStyle(.locus())
                .foregroundStyle(LocusTheme.muted)
                .accessibilityLabel("Close preview")
                .accessibilityIdentifier("files.preview.close")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            if let contents = workspaceFiles.previewedContents {
                WorkspaceSourceTextView(
                    contents: contents,
                    location: workspaceFiles.previewedLocation
                )
                .accessibilityIdentifier("files.preview.source")
                .frame(maxHeight: 260)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            }
        }
        .background(LocusTheme.white)
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }
}

private struct WorkspaceFileRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var workspaceFiles: WorkspaceFileModel
    let url: URL
    let index: Int

    private var relativePath: String {
        WorkspaceIndex.relativePath(url, root: model.workspacePath)
    }

    private var isSelected: Bool { workspaceFiles.previewedPath == relativePath }

    var body: some View {
        Button {
            if isSelected { workspaceFiles.closePreview() } else { workspaceFiles.preview(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.locus(size: 10))
                    .foregroundStyle(LocusTheme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let directory = (relativePath as NSString).deletingLastPathComponent
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    model.addWorkspaceFileToContext(relativePath)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.locus(size: 10))
                }
                .buttonStyle(.locus())
                .foregroundStyle(LocusTheme.muted)
                .help("Add to context")
                .accessibilityLabel("Add \(url.lastPathComponent) to context")
                .accessibilityIdentifier("files.row.\(index).addContext")
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(isSelected ? LocusTheme.white : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityLabel(relativePath)
        .accessibilityIdentifier("files.row.\(index)")
        .contextMenu {
            Button("Add to Context") { model.addWorkspaceFileToContext(relativePath) }
            Button("Mention in Composer") { model.mentionFileInComposer(url) }
            Divider()
            Button("Open in Viewer") { model.openFileViewer(path: relativePath) }
            Button("Reveal in Finder") { model.revealInFinder(relativePath) }
            Button("Open in Default App") { NSWorkspace.shared.open(url) }
            Button("Copy Relative Path") { model.copyMessage(relativePath) }
        }
    }
}
