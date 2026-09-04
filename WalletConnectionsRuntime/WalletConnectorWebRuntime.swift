import AppKit
import CryptoKit
import Foundation
import WebKit

private struct WalletWebCommand: Encodable {
    let id: String
    let operation: String
    let connector: String
    let payload: [String: AnyEncodable]
}

private struct WalletWebResponse<Value: Decodable>: Decodable {
    let id: String
    let value: Value?
    let error: String?
}

private struct WalletWebConfiguration: Encodable {
    let dappURL: String
    let metamaskRPCURLs: [String: String]
    let phantomAppID: String
    let phantomRedirectURL: String
}

private struct WalletWebEventEnvelope: Decodable {
    let connector: WalletConnectionConnector
    let kind: String
    let connectionID: String
    let networkIDs: [String]?
}

struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeValue = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

@MainActor
final class WalletConnectorWebRuntime: NSObject {
    private static let handlerName = "locusConnectorEvents"
    private static let contentWorld = WKContentWorld.world(
        name: "io.sparktales.locus.wallet-connections"
    )
    private static let storeID = UUID(uuidString: "328FC0CF-D8C8-4D63-9B1B-E6D970E62134")!
    private static let maximumResponseBytes = 256 * 1_024
    private static let maximumBundleBytes = 4 * 1_024 * 1_024
    private static let reviewedBundleSHA256 =
        "09aa8643956ae5e17ab004ccd85b62811a36f7f4e44535d2659ef43e512323bf"

    private let bundle: Bundle
    private let environment: [String: String]
    private let connectorConfigurationValues: [String: String]
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let allowedHosts: Set<String>
    private let reviewRegistry: WalletReviewRegistry?
    private let webView: WKWebView
    private var childWebViews: [WKWebView] = []
    private var panel: NSPanel?
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var eventHandlers: [
        WalletConnectionConnector: [(WalletConnectorEvent) -> Void]
    ] = [:]

