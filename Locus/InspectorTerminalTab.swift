import SwiftUI

/// A persistent, app-owned terminal for the active workspace.
struct InspectorTerminalTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TerminalPanel(terminal: model.terminal)
            .environmentObject(model)
    }
}

private struct TerminalPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var terminal: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalHostView(terminal: terminal)
                .accessibilityIdentifier("terminal.output")
                .overlay {
                    if let message = terminal.errorMessage {
                        ContentUnavailableView(
                            "Terminal unavailable",
                            systemImage: "terminal",
                            description: Text(message)
                        )
                        .background(LocusTheme.paperDeep)
                    }
                }
        }
        .background(LocusTheme.paperDeep)
        .onAppear {
            configure()
            terminal.ensureStarted()
            terminal.focus()
        }
        .onChange(of: model.workspacePath) { configure() }
        .onChange(of: model.settings.terminalShell) { configure() }
        .onChange(of: model.settings.terminalLoginShell) { configure() }
        .confirmationDialog(
            "A program is still running",
            isPresented: Binding(
                get: { terminal.needsWorkspaceSwitchConfirmation },
                set: { if !$0 { terminal.keepCurrentShell() } }
            )
        ) {
            Button("Restart in the new workspace", role: .destructive) {
                terminal.confirmWorkspaceSwitch()
            }
            Button("Keep the current shell", role: .cancel) {
                terminal.keepCurrentShell()
            }
        } message: {
            Text("Switching the terminal now will stop its foreground process. You can keep it running and restart the terminal later.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(terminal.isRunning ? Color.green : LocusTheme.muted)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(terminal.title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                Text(terminal.currentDirectory.isEmpty ? model.workspacePath : terminal.currentDirectory)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if TerminalSession.isSandboxedBuild {
                Label("Sandboxed", systemImage: "lock.fill")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(LocusTheme.warning)
                    .help("This terminal inherits the App Store sandbox and can access only approved locations.")
            }
            terminalButton("magnifyingglass", help: "Find") { terminal.showFind() }
            terminalButton("clear", help: "Clear scrollback") { terminal.clear() }
            terminalButton("arrow.clockwise", help: "Restart shell") { terminal.restart() }
            if terminal.isRunning {
                terminalButton("stop.fill", help: "Terminate shell", destructive: true) {
                    terminal.terminate()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .accessibilityIdentifier("terminal.header")
    }

    private func terminalButton(
        _ symbol: String,
        help: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(destructive ? LocusTheme.coral : LocusTheme.muted)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func configure() {
        terminal.configure(
            workspacePath: model.workspacePath,
            shell: model.settings.terminalShell,
            loginShell: model.settings.terminalLoginShell
        )
    }
}

private struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var terminal: TerminalSession

    func makeNSView(context: Context) -> NSView {
        terminal.hostView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
