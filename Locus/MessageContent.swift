import AppKit
import SwiftUI

/// Splits raw assistant output into reasoning ("thinking") and visible answer
/// segments. Local models such as qwen3 and deepseek-r1 stream their chain of
/// thought inside <think>/<thinking> tags; Locus renders those collapsed, the
/// way Claude Code presents extended thinking.
enum AssistantSegment: Hashable {
    case thinking(text: String, isComplete: Bool)
    case visible(String)

    static func parse(_ text: String) -> [AssistantSegment] {
        var segments: [AssistantSegment] = []
        var remainder = Substring(text)

        while let open = firstTag(in: remainder) {
            let before = remainder[..<open.range.lowerBound]
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.visible(String(before)))
            }
            let afterOpen = remainder[open.range.upperBound...]
            if let close = afterOpen.range(of: "</\(open.name)>") {
                let body = afterOpen[..<close.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    segments.append(.thinking(text: body, isComplete: true))
                }
                remainder = afterOpen[close.upperBound...]
            } else {
                let body = afterOpen.trimmingCharacters(in: .whitespacesAndNewlines)
                segments.append(.thinking(text: body, isComplete: false))
                remainder = Substring("")
            }
        }
        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.visible(String(remainder)))
        }
        return segments
    }

    private static func firstTag(in text: Substring) -> (name: String, range: Range<Substring.Index>)? {
        ["think", "thinking"]
            .compactMap { name in
                text.range(of: "<\(name)>").map { (name: name, range: $0) }
            }
            .min { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The segments a transcript in the given visibility mode renders.
    static func rendered(from text: String, mode: ThinkingVisibility) -> [AssistantSegment] {
        let segments = parse(text)
        guard mode == .hidden else { return segments }
        return segments.filter {
            if case .thinking = $0 { return false }
            return true
        }
    }
}

/// Block-level markdown structure for a visible segment: fenced code blocks
/// become dedicated cards, everything else stays inline-markdown paragraphs.
enum MarkdownFragment: Hashable {
    case text(String)
    case code(language: String?, body: String)

    static func parse(_ text: String) -> [MarkdownFragment] {
        var fragments: [MarkdownFragment] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var insideFence = false

        func flushText() {
            let joined = textLines.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fragments.append(.text(joined))
            }
            textLines = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if insideFence {
                    fragments.append(.code(
                        language: codeLanguage,
                        body: codeLines.joined(separator: "\n")
                    ))
                    codeLines = []
                    insideFence = false
                } else {
                    flushText()
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    insideFence = true
                }
            } else if insideFence {
                codeLines.append(String(line))
            } else {
                textLines.append(String(line))
            }
        }
        if insideFence {
            fragments.append(.code(language: codeLanguage, body: codeLines.joined(separator: "\n")))
        } else {
            flushText()
        }
        return fragments
    }
}

/// Finished replies are immutable. Parsing them again because an unrelated
/// app setting or hover state changed is pure main-thread work, so retain the
/// completed block structure for the lifetime of the process.
@MainActor
private enum FinishedMarkdownCache {
    private static var values: [String: [MarkdownFragment]] = [:]
    private static var order: [String] = []
    private static let limit = 128

    static func fragments(for text: String) -> [MarkdownFragment] {
        if let cached = values[text] { return cached }
        let parsed = MarkdownFragment.parse(text)
        values[text] = parsed
        order.append(text)
        if order.count > limit {
            values.removeValue(forKey: order.removeFirst())
        }
        return parsed
    }
}

