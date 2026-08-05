import SwiftUI
import WebKit

struct InspectorPreviewTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                TextField(
                    "http://localhost:3000",
                    text: Binding(
                        get: { model.settings.previewURL },
                        set: { model.settings.previewURL = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 9, design: .monospaced))
                .accessibilityLabel("Preview URL")
                .accessibilityIdentifier("preview.url")
                .onSubmit { model.reloadPreview() }

                Button {
                    model.reloadPreview()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload preview")
                .accessibilityLabel("Reload preview")
                .accessibilityIdentifier("preview.reload")
            }

            PreviewWebView(url: model.normalizedPreviewURL, reloadID: model.previewReloadID)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(LocusTheme.lineStrong, lineWidth: 1)
                }

            Button {
                model.openPreviewExternally()
            } label: {
                Label("Open in Browser", systemImage: "arrow.up.right.square")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 31)
            }
            .buttonStyle(.plain)
            .locusCard(radius: 8)
            .accessibilityIdentifier("preview.openBrowser")
        }
        .padding(14)
    }
}

struct PreviewWebView: NSViewRepresentable {
    let url: URL?
    let reloadID: UUID

    final class Coordinator {
        var loadedURL: URL?
        var reloadID: UUID?
        var proxyGeneration: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        applyProxy(to: store, coordinator: context.coordinator)
        configuration.websiteDataStore = store
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Supported replacement for the private "drawsBackground" KVC key,
        // which would raise (uncatchably) if WebKit ever renamed it.
        view.underPageBackgroundColor = .clear
        return view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url else { return }
        let generation = ProxyRuntime.shared.generation
        if context.coordinator.loadedURL != url
            || context.coordinator.reloadID != reloadID
            || context.coordinator.proxyGeneration != generation
        {
            context.coordinator.loadedURL = url
            context.coordinator.reloadID = reloadID
            applyProxy(to: webView.configuration.websiteDataStore, coordinator: context.coordinator)
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    /// The preview follows the manual proxy like everything else; the bypass
    /// list keeps the usual localhost dev server direct. Applied to the data
    /// store rather than baked in, so a settings change reaches the next load.
    private func applyProxy(to store: WKWebsiteDataStore, coordinator: Coordinator) {
        coordinator.proxyGeneration = ProxyRuntime.shared.generation
        if let proxy = ProxyRuntime.shared.current {
            store.proxyConfigurations = [ProxyConfigurator.networkProxyConfiguration(for: proxy)]
        } else {
            store.proxyConfigurations = []
        }
    }
}
