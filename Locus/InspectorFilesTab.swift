import AppKit
import SwiftUI

/// Search-first browser over the workspace file index. Flat rather than a
/// tree: the index is already flat and path-sorted, and at this width
/// indentation is the scarcest thing on screen.
struct InspectorFilesTab: View {
    @EnvironmentObject private var model: AppModel

    private var files: [URL] { model.filteredWorkspaceFiles }

    var body: some View {
        VStack(spacing: 0) {
            header

            if files.isEmpty {
                InspectorPlaceholder(
                    symbol: "folder",
                    title: model.fileQuery.isEmpty ? "No files indexed" : "No matching files",
                    message: model.fileQuery.isEmpty
                        ? "Locus indexes the text files in your workspace so you can attach them without leaving the conversation."
                        : "Nothing in this workspace matches that search.",
                    identifier: "files.empty"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(files.enumerated()), id: \.element) { index, url in
                            WorkspaceFileRow(url: url, index: index)
                                .environmentObject(model)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }

            if let path = model.previewedFilePath {
                filePeek(path)
            }
        }
        .task(id: model.workspacePath) {
            model.refreshWorkspaceIndex()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(LocusTheme.muted)
                TextField("Search files", text: $model.fileQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("files.search")
                if !model.fileQuery.isEmpty {
                    Button {
                        model.fileQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
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
                Text("\(files.count) of \(model.workspaceFileIndex.count) files")
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityIdentifier("files.count")
                Spacer()
                Button {
                    model.refreshWorkspaceIndex(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LocusTheme.muted)
                .help("Rescan the workspace")
                .accessibilityLabel("Rescan workspace")
                .accessibilityIdentifier("files.refresh")

                Button {
                    model.openWorkspaceInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
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
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button {
                    model.closeFilePreview()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LocusTheme.muted)
                .accessibilityLabel("Close preview")
                .accessibilityIdentifier("files.preview.close")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)

            if let contents = model.previewedFileContents {
                ScrollView {
                    CodeBlockView(language: (path as NSString).pathExtension, code: contents)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
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
    let url: URL
    let index: Int

    private var relativePath: String {
        WorkspaceIndex.relativePath(url, root: model.workspacePath)
    }

    private var isSelected: Bool { model.previewedFilePath == relativePath }

    var body: some View {
        Button {
            if isSelected { model.closeFilePreview() } else { model.previewFile(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(LocusTheme.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let directory = (relativePath as NSString).deletingLastPathComponent
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.system(size: 8))
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
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .accessibilityLabel(relativePath)
        .accessibilityIdentifier("files.row.\(index)")
        .contextMenu {
            Button("Add to Context") { model.addWorkspaceFileToContext(relativePath) }
            Button("Mention in Composer") { model.mentionFileInComposer(url) }
            Divider()
            Button("Reveal in Finder") { model.revealInFinder(relativePath) }
            Button("Open in Default App") { NSWorkspace.shared.open(url) }
            Button("Copy Relative Path") { model.copyMessage(relativePath) }
        }
    }
}