/// Heuristic for tool output that is a unified diff, so the Changes inspector
/// and tool cards can color it like Claude Code's diff view.
enum DiffDetector {
    static func isDiff(_ text: String) -> Bool {
        var additions = 0
        var deletions = 0
        var hunks = 0
        for line in text.split(separator: "\n").prefix(400) {
            if line.hasPrefix("@@") { hunks += 1 }
            else if line.hasPrefix("+"), !line.hasPrefix("+++") { additions += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { deletions += 1 }
            else if line.hasPrefix("+++") || line.hasPrefix("---") { hunks += 1 }
        }
        return hunks >= 1 ? (additions + deletions) >= 1 : (additions >= 1 && deletions >= 1)
    }
}

/// Renders finished assistant messages: reasoning per the transcript's
/// thinking-visibility mode, block markdown with copyable code cards, plain
/// paragraphs elsewhere.
struct MessageContentView: View {
    let text: String
    let isStreaming: Bool
    var reasoningText: String? = nil
    var thinkingVisibility: ThinkingVisibility = .collapsed

    var body: some View {
        let nativeReasoning = reasoningText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: 14) {
            if !nativeReasoning.isEmpty, thinkingVisibility != .hidden {
                ThinkingSegmentView(
                    text: nativeReasoning,
                    isActive: isStreaming && text.isEmpty,
                    forceExpanded: thinkingVisibility == .expanded
                )
            }
            if isStreaming {
                streamingAnswer(nativeReasoning: nativeReasoning)
            } else {
                finishedAnswer
            }
        }
    }

    @ViewBuilder
    private func streamingAnswer(nativeReasoning: String) -> some View {
        // Provider/inline reasoning arrives on its separate channel. Keeping
        // the active answer as one plain Text avoids reparsing an ever-growing
        // Markdown document for every 50 ms batch.
        if text.isEmpty {
            if nativeReasoning.isEmpty || thinkingVisibility == .hidden {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Thinking…")
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .accessibilityIdentifier("message.thinking.hiddenIndicator")
            }
        } else {
            Text(text)
                .font(.locus(size: 13))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineSpacing(5)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var finishedAnswer: some View {
        let segments = AssistantSegment.rendered(from: text, mode: thinkingVisibility)
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            switch segment {
            case .thinking(let body, _):
                ThinkingSegmentView(
                    text: body,
                    isActive: false,
                    forceExpanded: thinkingVisibility == .expanded
                )
            case .visible(let body):
                MarkdownBodyView(text: body)
            }
        }
    }
}

/// A complete Markdown answer body. Keeping this separate from assistant
/// reasoning also lets user-authored prompts use the same high-quality prose,
/// list, table, and code presentation without treating user text as reasoning.
struct MarkdownBodyView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(
                Array(FinishedMarkdownCache.fragments(for: text).enumerated()),
                id: \.offset
            ) { _, fragment in
                switch fragment {
                case .text(let value):
                    InlineMarkdownText(value)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }
}

/// The active reply bypasses SwiftUI Text layout. TextKit receives only the
/// newly appended UTF-16 suffix, so a 100 KB answer does not relayout its
/// entire String on every provider chunk.
struct StreamingMessageContentView: View {
    @ObservedObject var reply: StreamingReplyState
    let thinkingVisibility: ThinkingVisibility

    var body: some View {
        let snapshot = reply.snapshot
        VStack(alignment: .leading, spacing: 14) {
            if !snapshot.reasoning.isEmpty, thinkingVisibility != .hidden {
                StreamingThinkingSegmentView(
                    text: snapshot.reasoning,
                    isActive: snapshot.text.isEmpty,
                    forceExpanded: thinkingVisibility == .expanded
                )
            }
            if snapshot.text.isEmpty {
                if snapshot.reasoning.isEmpty || thinkingVisibility == .hidden {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Thinking…")
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
            } else {
                StreamingPlainTextView(
                    text: snapshot.text,
                    font: .systemFont(ofSize: 13),
                    color: NSColor(LocusTheme.inkSoft),
                    lineSpacing: 5
                )
                Capsule()
                    .fill(LocusTheme.signalDeep)
                    .frame(width: 9, height: 2)
                    .opacity(0.8)
            }
        }
    }
}

private struct StreamingThinkingSegmentView: View {
    let text: String
    let isActive: Bool
    let forceExpanded: Bool
    @State private var expanded = false

