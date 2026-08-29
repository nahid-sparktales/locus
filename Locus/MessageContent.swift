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

    /// The complete answer a response-level Copy action places on the
    /// pasteboard. Copy from the source message rather than the individually
    /// rendered Markdown views, whose selections stop at block boundaries.
    /// Local-model thinking tags remain private just as native reasoning does.
    static func copyableText(from text: String) -> String {
        parse(text)
            .compactMap { segment -> String? in
                guard case .visible(let value) = segment else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n\n")
    }
}

enum ResponseCopyFormat: String, CaseIterable, Identifiable {
    case plainText
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plainText: "Plain Text"
        case .markdown: "Markdown"
        }
    }
}

enum ResponseCopyPayload {
    static func text(from source: String, format: ResponseCopyFormat) -> String {
        let visibleMarkdown = AssistantSegment.copyableText(from: source)
        switch format {
        case .plainText:
            return MarkdownPlainTextRenderer.render(visibleMarkdown)
        case .markdown:
            return visibleMarkdown
        }
    }
}

enum QuoteSelectionFormatter {
    static func quote(_ selection: String) -> String {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .components(separatedBy: "\n")
            .map { line in line.isEmpty ? ">" : "> \(line)" }
            .joined(separator: "\n")
    }

    static func appending(_ selection: String, to draft: String) -> String {
        let quoted = quote(selection)
        guard !quoted.isEmpty else { return draft }
        let separator: String
        if draft.isEmpty || draft.hasSuffix("\n\n") {
            separator = ""
        } else if draft.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }
        return draft + separator + quoted + "\n\n"
    }
}

enum LongOutputPolicy {
    static let codeCollapseThreshold = 24
    static let codePreviewLineCount = 12
    static let tableCollapseThreshold = 10
    static let tablePreviewRowCount = 5

    static func codeLines(_ code: String) -> [String] {
        guard !code.isEmpty else { return [] }
        var lines = code.components(separatedBy: "\n")
        if code.hasSuffix("\n"), lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
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
    var reasoningSections: [String]? = nil
    var workspacePath: String? = nil
    var thinkingVisibility: ThinkingVisibility = .collapsed
    var onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)? = nil
    @StateObject private var selectionCoordinator = ResponseSelectionCoordinator()
    @State private var presentedStreamingText = ""

    var body: some View {
        let nativeReasoning = reasoningText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasReasoningSections = reasoningSections?.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } == true
        VStack(alignment: .leading, spacing: 14) {
            if (!nativeReasoning.isEmpty || hasReasoningSections), thinkingVisibility != .hidden {
                ThinkingSegmentView(
                    text: nativeReasoning,
                    sections: reasoningSections ?? [],
                    workspacePath: workspacePath,
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
        .onAppear {
            presentedStreamingText = text
        }
        .onChange(of: text) { _, next in
            guard !selectionCoordinator.isSelectionActive else { return }
            presentedStreamingText = next
        }
        .onChange(of: selectionCoordinator.selection) { _, _ in
            guard !selectionCoordinator.isSelectionActive else { return }
            presentedStreamingText = text
        }
    }

    @ViewBuilder
    private func streamingAnswer(nativeReasoning: String) -> some View {
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
            StreamingMarkdownBodyView(
                text: selectionCoordinator.isSelectionActive ? presentedStreamingText : text,
                workspacePath: workspacePath,
                selectionCoordinator: selectionCoordinator,
                onOpenWorkspaceReference: onOpenWorkspaceReference
            )
        }
    }

    @ViewBuilder
    private var finishedAnswer: some View {
        let segments = AssistantSegment.rendered(from: text, mode: thinkingVisibility)
        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
            switch segment {
            case .thinking(let body, _):
                ThinkingSegmentView(
                    text: body,
                    workspacePath: workspacePath,
                    isActive: false,
                    forceExpanded: thinkingVisibility == .expanded
                )
            case .visible(let body):
                SelectableVisibleAssistantSegment(
                    text: body,
                    workspacePath: workspacePath,
                    selectionRootPath: [index],
                    onOpenWorkspaceReference: onOpenWorkspaceReference
                )
            }
        }
    }
}

