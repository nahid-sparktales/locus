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
/// Parsed Markdown for finished messages, so re-rendering a transcript row does
/// not re-parse it — and so the selection store's fill-in for an unrealized row
/// costs no more than the row itself would.
enum FinishedMarkdownCache {
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

enum MarkdownPlainTextRenderer {
    static func render(_ source: String) -> String {
        stripBoundaryNewlines(render(blocks: MarkdownDocumentParser.parse(source)))
    }

    private static func render(blocks: [MarkdownRenderBlock]) -> String {
        var result = ""
        for block in blocks {
            append(render(block: block), to: &result)
        }
        return result
    }

    private static func render(block: MarkdownRenderBlock) -> String {
        switch block {
        case .paragraph(let runs):
            return inlineText(runs)
        case .heading(_, let runs):
            return inlineText(runs)
        case .code(_, let body):
            return body
        case .unordered(let items):
            return renderList(items, start: nil)
        case .ordered(let start, let items):
            return renderList(items, start: start)
        case .quote(let nested):
            return render(blocks: nested)
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
        case .rule:
            return "────────"
        case .table(let headers, _, let rows):
            return ([headers] + rows)
                .map { row in row.map(inlineText).joined(separator: "\t") }
                .joined(separator: "\n")
        case .rawText(let value):
            return value
        }
    }

