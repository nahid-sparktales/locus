import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Composer inputs: the context pack, chat file and pasted-image
/// attachments, live application capture, and simulator attachment.
extension AppModel {
    func addContext() {
        let panel = NSOpenPanel()
        panel.title = "Add files or folders to context"
        panel.prompt = "Add Context"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: workspacePath)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            _ = workspaceAccess.rememberAndActivate(url)
        }
        loadContext(from: panel.urls)
    }

    func addChatAttachments() {
        let panel = NSOpenPanel()
        panel.title = "Attach files to this message"
        panel.message = "Locus will send only the files you choose; attachments never grant folder access."
        panel.prompt = "Attach"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        loadChatAttachments(from: panel.urls)
    }

    func loadChatAttachments(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let remainingSlots = max(10 - chatAttachments.count, 0)
        guard remainingSlots > 0 else {
            chatAttachmentNotice = "A chat message can include up to 10 attachments."
            return
        }
        isLoadingChatAttachments = true
        chatAttachmentNotice = "Preparing attachments…"
        let existing = Set(chatAttachments.map { $0.url.standardizedFileURL })
        let selected = Array(urls.prefix(remainingSlots))
        let scopedURLs = selected.filter { $0.startAccessingSecurityScopedResource() }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ChatAttachmentLoader.readChatAttachments(selected, excluding: existing)
            }.value
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            guard let self else { return }
            chatAttachments.append(contentsOf: result.attachments)
            chatAttachmentNotice = result.notice
            isLoadingChatAttachments = false
            showToast(
                result.attachments.isEmpty
                    ? (result.notice ?? "No supported attachments were added")
                    : "Attached \(result.attachments.count) file\(result.attachments.count == 1 ? "" : "s")"
            )
        }
    }

    func removeChatAttachment(_ attachment: ChatAttachment) {
        chatAttachments.removeAll { $0.id == attachment.id }
        if chatAttachments.isEmpty { chatAttachmentNotice = nil }
    }

    var currentLiveApplicationTarget: ApplicationTarget? {
        liveApplicationTargets[currentSessionID]
    }

    var currentSimulatorTarget: SimulatorTarget? {
        simulatorControl.target(for: currentSessionID)
    }

    var hasComposerContextChips: Bool {
        !chatAttachments.isEmpty
            || currentLiveApplicationTarget != nil
            || currentSimulatorTarget != nil
    }

    var currentLiveApplicationIsConnected: Bool {
        currentLiveApplicationTarget.map(applicationContext.isConnected) ?? false
    }

    func attachCurrentApplicationSnapshot() {
        guard let target = applicationContext.lastExternalApplication else {
            showToast("Activate an application window, then return to Locus")
            return
        }
        attachApplicationSnapshot(target)
    }

    func attachApplicationSnapshot(_ target: ApplicationTarget) {
        guard chatAttachments.count < 10 else {
            chatAttachmentNotice = "A chat message can include up to 10 attachments."
            return
        }
        isLoadingChatAttachments = true
        chatAttachmentNotice = "Capturing \(target.name)…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isLoadingChatAttachments = false }
            do {
                let attachment = try await applicationContext.captureSnapshot(of: target)
                let imageBytes = chatAttachments.reduce(0) { $0 + ($1.imageData?.count ?? 0) }
                guard imageBytes + (attachment.imageData?.count ?? 0) <= 25_000_000 else {
                    chatAttachmentNotice = "The message can include up to 25 MB of images."
                    showToast("The Appshot exceeds the message image limit")
                    return
                }
                chatAttachments.append(attachment)
                chatAttachmentNotice = nil
                showToast("Attached \(target.name) Appshot")
            } catch {
                chatAttachmentNotice = error.localizedDescription
                showToast(error.localizedDescription)
            }
        }
    }

    func attachLiveApplication(_ target: ApplicationTarget) {
        guard !justChatEnabled else {
            showToast("Live application control is unavailable in Just Chat")
            return
        }
        if currentLiveApplicationTarget?.id == target.id { return }
        let alert = NSAlert()
        alert.messageText = currentLiveApplicationTarget == nil
            ? "Attach \(target.name) to this task?"
            : "Replace the attached application with \(target.name)?"
        alert.informativeText = "Locus will let this task inspect the selected app’s Accessibility text and window screenshots and control only this exact running process. Secure fields remain blocked. The attachment is forgotten when Locus quits."
        alert.alertStyle = .informational
        alert.addButton(withTitle: currentLiveApplicationTarget == nil ? "Attach" : "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        liveApplicationTargets[currentSessionID] = target
        computerControl.refreshPermissionStatus()
        announceComputerControlCapability()
        showToast("\(target.name) attached to this task")
    }

    func detachLiveApplication(sessionID: String? = nil) {
        let owner = sessionID ?? currentSessionID
        guard let target = liveApplicationTargets.removeValue(forKey: owner) else { return }
        computerControl.cancelPendingActions()
        announceComputerControlCapability()
        showToast("Detached \(target.name)")
    }

    func refreshSimulatorDevices() {
        Task { @MainActor [weak self] in await self?.simulatorControl.refreshDevices() }
    }

    func attachSimulator(_ device: SimulatorDevice) {
        guard !justChatEnabled else {
            showToast("Simulator control is unavailable in Just Chat")
            return
        }
        let existing = currentSimulatorTarget
        if existing?.udid == device.udid {
            selectInspectorTab(.simulator)
            return
        }
        let alert = NSAlert()
        alert.messageText = existing == nil
            ? "Attach \(device.name) to this task?"
            : "Replace \(existing?.device.name ?? "the simulator") with \(device.name)?"
        alert.informativeText = "Locus and this task will be able to view the simulator, send touch and keyboard input, build and launch apps, and capture screenshots. Hosted models may receive screenshots after separate provider consent. Avoid real accounts and sensitive data."
        alert.alertStyle = .informational
        alert.addButton(withTitle: existing == nil ? "Attach" : "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.simulatorControlEnabled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await simulatorControl.attach(
                    sessionID: currentSessionID,
                    udid: device.udid
                )
                objectWillChange.send()
                sendSimulatorControlCapability()
                selectInspectorTab(.simulator)
                showToast("Attached \(device.name)")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func detachSimulator(sessionID: String? = nil) {
        let owner = sessionID ?? currentSessionID
        guard let target = simulatorControl.target(for: owner) else { return }
        cancelSimulatorActions(sessionID: owner)
        simulatorControl.detach(sessionID: owner)
        objectWillChange.send()
        announceSimulatorControlCapability()
        showToast("Detached \(target.device.name)")
    }

    func simulatorDidDetachNatively() {
        objectWillChange.send()
        announceSimulatorControlCapability()
        showToast("Simulator shut down and detached")
    }

    func setSimulatorControlEnabled(_ enabled: Bool) {
        guard SimulatorControlService.isSupportedBuild else {
            settings.simulatorControlEnabled = false
            showToast("iOS Simulator control is unavailable in the App Store build")
            return
        }
        settings.simulatorControlEnabled = enabled
        if !enabled {
            cancelSimulatorActions()
            simulatorControl.detachAll()
            objectWillChange.send()
        }
        announceSimulatorControlCapability()
        showToast(enabled ? "iOS Simulator control enabled" : "iOS Simulator control disabled")
    }

    /// Attach images that exist only on the pasteboard — or were captured by
    /// the browser's annotator — under the same caps as file attachments:
    /// 10 files, 15 MB each, 25 MB of image data in total. Returns whether
    /// anything was attached, so callers holding user work (the annotation
    /// sheet) can refuse to discard it on a rejection.
    @discardableResult
    func addPastedImages(
        _ images: [(data: Data, mimeType: String)],
        nameStem: String = "Pasted image"
    ) -> Bool {
        guard !images.isEmpty else { return false }
        let remainingSlots = max(10 - chatAttachments.count, 0)
        guard remainingSlots > 0 else {
            chatAttachmentNotice = "A chat message can include up to 10 attachments."
            return false
        }
        var totalImageBytes = chatAttachments.reduce(0) { $0 + ($1.imageData?.count ?? 0) }
        var added: [ChatAttachment] = []
        var oversized = 0
        for image in images.prefix(remainingSlots) {
            guard image.data.count <= 15_000_000,
                  totalImageBytes + image.data.count <= 25_000_000
            else {
                oversized += 1
                continue
            }
            totalImageBytes += image.data.count
            added.append(ChatAttachment.pasted(
                imageData: image.data,
                mimeType: image.mimeType,
                nameStem: nameStem
            ))
        }
        chatAttachments.append(contentsOf: added)
        chatAttachmentNotice = oversized > 0
            ? "Skipped or limited: \(oversized) over the size limit."
            : chatAttachmentNotice
        if !added.isEmpty {
            showToast("Attached \(added.count) image\(added.count == 1 ? "" : "s")")
        } else if oversized > 0 {
            showToast("The pasted image is over the size limit")
        }
        return !added.isEmpty
    }

    /// True only when the selected local model is known to refuse images.
    /// Remote models report nothing about vision, and an unknown is not a
    /// warning — the runtime strip-and-retry covers an actual rejection.
    var activeModelRejectsImages: Bool {
        guard activeAccount == nil else { return false }
        return models.first { $0.name == selectedModel }?.visionCapable == false
    }

    func loadContext(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        isLoadingContext = true
        contextNotice = "Reading selected files…"
        let existing = Set(contextFiles.map { $0.url.standardizedFileURL })
        let remainingSlots = max(50 - contextFiles.count, 0)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ContextPackLoader.readContextSelection(urls, excluding: existing, limit: remainingSlots)
            }.value
            guard let self else { return }
            contextFiles.append(contentsOf: result.files)
            contextNotice = result.notice
            isLoadingContext = false
            rebalanceContextBudget()
            scheduleWorkspacePersistence()
            showToast(result.files.isEmpty ? (result.notice ?? "No readable text files were added") : "Added \(result.files.count) context files")
        }
    }

    func refreshContextFiles() async {
        guard !contextFiles.isEmpty else { return }
        let references = contextFiles
        let refreshed = await Task.detached(priority: .utility) {
            references.map(ContextPackLoader.reloadContextReference)
        }.value
        // Merge by id onto the CURRENT list: files removed or added while the
        // refresh ran off-thread must not be resurrected or dropped.
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        contextFiles = contextFiles.map { refreshedByID[$0.id] ?? $0 }
        rebalanceContextBudget()
        scheduleWorkspacePersistence()
    }

    func removeContext(_ file: ContextFile) {
        contextFiles.removeAll { $0.id == file.id }
        scheduleWorkspacePersistence()
    }

    func toggleContext(_ file: ContextFile) {
        guard let index = contextFiles.firstIndex(where: { $0.id == file.id }) else { return }
        guard contextFiles[index].isAvailable else {
            showToast(contextFiles[index].issue ?? "This file is unavailable")
            return
        }
        contextFiles[index].isIncluded.toggle()
        rebalanceContextBudget()
        scheduleWorkspacePersistence()
    }
}
