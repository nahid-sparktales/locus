import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The transcript card for an `interactive` answer part.
///
/// `original()` is the native, selectable title and summary the caller
/// already renders as the universal fallback; the sealed web view sits below
/// it at the part's fixed height. Every degraded state — the kill switch, a
/// rule list that did not compile, a host torn down for the budget, a hung or
/// crashed page — keeps the summary and replaces only the web view with a
/// placeholder, so the answer is never blank.
struct InteractiveAnswerView<Original: View>: View {
    let title: String
    let summary: String
    let html: String
    let height: CGFloat
    let isEnabled: Bool
    let identity: String
    let original: () -> Original

    init(
        title: String,
        summary: String,
        html: String,
        height: CGFloat,
        isEnabled: Bool,
        identity: String,
        @ViewBuilder original: @escaping () -> Original
    ) {
        self.title = title
        self.summary = summary
        self.html = html
        self.height = height
        self.isEnabled = isEnabled
        self.identity = identity
        self.original = original
    }

    var body: some View {
        InteractiveAnswerCard(
            title: title, summary: summary, html: html, height: height,
            isEnabled: isEnabled, original: original
        )
        .id(identity)
    }
}

/// What the card shows below the summary. Pure so the decision is testable
/// without a window.
enum InteractiveAnswerPresentation: Equatable {
    case summaryOnly
    case loading
    case web
    case unavailable
    case budgetExceeded
    case stopped

    static func mode(isEnabled: Bool, state: InteractiveAnswerHost.State) -> InteractiveAnswerPresentation {
        guard isEnabled else { return .summaryOnly }
        switch state {
        case .idle, .loading: return .loading
        case .ready: return .web
        case .unavailable: return .unavailable
        case .stopped(.budgetExceeded): return .budgetExceeded
        case .stopped(.unresponsive), .stopped(.terminated): return .stopped
        }
    }
}

private struct InteractiveAnswerCard<Original: View>: View {
    let title: String
    let summary: String
    let html: String
    let height: CGFloat
    let isEnabled: Bool
    let original: () -> Original

    @StateObject private var host: InteractiveAnswerHost
    @State private var enlarged = false
    @State private var saveStatus: String?

    init(
        title: String, summary: String, html: String, height: CGFloat,
        isEnabled: Bool, original: @escaping () -> Original
    ) {
        self.title = title
        self.summary = summary
        self.html = html
        self.height = height.clamped(to: InteractiveAnswerWebView.heightRange)
        self.isEnabled = isEnabled
        self.original = original
        _host = StateObject(wrappedValue: InteractiveAnswerHost(
            html: html,
            height: height.clamped(to: InteractiveAnswerWebView.heightRange)
        ))
    }

    private var mode: InteractiveAnswerPresentation {
        InteractiveAnswerPresentation.mode(isEnabled: isEnabled, state: host.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            original()
            if mode != .summaryOnly {
                content
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                actions
            }
        }
        .padding(14).locusCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interactive explanation, \(title)")
        .accessibilityIdentifier("message.interactiveAnswer")
        .task(id: host.state == .idle && isEnabled) {
            if isEnabled { host.start() }
        }
        .sheet(isPresented: $enlarged) {
            InteractiveAnswerSheet(title: title, html: html)
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .summaryOnly:
            EmptyView()
        case .web, .loading:
            ZStack {
                if mode == .loading {
                    placeholder("Loading interactive content…")
                }
                if host.webView != nil {
                    InteractiveAnswerWebView(host: host, height: height)
                        .accessibilityLabel("Interactive content, \(title)")
                }
            }
        case .unavailable:
            placeholder("Interactive content unavailable")
        case .budgetExceeded:
            placeholder("Interactive content paused to save memory") {
                Button("Show interactive content") { host.reload() }
                    .accessibilityIdentifier("message.interactiveAnswer.show")
            }
        case .stopped:
            placeholder(stoppedMessage) {
                Button("Reload") { host.reload() }
                    .accessibilityIdentifier("message.interactiveAnswer.reload")
            }
        }
    }

