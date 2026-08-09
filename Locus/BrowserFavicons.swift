import AppKit
import WebKit

/// Which URL to fetch a page's icon from. Pure, so the decision table tests
/// without a web view: a declared `link[rel~=icon]` wins when it is a real
/// web URL, anything else falls back to the origin's `/favicon.ico`, and a
/// page with no host has no icon to fetch.
enum FaviconLogic {
    static func candidateURL(declared: String?, pageURL: URL) -> URL? {
        guard let host = pageURL.host, !host.isEmpty else { return nil }
        if let declared,
           let url = URL(string: declared),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }
        var components = URLComponents()
        components.scheme = pageURL.scheme
        components.host = host
        components.port = pageURL.port
        components.path = "/favicon.ico"
        return components.url
    }

    /// The cache key for a page's icon: the origin, port included — two dev
    /// servers on localhost are different sites with different icons.
    static func cacheKey(for pageURL: URL?) -> String? {
        guard let pageURL, let host = pageURL.host, !host.isEmpty else { return nil }
        let scheme = pageURL.scheme?.lowercased() ?? "http"
        let port = pageURL.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

extension BrowserService {
    /// Read in the isolated reader world: shares the DOM, invisible to the
    /// page, so the declared icon cannot be forged by patching the page's own
    /// globals.
    static let faviconProbeJS = """
    const l = document.querySelector("link[rel~='icon' i]");
    return l ? new URL(l.getAttribute('href'), document.baseURI).href : null;
    """

    func favicon(forPageURL pageURL: URL?) -> NSImage? {
        FaviconLogic.cacheKey(for: pageURL).flatMap { favicons[$0] }
    }

    /// Called from `didFinish`. One attempt per origin per app session —
    /// in-flight and failed origins never retry, so tab churn cannot turn
    /// into request churn — and same-origin tabs share the cached icon.
    func noteFaviconOpportunity(for webView: WKWebView) {
        guard let pageURL = webView.url,
              let key = FaviconLogic.cacheKey(for: pageURL),
              !faviconHostsAttempted.contains(key) else { return }
        faviconHostsAttempted.insert(key)
        Task { @MainActor [weak self, weak webView] in
            let declared = (try? await webView?.callAsyncJavaScript(
                Self.faviconProbeJS,
                arguments: [:],
                in: nil,
                contentWorld: BrowserBridge.readerWorld
            )) as? String
            guard let self,
                  let target = FaviconLogic.candidateURL(declared: declared, pageURL: pageURL),
                  let data = await self.faviconFetcher(target),
                  data.count <= Self.maximumFaviconBytes,
                  let image = NSImage(data: data)
            else { return }
            self.favicons[key] = image
        }
    }

    static let maximumFaviconBytes = 512 * 1024

    /// The one network call in this file — and it must ride the configured
    /// proxy: the browser's invariant is that its traffic never escapes the
    /// proxy the user configured, so `URLSession.shared` is not an option.
    /// The configuration is built per fetch so a mid-session proxy change is
    /// always honored; favicons fetch at most once per host, so the cost is
    /// nothing.
    static func proxiedFaviconFetch(_ url: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        ProxyConfigurator.apply(ProxyRuntime.shared.current, to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) != false
        else { return nil }
        return data
    }
}
