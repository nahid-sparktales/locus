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
    /// The transcript's selection store, owned above the lazy list so a drag
    /// survives this row being recycled.
    var selectionStore: TranscriptSelectionStore? = nil
    var selectionRowID: String = ""
    var onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)? = nil
    @State private var presentedStreamingText = ""

    /// A streaming answer freezes its rendered text while it is being
    /// selected, so the ground does not move under the drag.
    private var isSelecting: Bool {
        selectionStore?.activeRowIDs.contains(selectionRowID) == true
    }

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
            guard !isSelecting else { return }
            presentedStreamingText = next
        }
        .onChange(of: isSelecting) { _, selecting in
            guard !selecting else { return }
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
                text: isSelecting ? presentedStreamingText : text,
                workspacePath: workspacePath,
                selectionStore: selectionStore,
                selectionRootPath: [0],
                selectionRowID: selectionRowID,
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
                MarkdownBodyView(
                    text: body,
                    workspacePath: workspacePath,
                    selectionStore: selectionStore,
                    selectionRootPath: [index],
                    selectionRowID: selectionRowID,
                    onOpenWorkspaceReference: onOpenWorkspaceReference
                )
            }
        }
    }
}

/// The active reply publishes an append-only revision. Completed Markdown
/// blocks freeze once, while the mutable tail stays native plain text.
struct StreamingMessageContentView: View {
    @ObservedObject var reply: StreamingReplyState
    let thinkingVisibility: ThinkingVisibility
    var workspacePath: String? = nil
    var activityOnly = false
    var activityMarkerAccent: LocusAccentSelection? = nil
    var selectionStore: TranscriptSelectionStore? = nil
    var selectionRowID: String = ""
    var onOpenWorkspaceReference: ((WorkspaceArtifactReference) -> Void)? = nil
    @State private var selectionSnapshot: StreamingReplySnapshot?

    private var isSelecting: Bool {
        selectionStore?.activeRowIDs.contains(selectionRowID) == true
    }

    var body: some View {
        let snapshot = selectionSnapshot ?? reply.snapshot
        VStack(alignment: .leading, spacing: 14) {
            if !snapshot.reasoning.isEmpty, thinkingVisibility != .hidden {
                StreamingThinkingSegmentView(
                    text: snapshot.reasoning,
                    sections: snapshot.reasoningSections,
                    isActive: snapshot.text.isEmpty,
                    forceExpanded: thinkingVisibility == .expanded,
                    activityOnly: activityOnly,
                    activityMarkerAccent: activityMarkerAccent,
                    workspacePath: workspacePath
                )
            }
            if snapshot.text.isEmpty {
                if snapshot.reasoning.isEmpty || thinkingVisibility == .hidden {
                    HStack(spacing: 10) {
                        if let activityMarkerAccent {
                            LocusMessageMarker(accent: activityMarkerAccent)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Thinking…")
                            .font(.locus(size: 9, weight: .semibold))
                            .foregroundStyle(LocusTheme.muted)
                    }
                }
            } else {
                StreamingMarkdownBodyView(
                    text: snapshot.text,
                    workspacePath: workspacePath,
                    selectionStore: selectionStore,
                    selectionRootPath: [0],
                    selectionRowID: selectionRowID,
                    onOpenWorkspaceReference: onOpenWorkspaceReference
                )
                Capsule()
                    .fill(LocusTheme.signalDeep)
                    .frame(width: 9, height: 2)
                    .opacity(0.8)
            }
        }
        .onChange(of: isSelecting) { _, selecting in
            selectionSnapshot = selecting ? reply.snapshot : nil
        }
    }
}

private struct StreamingThinkingSegmentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let sections: [String]
    let isActive: Bool
    let forceExpanded: Bool
    let activityOnly: Bool
    let activityMarkerAccent: LocusAccentSelection?
    var workspacePath: String? = nil
    @State private var expanded = false

    private var isOpen: Bool { expanded || forceExpanded }

    @ViewBuilder
    var body: some View {
        if isOpen {
            if activityOnly {
                HStack(alignment: .top, spacing: 10) {
                    activityMarker
                    detailedCard
                }
            } else {
                detailedCard
            }
        } else {
            compactRow
        }
    }

