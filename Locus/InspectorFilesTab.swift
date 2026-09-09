import AppKit
import SwiftUI

struct InspectorFilesTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var workspaceFiles: WorkspaceFileModel

    var body: some View {
        WorkspaceBrowserFilesContent(workspaceFiles: workspaceFiles, browser: model.workspaceBrowser)
            .task(id: model.workspacePath) { model.activateWorkspaceBrowser() }
    }
}

private struct WorkspaceBrowserFilesContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var workspaceFiles: WorkspaceFileModel
    @ObservedObject var browser: WorkspaceBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if browser.workspace.isEmpty {
                        Text("Waiting for the workspace…")
                            .foregroundStyle(LocusTheme.muted).padding()
                    } else if browser.isSearching {
                        searchContent
                    } else {
                        ForEach(Array(browser.rows.enumerated()), id: \.element.id) { index, row in treeRow(row, index: index) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            if let path = workspaceFiles.previewedPath { filePeek(path) }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(LocusTheme.muted)
                TextField("Search workspace", text: $browser.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("files.search")
                if !browser.query.isEmpty {
                    Button { browser.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.locus())
                        .accessibilityLabel("Clear file search")
                }
            }
            .font(.locus(size: 11))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(LocusTheme.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(LocusTheme.line, lineWidth: 1) }

            HStack(spacing: 8) {
                Text(countLabel)
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .accessibilityIdentifier("files.count")
                Spacer()
                Menu {
                    Toggle("Show hidden files", isOn: $browser.showHidden)
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("File visibility")
                    .accessibilityIdentifier("files.visibility")
                Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.locus())
                    .help("Refresh workspace files")
                    .accessibilityLabel("Rescan workspace")
                    .accessibilityIdentifier("files.refresh")
                Button { model.openWorkspaceInFinder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.locus())
                    .help("Reveal workspace in Finder")
                    .accessibilityLabel("Reveal workspace in Finder")
                    .accessibilityIdentifier("files.reveal")
            }
            .foregroundStyle(LocusTheme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(LocusTheme.line).frame(height: 1) }
    }

    private var countLabel: String {
        if browser.isSearching {
            if browser.searchPaused { return "\(browser.searchResults.count) matches · search paused" }
            if browser.searchState == .loading { return "\(browser.searchResults.count) matches · searching…" }
            if !browser.searchWarnings.isEmpty { return "\(browser.searchResults.count) matches · partial search" }
            return "\(browser.searchResults.count) matches"
        }
        if browser.rootState == .loading { return "Loading workspace…" }
        return "\(browser.directories[""]?.entries.count ?? 0) items in workspace root"
    }

    @ViewBuilder
    private var searchContent: some View {
        ForEach(Array(browser.visibleSearchResults.enumerated()), id: \.element.id) { index, entry in
            fileRow(entry, index: index, depth: 0, search: true)
        }
        if browser.searchResults.count > browser.searchVisibleCount {
            Button("Show 200 more matches") { browser.showMoreSearchResults() }
                .buttonStyle(.locus()).padding(8)
        }
        if browser.searchState == .loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching workspace · \(browser.searchExamined) items checked")
            }.font(.locus(size: 9)).foregroundStyle(LocusTheme.muted).padding(8)
        } else if case .failed(let error) = browser.searchState {
            failure(error) { browser.refresh() }
        } else if browser.searchPaused {
            VStack(alignment: .leading, spacing: 6) {
                Text("Search paused after \(browser.searchResults.count) matches. More files may match.")
                    .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                Button("Continue searching") { browser.continueSearch() }.buttonStyle(.locus())
            }.padding(8)
        } else if browser.searchResults.isEmpty {
            InspectorPlaceholder(symbol: "magnifyingglass", title: "No matching files",
                message: "No visible files or folders match this search. Hidden files can be included from File visibility.",
                identifier: "files.empty")
        }
        if !browser.searchWarnings.isEmpty {
            Text("Some folders could not be searched: " + browser.searchWarnings.joined(separator: ", "))
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.warningForeground).padding(8)
        }
    }

    @ViewBuilder
    private func treeRow(_ row: WorkspaceBrowserModel.Row, index: Int) -> some View {
        switch row.content {
        case .entry(let entry): fileRow(entry, index: index, depth: row.depth, search: false)
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading files…") }
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                .padding(.leading, CGFloat(row.depth) * 14 + 8).padding(.vertical, 8)
        case .failure(let path, let error):
            failure(error) { browser.loadDirectory(path) }.padding(.leading, CGFloat(row.depth) * 14)
        case .empty(let path):
            if path.isEmpty {
                InspectorPlaceholder(symbol: "folder", title: "No visible files",
                    message: "This workspace has no visible files or folders. Use File visibility to include hidden files.",
                    identifier: "files.empty")
            } else {
                Text("Empty folder").font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                    .padding(.leading, CGFloat(row.depth) * 14 + 8).padding(.vertical, 6)
            }
        case .more(let path, let remaining):
            Button("Show \(min(200, remaining)) more · \(remaining) remaining") { browser.showMore(in: path) }
                .buttonStyle(.locus()).font(.locus(size: 9))
                .padding(.leading, CGFloat(row.depth) * 14 + 8).padding(.vertical, 8)
        }
    }

    private func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Could not load files", systemImage: "exclamationmark.triangle")
            Text(message).foregroundStyle(LocusTheme.muted)
            Button("Retry", action: retry).buttonStyle(.locus())
        }.font(.locus(size: 9)).padding(8)
    }

    private func fileRow(_ entry: WorkspaceBrowserEntry, index: Int, depth: Int, search: Bool) -> some View {
        HStack(spacing: 4) {
            Button { model.openWorkspaceBrowserEntry(entry) } label: {
                HStack(spacing: 7) {
                    Image(systemName: entry.isDirectory && browser.expanded.contains(entry.path) ? "chevron.down" : "chevron.right")
                        .font(.locus(size: 8)).opacity(entry.isDirectory ? 1 : 0).frame(width: 8)
                    Image(systemName: entry.symbol).font(.locus(size: 11)).foregroundStyle(LocusTheme.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.locus(size: 10, weight: .semibold))
                            .foregroundStyle(LocusTheme.ink).lineLimit(1).truncationMode(.middle)
                        if search {
                            Text(entry.path).font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: search ? 42 : 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .accessibilityLabel(entry.isDirectory
                ? "\(browser.expanded.contains(entry.path) ? "Collapse" : "Expand") folder \(entry.path)"
                : "Open \(entry.path)")
            .accessibilityIdentifier("files.row.\(index)")
            if let title = entry.contextAction.label {
                Button { model.addWorkspaceBrowserEntry(entry) } label: {
                    Image(systemName: entry.contextAction == .context ? "plus.circle" : "paperclip")
                        .font(.locus(size: 10)).frame(width: 24, height: 28)
                }
                .buttonStyle(.locus()).foregroundStyle(LocusTheme.muted)
                .help(title).accessibilityLabel(title + " " + entry.name)
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 4)
        .frame(minHeight: search ? 42 : 32)
        .background(browser.selectedPath == entry.path ? LocusTheme.white : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contextMenu {
            Button(entry.isDirectory ? "Open folder" : "Open") { model.openWorkspaceBrowserEntry(entry) }
            if let title = entry.contextAction.label { Button(title) { model.addWorkspaceBrowserEntry(entry) } }
            if !entry.isDirectory {
                Button("Mention in composer") { model.mentionFileInComposer(URL(fileURLWithPath: browser.workspace).appendingPathComponent(entry.path)) }
            }
            Button("Reveal in Finder") { model.revealInFinder(entry.path) }
            Button("Copy relative path") { model.copyMessage(entry.path) }
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
