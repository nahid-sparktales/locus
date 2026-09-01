import Foundation
import Network

/// The manual proxy, fully resolved: normalized host, validated port, the
/// credential when one is configured, and the complete bypass list. `nil`
/// wherever this is expected means "connect the way the app always has" —
/// off mode, system mode (the OS applies its own), or an incomplete manual
/// configuration, which the settings UI refuses to save in the first place.
struct ResolvedProxy: Equatable {
    var type: ProxyType
    var host: String
    var port: Int
    var username: String?
    var password: String?
    var bypass: [String]
    var profileID: UUID? = nil
    var profileName: String = "Proxy"
    var isBlocking = false
}

/// One source of truth for what "the proxy" means, shared by every consumer:
/// URLSession configurations, the preview WKWebView, and the environment the
/// agent child process is launched with. The builders are pure so the tests
/// can cover them without a network stack — the same seam LocusClientIdentity
/// uses.
enum ProxyConfigurator {
    // MARK: - Normalization

    /// "http://proxy.corp:3128/" → "proxy.corp". People paste whole URLs into
    /// host fields; the scheme, path, port and any userinfo belong to other
    /// fields, so they are stripped rather than rejected.
    static func normalizedHost(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        // A trailing :port is dropped only when it cannot be part of an IPv6
        // literal: "[::1]:8080" and "proxy.corp:8080" lose it, "::1" keeps it.
        if let bracket = text.lastIndex(of: "]") {
            text = String(text[...bracket])
            text.removeAll { $0 == "[" || $0 == "]" }
        } else if let colon = text.lastIndex(of: ":"),
                  text.firstIndex(of: ":") == colon,
                  text[text.index(after: colon)...].allSatisfy(\.isNumber)
        {
            text = String(text[..<colon])
        }
        return text.lowercased()
    }

    /// User bypass entries: comma or whitespace separated, `*.corp.com`
    /// normalized to the `.corp.com` suffix form NO_PROXY understands.
    static func parseBypassList(_ raw: String) -> [String] {
        raw.lowercased()
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { entry -> String in
                let text = String(entry)
                return text.hasPrefix("*.") ? String(text.dropFirst()) : text
            }
            .filter { !$0.isEmpty }
    }