    private var isOpen: Bool { expanded || isActive || forceExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    if !forceExpanded {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.locus(size: 8, weight: .semibold))
                    }
                    Image(systemName: "brain").font(.locus(size: 10))
                    Text(isActive ? "Thinking…" : "Reasoning")
                        .font(.locus(size: 10, weight: .semibold))
                    if isActive { ProgressView().controlSize(.mini) }
                    Spacer()
                }
                .foregroundStyle(LocusTheme.muted)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .disabled(forceExpanded)

            if isOpen {
                StreamingPlainTextView(
                    text: text,
                    font: .systemFont(ofSize: 11),
                    color: NSColor(LocusTheme.muted),
                    lineSpacing: 4
                )
                .padding(.horizontal, 13)
                .padding(.bottom, 12)
            }
        }
        .background(LocusTheme.paperDeep.opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LocusTheme.line.opacity(0.8), lineWidth: 1)
        }
    }
}

struct StreamingPlainTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    let lineSpacing: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AppendOnlyTextView {
        let view = AppendOnlyTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.lineFragmentPadding = 0
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: AppendOnlyTextView, context: Context) {
        update(nsView, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: AppendOnlyTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.measuredHeight(for: width))
    }

    private func update(_ view: AppendOnlyTextView, coordinator: Coordinator) {
        let value = text as NSString
        let attributes = textAttributes
        if value.length >= coordinator.utf16Length {
            let suffix = value.substring(from: coordinator.utf16Length)
            if !suffix.isEmpty {
                view.textStorage?.append(NSAttributedString(string: suffix, attributes: attributes))
            }
        } else {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        coordinator.utf16Length = value.length
        view.invalidateIntrinsicContentSize()
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    final class Coordinator {
        var utf16Length = 0
    }
}

final class AppendOnlyTextView: NSTextView {
    func measuredHeight(for width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return 1 }
        textContainer.containerSize = NSSize(
            width: max(width, 1),
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        return max(ceil(layoutManager.usedRect(for: textContainer).height), 1)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: measuredHeight(for: max(bounds.width, 1))
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

/// Collapsible reasoning card. Expanded automatically only while the model is
/// actively thinking; collapsed once the answer starts. In the transcript's
/// Expanded mode the card is pinned open and the per-block toggle disabled.
struct ThinkingSegmentView: View {
    let text: String
    let isActive: Bool
    var forceExpanded = false
    @State private var expanded = false

    private var isOpen: Bool { expanded || isActive || forceExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    if !forceExpanded {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.locus(size: 8, weight: .semibold))
                    }
                    Image(systemName: "brain")
                        .font(.locus(size: 10))
                    Text(isActive ? "Thinking…" : "Reasoning")
                        .font(.locus(size: 10, weight: .semibold))
                    if isActive {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Spacer()
                }
                .foregroundStyle(LocusTheme.muted)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .disabled(forceExpanded)
            .accessibilityLabel(isOpen ? "Collapse thought process" : "Expand thought process")
            .accessibilityIdentifier("message.thinking.toggle")

            if isOpen {
                Text(text)
                    .font(.locus(size: 11))
                    .foregroundStyle(LocusTheme.muted)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 12)
            }
        }
        .background(LocusTheme.paperDeep.opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LocusTheme.line.opacity(0.8), lineWidth: 1)
        }
    }
}

struct MarkdownListItem: Hashable {
    let text: String
    let checked: Bool?
}