/// A reasoning boundary starts a new logical selection document. Keeping the
/// coordinator here prevents a drag from silently jumping across hidden or
/// collapsed private reasoning while full-response Copy remains source-backed.
private struct SelectableVisibleAssistantSegment: View {
    let text: String
    let workspacePath: String?
    let selectionRootPath: [Int]
    let onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)?
    @StateObject private var selectionCoordinator = ResponseSelectionCoordinator()

    var body: some View {
        MarkdownBodyView(
            text: text,
            workspacePath: workspacePath,
            selectionCoordinator: selectionCoordinator,
            selectionRootPath: selectionRootPath,
            onOpenWorkspaceReference: onOpenWorkspaceReference
        )
    }
}

/// The active reply reparses on the streaming coalescer's cadence and discards
/// stale results, so provider chunks never trigger synchronous Markdown work.
struct StreamingMessageContentView: View {
    @ObservedObject var reply: StreamingReplyState
    let thinkingVisibility: ThinkingVisibility
    var workspacePath: String? = nil
    var onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)? = nil
    @StateObject private var selectionCoordinator = ResponseSelectionCoordinator()
    @State private var presentedSnapshot = StreamingReplySnapshot()

    var body: some View {
        let snapshot = selectionCoordinator.isSelectionActive ? presentedSnapshot : reply.snapshot
        VStack(alignment: .leading, spacing: 14) {
            if !snapshot.reasoning.isEmpty, thinkingVisibility != .hidden {
                StreamingThinkingSegmentView(
                    text: snapshot.reasoning,
                    sections: snapshot.reasoningSections,
                    isActive: snapshot.text.isEmpty,
                    forceExpanded: thinkingVisibility == .expanded,
                    workspacePath: workspacePath
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
                StreamingMarkdownBodyView(
                    text: snapshot.text,
                    workspacePath: workspacePath,
                    selectionCoordinator: selectionCoordinator,
                    onOpenWorkspaceReference: onOpenWorkspaceReference
                )
                Capsule()
                    .fill(LocusTheme.signalDeep)
                    .frame(width: 9, height: 2)
                    .opacity(0.8)
            }
        }
        .onAppear {
            presentedSnapshot = reply.snapshot
        }
        .onChange(of: reply.snapshot) { _, next in
            guard !selectionCoordinator.isSelectionActive else { return }
            presentedSnapshot = next
        }
        .onChange(of: selectionCoordinator.selection) { _, _ in
            guard !selectionCoordinator.isSelectionActive else { return }
            presentedSnapshot = reply.snapshot
        }
    }
}