    init(
        bundle: Bundle,
        environment: [String: String]
    ) throws {
        self.bundle = bundle
        self.environment = environment
        connectorConfigurationValues = WalletConnectorReleaseConfiguration.runtimeValues(
            from: bundle, environment: environment
        )
        reviewRegistry = WalletReviewRegistry.loadBundled(from: bundle)
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let configuredHosts = bundle.object(
            forInfoDictionaryKey: "LocusWalletConnectorAllowedHosts"
        ) as? [String]
        allowedHosts = Set((configuredHosts ?? [
            "connect.metamask.io", "metamask.app.link",
            "connect.phantom.app", "auth.phantom.app",
            "wallet.slush.app", "my.slush.app",
        ]).map { $0.lowercased() })

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(
            forIdentifier: Self.storeID
        )
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        guard let scriptURL = bundle.url(
            forResource: "WalletConnections.bundle", withExtension: "js"
        ), let scriptData = try? Data(contentsOf: scriptURL),
              !scriptData.isEmpty,
              scriptData.count <= Self.maximumBundleBytes,
              SHA256.hash(data: scriptData).map({ String(format: "%02x", $0) }).joined()
                == Self.reviewedBundleSHA256,
              let scriptSource = String(data: scriptData, encoding: .utf8) else {
            throw WalletConnectorRuntimeError.unconfigured("Wallet connections")
        }
        // The reviewed vendor bundle runs only in an isolated global object and
        // only for the trusted local document. Pop-up configurations inherit the
        // user-content controller, so the protocol check prevents injection into
        // a wallet vendor's remote page.
        configuration.userContentController.addUserScript(WKUserScript(
            source: "if (location.protocol === 'file:') {\n\(scriptSource)\n}",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: Self.contentWorld
        ))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.addScriptMessageHandler(
            self, contentWorld: Self.contentWorld, name: Self.handlerName
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if DEBUG
        webView.isInspectable = environment["LOCUS_WALLET_CONNECTOR_INSPECTABLE"] == "1"
        #endif
        guard let resource = bundle.url(
            forResource: "WalletConnections", withExtension: "html"
        ) else {
            throw WalletConnectorRuntimeError.unconfigured("Wallet connections")
        }
        webView.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
    }

    func isConfigured(_ connector: WalletConnectionConnector) -> Bool {
        guard let reviewRegistry,
              let entry = reviewRegistry.manifest.connectors.first(where: {
                  $0.connector == connector
              }), let method = entry.methods.sorted(by: { $0.rawValue < $1.rawValue }).first,
              reviewRegistry.containsConnector(
                  connector, direction: .externalAccountToLocus, method: method,
                  configurationValues: connectorConfigurationValues
              ) else { return false }
        return switch connector {
        case .metamask:
            !WalletConnectorReleaseConfiguration.metamaskRPCURLs(
                values: connectorConfigurationValues,
                reviewedProviders: reviewRegistry.manifest.providerIdentities
            ).isEmpty
        case .slush:
            true
        case .phantom:
            !configurationValue(
                environmentKey: "LOCUS_PHANTOM_APP_ID",
                infoKey: "LocusPhantomAppID"
            ).isEmpty && validHTTPSURL(configurationValue(
                environmentKey: "LOCUS_PHANTOM_REDIRECT_URL",
                infoKey: "LocusPhantomRedirectURL"
            ))
        case .walletConnect:
            !configurationValue(
                environmentKey: "LOCUS_REOWN_PROJECT_ID",
                infoKey: "LocusReownProjectID"
            ).isEmpty
        case .embeddedBrowser:
            false
        }
    }

    func addEventHandler(
        connector: WalletConnectionConnector,
        handler: @escaping (WalletConnectorEvent) -> Void
    ) {
        eventHandlers[connector, default: []].append(handler)
    }

    func present(title: String) {
        let panel = panel ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = title
        panel.contentView = webView
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func jsonObject<T: Encodable>(_ value: T) throws -> AnyEncodable {
        AnyEncodable(value)
    }

    func request<Response: Decodable>(
        operation: String,
        connector: WalletConnectionConnector,
        payload: [String: Any]
    ) async throws -> Response {
        if ["connect", "restore", "execute"].contains(operation), !isConfigured(connector) {
            throw WalletConnectorRuntimeError.unconfigured("Wallet connections")
        }
        try await waitUntilReady()
        let command = WalletWebCommand(
            id: UUID().uuidString.lowercased(), operation: operation,
            connector: connector.rawValue,
            payload: try payload.mapValues(anyEncodable)
        )
        let encoded = try encoder.encode(command)
        guard encoded.count <= Self.maximumResponseBytes,
              let json = String(data: encoded, encoding: .utf8) else {
            throw WalletConnectorRuntimeError.malformedRequest
        }
        let result = try await evaluate(
            "return await window.LocusWalletConnections.handle(JSON.parse(commandJSON));",
            arguments: ["commandJSON": json]
        )
        guard let responseText = result as? String,
              let responseData = responseText.data(using: .utf8),
              responseData.count <= Self.maximumResponseBytes else {
            throw WalletConnectorRuntimeError.sdkFailure(
                "The connector returned malformed data."
            )
        }
        let response = try decoder.decode(
            WalletWebResponse<Response>.self, from: responseData
        )
        guard response.id == command.id else {
            throw WalletConnectorRuntimeError.sessionMismatch
        }
        if let error = response.error {
            throw WalletConnectorRuntimeError.sdkFailure(error)
        }
        guard let value = response.value else {
            throw WalletConnectorRuntimeError.sdkFailure(
                "The connector returned no result."
            )
        }
        return value
    }

    private func waitUntilReady() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    private func evaluate(
        _ source: String,
        arguments: [String: Any]
    ) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            source,
            arguments: arguments,
            in: nil,
            contentWorld: Self.contentWorld
        )
    }

    private func configurationValue(
        environmentKey: String,
        infoKey: String
    ) -> String {
        _ = environmentKey
        return connectorConfigurationValues[infoKey] ?? ""
    }

