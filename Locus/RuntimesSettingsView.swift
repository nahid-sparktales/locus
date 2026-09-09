import ServiceManagement
import SwiftUI

struct RuntimesSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var runtimes: RuntimeModel

    var body: some View {
        Form {
            Section("This Mac") {
                Text("Let selected agents continue after you close Locus. Your Mac must remain awake and logged in.")
                    .foregroundStyle(.secondary)
                LabeledContent("Background service", value: runtimes.installationStatus)
                if RuntimeInstallation.supported {
                    if RuntimeInstallation.enabled {
                        Button("Stop runtime") { Task { await runtimes.stopRuntime() } }
                        Text("Stopping the runtime pauses its work. Saved progress remains available.").font(.caption)
                    } else {
                        Button("Enable independent runtime") { Task { await runtimes.enable(workspace: model.workspacePath) } }.disabled(model.isBusy || model.taskWorkers.values.contains(where: { !$0.acceptsNewTurns }))
                    }
                    Button("Open macOS Login Items") { SMAppService.openSystemSettingsLoginItems() }
                } else {
                    Text("Independent runtime installation is available in direct-download Locus.")
                }
            }
            if let snapshot = runtimes.snapshot {
                Section("Agents on this runtime") {
                    if snapshot.paused == true { Button("Resume scheduling") { Task { await runtimes.resumeRuntime() } } }
                    if snapshot.workers.isEmpty { Text("Open a chat to start its runtime worker.").foregroundStyle(.secondary) }
                    ForEach(snapshot.workers) { worker in
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent(URL(fileURLWithPath: worker.workspace).lastPathComponent, value: worker.state.replacingOccurrences(of: "_", with: " ").capitalized)
                            if let reason = worker.waitingReason, !reason.isEmpty { Text(reason).font(.caption).textSelection(.enabled) }
                            if let interrupted = worker.interruptedCommands, !interrupted.isEmpty {
                                DisclosureGroup("Review interrupted requests") {
                                    Text("Their outcomes are uncertain. Inspect saved files and activity before allowing new work. These requests will not be replayed.").font(.caption)
                                    ForEach(interrupted) { item in
                                        Text(item.command["text"]?.string ?? item.command["path"]?.string ?? item.id).font(.caption).textSelection(.enabled)
                                    }
                                    Button("Keep saved work and allow new tasks") { Task { await runtimes.acknowledgeInterruption(worker) } }
                                }
                            }
                            Toggle("Keep running when Locus closes", isOn: Binding(
                                get: { worker.keepRunning },
                                set: { enabled in Task { await runtimes.setKeepRunning(sessionID: worker.sessionID, enabled: enabled) } }
                            ))
                            HStack {
                                Button("Pause") { Task { await runtimes.control(sessionID: worker.sessionID, action: "pause") } }
                                Button("Resume") { Task { await runtimes.control(sessionID: worker.sessionID, action: "resume") } }
                                Button("Stop") { Task { await runtimes.control(sessionID: worker.sessionID, action: "stop") } }
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
            if RuntimeInstallation.enabled { Section("Remote runtimes") { RemoteRuntimesView() } }
            if let error = runtimes.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .disabled(runtimes.isWorking)
        .task { await runtimes.refresh() }
        .accessibilityIdentifier("settings.runtimes")
    }
}