    /// Everything that must connect directly no matter what: loopback, the
    /// agent, the Ollama runtime, then whatever the user added. The agent and
    /// Ollama are the app's own plumbing — routing them through a proxy is
    /// never what a proxy setting means, and streaming NDJSON through one
    /// rarely survives anyway.
    static func bypassHosts(settings: AppSettings, ollamaHost: String?) -> [String] {
        var hosts = mandatoryBypassHosts(settings: settings, ollamaHost: ollamaHost)
        hosts += parseBypassList(settings.proxyBypass)
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    private static func mandatoryBypassHosts(
        settings: AppSettings,
        ollamaHost: String?
    ) -> [String] {
        var hosts = ["localhost", "127.0.0.1", "::1"]
        for candidate in [settings.backendURL, ollamaHost] {
            guard let candidate,
                  let url = URL(string: candidate),
                  let host = url.host?.lowercased(),
                  !host.isEmpty
            else { continue }
            hosts.append(host)
        }
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    static func bypassHosts(
        settings: AppSettings,
        profile: ProxyProfile,
        ollamaHost: String?,
        strict: Bool
    ) -> [String] {
        var hosts = mandatoryBypassHosts(settings: settings, ollamaHost: ollamaHost)
        if !strict { hosts += parseBypassList(profile.bypass) }
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }
    }

    // MARK: - Resolution

    /// The manual endpoint, or nil when manual mode is not fully configured.
    static func manualEndpoint(settings: AppSettings) -> (host: String, port: Int)? {
        guard let profile = selectedProfile(settings: settings, scope: .app) else { return nil }
        let host = normalizedHost(profile.host)
        guard !host.isEmpty,
              let port = AppSettings.clampProxyPort(profile.port)
        else { return nil }
        return (host, port)
    }

    /// Scope is the strongest assignment, then provider, then workspace, then
    /// the default profile. Invalid or disabled assignments fall back to the
    /// default instead of turning one typo into a direct-connection leak.
    static func selectedProfile(
        settings: AppSettings,
        scope: ProxyTrafficScope,
        workspacePath: String? = nil,
        providerAccountID: String? = nil,
        preferredProfileID: UUID? = nil
    ) -> ProxyProfile? {
        guard settings.resolvedProxyMode == .manual else { return nil }
        let profiles = settings.allProxyProfiles
        let configured = profiles.filter(\.isConfigured)
        guard !configured.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        func profile(_ raw: String?) -> ProxyProfile? {
            guard let raw, let id = UUID(uuidString: raw),
                  let candidate = byID[id], candidate.isConfigured
            else { return nil }
            return candidate
        }
        if let preferredProfileID,
           let preferred = byID[preferredProfileID], preferred.isConfigured {
            return preferred
        }
        if let scoped = profile(settings.proxyScopeProfileIDs[scope.rawValue]) {
            return scoped
        }
        if let providerAccountID,
           let provider = profile(settings.proxyProviderProfileIDs[providerAccountID]) {
            return provider
        }
        if let workspacePath {
            let key = SessionSummary.canonicalWorkspacePath(workspacePath)
            if let workspace = profile(settings.proxyWorkspaceProfileIDs[key]) {
                return workspace
            }
        }
        return profile(settings.proxyActiveProfileID) ?? configured[0]
    }

    static func resolved(
        settings: AppSettings,
        profile: ProxyProfile,
        password: String?,
        ollamaHost: String?
    ) -> ResolvedProxy? {
        let host = normalizedHost(profile.host)
        guard profile.enabled, !host.isEmpty,
              let port = AppSettings.clampProxyPort(profile.port)
        else { return nil }
        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let strict = settings.proxyStrictModeEnabled && settings.resolvedProxyMode == .manual
        return ResolvedProxy(
            type: profile.resolvedType,
            host: host,
            port: port,
            username: username.isEmpty ? nil : username,
            password: username.isEmpty ? nil : password,
            bypass: bypassHosts(
                settings: settings,
                profile: profile,
                ollamaHost: ollamaHost,
                strict: strict
            ),
            profileID: profile.id,
            profileName: profile.name
        )
    }

    static func resolved(
        settings: AppSettings,
        password: String?,
        ollamaHost: String?,
        scope: ProxyTrafficScope = .app,
        workspacePath: String? = nil,
        providerAccountID: String? = nil,
        preferredProfileID: UUID? = nil
    ) -> ResolvedProxy? {
        guard let profile = selectedProfile(
            settings: settings,
            scope: scope,
            workspacePath: workspacePath,
            providerAccountID: providerAccountID,
            preferredProfileID: preferredProfileID
        ) else { return nil }
        return resolved(
            settings: settings,
            profile: profile,
            password: password,
            ollamaHost: ollamaHost
        )
    }

    /// A deliberately unreachable local endpoint. Strict mode and an exhausted
    /// failover pool use this instead of returning nil, because nil means
    /// URLSession/WebKit are allowed to connect directly.
    static func blockingProxy(settings: AppSettings, ollamaHost: String?) -> ResolvedProxy {
        ResolvedProxy(
            type: .socks5,
            host: "127.0.0.1",
            port: 1,
            username: nil,
            password: nil,
            bypass: mandatoryBypassHosts(settings: settings, ollamaHost: ollamaHost),
            profileName: "Blocked",
            isBlocking: true
        )
    }

    // MARK: - Agent environment

    /// Strict: everything but RFC 3986 unreserved is encoded, so a password
    /// containing `:` `@` or `/` survives both the env-var handoff and its
    /// eventual place in a URL's userinfo.
    static func percentEncoded(_ raw: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
    }

    /// Every proxy variable the child's libraries consult. An overlay that set
    /// only the ones it needed would leave the rest inherited from the shell,
    /// and `requests`/`httpx`/`curl` prefer a scheme-specific `HTTPS_PROXY`
    /// over `ALL_PROXY` — so a stale shell variable would quietly outrank the
    /// proxy configured here. The overlay therefore names all six, using an
    /// empty value as a tombstone the spawn sites delete.
    static let proxyURLVariables = [
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "all_proxy",
    ]

    /// The env vars the agent child is launched with in manual mode. The proxy
    /// URLs deliberately carry no credential: the agent's own children — the
    /// model's shell commands, git, and MCP processes inherit these, and the
    /// password must never reach anything the model can run. The credential
    /// travels out of band, over the child's stdin, so that it never enters
    /// the exec-time environment block that `ps -E` can read for the life of
    /// the process.
    static func childEnvironment(
        settings: AppSettings,
        password: String?,
        ollamaHost: String?,
        scope: ProxyTrafficScope = .modelAndAgent,
        workspacePath: String? = nil,
        providerAccountID: String? = nil,
        preferredProfileID: UUID? = nil
    ) -> [String: String] {
        let resolved = resolved(
            settings: settings,
            password: password,
            ollamaHost: ollamaHost,
            scope: scope,
            workspacePath: workspacePath,
            providerAccountID: providerAccountID,
            preferredProfileID: preferredProfileID
        ) ?? (settings.proxyStrictModeEnabled && settings.resolvedProxyMode == .manual
            ? blockingProxy(settings: settings, ollamaHost: ollamaHost) : nil)
        guard let resolved else { return [:] }
        return childEnvironment(proxy: resolved)
    }

    static func childEnvironment(proxy: ResolvedProxy) -> [String: String] {
        // Start every variable tombstoned, then fill in the ones this proxy
        // type uses: whatever the shell had is replaced, not merged with.
        var environment = Dictionary(
            uniqueKeysWithValues: proxyURLVariables.map { ($0, "") }
        )
        switch proxy.type {
        case .http:
            let url = "http://\(renderedHost(proxy.host)):\(proxy.port)"
            for name in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
                environment[name] = url
            }
        case .socks5:
            // socks5h, not socks5: names resolve at the proxy, so DNS for the
            // hosts being reached through it never touches the local resolver.
            let url = "socks5h://\(renderedHost(proxy.host)):\(proxy.port)"
            for name in ["ALL_PROXY", "all_proxy"] {
                environment[name] = url
            }
        }
        let bypass = proxy.bypass.joined(separator: ",")
        environment["NO_PROXY"] = bypass
        environment["no_proxy"] = bypass
        return environment
    }

