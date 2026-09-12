import Foundation
import SwiftUI

protocol PlanComponentDescriptor {
    static var componentID: String { get }
    static var binaries: [(String, String)] { get }
    static var supportRoot: URL? { get }
    static var currentRoot: URL? { get }
    static var isInstalled: Bool { get }
    static func installedVersion() -> String?
}

/// Claude's official runtime is versioned independently from the OpenAI helper.
enum ClaudeComponent: PlanComponentDescriptor {
    static let componentID = "claude-plan"
    static let helperIdentifier = "io.sparktales.locus.claude"
    static var binaries: [(String, String)] { [("claude", helperIdentifier)] }
    static var supportRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "\(AppEdition.current.displayName)/Components/\(componentID)", directoryHint: .isDirectory)
    }
    static var currentRoot: URL? { supportRoot?.appending(path: "current", directoryHint: .isDirectory) }
    static var bundledHelper: URL? {
        let path = Bundle.main.bundleURL.appending(path: "Contents/Helpers/claude")
        return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
    }
    static var isInstalled: Bool {
        guard let path = currentRoot?.appending(path: "claude") else { return false }
        return FileManager.default.isExecutableFile(atPath: path.path)
    }
    static func installedVersion() -> String? {
        guard let path = currentRoot,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)
        else { return nil }
        return URL(fileURLWithPath: target).lastPathComponent
    }
    static func helperPathForBackend() -> String? {
        bundledHelper?.path ?? currentRoot?.appending(path: "claude").path
    }
}

#if !LOCUS_APP_STORE
struct ClaudeComponentDownloadView: View {
    @EnvironmentObject private var model: AppModel
    let account: ProviderAccount
    var body: some View {
        ClaudeComponentInstallControls(installer: model.claudeComponent, account: account)
    }
}

private struct ClaudeComponentInstallControls: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var installer: ClaudeComponentInstaller
    let account: ProviderAccount
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Download Claude plan support to connect your subscription.")
            if installer.state.isBusy {
                ProgressView()
                Button("Cancel") { installer.cancel() }
            } else {
                if case .failed(let message) = installer.state { Text(message).foregroundStyle(.red) }
                Button("Download Claude plan support") {
                    Task {
                        installer.install()
                        await installer.waitForCompletion()
                        await model.providerAccountsModel.refreshChatGPTAccount(for: account)
                    }
                }
                .accessibilityIdentifier("accountEditor.claude.downloadComponent")
            }
        }
    }
}
#endif
