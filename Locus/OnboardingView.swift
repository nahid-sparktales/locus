import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var onboarding: OnboardingModel
    @EnvironmentObject private var providers: ProviderAccountsModel
    @State private var editingAccount: ProviderAccount?
    @State private var modelLibraryPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch onboarding.progress.step {
                    case .startingPoint: startingPoint
                    case .model: connection
                    case .workspace: workspace
                    case .firstTask: firstTask
                    }
                    if let error = onboarding.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(LocusTheme.warning)
                            .accessibilityIdentifier("onboarding.error")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            footer
        }
        .font(.locus(size: 13))
        .foregroundStyle(LocusTheme.ink)
        .background(LocusTheme.paper)
        .frame(minWidth: 520, idealWidth: 630, maxWidth: 760, minHeight: 490, idealHeight: 570)
        .sheet(item: $editingAccount) { account in
            AccountEditorView(account: account, isNew: !providers.providerAccounts.contains { $0.id == account.id })
                .appFeatureEnvironment(from: model)
        }
        .sheet(isPresented: $modelLibraryPresented) {
            ModelLibraryView().appFeatureEnvironment(from: model)
        }
        .task {
            while !Task.isCancelled {
                onboarding.refreshReadiness()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onExitCommand { onboarding.dismiss() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Getting Started", systemImage: "sparkles")
                    .font(.locus(size: 14, weight: .semibold))
                Spacer()
                Text("Step \(onboarding.progress.step.rawValue + 1) of 4")
                    .foregroundStyle(LocusTheme.textSecondary)
            }
            Text(onboarding.progress.step.title)
                .font(.locus(size: 23, weight: .semibold))
                .accessibilityIdentifier("onboarding.title")
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step.rawValue <= onboarding.progress.step.rawValue
                              ? LocusTheme.signalDeep : LocusTheme.line)
                        .frame(height: 3)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(24)
    }

    private var startingPoint: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Start with something useful. You can explore the rest of Locus whenever you like.")
                .foregroundStyle(LocusTheme.textSecondary)
            ForEach(OnboardingStartingPoint.allCases) { point in
                Button { onboarding.select(point) } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: point == .documents ? "doc.text.magnifyingglass" : "chevron.left.forwardslash.chevron.right")
                            .font(.locus(size: 23))
                            .foregroundStyle(LocusTheme.signalDeep)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(point.title).font(.locus(size: 15, weight: .semibold))
                            Text(point == .documents
                                 ? "Ask questions about documents and make a summary you can keep."
                                 : "Understand a repository and save a useful guide to its structure.")
                                .foregroundStyle(LocusTheme.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: onboarding.progress.startingPoint == point ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(onboarding.progress.startingPoint == point ? LocusTheme.signalDeep : LocusTheme.textSecondary)
                    }
                    .padding(18)
                    .background(LocusTheme.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(onboarding.progress.startingPoint == point ? LocusTheme.signalDeep : LocusTheme.line, lineWidth: 1))
                }
                .buttonStyle(.locus())
                .disabled(onboarding.isRunning)
                .accessibilityIdentifier("onboarding.path.\(point.rawValue)")
                .accessibilityAddTraits(onboarding.progress.startingPoint == point ? .isSelected : [])
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(onboarding.readiness.ready ? "Your model is ready" : "Connect a model to continue", systemImage: onboarding.readiness.ready ? "checkmark.circle.fill" : "circle.dotted")
                .font(.locus(size: 15, weight: .semibold))
                .foregroundStyle(onboarding.readiness.ready ? LocusTheme.success : LocusTheme.ink)
                .accessibilityIdentifier("onboarding.readiness")
            Text(onboarding.readiness.detail).foregroundStyle(LocusTheme.textSecondary)
            if !onboarding.readiness.modelName.isEmpty {
                LabeledContent("Selected model", value: onboarding.readiness.modelName)
            }
            GroupBox("Local Ollama") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Runs on your Mac without API charges. Ollama and model weights are separate downloads.")
                        .foregroundStyle(LocusTheme.textSecondary)
                    HStack {
                        Menu("Choose installed model") {
                            ForEach(providers.localModels, id: \.name) { local in
                                Button(local.name) { model.selectModel(account: nil, model: local.name) }
                            }
                        }
                        .disabled(providers.localModels.isEmpty)
                        Button("Browse models…") { modelLibraryPresented = true }
                            .accessibilityIdentifier("onboarding.browseModels")
                        Spacer()
                    }
                    Link("Install Ollama", destination: URL(string: "https://ollama.com/download/mac")!)
                }.padding(8)
            }
            GroupBox("Use an account") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("A hosted model receives the content you send. ChatGPT plan access uses your subscription; API accounts are billed separately by their provider.")
                        .foregroundStyle(LocusTheme.textSecondary)
                    HStack {
                        Menu("Choose account") {
                            ForEach(providers.providerAccounts) { account in
                                Button(account.displayName) {
                                    model.selectModel(account: account, model: model.routedModel(for: account))
                                }
                            }
                        }.disabled(providers.providerAccounts.isEmpty)
                        Menu("Add account…") {
                            ForEach(ProviderKind.allCases) { kind in
                                Button(kind.marketingName) { editingAccount = ProviderAccount(kind: kind) }
                            }
                        }
                        if let account = model.activeAccount {
                            Button("Connection settings…") { editingAccount = account }
                        }
                    }
                }.padding(8)
            }
            Button(onboarding.isChecking ? "Checking…" : "Check connection / Retry") { onboarding.checkConnection() }
                .disabled(onboarding.isChecking)
                .accessibilityIdentifier("onboarding.checkConnection")
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A workspace keeps your chats, documents, and saved outputs together.")
                .foregroundStyle(LocusTheme.textSecondary)
            Button { model.chooseOnboardingSample() } label: {
                Label("Try the sample workspace", systemImage: "sparkles.rectangle.stack")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .disabled(onboarding.isRunning)
            .accessibilityIdentifier("onboarding.sample")
            Button { model.chooseOnboardingWorkspace() } label: {
                Label("Choose my own folder…", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .disabled(onboarding.isRunning)
            .accessibilityIdentifier("onboarding.chooseWorkspace")
            if let path = onboarding.progress.workspace {
                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark.circle.fill")
                    .font(.locus(size: 15, weight: .semibold))
                Text(path).font(.locus(size: 12)).foregroundStyle(LocusTheme.textSecondary).textSelection(.enabled)
            }
            Text("Document indexing is enabled when you start the document example. Files stay in this workspace and appear in Library → Documents.")
                .foregroundStyle(LocusTheme.textSecondary)
        }
    }

    private var firstTask: some View {
        VStack(alignment: .leading, spacing: 16) {
            if onboarding.progress.firstTaskCompleted {
                Label("Your first task is complete", systemImage: "checkmark.circle.fill")
                    .font(.locus(size: 18, weight: .semibold)).foregroundStyle(LocusTheme.success)
                Text("Your result is saved in Library → Outputs, with its own version history.")
                if let duration = onboarding.progress.durationMilliseconds {
                    Text("Task time: \(Double(duration) / 1_000, specifier: "%.1f") seconds")
                        .foregroundStyle(LocusTheme.textSecondary)
                }
                if let firstResponse = onboarding.progress.firstResponseMilliseconds {
                    Text("First response: \(Double(firstResponse) / 1_000, specifier: "%.1f") seconds")
                        .foregroundStyle(LocusTheme.textSecondary)
                }
                if let throughput = onboarding.progress.outputTokensPerSecond {
                    Text("Output throughput over the whole task: \(throughput, specifier: "%.1f") tokens/second")
                        .foregroundStyle(LocusTheme.textSecondary)
                }
                Text("These timings describe this task, including tool work; they do not measure model quality.")
                    .foregroundStyle(LocusTheme.textSecondary)
                Button("Open Outputs") {
                    onboarding.requestOutputs()
                }
            } else {
                Text(onboarding.progress.startingPoint == .documents
                     ? "Make a concise summary with citations to the documents in your workspace."
                     : "Map the repository and make a concise guide to its structure and next steps.")
                    .font(.locus(size: 16, weight: .medium))
                LabeledContent("Saved result", value: onboarding.progress.startingPoint.outputPath)
                Text("The task opens in a normal chat, where you can follow progress and answer any approval requests. Find this guide again under Help → Getting Started.")
                    .foregroundStyle(LocusTheme.textSecondary)
                if onboarding.isRunning {
                    Label(onboarding.isWaitingForOutput ? "Saving the output…" : "Your task is running in its chat", systemImage: "clock")
                    Button("Return to chat") { onboarding.dismiss() }
                } else {
                    Button(onboarding.isStarting ? "Starting…" : (onboarding.progress.failure == nil ? "Run first task" : "Retry first task")) {
                        onboarding.runFirstTask()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(onboarding.isStarting || !onboarding.readiness.ready || onboarding.progress.workspace == nil)
                    .accessibilityIdentifier("onboarding.runFirstTask")
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip setup") { onboarding.dismiss() }
                .accessibilityIdentifier("onboarding.skip")
            Spacer()
            if onboarding.progress.step != .startingPoint {
                Button("Back") { onboarding.back() }
                    .disabled(onboarding.isStarting)
                    .accessibilityIdentifier("onboarding.back")
            }
            if onboarding.progress.step != .firstTask {
                Button("Continue") { onboarding.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.continue")
            } else {
                Button("Done") { onboarding.dismiss() }
                    .accessibilityIdentifier("onboarding.done")
            }
        }.padding(20)
    }
}
