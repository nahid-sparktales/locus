import AppKit
import Combine
import Foundation
import os
import SwiftUI

let locusPerformanceSignposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "io.sparktales.locus",
    category: "UI Performance"
)

struct WorkspaceGeometrySnapshot: Equatable {
    var windowSize: CGSize = .zero
    var sidebarWidth: CGFloat = 0
    var workspaceWidth: CGFloat = 0
    var workspaceHeight: CGFloat = 0
    var inspectorWidth: CGFloat = 0
    var composerWidth: CGFloat = 0
    var docksSidebar = false
    var docksInspector = false

    static let empty = WorkspaceGeometrySnapshot()
}

/// Window-owned interaction state that stays independent from the broad
/// application model. Live resizing therefore invalidates only presentation
/// that genuinely depends on the gesture.
@MainActor
final class WorkspaceLayoutModel: ObservableObject {
    @Published private(set) var isLiveResizing = false
    private(set) var geometry = WorkspaceGeometrySnapshot.empty

    lazy var liveResizeCoordinator = LiveResizeCoordinator(layout: self)

    func updateGeometry(_ snapshot: WorkspaceGeometrySnapshot) {
        geometry = snapshot
    }

    fileprivate func setLiveResizing(_ value: Bool) {
        guard value != isLiveResizing else { return }
        isLiveResizing = value
    }
}

@MainActor
final class LiveResizeCoordinator {
    private weak var layout: WorkspaceLayoutModel?
    private let performanceMonitor: LiveResizePerformanceMonitor

    init(
        layout: WorkspaceLayoutModel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.layout = layout
        performanceMonitor = LiveResizePerformanceMonitor(
            reportPath: environment["LOCUS_PERFORMANCE_REPORT_PATH"]
        )
    }

    func beginLiveResize() {
        locusPerformanceSignposter.emitEvent("Begin Live Resize")
        performanceMonitor.begin()
        layout?.setLiveResizing(true)
    }

    func update(width: CGFloat) {
        // Native layout owns the exact width. Transcript and composer leaves
        // bucket their proposals, avoiding another publication per pixel.
        locusPerformanceSignposter.emitEvent(
            "Resize Frame",
            "width=\(width, format: .fixed(precision: 1))"
        )
    }

    func endLiveResize(finalWidth: CGFloat) {
        locusPerformanceSignposter.emitEvent(
            "End Live Resize",
            "width=\(finalWidth, format: .fixed(precision: 1))"
        )
        layout?.setLiveResizing(false)
        performanceMonitor.end(finalWidth: finalWidth)
    }
}

/// Opt-in local acceptance instrumentation. A run-loop interval starts when
/// AppKit wakes the main loop and ends immediately before it sleeps again,
/// which captures the resize event, SwiftUI update, layout, and display work
/// as one frame-work sample. Production launches pay no observer or storage
/// cost unless a report path is explicitly supplied.
@MainActor
final class LiveResizePerformanceMonitor {
    struct Summary: Codable, Equatable {
        let sampleCount: Int
        let p95MainThreadWorkMillis: Double
        let maximumMainThreadWorkMillis: Double
        let finalWidth: Double
    }

    private let reportURL: URL?
    private var observer: CFRunLoopObserver?
    private var frameStart: CFAbsoluteTime?
    private var samples: [Double] = []

    init(reportPath: String?) {
        guard let reportPath, !reportPath.isEmpty else {
            reportURL = nil
            return
        }
        reportURL = URL(fileURLWithPath: reportPath)
    }

    func begin() {
        guard reportURL != nil, observer == nil else { return }
        frameStart = nil
        samples.removeAll(keepingCapacity: true)
        let activities = CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
            | CFRunLoopActivity.exit.rawValue
        observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities,
            true,
            0
        ) { [weak self] _, activity in
            MainActor.assumeIsolated {
                self?.observe(activity)
            }
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    func end(finalWidth: CGFloat) {
        guard let reportURL else { return }
        finishPendingFrame()
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = nil
        }
        let summary = Self.summarize(samples: samples, finalWidth: finalWidth)
        guard let data = try? JSONEncoder().encode(summary) else { return }
        Task.detached(priority: .utility) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }

    static func summarize(samples: [Double], finalWidth: CGFloat) -> Summary {
        let sorted = samples.sorted()
        let p95Index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return Summary(
            sampleCount: sorted.count,
            p95MainThreadWorkMillis: sorted.isEmpty ? 0 : sorted[p95Index],
            maximumMainThreadWorkMillis: sorted.last ?? 0,
            finalWidth: Double(finalWidth)
        )
    }

    private func observe(_ activity: CFRunLoopActivity) {
        switch activity {
        case .afterWaiting:
            frameStart = CFAbsoluteTimeGetCurrent()
        case .beforeWaiting, .exit:
            finishPendingFrame()
        default:
            break
        }
    }

    private func finishPendingFrame() {
        guard let frameStart else { return }
        samples.append((CFAbsoluteTimeGetCurrent() - frameStart) * 1_000)
        self.frameStart = nil
    }
}