/// Semantic prose blocks inside the non-code portions of a response. This is
/// deliberately small and deterministic rather than a web renderer: it covers
/// the structures coding assistants produce most often while retaining native
/// text selection, accessibility, and macOS link handling.
enum MarkdownProseBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unordered([MarkdownListItem])
    case ordered(start: Int, items: [String])
    case quote(String)
    case rule
    case table(headers: [String], rows: [[String]])

    static func parse(_ text: String) -> [MarkdownProseBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownProseBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let level = headingLevel(line) {
                flushParagraph()
                blocks.append(.heading(
                    level: level,
                    text: String(line.drop(while: { $0 == "#" || $0 == " " }))
                ))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let headers = tableCells(line),
               isTableDivider(lines[index + 1], count: headers.count)
            {
                flushParagraph()
                var rows: [[String]] = []
                index += 2
                while index < lines.count,
                      let cells = tableCells(lines[index]),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty
                {
                    rows.append(normalized(cells, count: headers.count))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if quoteText(line) != nil {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count, let value = quoteText(lines[index]) {
                    quoteLines.append(value)
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if unorderedItem(line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while index < lines.count, let item = unorderedItem(lines[index]) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.unordered(items))
                continue
            }

            if let first = orderedItem(line) {
                flushParagraph()
                var items = [first.text]
                let start = first.number
                index += 1
                while index < lines.count, let item = orderedItem(lines[index]) {
                    items.append(item.text)
                    index += 1
                }
                blocks.append(.ordered(start: start, items: items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes > 0, hashes <= 6,
              line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first,
              first == "-" || first == "_" || first == "*" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func unorderedItem(_ line: String) -> MarkdownListItem? {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2,
              ["- ", "* ", "+ "].contains(where: { value.hasPrefix($0) })
        else { return nil }
        var body = String(value.dropFirst(2))
        var checked: Bool?
        if body.hasPrefix("[ ] ") {
            checked = false
            body.removeFirst(4)
        } else if body.lowercased().hasPrefix("[x] ") {
            checked = true
            body.removeFirst(4)
        }
        return MarkdownListItem(text: body, checked: checked)
    }

    private static func orderedItem(_ line: String) -> (number: Int, text: String)? {
        let value = line.trimmingCharacters(in: .whitespaces)
        let digits = value.prefix(while: { $0.isNumber })
        guard let number = Int(digits), !digits.isEmpty else { return nil }
        let suffix = value.dropFirst(digits.count)
        guard suffix.hasPrefix(". ") || suffix.hasPrefix(") ") else { return nil }
        return (number, String(suffix.dropFirst(2)))
    }

    private static func quoteText(_ line: String) -> String? {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix(">") else { return nil }
        return String(value.dropFirst().drop(while: { $0 == " " }))
    }

    private static func tableCells(_ line: String) -> [String]? {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.contains("|") else { return nil }
        var cells = value.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if value.hasPrefix("|") { cells.removeFirst() }
        if value.hasSuffix("|") { cells.removeLast() }
        return cells.count >= 2 ? cells : nil
    }

    private static func isTableDivider(_ line: String, count: Int) -> Bool {
        guard let cells = tableCells(line), cells.count == count else { return false }
        return cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }

    private static func normalized(_ cells: [String], count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }
}

/// Paragraph text with native inline Markdown and block-level hierarchy close
/// to Codex and Claude: crisp headings, readable lists, task state, quotes,
/// dividers, and horizontally safe tables.
struct InlineMarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownProseBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let value):
                    Text(inline(value))
                        .font(.locus(
                            size: level == 1 ? 20 : (level == 2 ? 17 : 14),
                            weight: level <= 2 ? .bold : .semibold
                        ))
                        .tracking(level <= 2 ? -0.25 : 0)
                        .foregroundStyle(LocusTheme.ink)
                        .padding(.top, level == 1 ? 7 : 4)
                        .textSelection(.enabled)

                case .paragraph(let value):
                    prose(value)

                case .unordered(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                if let checked = item.checked {
                                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                        .font(.locus(size: 10, weight: .semibold))
                                        .foregroundStyle(checked ? LocusTheme.success : LocusTheme.muted)
                                        .frame(width: 12)
                                } else {
                                    Circle()
                                        .fill(LocusTheme.inkSoft)
                                        .frame(width: 4, height: 4)
                                        .frame(width: 12)
                                }
                                prose(item.text)
                            }
                        }
                    }
                    .padding(.leading, 2)

                case .ordered(let start, let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text("\(start + offset).")
                                    .font(.locus(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                                    .frame(minWidth: 20, alignment: .trailing)
                                prose(item)
                            }
                        }
                    }

                case .quote(let value):
                    HStack(alignment: .top, spacing: 11) {
                        Capsule()
                            .fill(LocusTheme.lineStrong.opacity(0.75))
                            .frame(width: 3)
                        prose(value)
                            .foregroundStyle(LocusTheme.muted)
                    }
                    .padding(.vertical, 2)

                case .rule:
                    Rectangle()
                        .fill(LocusTheme.line)
                        .frame(height: 1)
                        .padding(.vertical, 4)

                case .table(let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows)
                }
            }
        }
        .tint(LocusTheme.signalDeep)
    }

    private func prose(_ value: String) -> some View {
        Text(inline(value))
            .font(.locus(size: 13))
            .foregroundStyle(LocusTheme.inkSoft)
            .lineSpacing(5)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func inline(_ value: String) -> AttributedString {
        var result = (try? AttributedString(
            markdown: value,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(value)
        for run in result.runs {
            guard run.inlinePresentationIntent?.contains(.code) == true else { continue }
            result[run.range].font = .locus(size: 12, weight: .medium, design: .monospaced)
            result[run.range].foregroundColor = LocusTheme.ink
            result[run.range].backgroundColor = LocusTheme.paperDeep
        }
        return result
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
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

    private func row(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let showsDivider = index != cells.indices.last
                Text(inline(cell))
                    .font(.locus(size: 11, weight: header ? .semibold : .regular))
                    .foregroundStyle(header ? LocusTheme.ink : LocusTheme.inkSoft)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(width: cellWidth, alignment: .leading)
                    .frame(minHeight: 34, alignment: .leading)
                    .padding(.horizontal, 10)
                    .overlay(alignment: .trailing) {
                        if showsDivider {
                            Rectangle().fill(LocusTheme.line.opacity(0.7)).frame(width: 1)
                        }
                    }
            }
        }
        .background(header ? LocusTheme.paperDeep.opacity(0.75) : Color.clear)
    }

    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(value)
    }
}

