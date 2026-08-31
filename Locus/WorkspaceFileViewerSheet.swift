import AppKit
import SwiftUI

/// A workspace file opened for reading in a large sheet, the way the Notebook
/// opens: the inspector's file peek stays a glance, this is where the file is
/// actually read. View-only on purpose — editing belongs to the user's editor,
/// reachable from the header.
struct WorkspaceFileViewerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: WorkspaceFileViewerRequest

    @State private var contents: String?

    /// Reading gets a higher ceiling than the inspector peek: this surface
    /// exists for files worth more than a glance.
    private static let byteLimit = 1_500_000

    var body: some View {
        VStack(spacing: 0) {
            header
            if let contents {
                WorkspaceSourceTextView(
                    contents: contents,
                    location: request.location,
                    textSize: 11,
                    numberSize: 9,
                    numberColumnWidth: 44
                )
                .accessibilityIdentifier("fileViewer.source")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 880, height: 620)
        .background(LocusTheme.panel)
        .onExitCommand { dismiss() }
        .task(id: request.id) {
            contents = await WorkspaceFileModel.previewText(
                at: request.url,
                byteLimit: Self.byteLimit
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File viewer, \(request.relativePath)")
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(request.url.lastPathComponent)
                        .font(.locus(size: 15, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let location = request.location {
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
                }
                Text(request.relativePath)
                    .font(.locus(size: 9, design: .monospaced))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            headerAction("Add to Context", symbol: "plus.circle") {
                model.addWorkspaceFileToContext(request.relativePath)
            }
            headerAction("Reveal in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([request.url])
            }
            headerAction("Open in Default App", symbol: "arrow.up.forward.app") {
                NSWorkspace.shared.open(request.url)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.locus())
            .accessibilityLabel("Close file viewer")
            .accessibilityIdentifier("fileViewer.close")
        }
        .padding(16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private func headerAction(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 12))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.locus())
        .foregroundStyle(LocusTheme.muted)
        .help(title)
        .accessibilityLabel("\(title): \(request.relativePath)")
    }
}

/// Line-numbered, horizontally scrollable source text, shared between the
/// inspector's file peek and the viewer sheet so the two never drift. Content
/// is laid out at least viewport-wide and pinned leading — a two-axis
/// ScrollView otherwise centers a stack of short lines in a wide viewport.
struct WorkspaceSourceTextView: View {
    let contents: String
    let location: WorkspacePreviewLocation?
    var textSize: CGFloat = 9
    var numberSize: CGFloat = 8
    var numberColumnWidth: CGFloat = 34

    private var lines: [String] {
        contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            let number = index + 1
                            WorkspaceSourceTextRow(
                                line: line,
                                number: number,
                                isHighlighted: number == location?.line,
                                textSize: textSize,
                                numberSize: numberSize,
                                numberColumnWidth: numberColumnWidth
                            )
                            .id(number)
                        }
                    }
                    .padding(.vertical, 7)
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
                .background(LocusTheme.paperDeep.opacity(0.34))
                .onAppear { scroll(to: location?.line, proxy: proxy) }
                .onChange(of: location) { _, next in
                    scroll(to: next?.line, proxy: proxy)
                }
            }
        }
    }

    private func scroll(to line: Int?, proxy: ScrollViewProxy) {
        guard let line else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(min(max(line, 1), max(lines.count, 1)), anchor: .center)
        }
    }
}

private struct WorkspaceSourceTextRow: View {
    let line: String
    let number: Int
    let isHighlighted: Bool
    let textSize: CGFloat
    let numberSize: CGFloat
    let numberColumnWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(String(number))
                .font(.locus(size: numberSize, design: .monospaced))
                .foregroundStyle(isHighlighted ? LocusTheme.signalDeep : LocusTheme.muted)
                .frame(width: numberColumnWidth, alignment: .trailing)
                .textSelection(.disabled)
            Text(line.isEmpty ? " " : line)
                .font(.locus(size: textSize, design: .monospaced))
                .foregroundStyle(LocusTheme.inkSoft)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                // A whitespace placeholder renders only background, which the
                // contrast audit reads as text against itself.
                .accessibilityHidden(line.isEmpty)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: textSize * 2.2, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? LocusTheme.signalDeep.opacity(0.11) : Color.clear)
        .accessibilityLabel(
            isHighlighted
                ? "Highlighted line \(number): \(line)"
                : "Line \(number): \(line)"
        )
    }
}