    private var compactRow: some View {
        Button {
            withAnimation(reduceMotion ? nil : LocusMotion.content) {
                expanded = true
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let activityMarkerAccent {
                    LocusMessageMarker(accent: activityMarkerAccent)
                } else {
                    Image(systemName: "brain")
                        .font(.locusExact(size: 12, weight: .regular))
                        .frame(width: 20)
                }
                Text(summaryText)
                    .font(.locusExact(size: 13, weight: .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if isActive { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(LocusTheme.muted)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityLabel("\(summaryText). Thought process, collapsed")
        .accessibilityIdentifier("message.thinking.toggle")
    }

    @ViewBuilder
    private var activityMarker: some View {
        if let activityMarkerAccent {
            LocusMessageMarker(accent: activityMarkerAccent)
        } else {
            Color.clear
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    private var detailedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !forceExpanded else { return }
                withAnimation(reduceMotion ? nil : LocusMotion.content) {
                    expanded = false
                }
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

    private var summaryText: String {
        let values = displaySections.compactMap { section -> String? in
            let plain = StreamingReasoningSummary.render(section)
            return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ").nilIfEmpty
        }
        return values.joined(separator: " · ").nilIfEmpty ?? (isActive ? "Thinking…" : "Reasoning")
    }

    private var displaySections: [String] {
        let nonempty = sections.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return nonempty.isEmpty ? [text] : nonempty
    }
}

struct StreamingPlainTextView: NSViewRepresentable {
    @Environment(\.locusIsLiveResizing) private var isLiveResizing
    let text: String
    let font: NSFont
    let color: NSColor
    let lineSpacing: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AppendOnlyTextView {
        let view = AppendOnlyTextView.make()
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
        view.setLiveResizeMeasurementActive(isLiveResizing)
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: AppendOnlyTextView, context: Context) {
        nsView.setLiveResizeMeasurementActive(isLiveResizing)
        update(nsView, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: AppendOnlyTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        nsView.setLiveResizeMeasurementActive(isLiveResizing)
        return CGSize(
            width: width,
            height: nsView.measuredHeight(for: width, isLiveResizing: isLiveResizing)
        )
    }

    private func update(_ view: AppendOnlyTextView, coordinator: Coordinator) {
        let value = text as NSString
        let attributes = textAttributes
        guard text != coordinator.text else { return }
        if text.hasPrefix(coordinator.text) {
            let suffix = value.substring(from: coordinator.utf16Length)
            if !suffix.isEmpty {
                view.textStorage?.append(NSAttributedString(string: suffix, attributes: attributes))
            }
        } else {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        coordinator.utf16Length = value.length
        coordinator.text = text
        view.contentDidChange()
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
        var text = ""
    }
}

enum StreamingReasoningSummary {
    static func render(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                line.drop(while: { "#>*-_` ".contains($0) })
            }
            .joined(separator: " ")
    }
}

final class AppendOnlyTextView: LocusSelectionTextView {
    private struct MeasurementKey: Hashable {
        let revision: UInt
        let width: CGFloat
    }

    private var contentRevision: UInt = 0
    private var measurements = TranscriptMeasurementCache<MeasurementKey>(capacity: 4)
    private var liveResizeMeasurementActive = false
    private var lastIntrinsicWidth: CGFloat?

    /// Shares the transcript's TextKit 1 stack and selection wash so the
    /// streaming fast path is indistinguishable from the parsed markdown that
    /// replaces it a frame later.
    static func make() -> AppendOnlyTextView {
        let stack = LocusSelectionTextView.makeTextKit1Stack()
        let view = AppendOnlyTextView(frame: .zero, textContainer: stack.container)
        view.adoptTextKit1(storage: stack.storage)
        return view
    }

    func contentDidChange() {
        contentRevision &+= 1
        measurements.removeAll()
        lastIntrinsicWidth = nil
        invalidateIntrinsicContentSize()
    }

    func setLiveResizeMeasurementActive(_ active: Bool) {
        guard active != liveResizeMeasurementActive else { return }
        let wasActive = liveResizeMeasurementActive
        liveResizeMeasurementActive = active
        lastIntrinsicWidth = nil
        if wasActive, !active {
            measurements.removeAll()
            invalidateIntrinsicContentSize()
        }
    }

    func measuredHeight(for width: CGFloat, isLiveResizing: Bool? = nil) -> CGFloat {
        guard let textContainer, let layoutManager else { return 1 }
        let effectiveWidth = ResponseSelectableTextView.effectiveMeasurementWidth(
            width,
            wraps: true,
            isLiveResizing: isLiveResizing ?? liveResizeMeasurementActive
        )
        let key = MeasurementKey(revision: contentRevision, width: effectiveWidth)
        if let cached = measurements.value(for: key) { return cached.height }
        textContainer.containerSize = NSSize(
            width: effectiveWidth,
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let height = max(ceil(layoutManager.usedRect(for: textContainer).height), 1)
        measurements.insert(NSSize(width: effectiveWidth, height: height), for: key)
        return height
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
        let effectiveWidth = ResponseSelectableTextView.effectiveMeasurementWidth(
            newSize.width,
            wraps: true,
            isLiveResizing: liveResizeMeasurementActive
        )
        if widthChanged, effectiveWidth != lastIntrinsicWidth {
            lastIntrinsicWidth = effectiveWidth
            invalidateIntrinsicContentSize()
        }
    }
}

/// Reasoning disclosure. Collapsed mode rests as a lightweight inline summary;
/// Expanded mode pins the existing detailed card open.
struct ThinkingSegmentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    var sections: [String] = []
    var workspacePath: String? = nil
    let isActive: Bool
    var forceExpanded = false
    @State private var expanded = false

    private var isOpen: Bool { expanded || forceExpanded }

    @ViewBuilder
    var body: some View {
        if isOpen {
            detailedCard
        } else {
            compactRow
        }
    }

    private var compactRow: some View {
        Button {
            withAnimation(reduceMotion ? nil : LocusMotion.content) {
                expanded = true
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "brain")
                    .font(.locusExact(size: 12, weight: .regular))
                    .frame(width: 20)
                Text(summaryText)
                    .font(.locusExact(size: 13, weight: .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if isActive { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(LocusTheme.muted)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityLabel("\(summaryText). Thought process, collapsed")
        .accessibilityIdentifier("message.thinking.toggle")
    }

    private var detailedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !forceExpanded else { return }
                withAnimation(reduceMotion ? nil : LocusMotion.content) {
                    expanded = false
                }
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

    private var summaryText: String {
        let values = displaySections.compactMap { section -> String? in
            let plain = MarkdownPlainTextRenderer.render(section)
            return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ").nilIfEmpty
        }
        return values.joined(separator: " · ").nilIfEmpty ?? (isActive ? "Thinking…" : "Reasoning")
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
    case punctuation
    case keyword
    case constant
    case string
    case number
    case comment
    case function
    case type
    case property
}

struct CodeToken: Hashable {
    var text: String
    let kind: CodeTokenKind
}

/// Small, dependency-free highlighter for the language families most common
/// in coding-agent replies. It is intentionally lexical rather than a full
/// parser: malformed or partial snippets still preserve every character and
/// receive stable, useful color without blocking rendering.
///
/// The classification rules below are all single-token lookarounds, which is
/// what keeps that property. An identifier is a call when `(` follows it, a
/// member when `.` precedes it, and a type when it opens uppercase — each
/// correct far more often than not across the languages an agent emits, and
/// each harmless when it guesses wrong, since the fallback is plain body color.
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

        /// A call is only recognised when `(` follows immediately. Allowing
        /// intervening spaces would recolor `if (x)` in C-family code.
        func opensCall(at position: Int) -> Bool {
            position < characters.count && characters[position] == "("
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
                let kind: CodeTokenKind
                if literalConstants.contains(word) {
                    // Checked ahead of keywords so `true`/`null`/`None` read as
                    // literals in every language rather than only where a
                    // keyword set happens to list them.
                    kind = .constant
                } else if keywords.contains(word) {
                    kind = .keyword
                } else if opensCall(at: index) {
                    kind = .function
                } else if start > 0, characters[start - 1] == "." {
                    kind = .property
                } else if word.first?.isUppercase == true {
                    kind = .type
                } else {
                    kind = .plain
                }
                emit(kind, start..<index)
                continue
            }

            index += 1
            emit(
                punctuationCharacters.contains(characters[start]) ? .punctuation : .plain,
                start..<index
            )
        }
        return tokens
    }

    static func highlighted(
        _ code: String,
        language: String?,
        fontSize: CGFloat = 12
    ) -> AttributedString {
        var result = AttributedString()
        for token in tokens(for: code, language: language) {
            var piece = AttributedString(token.text)
            // Sized literally rather than through `Font.locus`, whose point-size
            // bucketing is what made this path and the AppKit one disagree.
            piece.font = .system(size: fontSize, design: .monospaced)
            if LocusCodeTheme.isItalic(token.kind) {
                piece.font = piece.font?.italic()
            }
            piece.foregroundColor = LocusCodeTheme.color(for: token.kind)
            result.append(piece)
        }
        return result
    }

    private static let literalConstants: Set<String> = [
        "true", "false", "null", "nil", "None", "True", "False",
        "undefined", "NULL", "nullptr", "NaN", "Infinity"
    ]

    private static let punctuationCharacters: Set<Character> = Set(
        "{}()[]<>.,;:+-*/%=!&|^~?@\\"
    )

    private static func normalizedLanguage(_ language: String?) -> String {
        let value = language?
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init) ?? ""
        return switch value {
        case "js", "jsx", "javascript", "mjs", "cjs": "javascript"
        case "ts", "tsx", "typescript": "typescript"
        case "py", "python3": "python"
        case "sh", "bash", "zsh", "shell", "fish": "shell"
        case "rs": "rust"
        case "golang": "go"
        case "c++", "cpp", "cc", "hpp": "cpp"
        case "objc", "objective-c": "objective-c"
        case "yml": "yaml"
        case "kt", "kts": "kotlin"
        case "rb": "ruby"
        case "cs": "csharp"
        case "htm", "xhtml": "html"
        case "conf", "cfg", "properties": "ini"
        case "make", "mk": "makefile"
        case "docker": "dockerfile"
        case "postgres", "psql", "mysql", "sqlite": "sql"
        default: value
        }
    }

    private static func keywordSet(for language: String) -> Set<String> {
        switch language {
        case "swift":
            return ["actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "for", "func", "guard", "if", "import", "in", "init", "let", "private", "protocol", "public", "return", "self", "static", "struct", "switch", "throw", "throws", "try", "var", "where", "while"]
        case "javascript", "typescript":
            return ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "interface", "let", "new", "of", "return", "static", "super", "switch", "throw", "try", "type", "typeof", "var", "while", "yield"]
        case "python":
            return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"]
        case "rust":
            return ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while"]
        case "go":
            return ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]
        case "c", "cpp", "objective-c":
            return ["auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "float", "for", "if", "int", "long", "namespace", "new", "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "while"]
        case "csharp":
            return ["abstract", "as", "async", "await", "base", "bool", "break", "case", "catch", "class", "const", "continue", "default", "delegate", "do", "double", "else", "enum", "event", "finally", "for", "foreach", "if", "in", "int", "interface", "internal", "is", "lock", "namespace", "new", "out", "override", "params", "private", "protected", "public", "readonly", "ref", "return", "sealed", "static", "string", "struct", "switch", "this", "throw", "try", "typeof", "using", "var", "virtual", "void", "while", "yield"]
        case "java":
            return ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "var", "void", "volatile", "while"]
        case "kotlin":
            return ["as", "break", "by", "class", "companion", "const", "continue", "data", "do", "else", "enum", "external", "false", "final", "for", "fun", "if", "import", "in", "infix", "init", "interface", "internal", "is", "lateinit", "object", "open", "operator", "override", "package", "private", "protected", "public", "return", "sealed", "super", "suspend", "this", "throw", "try", "typealias", "val", "var", "vararg", "when", "while"]
        case "ruby":
            return ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "elsif", "else", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "unless", "until", "when", "while", "yield"]
        case "php":
            return ["abstract", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enum", "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "isset", "match", "namespace", "new", "print", "private", "protected", "public", "readonly", "require", "return", "static", "switch", "throw", "trait", "try", "unset", "use", "var", "while", "yield"]
        case "lua":
            return ["and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or", "repeat", "return", "then", "until", "while"]
        case "sql":
            return ["add", "all", "alter", "and", "as", "asc", "between", "by", "case", "cast", "column", "create", "delete", "desc", "distinct", "drop", "else", "end", "exists", "from", "full", "group", "having", "in", "index", "inner", "insert", "into", "is", "join", "left", "like", "limit", "not", "offset", "on", "or", "order", "outer", "primary", "references", "right", "select", "set", "table", "then", "union", "unique", "update", "values", "view", "when", "where", "with"]
        case "css", "scss", "less":
            return ["and", "important", "media", "import", "include", "keyframes", "mixin", "not", "supports", "use"]
        case "html", "xml", "svg":
            return ["class", "href", "id", "rel", "src", "style", "type", "xmlns"]
        case "json":
            return []
        case "yaml", "toml", "ini":
            return ["on", "off", "yes", "no"]
        case "dockerfile":
            return ["add", "arg", "cmd", "copy", "entrypoint", "env", "expose", "from", "healthcheck", "label", "run", "shell", "user", "volume", "workdir", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM", "HEALTHCHECK", "LABEL", "RUN", "SHELL", "USER", "VOLUME", "WORKDIR", "ADD"]
        case "makefile":
            return ["define", "else", "endef", "endif", "export", "ifdef", "ifeq", "ifndef", "ifneq", "include", "override", "unexport"]
        case "shell":
            return ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "readonly", "return", "then", "until", "while"]
        default:
            // An unknown fence still deserves structure. A union of the most
            // universal control-flow words colors sensibly across languages we
            // do not list, instead of the flat wall an empty set produced.
            return commonKeywords
        }
    }

    private static let commonKeywords: Set<String> = [
        "and", "as", "async", "await", "break", "case", "catch", "class", "const",
        "continue", "def", "default", "do", "elif", "else", "end", "enum", "export",
        "extends", "finally", "fn", "for", "from", "func", "function", "if", "import",
        "in", "interface", "is", "let", "match", "module", "namespace", "new", "not",
        "or", "package", "pass", "private", "protected", "public", "require", "return",
        "self", "static", "struct", "super", "switch", "then", "this", "throw", "trait",
        "try", "type", "use", "val", "var", "void", "when", "where", "while", "with",
        "yield"
    ]

    /// Getting this wrong is worse than having no comment color at all: the old
    /// `//` fallback for unrecognised fences turned ordinary TOML and INI paths
    /// into comments. Unknown languages now opt out instead.
    private static func lineCommentPrefix(for language: String) -> [Character]? {
        return switch language {
        case "python", "shell", "ruby", "yaml", "toml", "ini", "dockerfile",
             "makefile", "perl", "r", "elixir", "julia", "nim", "hcl", "terraform":
            ["#"]
        case "sql", "lua", "haskell", "ada":
            ["-", "-"]
        case "lisp", "clojure", "scheme", "asm":
            [";"]
        case "swift", "javascript", "typescript", "rust", "go", "c", "cpp",
             "objective-c", "csharp", "java", "kotlin", "php", "scala", "dart",
             "zig", "groovy":
            ["/", "/"]
        default:
            nil
        }
    }

    private static func supportsBlockComments(_ language: String) -> Bool {
        [
            "swift", "javascript", "typescript", "rust", "go", "c", "cpp",
            "objective-c", "csharp", "java", "kotlin", "php", "scala", "dart",
            "css", "scss", "less", "groovy", "zig"
        ].contains(language)
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
    static func attributed(
        _ code: String,
        language: String?,
        isDiff: Bool,
        fontSize: CGFloat = 12
    ) -> NSAttributedString {
        if isDiff { return attributedDiff(code, fontSize: fontSize) }
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        for token in CodeSyntaxHighlighter.tokens(for: code, language: language) {
            result.append(NSAttributedString(
                string: token.text,
                attributes: [
                    .font: LocusCodeTheme.font(size: fontSize, kind: token.kind),
                    .foregroundColor: LocusCodeTheme.nsColor(for: token.kind),
                    .paragraphStyle: paragraph
                ]
            ))
        }
        return result
    }

    private static func attributedDiff(_ code: String, fontSize: CGFloat) -> NSAttributedString {
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
            let lineHeight = (fontSize * 1.62).rounded()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            result.append(NSAttributedString(
                string: value,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
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
/// Handed down by the workspace so a shell code block in the transcript can
/// offer Run. Surfaces without a terminal (sheets, notes) leave it nil and
/// the button stays hidden.
private struct RunInTerminalActionKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var runInTerminalAction: ((String) -> Void)? {
        get { self[RunInTerminalActionKey.self] }
        set { self[RunInTerminalActionKey.self] = newValue }
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    var density: MarkdownRenderDensity = .regular
    var selectionStore: TranscriptSelectionStore? = nil
    var selectionSpan: TranscriptSelectionSpan? = nil
    @Environment(\.runInTerminalAction) private var runInTerminal
    @State private var copied = false
    @State private var collapsed = false
    @State private var sentToTerminal = false

    private static let shellLanguages: Set<String> = [
        "bash", "sh", "zsh", "shell", "shellscript", "fish",
    ]

    private var lines: [String] { LongOutputPolicy.codeLines(code) }

    private var isLong: Bool {
        lines.count > LongOutputPolicy.codeCollapseThreshold
    }

    private var visibleCode: String {
        guard collapsed, isLong else { return code }
        return lines.prefix(LongOutputPolicy.codePreviewLineCount).joined(separator: "\n")
    }

    private var isShell: Bool {
        Self.shellLanguages.contains(
            (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private var displayLanguage: String {
        if isShell { return "Terminal" }
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Code" : value.capitalized
    }

    private var isDiff: Bool {
        language?.lowercased() == "diff" || DiffDetector.isDiff(code)
    }

    private var headerSymbol: String {
        if isDiff { return "plusminus" }
        if isShell { return "terminal" }
        return "chevron.left.forwardslash.chevron.right"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: headerSymbol)
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
                if isShell, let runInTerminal {
                    Button {
                        runInTerminal(code)
                        sentToTerminal = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            sentToTerminal = false
                        }
                    } label: {
                        Label(
                            sentToTerminal ? "Sent" : "Run",
                            systemImage: sentToTerminal ? "checkmark" : "play.fill"
                        )
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(sentToTerminal ? LocusTheme.success : LocusTheme.muted)
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                        .background(LocusTheme.white.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.locus())
                    .help("Run in the workspace terminal")
                    .accessibilityLabel("Run code block in the terminal")
                    .accessibilityIdentifier("message.codeBlock.run")
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
                if let selectionStore, let selectionSpan {
                    ResponseSelectableText(
                        attributedText: NativeCodeTextRenderer.attributed(
                            visibleCode.isEmpty ? " " : visibleCode,
                            language: language,
                            isDiff: isDiff,
                            fontSize: density.codeFontSize
                        ),
                        span: selectionSpan.displaying(visibleCode),
                        store: selectionStore,
                        wraps: false
                    )
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, isDiff ? 8 : 11)
                } else if isDiff {
                    CodeDiffLines(code: visibleCode, fontSize: density.codeFontSize)
                } else {
                    Text(CodeSyntaxHighlighter.highlighted(
                        visibleCode.isEmpty ? " " : visibleCode,
                        language: language,
                        fontSize: density.codeFontSize
                    ))
                        .lineSpacing(4)
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
    let fontSize: CGFloat

    init(code: String, fontSize: CGFloat = 12) {
        lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        self.fontSize = fontSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.locusExact(size: fontSize, design: .monospaced))
                    .foregroundStyle(foreground(for: line))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .frame(minHeight: (fontSize * 1.62).rounded(), alignment: .leading)
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