enum CodeTokenKind: Hashable {
    case plain
    case keyword
    case string
    case number
    case comment
}

struct CodeToken: Hashable {
    var text: String
    let kind: CodeTokenKind
}

/// Small, dependency-free highlighter for the language families most common
/// in coding-agent replies. It is intentionally lexical rather than a full
/// parser: malformed or partial snippets still preserve every character and
/// receive stable, useful color without blocking rendering.
enum CodeSyntaxHighlighter {
    static func tokens(for code: String, language: String?) -> [CodeToken] {
        let family = normalizedLanguage(language)
        let keywords = keywordSet(for: family)
        let characters = Array(code)
        var tokens: [CodeToken] = []
        var index = 0

        func emit(_ kind: CodeTokenKind, _ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let value = String(characters[range])
            if tokens.last?.kind == kind {
                tokens[tokens.count - 1].text += value
            } else {
                tokens.append(CodeToken(text: value, kind: kind))
            }
        }

        while index < characters.count {
            let start = index

            if let prefix = lineCommentPrefix(for: family),
               matches(prefix, in: characters, at: index)
            {
                index += prefix.count
                while index < characters.count, characters[index] != "\n" { index += 1 }
                emit(.comment, start..<index)
                continue
            }

            if supportsBlockComments(family),
               matches(["/", "*"], in: characters, at: index)
            {
                index += 2
                while index < characters.count,
                      !matches(["*", "/"], in: characters, at: index)
                {
                    index += 1
                }
                index = min(index + 2, characters.count)
                emit(.comment, start..<index)
                continue
            }

            if characters[index] == "\"" || characters[index] == "'" || characters[index] == "`" {
                let quote = characters[index]
                index += 1
                var escaped = false
                while index < characters.count {
                    let character = characters[index]
                    index += 1
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == quote {
                        break
                    }
                }
                emit(.string, start..<index)
                continue
            }

            if characters[index].isNumber {
                index += 1
                while index < characters.count,
                      characters[index].isNumber
                        || characters[index] == "."
                        || characters[index] == "_"
                {
                    index += 1
                }
                emit(.number, start..<index)
                continue
            }

            if isIdentifierStart(characters[index]) {
                index += 1
                while index < characters.count, isIdentifierBody(characters[index]) {
                    index += 1
                }
                let word = String(characters[start..<index])
                emit(keywords.contains(word) ? .keyword : .plain, start..<index)
                continue
            }

            index += 1
            emit(.plain, start..<index)
        }
        return tokens
    }