/// High-frequency composer state is feature-owned so typing, queue edits, and
/// attachment progress do not publish through the entire application model.
@MainActor
final class ComposerStateModel: ObservableObject {
    private(set) var draftRevision: UInt = 0
    @Published var draftText = "" {
        didSet {
            guard draftText != oldValue else { return }
            draftRevision &+= 1
            draftDidChange?()
        }
    }
    @Published var queuedMessages: [String] = []
    @Published var attachments: [ChatAttachment] = []
    @Published var attachmentNotice: String?
    @Published var isLoadingAttachments = false
    @Published var focusToken = UUID()

    var draftDidChange: (() -> Void)?
}

/// Runtime status has a focused observation surface available to workspace
/// chrome. AppModel remains the compatibility owner while callers migrate.
@MainActor
final class RuntimeStatusModel: ObservableObject {
    @Published private(set) var agentPhase: RuntimePhase = .starting(
        "Starting the local agent…"
    )
    @Published private(set) var modelPhase: RuntimePhase = .starting(
        "Checking the model provider…"
    )
    @Published private(set) var isBusy = false
    @Published private(set) var hasPendingPermission = false
    @Published private(set) var steeringState: String?

    func update(
        agentPhase: RuntimePhase,
        modelPhase: RuntimePhase,
        isBusy: Bool,
        hasPendingPermission: Bool,
        steeringState: String?
    ) {
        if self.agentPhase != agentPhase { self.agentPhase = agentPhase }
        if self.modelPhase != modelPhase { self.modelPhase = modelPhase }
        if self.isBusy != isBusy { self.isBusy = isBusy }
        if self.hasPendingPermission != hasPendingPermission {
            self.hasPendingPermission = hasPendingPermission
        }
        if self.steeringState != steeringState { self.steeringState = steeringState }
    }

    func setAgentPhase(_ phase: RuntimePhase) {
        if agentPhase != phase { agentPhase = phase }
    }

    func setModelPhase(_ phase: RuntimePhase) {
        if modelPhase != phase { modelPhase = phase }
    }

    func setBusy(_ value: Bool) {
        if isBusy != value { isBusy = value }
    }

    func setPendingPermission(_ value: Bool) {
        if hasPendingPermission != value { hasPendingPermission = value }
    }

    func setSteeringState(_ value: String?) {
        if steeringState != value { steeringState = value }
    }
}

@MainActor
protocol AppCommandRouting: AnyObject {
    func submitDraft()
    func stop()
    func queueDraft()
    func steerDraft()
    func stopAndSendDraft()
}

extension AppModel: AppCommandRouting {}

private struct LocusLiveResizeEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

private struct LocusWorkspaceGeometryEnvironmentKey: EnvironmentKey {
    static let defaultValue = WorkspaceGeometrySnapshot.empty
}

private struct LocusCommandRouterEnvironmentKey: EnvironmentKey {
    static let defaultValue: (any AppCommandRouting)? = nil
}

extension EnvironmentValues {
    var locusIsLiveResizing: Bool {
        get { self[LocusLiveResizeEnvironmentKey.self] }
        set { self[LocusLiveResizeEnvironmentKey.self] = newValue }
    }

    var locusWorkspaceGeometry: WorkspaceGeometrySnapshot {
        get { self[LocusWorkspaceGeometryEnvironmentKey.self] }
        set { self[LocusWorkspaceGeometryEnvironmentKey.self] = newValue }
    }

    var locusCommandRouter: (any AppCommandRouting)? {
        get { self[LocusCommandRouterEnvironmentKey.self] }
        set { self[LocusCommandRouterEnvironmentKey.self] = newValue }
    }
}

/// Installs the feature models that own reactive UI state.
///
/// Views observe these objects directly instead of relying on `AppModel` to
/// republish every child change. `AppModel` remains available for orchestration
/// and cross-feature actions.
struct AppFeatureEnvironmentModifier: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        featureEnvironment(content)
    }

    @ViewBuilder
    private func featureEnvironment(_ content: Content) -> some View {
        content
            .environmentObject(model)
            .environment(\.locusCommandRouter, model)
            .environmentObject(model.workspaceLayout)
            .environmentObject(model.composerState)
            .environmentObject(model.runtimeStatus)
            .environmentObject(model.sessionCatalog)
            .environmentObject(model.transcriptPresentation)
            .environmentObject(model.providerAccountsModel)
            .environmentObject(model.voiceControl)
            .environmentObject(model.agentTeamsModel)
            .environmentObject(model.teamRunLive)
            .environmentObject(model.landingFlow)
            .environmentObject(model.runs)
            .environmentObject(model.evaluations)
            .environmentObject(model.knowledge)
            .environmentObject(model.activity)
            .environmentObject(model.schedule)
            .environmentObject(model.backgroundServicesModel)
            .environmentObject(model.extensionsModel)
            .environmentObject(model.gitWorkspace)
            .environmentObject(model.workspaceFiles)
            .environmentObject(model.agentInstructions)
            .environmentObject(model.applicationContext)
            .environmentObject(model.toastCenter)
            .environmentObject(model.computerControl)
            .environmentObject(model.simulatorControl)
#if !LOCUS_APP_STORE
            .environmentObject(model.codexComponent)
#endif
    }
}

extension View {
    func appFeatureEnvironment(from model: AppModel) -> some View {
        modifier(AppFeatureEnvironmentModifier(model: model))
    }
}
