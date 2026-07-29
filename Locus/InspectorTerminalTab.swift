import SwiftUI

/// A command console for the workspace. Output streams live; a command can be
/// cancelled and can be answered when it asks a question.
struct InspectorTerminalTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // The session is observed here rather than on AppModel so streaming
        // output redraws only this panel.
        TerminalPanel(terminal: model.terminal, workspacePath: model.workspacePath)
    }
}

private struct TerminalPanel: View {
    @ObservedObject var terminal: TerminalSession
    let workspacePath: String
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if terminal.isEmpty {
                InspectorPlaceholder(
                    symbol: "terminal",
                    title: "Console",
                    message: "Run a command in \(URL(fileURLWithPath: workspacePath).lastPathComponent). Output streams here as it happens.\n\nThis is not a full terminal: interactive apps like vim and top will not work.",
                    identifier: "terminal.empty"
                )
            } else {
                output
            }

            if terminal.isRunning {
                stdinBar
            }
            commandBar
        }
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(terminal.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .accessibilityIdentifier("terminal.output")
            .onChange(of: terminal.lines.count) {
                if let last = terminal.lines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var stdinBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(LocusTheme.muted)
            TextField("Answer a prompt…", text: $terminal.stdinDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .onSubmit { terminal.sendInput(terminal.stdinDraft) }
                .accessibilityIdentifier("terminal.stdin")
            Button("Send") { terminal.sendInput(terminal.stdinDraft) }
                .buttonStyle(.plain)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .disabled(terminal.stdinDraft.isEmpty)
                .accessibilityIdentifier("terminal.stdin.send")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(LocusTheme.white.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private var commandBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("$")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)

                TextField("git status", text: $terminal.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .focused($commandFocused)
                    .disabled(terminal.isRunning)
                    .onSubmit { terminal.run(terminal.draft) }
                    .accessibilityIdentifier("terminal.command")

                if terminal.isRunning {
                    ProgressView().controlSize(.small)
                    Button {
                        terminal.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white)
                            .frame(width: 22, height: 22)
                            .background(LocusTheme.coral)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Stop the command")
                    .accessibilityLabel("Stop command")
                    .accessibilityIdentifier("terminal.cancel")
                } else {
                    Button {
                        terminal.run(terminal.draft)
                    } label: {
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                terminal.draft.isEmpty ? LocusTheme.muted : LocusTheme.ink
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(terminal.draft.isEmpty)
                    .help("Run")
                    .accessibilityLabel("Run command")
                    .accessibilityIdentifier("terminal.run")
                }

                if !terminal.isEmpty {
                    Button {
                        terminal.clear()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the console")
                    .accessibilityLabel("Clear console")
                    .accessibilityIdentifier("terminal.clear")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .top) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private func color(for line: TerminalLine) -> Color {
        switch line.kind {
        case .command: LocusTheme.ink
        case .output: LocusTheme.inkSoft
        case .status: LocusTheme.muted
        }
    }
}