    private func validHTTPSURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "https",
              url.host?.isEmpty == false, url.user == nil,
              url.password == nil, url.fragment == nil else { return false }
        return true
    }

    private func configurePage() async throws {
        let pageConfiguration = WalletWebConfiguration(
            dappURL: "https://locus.app",
            metamaskRPCURLs: WalletConnectorReleaseConfiguration.metamaskRPCURLs(
                values: connectorConfigurationValues,
                reviewedProviders: reviewRegistry?.manifest.providerIdentities ?? []
            ),
            phantomAppID: configurationValue(
                environmentKey: "LOCUS_PHANTOM_APP_ID",
                infoKey: "LocusPhantomAppID"
            ),
            phantomRedirectURL: configurationValue(
                environmentKey: "LOCUS_PHANTOM_REDIRECT_URL",
                infoKey: "LocusPhantomRedirectURL"
            )
        )
        let data = try encoder.encode(pageConfiguration)
        guard data.count <= Self.maximumResponseBytes,
              let json = String(data: data, encoding: .utf8),
              let configured = try await evaluate(
                  "return window.LocusWalletConnections.configure(JSON.parse(configurationJSON));",
                  arguments: ["configurationJSON": json]
              ) as? Bool,
              configured else {
            throw WalletConnectorRuntimeError.unconfigured("Wallet connections")
        }
    }

    private func resolveReady(_ result: Result<Void, Error>) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        switch result {
        case .success:
            ready = true
            for waiter in waiters { waiter.resume() }
        case .failure(let error):
            for waiter in waiters { waiter.resume(throwing: error) }
        }
    }

    private func anyEncodable(_ value: Any) throws -> AnyEncodable {
        switch value {
        case let value as AnyEncodable: value
        case let value as String: AnyEncodable(value)
        case let value as Bool: AnyEncodable(value)
        case let value as Int: AnyEncodable(value)
        case let value as [String]: AnyEncodable(value)
        default: throw WalletConnectorRuntimeError.malformedRequest
        }
    }

    private func emit(_ event: WalletConnectorEvent, connector: WalletConnectionConnector) {
        for handler in eventHandlers[connector] ?? [] { handler(event) }
    }
}

extension WalletConnectorWebRuntime: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        _ = webView
        _ = navigation
        guard !ready else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await configurePage()
                resolveReady(.success(()))
            } catch {
                resolveReady(.failure(error))
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.isFileURL {
            decisionHandler(.allow)
            return
        }
        if url.scheme?.lowercased() == "https",
           let host = url.host?.lowercased(), allowedHosts.contains(host) {
            decisionHandler(.allow)
            return
        }
        if let scheme = url.scheme?.lowercased(),
           ["metamask", "phantom", "slush"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}

extension WalletConnectorWebRuntime: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        _ = webView
        _ = windowFeatures
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self
        childWebViews.append(child)
        panel?.contentView = child
        if let request = navigationAction.request.url.map({ URLRequest(url: $0) }) {
            child.load(request)
        }
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        childWebViews.removeAll { $0 === webView }
        panel?.contentView = self.webView
    }
}

extension WalletConnectorWebRuntime: WKScriptMessageHandlerWithReply {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated { [weak self] in
            guard let self,
                  self.receive(
                    userContentController: userContentController,
                    message: message
                  ) else {
                replyHandler(nil, "The connector event was rejected.")
                return
            }
            replyHandler(true, nil)
        }
    }

    private func receive(
        userContentController: WKUserContentController,
        message: WKScriptMessage
    ) -> Bool {
        _ = userContentController
        guard message.name == Self.handlerName,
              message.frameInfo.isMainFrame,
              let object = message.body as? [String: Any],
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= Self.maximumResponseBytes,
              let envelope = try? decoder.decode(
                  WalletWebEventEnvelope.self, from: data
              ),
              !envelope.connectionID.isEmpty,
              envelope.connectionID.utf8.count <= 64,
              envelope.connectionID.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(
                    CharacterSet(charactersIn: "-_")
                  ).contains($0)
              }),
              (envelope.networkIDs?.count ?? 0) <= 8,
              envelope.networkIDs?.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 128
              }) != false else { return false }
        switch envelope.kind {
        case "network_changed":
            emit(.networksChanged(
                connectionID: envelope.connectionID,
                networkIDs: Set(envelope.networkIDs ?? [])
            ), connector: envelope.connector)
        case "disconnected":
            emit(.disconnected(connectionID: envelope.connectionID),
                 connector: envelope.connector)
        case "expired":
            emit(.expired(connectionID: envelope.connectionID),
                 connector: envelope.connector)
        default:
            return false
        }
        return true
    }
}
