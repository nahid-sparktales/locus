import AppKit
import Markdown
import SwiftUI

struct MarkdownInlineStyle: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let strong = Self(rawValue: 1 << 0)
    static let emphasis = Self(rawValue: 1 << 1)
    static let strikethrough = Self(rawValue: 1 << 2)
    static let code = Self(rawValue: 1 << 3)
}

struct MarkdownInlineRun: Hashable, Sendable {
    let text: String
    var style: MarkdownInlineStyle = []
    var destination: String?
    var isImage = false
}

enum MarkdownColumnAlignment: Hashable, Sendable {
    case left
    case center
    case right
}

struct MarkdownRenderListItem: Hashable, Sendable {
    let checked: Bool?
    let blocks: [MarkdownRenderBlock]
}

indirect enum MarkdownRenderBlock: Hashable, Sendable {
    case paragraph([MarkdownInlineRun])
    case heading(level: Int, runs: [MarkdownInlineRun])
    case code(language: String?, body: String)
    case unordered([MarkdownRenderListItem])
    case ordered(start: Int, items: [MarkdownRenderListItem])
    case quote([MarkdownRenderBlock])
    case rule
    case table(
        headers: [[MarkdownInlineRun]],
        alignments: [MarkdownColumnAlignment],
        rows: [[[MarkdownInlineRun]]]
    )
    case rawText(String)
}

/// Converts Swift Markdown's GFM tree into a small Sendable display model.
/// The conversion is safe to perform off the main actor and deliberately
/// retains raw HTML as literal text instead of ever handing it to a web view.
enum MarkdownDocumentParser {
    static func parse(_ source: String) -> [MarkdownRenderBlock] {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        return blocks(in: document.children)
    }

    private static func blocks(in children: MarkupChildren) -> [MarkdownRenderBlock] {
        children.flatMap(blocks(for:))
    }

    private static func blocks(for markup: any Markup) -> [MarkdownRenderBlock] {
        switch markup {
        case let paragraph as Paragraph:
            return [.paragraph(inlineRuns(in: paragraph))]
        case let heading as Heading:
            return [.heading(level: heading.level, runs: inlineRuns(in: heading))]
        case let code as CodeBlock:
            return [.code(language: code.language, body: code.code)]
        case let list as UnorderedList:
            return [.unordered(list.children.compactMap(listItem))]
        case let list as OrderedList:
            return [.ordered(
                start: Int(list.startIndex),
                items: list.children.compactMap(listItem)
            )]
        case let quote as BlockQuote:
            return [.quote(blocks(in: quote.children))]
        case is ThematicBreak:
            return [.rule]
        case let table as Markdown.Table:
            return [tableBlock(table)]
        case let html as HTMLBlock:
            return [.rawText(html.rawHTML)]
        default:
            let nested = blocks(in: markup.children)
            if !nested.isEmpty { return nested }
            let runs = inlineRuns(in: markup)
            return runs.isEmpty ? [] : [.paragraph(runs)]
        }
    }

    private static func listItem(_ markup: any Markup) -> MarkdownRenderListItem? {
        guard let item = markup as? ListItem else { return nil }
        let checked: Bool?
        switch item.checkbox {
        case .checked: checked = true
        case .unchecked: checked = false
        case nil: checked = nil
        }
        return MarkdownRenderListItem(checked: checked, blocks: blocks(in: item.children))
    }

    private static func tableBlock(_ table: Markdown.Table) -> MarkdownRenderBlock {
        let headers = table.head.children.compactMap { child -> [MarkdownInlineRun]? in
            guard let cell = child as? Markdown.Table.Cell else { return nil }
            return inlineRuns(in: cell)
        }
        let rows = Array(table.body.rows.map { row in
            row.children.compactMap { child -> [MarkdownInlineRun]? in
                guard let cell = child as? Markdown.Table.Cell else { return nil }
                return inlineRuns(in: cell)
            }
        })
        let alignments = table.columnAlignments.map { alignment in
            switch alignment {
            case .center: MarkdownColumnAlignment.center
            case .right: MarkdownColumnAlignment.right
            case .left, nil: MarkdownColumnAlignment.left
            }
        }
        return .table(headers: headers, alignments: alignments, rows: rows)
    }