    private static func renderList(
        _ items: [MarkdownRenderListItem],
        start: Int?
    ) -> String {
        items.enumerated().map { offset, item in
            let marker: String
            if let checked = item.checked {
                marker = checked ? "[x]" : "[ ]"
            } else if let start {
                marker = "\(start + offset)."
            } else {
                marker = "•"
            }
            let content = render(blocks: item.blocks)
            let continuation = String(repeating: " ", count: marker.count + 1)
            return content.components(separatedBy: "\n").enumerated().map { index, line in
                if index == 0 { return "\(marker) \(line)" }
                return line.isEmpty ? "" : "\(continuation)\(line)"
            }
            .joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    private static func inlineText(_ runs: [MarkdownInlineRun]) -> String {
        var result = ""
        var index = 0
        while index < runs.count {
            let run = runs[index]
            if run.isImage {
                let label = run.text.hasPrefix("Image: ")
                    ? String(run.text.dropFirst("Image: ".count))
                    : run.text
                result += label
                if let destination = run.destination, !destination.isEmpty {
                    result += " (\(destination))"
                }
                index += 1
                continue
            }
            if let destination = run.destination, !destination.isEmpty {
                var label = ""
                while index < runs.count,
                      runs[index].destination == destination,
                      !runs[index].isImage
                {
                    label += runs[index].text
                    index += 1
                }
                result += label
                if label != destination { result += " (\(destination))" }
                continue
            }
            result += run.text
            index += 1
        }
        return result
    }

    private static func append(_ block: String, to result: inout String) {
        guard !block.isEmpty else { return }
        if result.isEmpty {
            result = block
        } else if result.hasSuffix("\n\n") {
            result += block
        } else if result.hasSuffix("\n") {
            result += "\n" + block
        } else {
            result += "\n\n" + block
        }
    }

    private static func stripBoundaryNewlines(_ value: String) -> String {
        String(
            value
                .drop(while: { $0 == "\n" || $0 == "\r" })
                .reversed()
                .drop(while: { $0 == "\n" || $0 == "\r" })
                .reversed()
        )
    }
}

enum MarkdownRenderDensity: Sendable {
    case regular
    case compact

    var fontSize: CGFloat { self == .compact ? 11 : 13 }
    var lineSpacing: CGFloat { self == .compact ? 3 : 5 }

    /// Sized literally at both leaves. Routing these through `Font.locus`, whose
    /// point sizes are buckets rather than values, is what let the AppKit and
    /// SwiftUI code paths render the same block at two different sizes.
    var codeFontSize: CGFloat { self == .compact ? 11 : 12 }
    var inlineCodeFontSize: CGFloat { self == .compact ? 10 : 12 }
    var headingLineSpacing: CGFloat { self == .compact ? 0 : 1 }

    func headingSize(level: Int) -> CGFloat {
        if self == .compact {
            return switch level {
            case 1: 13
            case 2: 12
            default: 11
            }
        }
        return switch level {
        case 1: 20
        case 2: 16
        case 3: 14
        default: 13
        }
    }

    func headingWeight(level: Int) -> NSFont.Weight {
        level == 1 ? .bold : .semibold
    }

    /// Space above `block`, given what precedes it.
    ///
    /// The single most consequential rule here is that a heading takes far more
    /// room above than below. A uniform gap — what this replaced — gives a
    /// section break exactly as much weight as a paragraph break, which is why
    /// long answers read as one undifferentiated column.
    func topSpacing(from previous: MarkdownRenderBlock?, to block: MarkdownRenderBlock) -> CGFloat {
        guard let previous else { return 0 }
        let compact = self == .compact

        if case .heading(let level, _) = block {
            return level <= 2 ? (compact ? 14 : 22) : (compact ? 12 : 18)
        }
        if case .heading = previous { return compact ? 4 : 6 }
        if case .rule = block { return compact ? 12 : 20 }
        if case .rule = previous { return compact ? 12 : 20 }
        if block.isCodeOrTable || previous.isCodeOrTable { return compact ? 9 : 14 }
        if block.isList {
            // A list reads as a continuation of the sentence introducing it.
            if case .paragraph = previous { return compact ? 5 : 8 }
        }
        return compact ? 8 : 12
    }
}

extension MarkdownRenderBlock {
    var isCodeOrTable: Bool {
        switch self {
        case .code, .table: true
        default: false
        }
    }

    var isList: Bool {
        switch self {
        case .unordered, .ordered: true
        default: false
        }
    }
}

/// The one place a Markdown inline run turns into type and colour.
///
/// Both leaves — the AppKit `NSAttributedString` used whenever a selection
/// coordinator is present, and the SwiftUI `AttributedString` fallback — resolve
/// through this. Previously each decided independently and had already drifted:
/// inline code took different foregrounds, links underlined on only one path,
/// and the two disagreed on code size.
struct MarkdownInlineStyleSpec {
    var fontSize: CGFloat
    var weight: NSFont.Weight
    var isMonospaced: Bool
    var isBold: Bool
    var isItalic: Bool
    var isStrikethrough: Bool
    var isUnderlined: Bool
    var foreground: Color
    var pillFill: Color?

    static func resolve(
        run: MarkdownInlineRun,
        baseSize: CGFloat,
        baseWeight: NSFont.Weight,
        baseColor: Color,
        inlineCodeSize: CGFloat,
        link: URL?
    ) -> Self {
        var spec = Self(
            fontSize: baseSize,
            weight: baseWeight,
            isMonospaced: false,
            isBold: run.style.contains(.strong),
            isItalic: run.style.contains(.emphasis),
            isStrikethrough: run.style.contains(.strikethrough),
            isUnderlined: false,
            foreground: baseColor,
            pillFill: nil
        )

        // Bold reads darker as well as heavier. Body prose sits at `inkSoft`, so
        // weight alone gave emphasis no contrast to work with.
        if spec.isBold { spec.foreground = LocusTheme.ink }

        if run.style.contains(.code) {
            spec.isMonospaced = true
            spec.fontSize = inlineCodeSize
            spec.weight = .medium
            spec.isBold = false
            spec.foreground = LocusTheme.ink
            spec.pillFill = LocusTheme.inlineCodeFill
        }

        if link != nil {
            spec.foreground = LocusTheme.signalDeep
            spec.isUnderlined = true
        }

        return spec
    }

    var nsFont: NSFont {
        var font = isMonospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
            : NSFont.systemFont(ofSize: fontSize, weight: weight)
        var traits: NSFontTraitMask = []
        if isBold { traits.insert(.boldFontMask) }
        if isItalic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        return font
    }

    var swiftUIFont: Font {
        var font = Font.locusExact(
            size: fontSize,
            weight: swiftUIWeight,
            design: isMonospaced ? .monospaced : .default
        )
        if isBold { font = font.bold() }
        if isItalic { font = font.italic() }
        return font
    }

    private var swiftUIWeight: Font.Weight {
        if weight >= .bold { return .bold }
        if weight >= .semibold { return .semibold }
        if weight >= .medium { return .medium }
        return .regular
    }
}

/// Builds the logical document that sits behind the independently laid-out
/// native Markdown leaves. Paths mirror the render tree, while prefixes and
/// separators preserve list markers, task state, quotes, and table structure
/// on Copy/Quote/Search.
enum MarkdownSelectionProjection {
    /// Keyed by the *local* dotted tree path, because that is what a leaf knows
    /// about itself when it looks its span up. `rowID` travels inside the span
    /// so the store can tell two rows' leaves apart.
    static func spans(
        for blocks: [MarkdownRenderBlock],
        rootPath: [Int] = [],
        firstSeparator: String = "",
        rowID: String = ""
    ) -> [String: TranscriptSelectionSpan] {
        var result: [String: TranscriptSelectionSpan] = [:]
        projectBlocks(
            blocks,
            rootPath: rootPath,
            firstSeparator: firstSeparator,
            laterSeparator: "\n\n",
            firstPrefix: "",
            laterPrefix: "",
            rowID: rowID,
            into: &result
        )
        return result
    }

    private static func projectBlocks(
        _ blocks: [MarkdownRenderBlock],
        rootPath: [Int],
        firstSeparator: String,
        laterSeparator: String,
        firstPrefix: String,
        laterPrefix: String,
        rowID: String,
        into result: inout [String: TranscriptSelectionSpan]
    ) {
        for (index, block) in blocks.enumerated() {
            project(
                block,
                path: rootPath + [index],
                separator: index == 0 ? firstSeparator : laterSeparator,
                prefix: index == 0 ? firstPrefix : laterPrefix,
                rowID: rowID,
                into: &result
            )
        }
    }

    private static func project(
        _ block: MarkdownRenderBlock,
        path: [Int],
        separator: String,
        prefix: String,
        rowID: String,
        into result: inout [String: TranscriptSelectionSpan]
    ) {
        switch block {
        case .paragraph(let runs), .heading(_, let runs):
            append(inlineText(runs), path: path, separator: separator, prefix: prefix, rowID: rowID, into: &result)
        case .rawText(let text), .code(_, let text):
            append(text, path: path, separator: separator, prefix: prefix, rowID: rowID, into: &result)
        case .rule:
            break
        case .quote(let nested):
            projectBlocks(
                nested,
                rootPath: path,
                firstSeparator: separator,
                laterSeparator: "\n",
                firstPrefix: prefix + "> ",
                laterPrefix: prefix + "> ",
                rowID: rowID,
                into: &result
            )
        case .unordered(let items):
            projectList(items, start: nil, path: path, separator: separator, prefix: prefix, rowID: rowID, into: &result)
        case .ordered(let start, let items):
            projectList(items, start: start, path: path, separator: separator, prefix: prefix, rowID: rowID, into: &result)
        case .table(let headers, _, let rows):
            let allRows = [headers] + rows
            for (rowIndex, row) in allRows.enumerated() {
                for (columnIndex, cell) in row.enumerated() {
                    let cellSeparator: String
                    if rowIndex == 0, columnIndex == 0 {
                        cellSeparator = separator
                    } else if columnIndex == 0 {
                        cellSeparator = "\n"
                    } else {
                        cellSeparator = "\t"
                    }
                    append(
                        inlineText(cell),
                        path: path + [rowIndex, columnIndex],
                        separator: cellSeparator,
                        prefix: columnIndex == 0 ? prefix : "",
                        rowID: rowID,
                        into: &result
                    )
                }
            }
        }
    }

    private static func projectList(
        _ items: [MarkdownRenderListItem],
        start: Int?,
        path: [Int],
        separator: String,
        prefix: String,
        rowID: String,
        into result: inout [String: TranscriptSelectionSpan]
    ) {
        for (itemIndex, item) in items.enumerated() {
            let marker: String
            if let checked = item.checked {
                marker = checked ? "[x]" : "[ ]"
            } else if let start {
                marker = "\(start + itemIndex)."
            } else {
                marker = "•"
            }
            let continuation = prefix + String(repeating: " ", count: marker.utf16.count + 1)
            projectBlocks(
                item.blocks,
                rootPath: path + [itemIndex],
                firstSeparator: itemIndex == 0 ? separator : "\n",
                laterSeparator: "\n",
                firstPrefix: prefix + marker + " ",
                laterPrefix: continuation,
                rowID: rowID,
                into: &result
            )
        }
    }

    private static func append(
        _ text: String,
        path: [Int],
        separator: String,
        prefix: String,
        rowID: String,
        into result: inout [String: TranscriptSelectionSpan]
    ) {
        guard !text.isEmpty else { return }
        let span = TranscriptSelectionSpan(
            treePath: path,
            displayedText: text,
            separatorBefore: separator,
            copyPrefix: prefix,
            rowID: rowID
        )
        result[path.map(String.init).joined(separator: ".")] = span
    }

    private static func inlineText(_ runs: [MarkdownInlineRun]) -> String {
        runs.map(\.text).joined()
    }
}

enum MarkdownNativeText {
    static func attributed(
        _ runs: [MarkdownInlineRun],
        size: CGFloat,
        weight: NSFont.Weight,
        color: Color,
        lineSpacing: CGFloat,
        inlineCodeSize: CGFloat,
        workspacePath: String?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        for run in runs {
            let url = MarkdownLinkPolicy.renderedURL(for: run, workspacePath: workspacePath)
            let spec = MarkdownInlineStyleSpec.resolve(
                run: run,
                baseSize: size,
                baseWeight: weight,
                baseColor: color,
                inlineCodeSize: inlineCodeSize,
                link: url
            )
            var attributes: [NSAttributedString.Key: Any] = [
                .font: spec.nsFont,
                .foregroundColor: NSColor(spec.foreground),
                .paragraphStyle: paragraph
            ]
            if spec.isStrikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if spec.isUnderlined {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let fill = spec.pillFill {
                // A custom attribute rather than `.backgroundColor`: the pill is
                // drawn rounded and padded by `LocusMarkdownLayoutManager`.
                attributes[.locusInlineCodePill] = NSColor(fill)
            }
            if let url { attributes[.link] = url }
            let piece = NSMutableAttributedString(string: run.text, attributes: attributes)
            if spec.pillFill != nil, piece.length > 0 {
                // Trailing room only, so the following word clears the pill's
                // right edge. Kerning the whole run would letter-space the code.
                piece.addAttribute(
                    .kern,
                    value: 3.0,
                    range: NSRange(location: piece.length - 1, length: 1)
                )
            }
            result.append(piece)
        }
        return result
    }

    static func plain(
        _ text: String,
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}

struct MarkdownBodyView: View {
    let text: String
    var workspacePath: String? = nil
    var density: MarkdownRenderDensity = .regular
    var selectionStore: TranscriptSelectionStore? = nil
    var selectionRootPath: [Int] = []
    var selectionFirstSeparator = ""
    var selectionRowID: String = ""
    var onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)? = nil

    var body: some View {
        let blocks = FinishedMarkdownCache.blocks(for: text)
        MarkdownBlocksView(
            blocks: blocks,
            workspacePath: workspacePath,
            density: density,
            selectionStore: selectionStore,
            selectionSpans: MarkdownSelectionProjection.spans(
                for: blocks,
                rootPath: selectionRootPath,
                firstSeparator: selectionFirstSeparator,
                rowID: selectionRowID
            ),
            pathPrefix: selectionRootPath,
            onOpenWorkspaceReference: onOpenWorkspaceReference
        )
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
    }

    private func open(_ url: URL) {
        if let reference = WorkspaceArtifactReference.fromNavigationURL(
            url,
            workspacePath: workspacePath
        ) {
            if let onOpenWorkspaceReference {
                onOpenWorkspaceReference(reference)
            } else {
                NSWorkspace.shared.open(reference.url)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Streaming Markdown is parsed at the transcript's already-coalesced update
/// cadence on a detached task. A superseding text snapshot cancels the stale
/// presentation before it can replace the newest one.
struct StreamingMarkdownBodyView: View {
    let text: String
    var workspacePath: String? = nil
    var density: MarkdownRenderDensity = .regular
    var selectionStore: TranscriptSelectionStore? = nil
    var selectionRootPath: [Int] = []
    var selectionRowID: String = ""
    var onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)? = nil
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
                    density: density,
                    selectionStore: selectionStore,
                    selectionSpans: MarkdownSelectionProjection.spans(
                        for: blocks,
                        rootPath: selectionRootPath,
                        rowID: selectionRowID
                    ),
                    pathPrefix: selectionRootPath,
                    onOpenWorkspaceReference: onOpenWorkspaceReference
                )
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
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

    private func open(_ url: URL) {
        if let reference = WorkspaceArtifactReference.fromNavigationURL(
            url,
            workspacePath: workspacePath
        ) {
            if let onOpenWorkspaceReference {
                onOpenWorkspaceReference(reference)
            } else {
                NSWorkspace.shared.open(reference.url)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownRenderBlock]
    let workspacePath: String?
    let density: MarkdownRenderDensity
    let selectionStore: TranscriptSelectionStore?
    let selectionSpans: [String: TranscriptSelectionSpan]
    let pathPrefix: [Int]
    let onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)?
    /// Nested lists step in; the top level does not.
    var nestingDepth = 0
    /// Set by block quotes. The AppKit leaves paint their own colour, so a
    /// `.foregroundStyle` on the parent never reached them.
    var textColor: Color?

    var body: some View {
        // Spacing is per-transition rather than uniform, so headings can take
        // more room above than below.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, path: pathPrefix + [index])
                    .padding(.top, density.topSpacing(
                        from: index == 0 ? nil : blocks[index - 1],
                        to: block
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(LocusTheme.signalDeep)
    }

    private var proseColor: Color {
        textColor ?? (density == .compact ? LocusTheme.muted : LocusTheme.inkSoft)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownRenderBlock, path: [Int]) -> some View {
        switch block {
        case .paragraph(let runs):
            if let artifact = standaloneArtifact(in: runs) {
                if artifact.kind == .image, let image = NSImage(contentsOf: artifact.url) {
                    WorkspaceImageArtifactView(
                        reference: artifact,
                        image: image,
                        caption: runs.map(\.text).joined(),
                        selectionStore: selectionStore,
                        selectionSpan: selectionSpan(at: path),
                        onOpen: { open(artifact) }
                    )
                } else {
                    WorkspaceArtifactCard(
                        reference: artifact,
                        selectionStore: selectionStore,
                        selectionSpan: selectionSpan(at: path),
                        onOpen: { open(artifact) }
                    )
                }
            } else {
                prose(runs, path: path)
            }

        case .heading(let level, let runs):
            selectableInline(
                runs,
                path: path,
                fontSize: density.headingSize(level: level),
                fontWeight: density.headingWeight(level: level),
                color: LocusTheme.ink,
                lineSpacing: density.headingLineSpacing
            )

        case .code(let language, let body):
            CodeBlockView(
                language: language,
                code: body,
                density: density,
                selectionStore: selectionStore,
                selectionSpan: selectionSpan(at: path)
            )

        case .unordered(let items):
            list(items: items, start: nil, path: path)

        case .ordered(let start, let items):
            list(items: items, start: start, path: path)

        case .quote(let nested):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(LocusTheme.lineStrong.opacity(0.75))
                    .frame(width: 3)
                MarkdownBlocksView(
                    blocks: nested,
                    workspacePath: workspacePath,
                    density: density,
                    selectionStore: selectionStore,
                    selectionSpans: selectionSpans,
                    pathPrefix: path,
                    onOpenWorkspaceReference: onOpenWorkspaceReference,
                    nestingDepth: nestingDepth,
                    textColor: LocusTheme.muted
                )
            }

        case .rule:
            Rectangle()
                .fill(LocusTheme.line)
                .frame(height: 1)

        case .table(let headers, let alignments, let rows):
            MarkdownTableRenderer(
                headers: headers,
                alignments: alignments,
                rows: rows,
                workspacePath: workspacePath,
                density: density,
                selectionStore: selectionStore,
                selectionSpans: selectionSpans,
                path: path,
                onOpenWorkspaceReference: onOpenWorkspaceReference
            )

        case .rawText(let value):
            selectablePlain(
                value,
                path: path,
                font: .monospacedSystemFont(ofSize: density.fontSize, weight: .regular),
                color: NSColor(LocusTheme.inkSoft),
                lineSpacing: density.lineSpacing
            )
            .accessibilityLabel("Raw HTML shown as text")
        }
    }

    private func list(items: [MarkdownRenderListItem], start: Int?, path: [Int]) -> some View {
        VStack(alignment: .leading, spacing: density == .compact ? 3 : 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .top, spacing: 8) {
                    listMarker(item: item, number: start.map { $0 + offset })
                        .frame(width: start == nil ? 14 : 24, alignment: .trailing)
                    MarkdownBlocksView(
                        blocks: item.blocks,
                        workspacePath: workspacePath,
                        density: density,
                        selectionStore: selectionStore,
                        selectionSpans: selectionSpans,
                        pathPrefix: path + [offset],
                        onOpenWorkspaceReference: onOpenWorkspaceReference,
                        nestingDepth: nestingDepth + 1,
                        textColor: textColor
                    )
                }
            }
        }
        .padding(.leading, nestingDepth > 0 ? 10 : 2)
    }

    @ViewBuilder
    private func listMarker(item: MarkdownRenderListItem, number: Int?) -> some View {
        if let checked = item.checked {
            SwiftUI.Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(checked ? LocusTheme.success : LocusTheme.muted)
                .padding(.top, 2)
        } else if let number {
            // Set in the body face at body size: an ordered marker is part of
            // the sentence, not a caption sitting beside it.
            SwiftUI.Text("\(number).")
                .font(.locusExact(size: density.fontSize))
                .foregroundStyle(LocusTheme.muted)
                .padding(.top, 0)
        } else {
            Circle()
                .fill(LocusTheme.muted)
                .frame(width: 4, height: 4)
                .padding(.top, density == .compact ? 5 : 7)
        }
    }

    @ViewBuilder
    private func prose(_ runs: [MarkdownInlineRun], path: [Int]) -> some View {
        selectableInline(
            runs,
            path: path,
            fontSize: density.fontSize,
            fontWeight: .regular,
            color: proseColor,
            lineSpacing: density.lineSpacing
        )
    }

    @ViewBuilder
    private func selectableInline(
        _ runs: [MarkdownInlineRun],
        path: [Int],
        fontSize: CGFloat,
        fontWeight: NSFont.Weight,
        color: Color,
        lineSpacing: CGFloat
    ) -> some View {
        if let selectionStore, let span = selectionSpan(at: path) {
            ResponseSelectableText(
                attributedText: MarkdownNativeText.attributed(
                    runs,
                    size: fontSize,
                    weight: fontWeight,
                    color: color,
                    lineSpacing: lineSpacing,
                    inlineCodeSize: density.inlineCodeFontSize,
                    workspacePath: workspacePath
                ),
                span: span,
                store: selectionStore,
                onOpenURL: open
            )
            .fixedSize(horizontal: false, vertical: true)
        } else {
            SwiftUI.Text(attributed(
                runs,
                baseSize: fontSize,
                baseWeight: fontWeight,
                baseColor: color
            ))
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func selectablePlain(
        _ text: String,
        path: [Int],
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat
    ) -> some View {
        if let selectionStore, let span = selectionSpan(at: path) {
            ResponseSelectableText(
                attributedText: MarkdownNativeText.plain(
                    text,
                    font: font,
                    color: color,
                    lineSpacing: lineSpacing
                ),
                span: span,
                store: selectionStore
            )
            .fixedSize(horizontal: false, vertical: true)
        } else {
            SwiftUI.Text(text)
                .font(.locusExact(size: font.pointSize, design: font.isFixedPitch ? .monospaced : .default))
                .foregroundStyle(Color(nsColor: color))
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func selectionSpan(at path: [Int]) -> TranscriptSelectionSpan? {
        selectionSpans[path.map(String.init).joined(separator: ".")]
    }

    /// Fallback leaf used only when no selection coordinator is present.
    /// Resolves through the same spec as the AppKit leaf so the two cannot drift.
    private func attributed(
        _ runs: [MarkdownInlineRun],
        baseSize: CGFloat,
        baseWeight: NSFont.Weight,
        baseColor: Color
    ) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            let url = MarkdownLinkPolicy.renderedURL(for: run, workspacePath: workspacePath)
            let spec = MarkdownInlineStyleSpec.resolve(
                run: run,
                baseSize: baseSize,
                baseWeight: baseWeight,
                baseColor: baseColor,
                inlineCodeSize: density.inlineCodeFontSize,
                link: url
            )
            var piece = AttributedString(run.text)
            piece.font = spec.swiftUIFont
            piece.foregroundColor = spec.foreground
            if spec.isStrikethrough { piece.strikethroughStyle = .single }
            if spec.isUnderlined { piece.underlineStyle = .single }
            // No layout manager on this path, so the pill degrades to a flat
            // fill rather than a rounded one.
            if let fill = spec.pillFill { piece.backgroundColor = fill }
            if let url { piece.link = url }
            result.append(piece)
        }
        return result
    }

    private func standaloneArtifact(in runs: [MarkdownInlineRun]) -> WorkspaceArtifactReference? {
        guard runs.count == 1, let run = runs.first else { return nil }
        let raw: String?
        if let destination = run.destination {
            raw = destination
        } else if run.style.contains(.code) {
            raw = run.text
        } else {
            raw = nil
        }
        return WorkspaceArtifactReference.classify(raw, workspacePath: workspacePath)
    }

    private func open(_ url: URL) {
        if let reference = WorkspaceArtifactReference.fromNavigationURL(
            url,
            workspacePath: workspacePath
        ) {
            if let onOpenWorkspaceReference {
                onOpenWorkspaceReference(reference)
            } else {
                NSWorkspace.shared.open(reference.url)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func open(_ reference: WorkspaceArtifactReference) {
        if let onOpenWorkspaceReference {
            onOpenWorkspaceReference(reference)
        } else {
            NSWorkspace.shared.open(reference.url)
        }
    }
}

struct WorkspaceSourceLocation: Hashable, Sendable {
    let line: Int
    let column: Int?
}

enum WorkspaceArtifactKind: String, Hashable, Sendable {
    case source
    case image
    case pdf
    case document
    case spreadsheet
    case presentation
    case audio
    case video
    case other

    var label: String {
        switch self {
        case .source: "Source file"
        case .image: "Image"
        case .pdf: "PDF"
        case .document: "Document"
        case .spreadsheet: "Spreadsheet"
        case .presentation: "Presentation"
        case .audio: "Audio"
        case .video: "Video"
        case .other: "File"
        }
    }

    var symbol: String {
        switch self {
        case .source: "doc.text"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle.angled"
        case .audio: "waveform"
        case .video: "film"
        case .other: "doc"
        }
    }
}

struct WorkspaceArtifactReference: Hashable, Sendable {
    let url: URL
    let relativePath: String
    let kind: WorkspaceArtifactKind
    let byteCount: Int64?
    let sourceLocation: WorkspaceSourceLocation?

    var displaySize: String? {
        guard let byteCount else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var navigationURL: URL {
        var components = URLComponents()
        components.scheme = "locus-workspace"
        components.host = "open"
        components.path = "/" + relativePath
        var query: [URLQueryItem] = []
        if let sourceLocation {
            query.append(.init(name: "line", value: String(sourceLocation.line)))
            if let column = sourceLocation.column {
                query.append(.init(name: "column", value: String(column)))
            }
        }
        components.queryItems = query.isEmpty ? nil : query
        return components.url ?? url
    }

    static func classify(_ raw: String?, workspacePath: String?) -> Self? {
        guard let workspacePath,
              let parsed = WorkspacePathReferenceParser.parse(raw),
              let url = MarkdownLinkPolicy.containedWorkspaceFileURL(
                parsed.path,
                workspacePath: workspacePath
              ),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }

        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let relative = WorkspaceIndex.relativePath(url, root: root.path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Self(
            url: url,
            relativePath: relative,
            kind: kind(for: url.pathExtension),
            byteCount: values?.fileSize.map(Int64.init),
            sourceLocation: parsed.location
        )
    }

    static func fromNavigationURL(_ url: URL, workspacePath: String?) -> Self? {
        guard url.scheme == "locus-workspace", url.host == "open" else { return nil }
        var raw = String(url.path.dropFirst())
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let line = items.first(where: { $0.name == "line" })?.value {
            raw += ":" + line
            if let column = items.first(where: { $0.name == "column" })?.value {
                raw += ":" + column
            }
        }
        return classify(raw, workspacePath: workspacePath)
    }

    private static func kind(for pathExtension: String) -> WorkspaceArtifactKind {
        let value = pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(value) {
            return .image
        }
        if value == "pdf" { return .pdf }
        if ["doc", "docx", "rtf", "pages", "odt"].contains(value) { return .document }
        if ["xls", "xlsx", "csv", "tsv", "numbers", "ods"].contains(value) { return .spreadsheet }
        if ["ppt", "pptx", "key", "odp"].contains(value) { return .presentation }
        if ["mp3", "m4a", "wav", "aiff", "flac", "aac", "ogg"].contains(value) { return .audio }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(value) { return .video }
        if ["swift", "m", "mm", "h", "c", "cc", "cpp", "rs", "go", "py", "js", "jsx", "ts", "tsx", "json", "yaml", "yml", "toml", "md", "txt", "sh", "zsh", "html", "css", "sql", "xml"].contains(value) {
            return .source
        }
        return .other
    }
}

enum WorkspacePathReferenceParser {
    struct Parsed: Hashable, Sendable {
        let path: String
        let location: WorkspaceSourceLocation?
    }

    static func parse(_ raw: String?) -> Parsed? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        if value.hasPrefix("<"), value.hasSuffix(">") {
            value = String(value.dropFirst().dropLast())
        }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
           scheme != "file"
        {
            return nil
        }

        let patterns = [
            #"#L([0-9]+)(?:C([0-9]+))?$"#,
            #":([0-9]+)(?::([0-9]+))?$"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..., in: value)
                  ),
                  let whole = Range(match.range(at: 0), in: value),
                  let lineRange = Range(match.range(at: 1), in: value),
                  let line = Int(value[lineRange]), line > 0
            else { continue }
            let column: Int?
            if match.range(at: 2).location != NSNotFound,
               let columnRange = Range(match.range(at: 2), in: value)
            {
                column = Int(value[columnRange]).flatMap { $0 > 0 ? $0 : nil }
            } else {
                column = nil
            }
            let rawPath = String(value[..<whole.lowerBound])
            let decoded = rawPath.removingPercentEncoding ?? rawPath
            let path = URL(string: decoded).flatMap { $0.isFileURL ? $0.path : nil } ?? decoded
            return Parsed(path: path, location: .init(line: line, column: column))
        }

        let path: String
        if let fileURL = URL(string: value), fileURL.isFileURL {
            path = fileURL.path
        } else {
            path = value.removingPercentEncoding ?? value
        }
        return Parsed(path: path, location: nil)
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
            if scheme == "file" {
                guard let parsed = WorkspacePathReferenceParser.parse(raw) else { return nil }
                return containedWorkspaceFileURL(parsed.path, workspacePath: workspacePath)
            }
            return nil
        }
        guard let parsed = WorkspacePathReferenceParser.parse(raw) else { return nil }
        return containedWorkspaceFileURL(parsed.path, workspacePath: workspacePath)
    }

    static func renderedURL(for run: MarkdownInlineRun, workspacePath: String?) -> URL? {
        let localCandidate = run.destination ?? (run.style.contains(.code) ? run.text : nil)
        if let reference = WorkspaceArtifactReference.classify(
            localCandidate,
            workspacePath: workspacePath
        ) {
            return reference.navigationURL
        }
        return safeURL(run.destination, workspacePath: workspacePath)
    }

    static func workspaceImageURL(_ raw: String?, workspacePath: String?) -> URL? {
        guard let url = safeURL(raw, workspacePath: workspacePath), url.isFileURL,
              imageExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }

    static func containedWorkspaceFileURL(_ rawPath: String, workspacePath: String?) -> URL? {
        guard let workspacePath else { return nil }
        let url = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : URL(fileURLWithPath: workspacePath, isDirectory: true).appending(path: rawPath)
        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }
}

private struct WorkspaceImageArtifactView: View {
    let reference: WorkspaceArtifactReference
    let image: NSImage
    let caption: String
    let selectionStore: TranscriptSelectionStore?
    let selectionSpan: TranscriptSelectionSpan?
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SwiftUI.Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 620, maxHeight: 420, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(LocusTheme.line.opacity(0.8), lineWidth: 1)
                }

            HStack(spacing: 8) {
                if let selectionStore, let selectionSpan {
                    ResponseSelectableText(
                        attributedText: MarkdownNativeText.plain(
                            caption,
                            font: .systemFont(ofSize: 11, weight: .medium),
                            color: NSColor(LocusTheme.muted),
                            lineSpacing: 0
                        ),
                        span: selectionSpan,
                        store: selectionStore
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(caption)
                        .font(.locus(size: 9, weight: .medium))
                        .foregroundStyle(LocusTheme.muted)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                artifactAction("Open", symbol: "arrow.up.forward.app", action: onOpen)
                artifactAction("Reveal", symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([reference.url])
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image artifact, \(reference.relativePath)")
    }

    private func artifactAction(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.locus(size: 9, weight: .semibold))
        }
        .buttonStyle(.locus())
        .foregroundStyle(LocusTheme.muted)
        .accessibilityLabel("\(title) \(reference.relativePath)")
    }
}

private struct WorkspaceArtifactCard: View {
    let reference: WorkspaceArtifactReference
    let selectionStore: TranscriptSelectionStore?
    let selectionSpan: TranscriptSelectionSpan?
    let onOpen: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LocusTheme.paperDeep.opacity(0.9))
                    .frame(width: 38, height: 38)
                Image(systemName: reference.kind.symbol)
                    .font(.locus(size: 14, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let selectionStore, let selectionSpan {
                    ResponseSelectableText(
                        attributedText: MarkdownNativeText.plain(
                            reference.url.lastPathComponent,
                            font: .systemFont(ofSize: 10, weight: .semibold),
                            color: NSColor(LocusTheme.ink),
                            lineSpacing: 0
                        ),
                        span: selectionSpan.displaying(reference.url.lastPathComponent),
                        store: selectionStore
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(reference.url.lastPathComponent)
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 5) {
                    Text(reference.kind.label)
                    if let displaySize = reference.displaySize {
                        Text("·")
                        Text(displaySize)
                    }
                    if let location = reference.sourceLocation {
                        Text("·")
                        Text("line \(location.line)")
                    }
                }
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.muted)
            }

            Spacer(minLength: 8)
            cardAction("Open", symbol: "arrow.up.forward.app", action: onOpen)
            cardAction("Reveal", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([reference.url])
            }
            cardAction(copied ? "Copied" : "Copy Path", symbol: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reference.relativePath, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    copied = false
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 58)
        .background(LocusTheme.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(reference.kind.label) artifact, \(reference.relativePath)")
    }

    private func cardAction(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 25, height: 25)
        }
        .buttonStyle(.locus())
        .foregroundStyle(title == "Copied" ? LocusTheme.success : LocusTheme.muted)
        .help(title)
        .accessibilityLabel("\(title) \(reference.relativePath)")
    }
}

private struct MarkdownTableRenderer: View {
    let headers: [[MarkdownInlineRun]]
    let alignments: [MarkdownColumnAlignment]
    let rows: [[[MarkdownInlineRun]]]
    let workspacePath: String?
    let density: MarkdownRenderDensity
    let selectionStore: TranscriptSelectionStore?
    let selectionSpans: [String: TranscriptSelectionSpan]
    let path: [Int]
    let onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)?
    @State private var collapsed = false
    /// Measured once at construction. A fixed width for every column made even a
    /// two-column table scroll sideways; sizing to content is what lets a normal
    /// table simply sit in the reply.
    private let columnWidths: [CGFloat]

    init(
        headers: [[MarkdownInlineRun]],
        alignments: [MarkdownColumnAlignment],
        rows: [[[MarkdownInlineRun]]],
        workspacePath: String?,
        density: MarkdownRenderDensity,
        selectionStore: TranscriptSelectionStore?,
        selectionSpans: [String: TranscriptSelectionSpan],
        path: [Int],
        onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)?
    ) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
        self.workspacePath = workspacePath
        self.density = density
        self.selectionStore = selectionStore
        self.selectionSpans = selectionSpans
        self.path = path
        self.onOpenWorkspaceReference = onOpenWorkspaceReference
        columnWidths = Self.columnWidths(
            headers: headers,
            rows: rows,
            fontSize: density == .compact ? 10 : 12
        )
    }

    private var cellFontSize: CGFloat { density == .compact ? 10 : 12 }

    /// Widths cover every row, not just the visible ones, so collapsing a long
    /// table does not resize its columns underneath the reader.
    private static func columnWidths(
        headers: [[MarkdownInlineRun]],
        rows: [[[MarkdownInlineRun]]],
        fontSize: CGFloat
    ) -> [CGFloat] {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return [] }
        func width(_ runs: [MarkdownInlineRun], header: Bool) -> CGFloat {
            let text = runs.map(\.text).joined()
            guard !text.isEmpty else { return 0 }
            let font = NSFont.systemFont(
                ofSize: fontSize,
                weight: header ? .semibold : .regular
            )
            return NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        return (0..<columnCount).map { column in
            var widest: CGFloat = 0
            if column < headers.count { widest = width(headers[column], header: true) }
            for row in rows where column < row.count {
                widest = max(widest, width(row[column], header: false))
            }
            return min(max(widest.rounded(.up), 44), 300)
        }
    }

    private func cellWidth(at index: Int) -> CGFloat {
        index < columnWidths.count ? columnWidths[index] : 154
    }

    private var isLong: Bool {
        rows.count > LongOutputPolicy.tableCollapseThreshold
    }

    private var visibleRows: [[[MarkdownInlineRun]]] {
        guard collapsed, isLong else { return rows }
        return Array(rows.prefix(LongOutputPolicy.tablePreviewRowCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLong {
                HStack(spacing: 7) {
                    Image(systemName: "tablecells")
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                    Text("Table")
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.inkSoft)
                    Text("\(rows.count) rows")
                        .font(.locus(size: 9, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                    Spacer()
                    Button {
                        collapsed.toggle()
                    } label: {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                            .font(.locus(size: 8, weight: .semibold))
                            .foregroundStyle(LocusTheme.muted)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.locus())
                    .help(collapsed ? "Expand table" : "Collapse table")
                    .accessibilityLabel(
                        collapsed
                            ? "Expand \(rows.count)-row table"
                            : "Collapse \(rows.count)-row table"
                    )
                    .accessibilityIdentifier("message.table.collapse")
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(LocusTheme.paperDeep.opacity(0.78))
                Rectangle().fill(LocusTheme.line.opacity(0.8)).frame(height: 1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    row(headers, rowIndex: 0, header: true)
                    Rectangle().fill(LocusTheme.lineStrong.opacity(0.8)).frame(height: 1)
                    ForEach(Array(visibleRows.enumerated()), id: \.offset) { index, cells in
                        row(cells, rowIndex: index + 1, header: false)
                            .background(index.isMultiple(of: 2) ? Color.clear : LocusTheme.paperDeep.opacity(0.28))
                        if index < visibleRows.count - 1 {
                            Rectangle().fill(LocusTheme.line.opacity(0.7)).frame(height: 1)
                        }
                    }
                }
            }

            if collapsed, isLong {
                Rectangle().fill(LocusTheme.line.opacity(0.8)).frame(height: 1)
                Button("Show all \(rows.count) rows") {
                    collapsed = false
                }
                .buttonStyle(.plain)
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.signalDeep)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityIdentifier("message.table.showAll")
            }
        }
        .background(LocusTheme.white)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Table with \(headers.count) columns and \(rows.count) rows"
                + (collapsed ? ", collapsed" : ", expanded")
        )
    }

    private func row(
        _ cells: [[MarkdownInlineRun]],
        rowIndex: Int,
        header: Bool
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let alignment = index < alignments.count ? alignments[index] : .left
                let edge: Alignment = switch alignment {
                case .left: .leading
                case .center: .center
                case .right: .trailing
                }
                cellText(cell, path: path + [rowIndex, index], header: header)
                    .frame(width: cellWidth(at: index), alignment: edge)
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

    @ViewBuilder
    private func cellText(
        _ runs: [MarkdownInlineRun],
        path: [Int],
        header: Bool
    ) -> some View {
        let size = cellFontSize
        let weight: NSFont.Weight = header ? .semibold : .regular
        let color = header ? LocusTheme.ink : LocusTheme.inkSoft
        let key = path.map(String.init).joined(separator: ".")
        if let selectionStore, let span = selectionSpans[key] {
            ResponseSelectableText(
                attributedText: MarkdownNativeText.attributed(
                    runs,
                    size: size,
                    weight: weight,
                    color: color,
                    lineSpacing: 2,
                    inlineCodeSize: density.inlineCodeFontSize,
                    workspacePath: workspacePath
                ),
                span: span,
                store: selectionStore,
                onOpenURL: open
            )
            .fixedSize(horizontal: false, vertical: true)
        } else {
            SwiftUI.Text(attributed(runs, size: size, weight: weight, color: color))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attributed(
        _ runs: [MarkdownInlineRun],
        size: CGFloat,
        weight: NSFont.Weight,
        color: Color
    ) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            let url = MarkdownLinkPolicy.renderedURL(for: run, workspacePath: workspacePath)
            let spec = MarkdownInlineStyleSpec.resolve(
                run: run,
                baseSize: size,
                baseWeight: weight,
                baseColor: color,
                inlineCodeSize: density.inlineCodeFontSize,
                link: url
            )
            var piece = AttributedString(run.text)
            piece.font = spec.swiftUIFont
            piece.foregroundColor = spec.foreground
            if spec.isStrikethrough { piece.strikethroughStyle = .single }
            if spec.isUnderlined { piece.underlineStyle = .single }
            if let fill = spec.pillFill { piece.backgroundColor = fill }
            if let url { piece.link = url }
            result.append(piece)
        }
        return result
    }

    private func open(_ url: URL) {
        if let reference = WorkspaceArtifactReference.fromNavigationURL(
            url,
            workspacePath: workspacePath
        ) {
            if let onOpenWorkspaceReference {
                onOpenWorkspaceReference(reference)
            } else {
                NSWorkspace.shared.open(reference.url)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