private struct StreamingThinkingSegmentView: View {
    let text: String
    let sections: [String]
    let isActive: Bool
    let forceExpanded: Bool
    var workspacePath: String? = nil
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
                ReasoningSectionsView(
                    sections: displaySections,
                    workspacePath: workspacePath,
                    streaming: true
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

    private var displaySections: [String] {
        let nonempty = sections.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return nonempty.isEmpty ? [text] : nonempty
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
    var sections: [String] = []
    var workspacePath: String? = nil
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
                ReasoningSectionsView(
                    sections: displaySections,
                    workspacePath: workspacePath,
                    streaming: false
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

    private var displaySections: [String] {
        let nonempty = sections.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return nonempty.isEmpty ? [text] : nonempty
    }
}

private struct ReasoningSectionsView: View {
    let sections: [String]
    let workspacePath: String?
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if streaming {
                    StreamingMarkdownBodyView(
                        text: section,
                        workspacePath: workspacePath,
                        density: .compact
                    )
                } else {
                    MarkdownBodyView(
                        text: section,
                        workspacePath: workspacePath,
                        density: .compact
                    )
                }
                if index < sections.count - 1 {
                    Rectangle()
                        .fill(LocusTheme.line.opacity(0.75))
                        .frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

enum NativeCodeTextRenderer {
    static func attributed(_ code: String, language: String?, isDiff: Bool) -> NSAttributedString {
        if isDiff { return attributedDiff(code) }
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        for token in CodeSyntaxHighlighter.tokens(for: code, language: language) {
            let color: NSColor = switch token.kind {
            case .plain: NSColor(LocusTheme.inkSoft)
            case .keyword: NSColor(LocusTheme.signalDeep)
            case .string: NSColor(LocusTheme.blue)
            case .number: NSColor(LocusTheme.coral)
            case .comment: NSColor(LocusTheme.muted)
            }
            result.append(NSAttributedString(
                string: token.text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: color,
                    .paragraphStyle: paragraph
                ]
            ))
        }
        return result
    }

    private static func attributedDiff(_ code: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            let value = line + (index < lines.count - 1 ? "\n" : "")
            let foreground: NSColor
            let background: NSColor
            if line.hasPrefix("@@") {
                foreground = NSColor(LocusTheme.blue)
                background = NSColor(LocusTheme.blue).withAlphaComponent(0.07)
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                foreground = NSColor(LocusTheme.success)
                background = NSColor(LocusTheme.success).withAlphaComponent(0.1)
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                foreground = NSColor(LocusTheme.coral)
                background = NSColor(LocusTheme.coral).withAlphaComponent(0.1)
            } else {
                foreground = NSColor(LocusTheme.inkSoft)
                background = .clear
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 20
            paragraph.maximumLineHeight = 20
            result.append(NSAttributedString(
                string: value,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: foreground,
                    .backgroundColor: background,
                    .paragraphStyle: paragraph
                ]
            ))
        }
        return result
    }
}

/// Fenced code rendered as a native macOS code card. Diff fences receive
/// per-line add/remove treatment; all other languages retain exact whitespace
/// and scroll horizontally without forcing the conversation itself sideways.
struct CodeBlockView: View {
    let language: String?
    let code: String
    var selectionCoordinator: ResponseSelectionCoordinator? = nil
    var selectionSpan: TranscriptSelectionSpan? = nil
    @State private var copied = false
    @State private var collapsed = false

    private var lines: [String] { LongOutputPolicy.codeLines(code) }

    private var isLong: Bool {
        lines.count > LongOutputPolicy.codeCollapseThreshold
    }

    private var visibleCode: String {
        guard collapsed, isLong else { return code }
        return lines.prefix(LongOutputPolicy.codePreviewLineCount).joined(separator: "\n")
    }

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
                if isLong {
                    Text("\(lines.count) lines")
                        .font(.locus(size: 9, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                if isLong {
                    Button {
                        collapsed.toggle()
                    } label: {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                            .font(.locus(size: 8, weight: .semibold))
                            .foregroundStyle(LocusTheme.muted)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.locus())
                    .help(collapsed ? "Expand code block" : "Collapse code block")
                    .accessibilityLabel(
                        collapsed
                            ? "Expand \(lines.count)-line code block"
                            : "Collapse \(lines.count)-line code block"
                    )
                    .accessibilityIdentifier("message.codeBlock.collapse")
                }
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
                if let selectionCoordinator, let selectionSpan {
                    ResponseSelectableText(
                        attributedText: NativeCodeTextRenderer.attributed(
                            visibleCode.isEmpty ? " " : visibleCode,
                            language: language,
                            isDiff: isDiff
                        ),
                        span: selectionSpan.displaying(visibleCode),
                        coordinator: selectionCoordinator,
                        wraps: false
                    )
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, isDiff ? 8 : 11)
                } else if isDiff {
                    CodeDiffLines(code: visibleCode)
                } else {
                    Text(CodeSyntaxHighlighter.highlighted(
                        visibleCode.isEmpty ? " " : visibleCode,
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

            if collapsed, isLong {
                Rectangle()
                    .fill(LocusTheme.line.opacity(0.8))
                    .frame(height: 1)
                Button("Show all \(lines.count) lines") {
                    collapsed = false
                }
                .buttonStyle(.plain)
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(LocusTheme.signalDeep)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityIdentifier("message.codeBlock.showAll")
            }
        }
        .background(LocusTheme.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isLong
                ? "\(displayLanguage) code block, \(lines.count) lines"
                : "\(displayLanguage) code block"
        )
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