    private static func inlineRuns(
        in markup: any Markup,
        style: MarkdownInlineStyle = [],
        destination: String? = nil
    ) -> [MarkdownInlineRun] {
        var result: [MarkdownInlineRun] = []
        for child in markup.children {
            switch child {
            case let text as Markdown.Text:
                result.append(.init(text: text.string, style: style, destination: destination))
            case let code as InlineCode:
                result.append(.init(
                    text: code.code,
                    style: style.union(.code),
                    destination: destination
                ))
            case is SoftBreak:
                result.append(.init(text: " ", style: style, destination: destination))
            case is LineBreak:
                result.append(.init(text: "\n", style: style, destination: destination))
            case let html as InlineHTML:
                result.append(.init(text: html.rawHTML, style: style, destination: destination))
            case let strong as Strong:
                result += inlineRuns(
                    in: strong,
                    style: style.union(.strong),
                    destination: destination
                )
            case let emphasis as Emphasis:
                result += inlineRuns(
                    in: emphasis,
                    style: style.union(.emphasis),
                    destination: destination
                )
            case let strike as Strikethrough:
                result += inlineRuns(
                    in: strike,
                    style: style.union(.strikethrough),
                    destination: destination
                )
            case let link as Markdown.Link:
                result += inlineRuns(
                    in: link,
                    style: style,
                    destination: link.destination
                )
            case let image as Markdown.Image:
                let alt = inlineRuns(in: image).map(\.text).joined()
                result.append(.init(
                    text: alt.isEmpty ? "Image" : "Image: \(alt)",
                    style: style,
                    destination: image.source,
                    isImage: true
                ))
            default:
                result += inlineRuns(in: child, style: style, destination: destination)
            }
        }
        return result
    }
}

@MainActor
private enum FinishedMarkdownCache {
    private static var values: [String: [MarkdownRenderBlock]] = [:]
    private static var order: [String] = []
    private static let limit = 128

    static func blocks(for text: String) -> [MarkdownRenderBlock] {
        if let cached = values[text] { return cached }
        let parsed = MarkdownDocumentParser.parse(text)
        values[text] = parsed
        order.append(text)
        if order.count > limit {
            values.removeValue(forKey: order.removeFirst())
        }
        return parsed
    }
}

enum MarkdownRenderDensity: Sendable {
    case regular
    case compact

    var fontSize: CGFloat { self == .compact ? 11 : 13 }
    var lineSpacing: CGFloat { self == .compact ? 3 : 5 }
    var blockSpacing: CGFloat { self == .compact ? 8 : 12 }
}

struct MarkdownBodyView: View {
    let text: String
    var workspacePath: String? = nil
    var density: MarkdownRenderDensity = .regular

    var body: some View {
        MarkdownBlocksView(
            blocks: FinishedMarkdownCache.blocks(for: text),
            workspacePath: workspacePath,
            density: density
        )
    }
}

/// Streaming Markdown is parsed at the transcript's already-coalesced update
/// cadence on a detached task. A superseding text snapshot cancels the stale
/// presentation before it can replace the newest one.
struct StreamingMarkdownBodyView: View {
    let text: String
    var workspacePath: String? = nil
    var density: MarkdownRenderDensity = .regular
    @State private var blocks: [MarkdownRenderBlock] = []