    /// The proxy password, ready for the out-of-band handoff, or nil when the
    /// proxy needs no sign-in. Both halves are percent-encoded, so the first
    /// colon is unambiguously the separator.
    static func childCredential(
        settings: AppSettings,
        password: String?,
        scope: ProxyTrafficScope = .modelAndAgent,
        workspacePath: String? = nil,
        providerAccountID: String? = nil,
        preferredProfileID: UUID? = nil
    ) -> String? {
        guard let profile = selectedProfile(
            settings: settings,
            scope: scope,
            workspacePath: workspacePath,
            providerAccountID: providerAccountID,
            preferredProfileID: preferredProfileID
        ) else { return nil }
        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return nil }
        return percentEncoded(username) + ":" + percentEncoded(password ?? "")
    }

    /// An IPv6 literal needs brackets once it is part of a URL.
    private static func renderedHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    /// Pure translation of the `CFNetworkCopySystemProxySettings` dictionary
    /// into the same env-var shape, for system mode. URLSession follows the
    /// system configuration on its own; this exists because the agent's
    /// libraries read the environment, not SystemConfiguration. A PAC-based
    /// setup cannot be expressed as env vars at all — the translation is
    /// empty, and the settings UI says so.
    static func environmentFromSystemProxies(
        _ proxies: [String: Any],
        settings: AppSettings,
        ollamaHost: String?
    ) -> [String: String] {
        // Tombstones even when nothing is expressible, so that "follow the
        // system" is deterministic: a PAC setup or a system with no proxy at
        // all means the agent connects directly, rather than falling back to
        // whatever proxy variables happened to be in the launching shell.
        let tombstoned = Dictionary(uniqueKeysWithValues: proxyURLVariables.map { ($0, "") })
        guard (proxies["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue != true else {
            return tombstoned
        }
        func endpoint(_ enable: String, _ host: String, _ port: String) -> String? {
            guard (proxies[enable] as? NSNumber)?.boolValue == true,
                  let name = proxies[host] as? String,
                  !name.isEmpty
            else { return nil }
            let rendered = renderedHost(name.lowercased())
            guard let number = (proxies[port] as? NSNumber)?.intValue else { return rendered }
            return "\(rendered):\(number)"
        }
        var environment: [String: String] = [:]
        if let http = endpoint("HTTPEnable", "HTTPProxy", "HTTPPort") {
            environment["HTTP_PROXY"] = "http://\(http)"
            environment["http_proxy"] = "http://\(http)"
        }
        if let https = endpoint("HTTPSEnable", "HTTPSProxy", "HTTPSPort") {
            // The "HTTPS proxy" in system settings is still an HTTP CONNECT
            // proxy — the scheme names how to reach it, not what it carries.
            environment["HTTPS_PROXY"] = "http://\(https)"
            environment["https_proxy"] = "http://\(https)"
        }
        if let socks = endpoint("SOCKSEnable", "SOCKSProxy", "SOCKSPort") {
            environment["ALL_PROXY"] = "socks5h://\(socks)"
            environment["all_proxy"] = "socks5h://\(socks)"
        }
        guard !environment.isEmpty else { return tombstoned }
        // Same rule as manual mode: what the system says replaces whatever the
        // shell had, so a variable the system config does not set is tombstoned
        // rather than left to outrank it.
        for name in proxyURLVariables where environment[name] == nil {
            environment[name] = ""
        }
        var bypass = bypassHosts(settings: settings, ollamaHost: ollamaHost)
        for exception in proxies["ExceptionsList"] as? [String] ?? [] {
            let entry = exception.lowercased()
            bypass.append(entry.hasPrefix("*.") ? String(entry.dropFirst()) : entry)
        }
        var seen = Set<String>()
        let joined = bypass.filter { seen.insert($0).inserted }.joined(separator: ",")
        environment["NO_PROXY"] = joined
        environment["no_proxy"] = joined
        return environment
    }

    /// The system proxy dictionary, straight from SystemConfiguration.
    static func systemProxyDictionary() -> [String: Any] {
        (CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    /// True when system mode cannot reach the agent because the system proxy
    /// is a PAC file. Surfaced live in the Network settings page.
    static func systemProxyUsesPAC() -> Bool {
        (systemProxyDictionary()["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true
    }

    /// What a child process is launched with, per mode. Never the credential:
    /// that travels out of band, and only to the agent.
    static func agentEnvironmentOverlay(
        settings: AppSettings,
        ollamaHost: String?,
        scope: ProxyTrafficScope = .modelAndAgent,
        workspacePath: String? = nil,
        providerAccountID: String? = nil,
        preferredProfileID: UUID? = nil
    ) -> [String: String] {
        switch settings.resolvedProxyMode {
        case .off:
            // Off manages nothing, so whatever the shell provided is left
            // exactly as it was.
            [:]
        case .manual:
            childEnvironment(
                settings: settings,
                password: nil,
                ollamaHost: ollamaHost,
                scope: scope,
                workspacePath: workspacePath,
                providerAccountID: providerAccountID,
                preferredProfileID: preferredProfileID
            )
        case .system:
            environmentFromSystemProxies(
                systemProxyDictionary(),
                settings: settings,
                ollamaHost: ollamaHost
            )
        }
    }

    // MARK: - URLSession / WebKit

    static func networkProxyConfiguration(for proxy: ResolvedProxy) -> ProxyConfiguration {
        // Every path into ResolvedProxy clamps the port to 1...65535, but the
        // conversion is written not to trap if one ever does not.
        let port = UInt16(exactly: proxy.port).flatMap(NWEndpoint.Port.init(rawValue:))
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxy.host),
            port: port ?? .init(integerLiteral: 8080)
        )
        var configuration: ProxyConfiguration
        switch proxy.type {
        case .http:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        case .socks5:
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        }
        if let username = proxy.username {
            configuration.applyCredential(username: username, password: proxy.password ?? "")
        }
        // An unreachable proxy must be an error, not a quiet direct
        // connection — failing over would leak exactly the traffic the user
        // configured the proxy to carry.
        configuration.allowFailover = false
        configuration.excludedDomains = proxy.bypass
        return configuration
    }

    static func apply(_ proxy: ResolvedProxy?, to configuration: URLSessionConfiguration) {
        guard let proxy else { return }
        configuration.proxyConfigurations = [networkProxyConfiguration(for: proxy)]
    }
}

/// Verifies a proxy straight from the settings draft, the way
/// `RemoteEndpointTester` verifies an endpoint: no side effects, nothing
/// saved, the live sessions untouched.
enum ProxyProbe {
    struct Outcome {
        let ok: Bool
        let message: String
        let latencyMilliseconds: Int?
        let exitIP: String?
        let location: String?

        init(
            ok: Bool,
            message: String,
            latencyMilliseconds: Int? = nil,
            exitIP: String? = nil,
            location: String? = nil
        ) {
            self.ok = ok
            self.message = message
            self.latencyMilliseconds = latencyMilliseconds
            self.exitIP = exitIP
            self.location = location
        }
    }

    static func test(proxy: ResolvedProxy, target: URL) async -> Outcome {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // Deliberately without the bypass list. The question this button
        // answers is "does the proxy work", and a target the bypass list
        // happens to cover would otherwise connect directly and report
        // success for a proxy that was never contacted.
        var probed = proxy
        probed.bypass = []
        ProxyConfigurator.apply(probed, to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: target)
        request.httpMethod = "HEAD"
        LocusClientIdentity.apply(to: &request)
        let started = Date()
        do {
            // Any HTTP status at all proves the proxy carried the request —
            // what the target thinks of a HEAD is not the proxy's doing.
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            return Outcome(
                ok: true,
                message: "The proxy carried the request — \(target.host ?? "the test host") answered \(status) in \(elapsed) ms.",
                latencyMilliseconds: elapsed
            )
        } catch {
            return Outcome(ok: false, message: Self.describe(error, proxy: proxy))
        }
    }

    /// Health and leak audit used by the failover pool. The response reports
    /// the exit address observed outside the Mac; SOCKS profiles additionally
    /// keep DNS remote through `socks5h`. A failed audit is never interpreted
    /// as permission to connect directly.
    static func audit(proxy: ResolvedProxy) async -> Outcome {
        guard let target = URL(string: "https://www.cloudflare.com/cdn-cgi/trace") else {
            return Outcome(ok: false, message: "The audit target is unavailable.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        var probed = proxy
        probed.bypass = []
        ProxyConfigurator.apply(probed, to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        LocusClientIdentity.apply(to: &request)
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<400).contains(status), data.count <= 32_768 else {
                return Outcome(ok: false, message: "The proxy audit returned HTTP \(status).")
            }
            let values = Dictionary(uniqueKeysWithValues: String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .compactMap { line -> (String, String)? in
                    let pieces = line.split(separator: "=", maxSplits: 1).map(String.init)
                    return pieces.count == 2 ? (pieces[0], pieces[1]) : nil
                })
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            let exitIP = values["ip"]
            let location = values["loc"]
            let dns = proxy.type == .socks5 ? " · remote DNS" : ""
            let address = exitIP.map { " · exit \($0)" } ?? ""
            return Outcome(
                ok: true,
                message: "Healthy in \(elapsed) ms\(address)\(dns)",
                latencyMilliseconds: elapsed,
                exitIP: exitIP,
                location: location
            )
        } catch {
            return Outcome(ok: false, message: describe(error, proxy: proxy))
        }
    }

    /// Says what went wrong in terms of the proxy, which is what the button is
    /// asking about. The codes are the ones a real proxy actually produces:
    /// a rejected sign-in arrives as POSIX `EAUTH` from the Network framework
    /// rather than as `NSURLErrorUserAuthenticationRequired`, so matching only
    /// the URL-loading constant left the useful case showing "The operation
    /// couldn't be completed."
    static func describe(_ error: Error, proxy: ResolvedProxy) -> String {
        let error = error as NSError
        let address = "\(proxy.host):\(proxy.port)"
        let rejectedSignIn = (error.domain == NSPOSIXErrorDomain && error.code == Int(EAUTH))
            || error.code == NSURLErrorUserAuthenticationRequired
        if rejectedSignIn {
            return proxy.username == nil
                ? "The proxy requires a sign-in. Turn on \"The proxy requires sign-in\" and enter its username and password."
                : "The proxy rejected the sign-in. Check the username and password."
        }
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                // A proxy that wants a sign-in it did not get often just stops
                // answering rather than saying 407, which is indistinguishable
                // from a dead one here — so when no sign-in is configured, name
                // that as the likely cause instead of only blaming the address.
                return proxy.username == nil
                    ? "The proxy did not answer at \(address). If it requires a sign-in, turn that on and enter the username and password."
                    : "The proxy did not answer at \(address)."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "No host named \(proxy.host) could be found. Check the proxy address."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "The proxy answered at \(address), but the secure connection through it failed."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

/// The active proxy, as a process-wide snapshot. Static call sites like the
/// endpoint tester have no path to AppModel, so AppModel pushes changes here
/// and everyone reads the snapshot; `generation` lets long-lived sessions
/// notice a change and rebuild instead of carrying a stale configuration.
final class ProxyRuntime: @unchecked Sendable {
    static let shared = ProxyRuntime()

    private let lock = NSLock()
    private var proxy: ResolvedProxy?
    private var scopedProxies: [ProxyTrafficScope: ResolvedProxy] = [:]
    private var generationValue = 0
    private var lastSettings: AppSettings?
    private var lastPassword: String?
    private var profilePasswords: [UUID: String] = [:]
    private var lastOllamaHost: String?
    private var lastWorkspacePath: String?
    private var lastProviderAccountID: String?
    private var healthByProfileID: [UUID: ProxyHealthRecord] = [:]
    private var hasCompletedHealthCheck = false
    private let appSession = ProxyAwareSession(scope: .app)
    private let browserSession = ProxyAwareSession(scope: .browser)
    private let modelSession = ProxyAwareSession(scope: .modelAndAgent)
    private let downloadSession = ProxyAwareSession(scope: .downloads)
    private let toolsSession = ProxyAwareSession(scope: .gitAndTools)

    var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return generationValue
    }

    var current: ResolvedProxy? {
        lock.lock(); defer { lock.unlock() }
        return proxy
    }

    func current(for scope: ProxyTrafficScope) -> ResolvedProxy? {
        lock.lock(); defer { lock.unlock() }
        return scopedProxies[scope]
    }

    var healthSnapshot: [ProxyHealthRecord] {
        lock.lock(); defer { lock.unlock() }
        return healthByProfileID.values.sorted {
            if $0.ok != $1.ok { return $0.ok && !$1.ok }
            return ($0.latencyMilliseconds ?? .max) < ($1.latencyMilliseconds ?? .max)
        }
    }

    func update(
        settings: AppSettings,
        password: String?,
        profilePasswords: [UUID: String] = [:],
        workspacePath: String? = nil,
        providerAccountID: String? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        var incomingPasswords = profilePasswords
        if let password { incomingPasswords[ProxyProfile.primaryID] = password }
        let healthConfigurationChanged = lastSettings?.allProxyProfiles
            != settings.allProxyProfiles || self.profilePasswords != incomingPasswords
        lastSettings = settings
        lastPassword = password
        self.profilePasswords = incomingPasswords
        if let workspacePath { lastWorkspacePath = workspacePath }
        lastProviderAccountID = providerAccountID
        let liveIDs = Set(settings.allProxyProfiles.map(\.id))
        healthByProfileID = healthByProfileID.filter { liveIDs.contains($0.key) }
        if healthConfigurationChanged {
            healthByProfileID = [:]
            hasCompletedHealthCheck = false
        } else if !settings.proxyAutoFailoverEnabled {
            hasCompletedHealthCheck = false
        }
        recomputeLocked()
    }

    func noteRoutingContext(workspacePath: String?, providerAccountID: String?) {
        lock.lock(); defer { lock.unlock() }
        lastWorkspacePath = workspacePath
        lastProviderAccountID = providerAccountID
        recomputeLocked()
    }

    /// The Ollama host is runtime state, not a setting — the agent reports it
    /// after the fact — so it feeds the bypass list through its own channel.
    func noteOllamaHost(_ host: String?) {
        lock.lock(); defer { lock.unlock() }
        lastOllamaHost = host
        recomputeLocked()
    }

    @discardableResult
    private func recomputeLocked() -> Bool {
        guard let settings = lastSettings else { return false }
        var next: [ProxyTrafficScope: ResolvedProxy] = [:]
        for scope in ProxyTrafficScope.allCases {
            if let resolved = resolvedLocked(
                settings: settings,
                scope: scope,
                workspacePath: lastWorkspacePath,
                providerAccountID: lastProviderAccountID
            ) {
                next[scope] = resolved
            }
        }
        guard next != scopedProxies else { return false }
        scopedProxies = next
        proxy = next[.app]
        generationValue += 1
        return true
    }

    private func resolvedLocked(
        settings: AppSettings,
        scope: ProxyTrafficScope,
        workspacePath: String?,
        providerAccountID: String?
    ) -> ResolvedProxy? {
        guard settings.resolvedProxyMode == .manual else { return nil }
        let preferred = ProxyConfigurator.selectedProfile(
            settings: settings,
            scope: scope,
            workspacePath: workspacePath,
            providerAccountID: providerAccountID
        )
        var selected = preferred
        if settings.proxyAutoFailoverEnabled, hasCompletedHealthCheck {
            if let preferred, healthByProfileID[preferred.id]?.ok == true {
                selected = preferred
            } else {
                selected = settings.allProxyProfiles
                    .filter { $0.isConfigured && healthByProfileID[$0.id]?.ok == true }
                    .sorted {
                        let lhs = healthByProfileID[$0.id]?.latencyMilliseconds ?? .max
                        let rhs = healthByProfileID[$1.id]?.latencyMilliseconds ?? .max
                        if lhs != rhs { return lhs < rhs }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    .first
            }
        }
        guard let selected else {
            return settings.proxyStrictModeEnabled
                || (settings.proxyAutoFailoverEnabled && hasCompletedHealthCheck)
                ? ProxyConfigurator.blockingProxy(
                    settings: settings,
                    ollamaHost: lastOllamaHost
                ) : nil
        }
        return ProxyConfigurator.resolved(
            settings: settings,
            profile: selected,
            password: profilePasswords[selected.id]
                ?? (selected.id == ProxyProfile.primaryID ? lastPassword : nil),
            ollamaHost: lastOllamaHost
        )
    }

    /// A copy of `base` with the active proxy applied. In off and system mode
    /// this is `base` untouched — URLSession follows the OS on its own.
    func configuration(
        base: URLSessionConfiguration = .default,
        scope: ProxyTrafficScope = .app
    ) -> URLSessionConfiguration {
        ProxyConfigurator.apply(current(for: scope), to: base)
        return base
    }

    /// Drop-in for the `URLSession.shared` call sites, which cannot take a
    /// proxy: same default configuration, rebuilt when the proxy changes.
    var urlSession: URLSession {
        urlSession(for: .app)
    }

    func urlSession(for scope: ProxyTrafficScope) -> URLSession {
        switch scope {
        case .app: appSession.current
        case .browser: browserSession.current
        case .modelAndAgent: modelSession.current
        case .downloads: downloadSession.current
        case .gitAndTools: toolsSession.current
        }
    }

    /// A short-lived session for traffic deliberately attributed to a provider
    /// account other than the active chat route, such as explicitly selected
    /// cloud speech. This preserves provider-specific proxy assignments without
    /// mutating the process-wide routing context used by model traffic.
    func urlSession(
        for scope: ProxyTrafficScope,
        workspacePath: String?,
        providerAccountID: String?
    ) -> URLSession {
        lock.lock()
        let resolved: ResolvedProxy?
        if let settings = lastSettings {
            resolved = resolvedLocked(
                settings: settings,
                scope: scope,
                workspacePath: workspacePath ?? lastWorkspacePath,
                providerAccountID: providerAccountID
            )
        } else {
            resolved = nil
        }
        lock.unlock()
        let configuration = URLSessionConfiguration.default
        ProxyConfigurator.apply(resolved, to: configuration)
        return URLSession(configuration: configuration)
    }

    /// Proxy env for helper processes that are not the agent — `ollama serve`
    /// downloads models itself, so it needs the route. Never the credential:
    /// that reaches the agent alone, and only out of band.
    var helperEnvironmentOverlay: [String: String] {
        environmentOverlay(scope: .downloads)
    }

    func environmentOverlay(
        scope: ProxyTrafficScope,
        workspacePath: String? = nil,
        providerAccountID: String? = nil
    ) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard let settings = lastSettings else { return [:] }
        switch settings.resolvedProxyMode {
        case .off: return [:]
        case .system:
            return ProxyConfigurator.environmentFromSystemProxies(
                ProxyConfigurator.systemProxyDictionary(),
                settings: settings,
                ollamaHost: lastOllamaHost
            )
        case .manual:
            let hasExplicitContext = workspacePath != nil || providerAccountID != nil
            let resolved = hasExplicitContext
                ? resolvedLocked(
                    settings: settings,
                    scope: scope,
                    workspacePath: workspacePath ?? lastWorkspacePath,
                    providerAccountID: providerAccountID
                )
                : scopedProxies[scope]
            guard let resolved else { return [:] }
            return ProxyConfigurator.childEnvironment(proxy: resolved)
        }
    }

    func childCredential(
        scope: ProxyTrafficScope,
        workspacePath: String? = nil,
        providerAccountID: String? = nil
    ) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let settings = lastSettings else { return nil }
        let hasExplicitContext = workspacePath != nil || providerAccountID != nil
        let resolved = hasExplicitContext
            ? resolvedLocked(
                settings: settings,
                scope: scope,
                workspacePath: workspacePath ?? lastWorkspacePath,
                providerAccountID: providerAccountID
            )
            : scopedProxies[scope]
        guard let resolved, !resolved.isBlocking,
              let username = resolved.username
        else { return nil }
        return ProxyConfigurator.percentEncoded(username) + ":"
            + ProxyConfigurator.percentEncoded(resolved.password ?? "")
    }

    /// Audits every enabled endpoint concurrently and atomically publishes the
    /// resulting pool. Returns whether any effective route changed, which lets
    /// AppModel rebuild agent processes only when failover actually moved.
    func refreshHealth() async -> (records: [ProxyHealthRecord], routingChanged: Bool) {
        guard let context = healthAuditContext() else { return ([], false) }
        let settings = context.settings
        let ollamaHost = context.ollamaHost
        let passwords = context.passwords
        let profiles = context.profiles

        let records = await withTaskGroup(of: ProxyHealthRecord.self) { group in
            for profile in profiles {
                group.addTask {
                    guard let resolved = ProxyConfigurator.resolved(
                        settings: settings,
                        profile: profile,
                        password: passwords[profile.id],
                        ollamaHost: ollamaHost
                    ) else {
                        return ProxyHealthRecord(
                            profileID: profile.id,
                            profileName: profile.name,
                            ok: false,
                            latencyMilliseconds: nil,
                            exitIP: nil,
                            location: nil,
                            message: "The profile is incomplete.",
                            checkedAt: Date()
                        )
                    }
                    let outcome = await ProxyProbe.audit(proxy: resolved)
                    return ProxyHealthRecord(
                        profileID: profile.id,
                        profileName: profile.name,
                        ok: outcome.ok,
                        latencyMilliseconds: outcome.latencyMilliseconds,
                        exitIP: outcome.exitIP,
                        location: outcome.location,
                        message: outcome.message,
                        checkedAt: Date()
                    )
                }
            }
            var output: [ProxyHealthRecord] = []
            for await record in group { output.append(record) }
            return output
        }

        return publishHealth(records)
    }

    private typealias HealthAuditContext = (
        settings: AppSettings,
        ollamaHost: String?,
        passwords: [UUID: String],
        profiles: [ProxyProfile]
    )

    private func healthAuditContext() -> HealthAuditContext? {
        lock.lock()
        guard let settings = lastSettings, settings.resolvedProxyMode == .manual else {
            lock.unlock()
            return nil
        }
        let context = (
            settings: settings,
            ollamaHost: lastOllamaHost,
            passwords: profilePasswords,
            profiles: settings.allProxyProfiles.filter(\.isConfigured)
        )
        lock.unlock()
        return context
    }

    private func publishHealth(
        _ records: [ProxyHealthRecord]
    ) -> (records: [ProxyHealthRecord], routingChanged: Bool) {
        lock.lock(); defer { lock.unlock() }
        healthByProfileID = Dictionary(uniqueKeysWithValues: records.map { ($0.profileID, $0) })
        hasCompletedHealthCheck = true
        let changed = recomputeLocked()
        return (healthSnapshotLocked(), changed)
    }

    /// Deterministic seam for routing tests; production health records enter
    /// through `refreshHealth`, which performs the network audit first.
    @discardableResult
    func applyHealthSnapshotForTesting(_ records: [ProxyHealthRecord]) -> Bool {
        publishHealth(records).routingChanged
    }

    private func healthSnapshotLocked() -> [ProxyHealthRecord] {
        healthByProfileID.values.sorted {
            if $0.ok != $1.ok { return $0.ok && !$1.ok }
            return ($0.latencyMilliseconds ?? .max) < ($1.latencyMilliseconds ?? .max)
        }
    }
}

/// A URLSession that rebuilds itself whenever the proxy generation moves, so
/// a `static let` session stops meaning "the proxy settings from launch".
final class ProxyAwareSession: @unchecked Sendable {
    private let lock = NSLock()
    private let scope: ProxyTrafficScope
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let makeDelegate: (@Sendable () -> URLSessionDelegate)?
    private var session: URLSession?
    private var builtGeneration = -1

    init(
        scope: ProxyTrafficScope = .app,
        configuration: @escaping @Sendable () -> URLSessionConfiguration = { .default },
        delegate: (@Sendable () -> URLSessionDelegate)? = nil
    ) {
        self.scope = scope
        makeConfiguration = configuration
        makeDelegate = delegate
    }

    var current: URLSession {
        lock.lock(); defer { lock.unlock() }
        let generation = ProxyRuntime.shared.generation
        if let session, builtGeneration == generation { return session }
        // In-flight requests on the old session run to completion under the
        // old proxy; only new work picks up the change.
        session?.finishTasksAndInvalidate()
        let built = URLSession(
            configuration: ProxyRuntime.shared.configuration(
                base: makeConfiguration(),
                scope: scope
            ),
            delegate: makeDelegate?(),
            delegateQueue: nil
        )
        session = built
        builtGeneration = generation
        return built
    }
}
