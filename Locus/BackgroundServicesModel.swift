import Foundation

/// Owns the Overview tab's background dev-server rows, with a generation
/// counter so a stale in-flight list response can never resurrect a service
/// the user just stopped. AppModel wires it via configure(...) and bridges
/// its publication; it never retains AppModel.
@MainActor
final class BackgroundServicesModel: ObservableObject {
    @Published private(set) var backgroundServices: [BackgroundServiceRecord] = []

    private var backgroundServicesRefreshGeneration = 0

    private var transportProvider: () -> BackendService? = { nil }
    private var recordingSessionIDProvider: () -> String = { "" }
    private var websiteOutput: (URL, String) -> Void = { _, _ in }
    private var toastHandler: (String) -> Void = { _ in }

    func configure(
        transportProvider: @escaping () -> BackendService?,
        recordingSessionIDProvider: @escaping () -> String,
        websiteOutput: @escaping (URL, String) -> Void,
        toastHandler: @escaping (String) -> Void
    ) {
        self.transportProvider = transportProvider
        self.recordingSessionIDProvider = recordingSessionIDProvider
        self.websiteOutput = websiteOutput
        self.toastHandler = toastHandler
    }

    /// - Parameter recordingOutputs: when the refresh follows a service start
    ///   in this session, dev servers that were not running before and expose
    ///   a port become website outputs of the session that was active when
    ///   the start happened.
    func refreshBackgroundServices(recordingOutputs: Bool = false) {
        backgroundServicesRefreshGeneration += 1
        let generation = backgroundServicesRefreshGeneration
        guard let transport = transportProvider() else { return }
        let recordingSessionID = recordingOutputs ? recordingSessionIDProvider() : ""
        let alreadyRunning = Set(backgroundServices.filter(\.running).map(\.name))
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await transport.get(
                    "/api/services", as: BackgroundServicesResponse.self
                )
                guard generation == backgroundServicesRefreshGeneration else { return }
                backgroundServices = response.services
                guard !recordingSessionID.isEmpty else { return }
                for service in response.services
                where service.running && !alreadyRunning.contains(service.name) {
                    guard let port = service.port,
                          let url = URL(string: "http://localhost:\(port)")
                    else { continue }
                    websiteOutput(url, recordingSessionID)
                }
            } catch {
                guard generation == backgroundServicesRefreshGeneration else { return }
                backgroundServices = []
            }
        }
    }

    /// Stops every running background process from the Overview's
    /// "Stop all" action. Rows disappear immediately; the refresh afterwards
    /// restores anything the backend could not stop.
    func stopAllBackgroundServices() {
        let running = backgroundServices.filter(\.running)
        guard !running.isEmpty else { return }
        backgroundServicesRefreshGeneration += 1
        let runningNames = Set(running.map(\.name))
        backgroundServices.removeAll { runningNames.contains($0.name) }
        guard let transport = transportProvider() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failed = 0
            for service in running {
                guard let encoded = service.name.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) else { continue }
                do {
                    _ = try await transport.delete(
                        "/api/services/\(encoded)", as: BackgroundServiceStopResponse.self
                    )
                } catch {
                    failed += 1
                }
            }
            let noun = running.count == 1 ? "background process" : "background processes"
            toastHandler(
                failed == 0
                    ? "Stopped \(running.count) \(noun)"
                    : "Could not stop \(failed) of \(running.count) \(noun)"
            )
            refreshBackgroundServices()
        }
    }

    /// Test seam: the Overview derives its Background processes rows from
    /// this list, and unit tests have no backend to refresh from.
    func applyBackgroundServicesForTesting(_ services: [BackgroundServiceRecord]) {
        backgroundServicesRefreshGeneration += 1
        backgroundServices = services
    }

    func stopBackgroundService(_ service: BackgroundServiceRecord) {
        guard let encoded = service.name.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else { return }
        // Stop is authoritative in the interface. Invalidate older in-flight
        // list requests so a stale response cannot make the service reappear.
        backgroundServicesRefreshGeneration += 1
        backgroundServices.removeAll { $0.name == service.name }
        guard let transport = transportProvider() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await transport.delete(
                    "/api/services/\(encoded)", as: BackgroundServiceStopResponse.self
                )
                toastHandler(service.running ? "Stopped \(service.name)" : "Dismissed \(service.name)")
                refreshBackgroundServices()
            } catch {
                toastHandler("Could not stop \(service.name): \(error.localizedDescription)")
                refreshBackgroundServices()
            }
        }
    }
}