    var body: some View {
        Group {
            if blocks.isEmpty, !text.isEmpty {
                StreamingPlainTextView(
                    text: text,
                    font: .systemFont(ofSize: density.fontSize),
                    color: NSColor(density == .compact ? LocusTheme.muted : LocusTheme.inkSoft),
                    lineSpacing: density.lineSpacing
                )
            } else {
                MarkdownBlocksView(
                    blocks: blocks,
                    workspacePath: workspacePath,
                    density: density
                )
            }
        }
        .task(id: text) {
            let snapshot = text
            let parseTask = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return [MarkdownRenderBlock]() }
                let parsed = MarkdownDocumentParser.parse(snapshot)
                return Task.isCancelled ? [] : parsed
            }
            let parsed = await withTaskCancellationHandler {
                await parseTask.value
            } onCancel: {
                parseTask.cancel()
            }
            guard !Task.isCancelled, snapshot == text else { return }
            blocks = parsed
        }
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownRenderBlock]
    let workspacePath: String?
    let density: MarkdownRenderDensity

    var body: some View {
        VStack(alignment: .leading, spacing: density.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(LocusTheme.signalDeep)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownRenderBlock) -> some View {
        switch block {
        case .paragraph(let runs):
            if let image = localImage(in: runs) {
                VStack(alignment: .leading, spacing: 6) {
                    SwiftUI.Image(nsImage: image.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 620, maxHeight: 420, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    SwiftUI.Text(image.label)
                        .font(.locus(size: 9, weight: .medium))
                        .foregroundStyle(LocusTheme.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(image.label)
            } else {
                prose(runs)
            }

        case .heading(let level, let runs):
            SwiftUI.Text(attributed(runs, headingLevel: level))
                .font(.locus(
                    size: density == .compact
                        ? (level <= 2 ? 13 : 11)
                        : (level == 1 ? 20 : (level == 2 ? 17 : 14)),
                    weight: level <= 2 ? .bold : .semibold
                ))
                .tracking(level <= 2 ? -0.2 : 0)
                .foregroundStyle(LocusTheme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let body):
            CodeBlockView(language: language, code: body)

        case .unordered(let items):
            list(items: items, start: nil)

        case .ordered(let start, let items):
            list(items: items, start: start)

        case .quote(let nested):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(LocusTheme.lineStrong.opacity(0.75))
                    .frame(width: 3)
                MarkdownBlocksView(
                    blocks: nested,
                    workspacePath: workspacePath,
                    density: density
                )
                .foregroundStyle(LocusTheme.muted)
            }
            .padding(.vertical, 2)

        case .rule:
            Rectangle()
                .fill(LocusTheme.line)
                .frame(height: 1)
                .padding(.vertical, 3)

        case .table(let headers, let alignments, let rows):
            MarkdownTableRenderer(
                headers: headers,
                alignments: alignments,
                rows: rows,
                workspacePath: workspacePath,
                density: density
            )

        case .rawText(let value):
            SwiftUI.Text(value)
                .font(.locus(size: density.fontSize, design: .monospaced))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineSpacing(density.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Raw HTML shown as text")
        }
    }

    private func list(items: [MarkdownRenderListItem], start: Int?) -> some View {
        VStack(alignment: .leading, spacing: density == .compact ? 4 : 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .top, spacing: 8) {
                    listMarker(item: item, number: start.map { $0 + offset })
                        .frame(width: start == nil ? 14 : 24, alignment: .trailing)
                    MarkdownBlocksView(
                        blocks: item.blocks,
                        workspacePath: workspacePath,
                        density: density
                    )
                }
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func listMarker(item: MarkdownRenderListItem, number: Int?) -> some View {
        if let checked = item.checked {
            SwiftUI.Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(checked ? LocusTheme.success : LocusTheme.muted)
                .padding(.top, 2)
        } else if let number {
            SwiftUI.Text("\(number).")
                .font(.locus(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(LocusTheme.muted)
                .padding(.top, 1)
        } else {
            Circle()
                .fill(LocusTheme.inkSoft)
                .frame(width: 4, height: 4)
                .padding(.top, 7)
        }
    }

    private func prose(_ runs: [MarkdownInlineRun]) -> some View {
        SwiftUI.Text(attributed(runs))
            .font(.locus(size: density.fontSize))
            .foregroundStyle(density == .compact ? LocusTheme.muted : LocusTheme.inkSoft)
            .lineSpacing(density.lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attributed(
        _ runs: [MarkdownInlineRun],
        headingLevel: Int? = nil
    ) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.style.contains(.strong) { intent.insert(.stronglyEmphasized) }
            if run.style.contains(.emphasis) { intent.insert(.emphasized) }
            if run.style.contains(.strikethrough) { intent.insert(.strikethrough) }
            if run.style.contains(.code) { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if run.style.contains(.code) {
                piece.font = .locus(
                    size: max(density.fontSize - 1, 10),
                    weight: .medium,
                    design: .monospaced
                )
                piece.foregroundColor = LocusTheme.ink
                piece.backgroundColor = LocusTheme.paperDeep
            }
            if let url = MarkdownLinkPolicy.safeURL(run.destination, workspacePath: workspacePath) {
                piece.link = url
                piece.foregroundColor = LocusTheme.signalDeep
            }
            result.append(piece)
        }
        return result
    }

    private func localImage(
        in runs: [MarkdownInlineRun]
    ) -> (image: NSImage, label: String)? {
        guard runs.count == 1, let run = runs.first, run.isImage,
              let url = MarkdownLinkPolicy.workspaceImageURL(
                run.destination,
                workspacePath: workspacePath
              ),
              let image = NSImage(contentsOf: url)
        else { return nil }
        return (image, run.text)
    }
}

enum MarkdownLinkPolicy {
    private static let remoteSchemes = Set(["http", "https", "mailto"])
    private static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff"])

    static func safeURL(_ raw: String?, workspacePath: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            if remoteSchemes.contains(scheme) { return url }
            if scheme == "file" { return containedFileURL(url, workspacePath: workspacePath) }
            return nil
        }
        guard let workspacePath else { return nil }
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: workspacePath, isDirectory: true).appending(path: raw)
        return containedFileURL(url, workspacePath: workspacePath)
    }

    static func workspaceImageURL(_ raw: String?, workspacePath: String?) -> URL? {
        guard let url = safeURL(raw, workspacePath: workspacePath), url.isFileURL,
              imageExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }

    private static func containedFileURL(_ url: URL, workspacePath: String?) -> URL? {
        guard let workspacePath else { return nil }
        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }
}

private struct MarkdownTableRenderer: View {
    let headers: [[MarkdownInlineRun]]
    let alignments: [MarkdownColumnAlignment]
    let rows: [[[MarkdownInlineRun]]]
    let workspacePath: String?
    let density: MarkdownRenderDensity
    private let cellWidth: CGFloat = 154

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(headers, header: true)
                Rectangle().fill(LocusTheme.lineStrong.opacity(0.8)).frame(height: 1)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    row(cells, header: false)
                        .background(index.isMultiple(of: 2) ? Color.clear : LocusTheme.paperDeep.opacity(0.28))
                    if index < rows.count - 1 {
                        Rectangle().fill(LocusTheme.line.opacity(0.7)).frame(height: 1)
                    }
                }
            }
            .background(LocusTheme.white)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table with \(headers.count) columns and \(rows.count) rows")
    }

    private func row(_ cells: [[MarkdownInlineRun]], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let alignment = index < alignments.count ? alignments[index] : .left
                let edge: Alignment = switch alignment {
                case .left: .leading
                case .center: .center
                case .right: .trailing
                }
                SwiftUI.Text(attributed(cell))
                    .font(.locus(size: density == .compact ? 10 : 11, weight: header ? .semibold : .regular))
                    .foregroundStyle(header ? LocusTheme.ink : LocusTheme.inkSoft)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(width: cellWidth, alignment: edge)
                    .frame(minHeight: 34, alignment: edge)
                    .padding(.horizontal, 10)
                    .overlay(alignment: .trailing) {
                        if index != cells.indices.last {
                            Rectangle().fill(LocusTheme.line.opacity(0.7)).frame(width: 1)
                        }
                    }
            }
        }
        .background(header ? LocusTheme.paperDeep.opacity(0.75) : Color.clear)
    }

    private func attributed(_ runs: [MarkdownInlineRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.style.contains(.strong) { intent.insert(.stronglyEmphasized) }
            if run.style.contains(.emphasis) { intent.insert(.emphasized) }
            if run.style.contains(.strikethrough) { intent.insert(.strikethrough) }
            if run.style.contains(.code) { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let url = MarkdownLinkPolicy.safeURL(run.destination, workspacePath: workspacePath) {
                piece.link = url
            }
            result.append(piece)
        }
        return result
    }
}