    private var stoppedMessage: String {
        switch host.state {
        case .stopped(.unresponsive): "This interactive content stopped responding and was closed."
        case .stopped(.terminated): "This interactive content stopped."
        default: "This interactive content stopped."
        }
    }

    private func placeholder(_ message: String) -> some View {
        placeholder(message) { EmptyView() }
    }

    private func placeholder<Action: View>(
        _ message: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.locus(size: 12))
                .foregroundStyle(LocusTheme.textSecondary)
                .multilineTextAlignment(.center)
            action()
                .buttonStyle(.locus(.card))
                .font(.locus(size: 12))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LocusTheme.surfaceStructural)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Open larger") { enlarged = true }
                .disabled(mode != .web)
                .accessibilityIdentifier("message.interactiveAnswer.openLarger")
            Button("Copy HTML") { copyHTML() }
                .accessibilityIdentifier("message.interactiveAnswer.copy")
            Button("Save As…") { saveDocument() }
                .accessibilityIdentifier("message.interactiveAnswer.save")
            if let saveStatus {
                Text(saveStatus)
                    .font(.locus(size: 11))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("message.interactiveAnswer.saveStatus")
            }
        }
        .buttonStyle(.locus()).font(.locus(size: 11))
    }

    private func copyHTML() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .string)
    }

    private func saveDocument() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = InteractiveAnswerDocument.suggestedFileName(title: title)
        panel.title = "Save Interactive Answer"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try InteractiveAnswerDocument.write(
                html: html,
                to: url,
                appearance: InteractiveAnswerHost.applicationAppearance()
            )
            saveStatus = "Saved \(url.lastPathComponent)"
        } catch {
            saveStatus = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// "Open larger": the same fragment in a second sealed host at the maximum
/// height, in a sheet the person dismisses with Close or Escape.
private struct InteractiveAnswerSheet: View {
    let title: String
    let html: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var host: InteractiveAnswerHost

    init(title: String, html: String) {
        self.title = title
        self.html = html
        _host = StateObject(wrappedValue: InteractiveAnswerHost(
            html: html,
            height: InteractiveAnswerWebView.heightRange.upperBound
        ))
    }

    private var mode: InteractiveAnswerPresentation {
        InteractiveAnswerPresentation.mode(isEnabled: true, state: host.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.locus(size: 15, weight: .semibold))
                    .foregroundStyle(LocusTheme.textPrimary)
                    .lineLimit(2)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.locus())
                    .font(.locus(size: 12))
                    .accessibilityIdentifier("message.interactiveAnswer.close")
            }
            Group {
                switch mode {
                case .web, .loading:
                    ZStack {
                        if mode == .loading {
                            Text("Loading interactive content…")
                                .font(.locus(size: 12))
                                .foregroundStyle(LocusTheme.textSecondary)
                        }
                        if host.webView != nil {
                            InteractiveAnswerWebView(host: host, height: InteractiveAnswerWebView.heightRange.upperBound)
                                .accessibilityLabel("Interactive content, \(title)")
                        }
                    }
                case .stopped, .budgetExceeded:
                    VStack(spacing: 10) {
                        Text("This interactive content stopped.")
                            .font(.locus(size: 12))
                            .foregroundStyle(LocusTheme.textSecondary)
                        Button("Reload") { host.reload() }
                            .buttonStyle(.locus(.card))
                            .font(.locus(size: 12))
                    }
                case .unavailable, .summaryOnly:
                    Text("Interactive content unavailable")
                        .font(.locus(size: 12))
                        .foregroundStyle(LocusTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: InteractiveAnswerWebView.heightRange.upperBound)
            .background(LocusTheme.surfaceStructural)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(18)
        .frame(minWidth: 720, idealWidth: 900, minHeight: 720 + 90)
        .background(LocusTheme.surfacePanel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message.interactiveAnswer.sheet")
        .task { host.start() }
    }
}
