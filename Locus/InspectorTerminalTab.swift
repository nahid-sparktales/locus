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
            services
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
            model.refreshBackgroundServices()
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

    private var services: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Managed services", systemImage: "server.rack")
                    .font(.locus(size: 8, weight: .semibold))
                Spacer()
                Button { model.refreshBackgroundServices() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.locus())
                .help("Refresh managed services")
            }
            ForEach(model.backgroundServices) { service in
                HStack(spacing: 7) {
                    Circle()
                        .fill(service.running ? LocusTheme.success : LocusTheme.warning)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.name)
                            .font(.locus(size: 8, weight: .semibold))
                        Text(service.port.map { "localhost:\($0) · pid \(service.pid ?? 0)" }
                            ?? "pid \(service.pid ?? 0)")
                            .font(.locus(size: 7, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted)
                    }
                    Spacer()
                    if service.running {
                        Button("Stop", role: .destructive) {
                            model.stopBackgroundService(service)
                        }
                        .buttonStyle(.locus())
                        .font(.locus(size: 8))
                    } else {
                        HStack(spacing: 6) {
                            Text("Exited \(service.exitCode ?? 0)")
                                .font(.locus(size: 7, design: .monospaced))
                                .foregroundStyle(LocusTheme.warning)
                            Button("Dismiss") {
                                model.stopBackgroundService(service)
                            }
                            .buttonStyle(.locus())
                            .font(.locus(size: 8))
                        }
                    }
                }
            }
            if model.backgroundServices.isEmpty {
                Text("No managed services. Agents use these for servers and watchers that should survive Stop.")
                    .font(.locus(size: 7))
                    .foregroundStyle(LocusTheme.muted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .accessibilityIdentifier("terminal.managedServices")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(terminal.isRunning ? LocusTheme.success : LocusTheme.muted)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(terminal.title)
                    .font(.locus(size: 9, weight: .semibold))
                    .lineLimit(1)
                Text(terminal.currentDirectory.isEmpty ? model.workspacePath : terminal.currentDirectory)
                    .font(.locus(size: 8, design: .monospaced))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if TerminalSession.isSandboxedBuild {
                Label("Sandboxed", systemImage: "lock.fill")
                    .font(.locus(size: 7, weight: .semibold))
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
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(destructive ? LocusTheme.coral : LocusTheme.muted)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.locus())
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
        terminal.updateAppearance(isDark: context.environment.colorScheme == .dark)
        return terminal.hostView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        terminal.updateAppearance(isDark: context.environment.colorScheme == .dark)
    }
}
