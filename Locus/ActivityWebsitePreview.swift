import SwiftUI
import WebKit

/// A contained output preview. It has no agent bridge, file access, or shared sign-in state.
struct ActivityWebsitePreview: View {
    let url: URL
    @Environment(\.locusViewColors) private var colors
    @State private var failure: String?
    @State private var attempt = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "globe")
                Text(url.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("Reload") { failure = nil; attempt += 1 }.buttonStyle(.locus())
            }.font(.locus(size: 11)).foregroundStyle(colors.muted).padding(10).background(colors.panel)
            if let failure {
                VStack(spacing: 12) {
                    Label("Preview unavailable", systemImage: "wifi.exclamationmark").font(.locus(size: 16, weight: .semibold))
                    Text(failure).font(.locus(size: 12)).foregroundStyle(colors.muted)
                    Text("The website may require sign-in or its preview server may have stopped.")
                        .font(.locus(size: 11)).foregroundStyle(colors.muted)
                    Link("Open website in browser", destination: url).font(.locus(size: 12))
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ActivityWebsiteWebView(url: url, failure: $failure).id(attempt)
            }
        }.background(colors.panel).accessibilityIdentifier("activity.result.website")
    }
}

private struct ActivityWebsiteWebView: NSViewRepresentable {
    let url: URL
    @Binding var failure: String?
    func makeCoordinator() -> Coordinator { Coordinator(failure: $failure) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var failure: Binding<String?>
        init(failure: Binding<String?>) { self.failure = failure }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") else {
                decisionHandler(.cancel); return
            }
            if action.targetFrame == nil { decisionHandler(.cancel); webView.load(action.request) }
            else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { failure.wrappedValue = error.localizedDescription }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { failure.wrappedValue = error.localizedDescription }
        }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    }
}
