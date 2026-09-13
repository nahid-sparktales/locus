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
                Text("Step \(onboarding.stepNumber) of \(onboarding.steps.count)")
                    .foregroundStyle(LocusTheme.textSecondary)
            }
            Text(onboarding.stepTitle)
                .font(.locus(size: 23, weight: .semibold))
                .accessibilityIdentifier("onboarding.title")
            HStack(spacing: 6) {
                ForEach(onboarding.steps, id: \.rawValue) { step in
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
            Text("Pick something to try. We’ll help you take the first step.")
                .foregroundStyle(LocusTheme.textSecondary)
            ForEach(OnboardingStartingPoint.allCases) { point in
                Button { onboarding.select(point) } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: point.symbol)
                            .font(.locus(size: 23))
                            .foregroundStyle(LocusTheme.signalDeep)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(point.title).font(.locus(size: 15, weight: .semibold))
                            Text(point.summary)
                                .foregroundStyle(LocusTheme.textSecondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: onboarding.progress.startingPoint == point ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(onboarding.progress.startingPoint == point ? LocusTheme.signalDeep : LocusTheme.textSecondary)
                    }
                    .padding(16)
                    .background(LocusTheme.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(onboarding.progress.startingPoint == point ? LocusTheme.signalDeep : LocusTheme.line, lineWidth: 1))
                }
                .buttonStyle(.locus())
                .disabled(onboarding.isStarting || onboarding.isRunning)
                .accessibilityIdentifier("onboarding.path.\(point.rawValue)")
                .accessibilityAddTraits(onboarding.progress.startingPoint == point ? .isSelected : [])
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(onboarding.readiness.ready ? "You’re connected" : "Connect the AI you want to use", systemImage: onboarding.readiness.ready ? "checkmark.circle.fill" : "circle.dotted")
                .font(.locus(size: 15, weight: .semibold))
                .foregroundStyle(onboarding.readiness.ready ? LocusTheme.success : LocusTheme.ink)
                .accessibilityIdentifier("onboarding.readiness")
            if onboarding.readiness.ready {
                Text("\(onboarding.readiness.modelName) is ready. Continue when you’re ready to try it.")
                    .foregroundStyle(LocusTheme.textSecondary)
                DisclosureGroup("Change AI connection") {
                    connectionOptions.padding(.top, 12)
                }
            } else {
                Text("Use an account you already have, or run AI on your Mac with Ollama.")
                    .foregroundStyle(LocusTheme.textSecondary)
                connectionOptions
                DisclosureGroup("Connection details") {
                    Text(onboarding.readiness.detail)
                        .foregroundStyle(LocusTheme.textSecondary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var connectionOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Run on your Mac") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Use Ollama for local AI without API charges. Install Ollama, then download a model.")
                        .foregroundStyle(LocusTheme.textSecondary)
                    HStack {
                        Menu("Choose a model") {
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
                    Text("Connect ChatGPT or another AI provider. Content is sent to that service; API usage may cost extra.")
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
                            ForEach(ProviderKind.allCases.filter { $0 != .claudePlan || model.claudePlanEnabled }) { kind in
                                Button(kind.marketingName) { editingAccount = ProviderAccount(kind: kind) }
                            }
                        }
                        if let account = model.activeAccount {
                            Button("Connection settings…") { editingAccount = account }
                        }
                    }
                }.padding(8)
            }
            Button(onboarding.isChecking ? "Checking…" : "Check connection") { onboarding.checkConnection() }
                .disabled(onboarding.isChecking)
                .accessibilityIdentifier("onboarding.checkConnection")
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Locus uses a folder, called a workspace, to keep your files and results together.")
                .foregroundStyle(LocusTheme.textSecondary)
            Button { model.chooseOnboardingSample() } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Try a sample", systemImage: "sparkles.rectangle.stack")
                        .font(.locus(size: 14, weight: .semibold))
                    Text("Ready-made files to explore. A good place to start.")
                        .foregroundStyle(LocusTheme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .disabled(onboarding.isRunning)
            .accessibilityIdentifier("onboarding.sample")
            Button { model.chooseOnboardingWorkspace() } label: {
                Label("Use my own folder…", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .disabled(onboarding.isRunning)
            .accessibilityIdentifier("onboarding.chooseWorkspace")
            if let path = onboarding.progress.workspace {
                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark.circle.fill")
                    .font(.locus(size: 15, weight: .semibold))
                    .help(path)
            }
            if onboarding.progress.startingPoint == .documents {
                Text("Locus will make the documents in this folder searchable when you start. You can find them in Library → Documents.")
                    .foregroundStyle(LocusTheme.textSecondary)
            }
        }
    }

    private var firstTask: some View {
        VStack(alignment: .leading, spacing: 16) {
            if onboarding.progress.startingPoint == .agents {
                agentSetup
            } else if onboarding.progress.firstTaskCompleted {
                Label("Your first task is complete", systemImage: "checkmark.circle.fill")
                    .font(.locus(size: 18, weight: .semibold)).foregroundStyle(LocusTheme.success)
                Text("Your result is ready in Library → Outputs.")
                Button("View my result") { onboarding.requestOutputs() }
                    .buttonStyle(.borderedProminent)
                DisclosureGroup("Task details") {
                    taskDetails.padding(.top, 8)
                }
            } else {
                Text(onboarding.progress.startingPoint == .documents
                     ? "Turn your documents into a short summary with links to the sources."
                     : "Get a short guide to your code project and ideas for what to do next.")
                    .font(.locus(size: 16, weight: .medium))
                if let outputPath = onboarding.progress.startingPoint.outputPath {
                    LabeledContent("Saved as", value: outputPath)
                }
                Text("Follow along in the chat. Locus will ask if it needs your help.")
                    .foregroundStyle(LocusTheme.textSecondary)
                if onboarding.isRunning {
                    Label(onboarding.isWaitingForOutput ? "Saving your result…" : "Your task is running", systemImage: "clock")
                    Button("Return to chat") { onboarding.dismiss() }
                } else {
                    Button(onboarding.isStarting ? "Starting…" : (onboarding.progress.failure == nil ? "Start my first task" : "Try again")) {
                        onboarding.runFirstTask()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(onboarding.isStarting || !onboarding.readiness.ready || onboarding.progress.workspace == nil)
                    .accessibilityIdentifier("onboarding.runFirstTask")
                    if !onboarding.readiness.ready || onboarding.progress.workspace == nil {
                        Text(!onboarding.readiness.ready
                             ? "Go back to connect your AI before starting."
                             : "Go back to choose a sample or your own folder.")
                            .foregroundStyle(LocusTheme.textSecondary)
                    }
                }
            }
        }
    }

    private var agentSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("An agent remembers what you want done and runs when you choose.")
                .font(.locus(size: 16, weight: .medium))
            VStack(alignment: .leading, spacing: 14) {
                Label("Get a summary every morning", systemImage: "sun.max")
                Label("Review a project each week", systemImage: "calendar")
                Label("Respond when a new message arrives", systemImage: "bubble.left.and.bubble.right")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LocusTheme.white, in: RoundedRectangle(cornerRadius: 12))
            Text("Give your agent instructions, then choose a schedule or an event to start it. You can review everything before saving.")
                .foregroundStyle(LocusTheme.textSecondary)
            Button("Create an agent") { onboarding.requestAgentSetup() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("onboarding.createAgent")
            Text("Keep Locus open on your Mac for automatic tasks. Find and manage them in Agents.")
                .foregroundStyle(LocusTheme.textSecondary)
        }
    }

    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        }
    }

    private var footer: some View {
        HStack {
            Button("Not now") { onboarding.dismiss() }
                .help("Your progress is saved. Return from Help → Getting Started.")
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
