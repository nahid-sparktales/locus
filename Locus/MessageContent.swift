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
        VStack(alignment: .leading, spacing: 10) {
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
                .font(.locus(size: 12))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineSpacing(4)
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
                ForEach(
                    Array(FinishedMarkdownCache.fragments(for: body).enumerated()),
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
}

/// The active reply bypasses SwiftUI Text layout. TextKit receives only the
/// newly appended UTF-16 suffix, so a 100 KB answer does not relayout its
/// entire String on every provider chunk.
struct StreamingMessageContentView: View {
    @ObservedObject var reply: StreamingReplyState
    let thinkingVisibility: ThinkingVisibility

    var body: some View {
        let snapshot = reply.snapshot
        VStack(alignment: .leading, spacing: 10) {
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
                    font: .systemFont(ofSize: 12),
                    color: NSColor(LocusTheme.inkSoft),
                    lineSpacing: 4
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
                    Text(isActive ? "Thinking…" : "Thought process")
                        .font(.locus(size: 9, weight: .semibold))
                    if isActive { ProgressView().controlSize(.mini) }
                    Spacer()
                }
                .foregroundStyle(LocusTheme.muted)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .disabled(forceExpanded)

            if isOpen {
                StreamingPlainTextView(
                    text: text,
                    font: .systemFont(ofSize: 10),
                    color: NSColor(LocusTheme.muted),
                    lineSpacing: 3
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(LocusTheme.paperDeep.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                    Text(isActive ? "Thinking…" : "Thought process")
                        .font(.locus(size: 9, weight: .semibold))
                    if isActive {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Spacer()
                }
                .foregroundStyle(LocusTheme.muted)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .disabled(forceExpanded)
            .accessibilityLabel(isOpen ? "Collapse thought process" : "Expand thought process")
            .accessibilityIdentifier("message.thinking.toggle")

            if isOpen {
                Text(text)
                    .font(.locus(size: 10))
                    .foregroundStyle(LocusTheme.muted)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(LocusTheme.paperDeep.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LocusTheme.line.opacity(0.8), lineWidth: 1)
        }
    }
}

/// Paragraph text with inline markdown, with lightweight heading emphasis.
struct InlineMarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    private enum ProseBlock: Hashable {
        case heading(Int, String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(proseBlocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let value):
                    Text(value)
                        .font(.locus(size: level <= 2 ? 15 : 13, weight: .bold))
                        .foregroundStyle(LocusTheme.ink)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                case .paragraph(let value):
                    Text(inline(value))
                        .font(.locus(size: 12))
                        .foregroundStyle(LocusTheme.inkSoft)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Coalesce consecutive prose and list lines into one Text view. Blank
    /// lines and headings remain semantic boundaries, avoiding hundreds of
    /// SwiftUI nodes in long model replies.
    private var proseBlocks: [ProseBlock] {
        var result: [ProseBlock] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let level = headingLevel(line) {
                flush()
                result.append(.heading(
                    level,
                    String(line.drop(while: { $0 == "#" || $0 == " " }))
                ))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    private func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes > 0, hashes <= 6,
              line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private func inline(_ line: String) -> AttributedString {
        (try? AttributedString(
            markdown: line,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(line)
    }
}

/// Fenced code block card with a language chip and a copy button.
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").lowercased())
                    .font(.locus(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
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
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.locus(size: 8, weight: .semibold))
                        .foregroundStyle(copied ? LocusTheme.success : LocusTheme.muted)
                }
                .buttonStyle(.locus())
                .accessibilityLabel("Copy code block")
                .accessibilityIdentifier("message.codeBlock.copy")
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(LocusTheme.paperDeep.opacity(0.8))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.locus(size: 10, design: .monospaced))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(LocusTheme.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
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