    static func highlighted(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString()
        for token in tokens(for: code, language: language) {
            var piece = AttributedString(token.text)
            piece.font = .locus(size: 11, design: .monospaced)
            piece.foregroundColor = switch token.kind {
            case .plain: LocusTheme.inkSoft
            case .keyword: LocusTheme.signalDeep
            case .string: LocusTheme.blue
            case .number: LocusTheme.coral
            case .comment: LocusTheme.muted
            }
            result.append(piece)
        }
        return result
    }

    private static func normalizedLanguage(_ language: String?) -> String {
        let value = language?
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        return switch value {
        case "js", "jsx", "javascript": "javascript"
        case "ts", "tsx", "typescript": "typescript"
        case "py", "python3": "python"
        case "sh", "bash", "zsh", "shell": "shell"
        case "rs": "rust"
        case "golang": "go"
        case "c++", "cpp", "cc": "cpp"
        case "objc", "objective-c": "objective-c"
        case "yml": "yaml"
        default: value
        }
    }

    private static func keywordSet(for language: String) -> Set<String> {
        switch language {
        case "swift":
            return ["actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import", "in", "init", "let", "nil", "private", "protocol", "public", "return", "self", "static", "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while"]
        case "javascript", "typescript":
            return ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "return", "static", "super", "switch", "throw", "true", "try", "type", "typeof", "undefined", "var", "while", "yield"]
        case "python":
            return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case "rust":
            return ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        case "go":
            return ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]
        case "c", "cpp", "objective-c":
            return ["auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "false", "float", "for", "if", "int", "long", "namespace", "new", "nullptr", "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "while"]
        case "json":
            return ["false", "null", "true"]
        case "shell":
            return ["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "local", "return", "then", "until", "while"]
        default:
            return []
        }
    }

    private static func lineCommentPrefix(for language: String) -> [Character]? {
        return switch language {
        case "python", "shell", "ruby", "yaml": ["#"]
        case "sql": ["-", "-"]
        case "json", "html", "css", "markdown", "md", "": nil
        default: ["/", "/"]
        }
    }

    private static func supportsBlockComments(_ language: String) -> Bool {
        !["python", "shell", "ruby", "yaml", "sql", "json", "markdown", "md", ""].contains(language)
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private static func isIdentifierBody(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private static func matches(
        _ prefix: [Character],
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard index + prefix.count <= characters.count else { return false }
        return Array(characters[index..<(index + prefix.count)]) == prefix
    }
}

/// Fenced code rendered as a native macOS code card. Diff fences receive
/// per-line add/remove treatment; all other languages retain exact whitespace
/// and scroll horizontally without forcing the conversation itself sideways.
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    private var displayLanguage: String {
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Code" : value.capitalized
    }

    private var isDiff: Bool {
        language?.lowercased() == "diff" || DiffDetector.isDiff(code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: isDiff ? "plusminus" : "chevron.left.forwardslash.chevron.right")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
                Text(displayLanguage)
                    .font(.locus(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.inkSoft)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    Label(
                        copied ? "Copied" : "Copy",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(copied ? LocusTheme.success : LocusTheme.muted)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(LocusTheme.white.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.locus())
                .accessibilityLabel("Copy code block")
                .accessibilityIdentifier("message.codeBlock.copy")
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(LocusTheme.paperDeep.opacity(0.78))

            Rectangle()
                .fill(LocusTheme.line.opacity(0.8))
                .frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                if isDiff {
                    CodeDiffLines(code: code)
                } else {
                    Text(CodeSyntaxHighlighter.highlighted(
                        code.isEmpty ? " " : code,
                        language: language
                    ))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LocusTheme.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(displayLanguage) code block")
    }
}

private struct CodeDiffLines: View {
    let lines: [String]

    init(code: String) {
        lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.locus(size: 11, design: .monospaced))
                    .foregroundStyle(foreground(for: line))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 20, alignment: .leading)
                    .background(background(for: line))
            }
        }
        .padding(.vertical, 8)
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("@@") { return LocusTheme.blue }
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return LocusTheme.success }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return LocusTheme.coral }
        return LocusTheme.inkSoft
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return LocusTheme.success.opacity(0.1)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return LocusTheme.coral.opacity(0.1)
        }
        if line.hasPrefix("@@") { return LocusTheme.blue.opacity(0.07) }
        return Color.clear
    }
}

/// Unified-diff text with per-line add/remove coloring.
///
/// Two layout traps live here, both of which pegged the main thread when the
/// Changes panel started showing real, file-sized diffs:
///
/// 1. A horizontal `ScrollView` proposes an unbounded width, and a stack of
///    `maxWidth: .infinity` rows under an unbounded proposal sends the layout
///    engine into a spin. So the width is bounded and long lines truncate.
/// 2. A lazy stack nested directly inside another lazy stack oscillates: the
///    outer one estimates the inner one's height, the inner one materializes,
///    the height changes, and it re-estimates forever. So laziness is used
///    only together with `maxHeight`, which gives this view its own scroll
///    view and a height the parent can rely on.
struct DiffTextView: View {
    let text: String
    /// When set, the diff scrolls inside this height instead of growing the
    /// parent. Required whenever the parent is itself a lazy stack.
    var maxHeight: CGFloat?
    private let lines: [String]

    init(text: String, maxHeight: CGFloat? = nil) {
        self.text = text
        self.maxHeight = maxHeight
        // Split once here rather than in `body`, which runs on every pass.
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        if let maxHeight {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { rows }
                    .textSelection(.enabled)
            }
            .frame(maxHeight: maxHeight)
        } else {
            VStack(alignment: .leading, spacing: 0) { rows }
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line.isEmpty ? " " : line)
                .font(.locus(size: 9, design: .monospaced))
                .foregroundStyle(color(for: line))
                // One source line stays one row: wrapping a long diff line
                // costs a text-layout pass per row and buys little in a panel
                // this narrow.
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(background(for: line))
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("@@") { return LocusTheme.blue }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return LocusTheme.muted }
        if line.hasPrefix("+") { return LocusTheme.success }
        if line.hasPrefix("-") { return LocusTheme.coral }
        return LocusTheme.inkSoft
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return LocusTheme.success.opacity(0.09) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return LocusTheme.coral.opacity(0.09) }
        return .clear
    }
}

/// Chooses between diff-aware and plain monospaced rendering for tool output.
struct ToolOutputText: View {
    let text: String

    var body: some View {
        if DiffDetector.isDiff(text) {
            DiffTextView(text: text)
        } else {
            Text(text)
                .font(.locus(size: 9, design: .monospaced))
                .foregroundStyle(LocusTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
