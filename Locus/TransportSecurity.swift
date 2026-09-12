import Foundation

/// How exposed a connection to a given URL is.
///
/// The distinction that matters is not http-versus-https on its own: a plain
/// HTTP request to Ollama on this Mac never leaves the machine, while the same
/// request to a hostname that resolves off-network crosses every hop in
/// between in the clear. `cleartextPrivate` is the price of supporting
/// self-hosted model servers; `cleartextRoutable` is the case worth warning a
/// user about.
enum EndpointExposure: Equatable {
    /// TLS applies. App Transport Security no longer enforces this for us, but
    /// certificate trust evaluation — chain, hostname, expiry — still does.
    case encrypted
    /// Unencrypted, but addressed to this machine or this network segment.
    case cleartextPrivate
    /// Unencrypted and routable: the bytes leave the local network as plain text.
    case cleartextRoutable
}

/// The checks that replace App Transport Security for the traffic Locus
/// controls.
///
/// The app ships `NSAllowsArbitraryLoads` because model servers the user runs
/// themselves — Ollama, llama.cpp, LM Studio — serve plain HTTP on LAN
/// addresses that no certificate authority will vouch for, and Apple offers no
/// narrower key that reaches them: `NSAllowsLocalNetworking` does not cover
/// RFC1918 literals, and `NSExceptionDomains` does not accept IP addresses at
/// all. The cost of the blanket key is that the OS stops enforcing HTTPS for
/// *every* connection the process makes, including ones the user never
/// configured. This type is what enforces it instead, and
/// `Tools/AuditTransportSecurity.sh` keeps new cleartext literals from landing.
enum TransportSecurity {
    /// Schemes that carry their own transport encryption.
    private static let encryptedSchemes: Set<String> = ["https", "wss"]

    static func isEncrypted(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return encryptedSchemes.contains(scheme)
    }

    static func exposure(of url: URL) -> EndpointExposure {
        if isEncrypted(url) { return .encrypted }
        guard let host = url.host, !host.isEmpty else { return .cleartextRoutable }
        return isPrivate(host: host) ? .cleartextPrivate : .cleartextRoutable
    }

    /// Whether a host names this machine or something on the same private
    /// network — the set of addresses whose cleartext traffic never reaches an
    /// untrusted hop.
    ///
    /// This is deliberately wider than Apple's `NSAllowsLocalNetworking`, which
    /// stops at `.local`, unqualified names and the loopback and link-local
    /// ranges. The private IPv4 ranges are what users actually type when their
    /// GPU box lives on the other side of the room, and the carrier-grade NAT
    /// range covers Tailscale, which is how a lot of people reach it.
    static func isPrivate(host rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        // URL.host keeps the brackets on an IPv6 literal in some constructions.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // Zone identifiers (fe80::1%en0) are never part of a routable address.
        if let zone = host.firstIndex(of: "%") { host = String(host[host.startIndex..<zone]) }
        guard !host.isEmpty else { return false }

        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasSuffix(".local") { return true }
        if let octets = ipv4Octets(host) { return isPrivateIPv4(octets) }
        if host.contains(":") { return isPrivateIPv6(host) }
        // An unqualified name — "gpubox" — cannot resolve outside the local
        // network's own resolver, so it belongs with the private addresses.
        return !host.contains(".")
    }

    /// Parses a dotted-quad literal. Returns nil for anything else, including
    /// hostnames that merely contain dots.
    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            // UInt8("007") parses, but a leading-zero octet is not a form any
            // caller should be handing us, and treating it as decimal here
            // would disagree with how the resolver reads it.
            guard part.count == String(Int(part) ?? -1).count, let value = UInt8(part) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivateIPv4(_ octets: [UInt8]) -> Bool {
        switch (octets[0], octets[1]) {
        case (127, _): return true                    // loopback
        case (10, _): return true                     // RFC1918
        case (192, 168): return true                  // RFC1918
        case (172, 16...31): return true              // RFC1918
        case (169, 254): return true                  // link-local
        case (100, 64...127): return true             // CGNAT, and Tailscale with it
        case (0, _): return true                      // "this network"
        default: return false
        }
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        if host == "::1" || host == "::" { return true }
        // Unique-local (fc00::/7) and link-local (fe80::/10). Comparing the
        // textual prefix is enough: both ranges are fixed in the first byte and
        // an IPv6 literal cannot abbreviate its leading group away.
        let prefix = host.prefix(4)
        if prefix.hasPrefix("fc") || prefix.hasPrefix("fd") { return true }
        if prefix.hasPrefix("fe8") || prefix.hasPrefix("fe9")
            || prefix.hasPrefix("fea") || prefix.hasPrefix("feb") { return true }
        // An IPv4-mapped literal carries an IPv4 address that still decides it.
        if let mapped = host.split(separator: ":").last.map(String.init),
           let octets = ipv4Octets(mapped) {
            return isPrivateIPv4(octets)
        }
        return false
    }

    /// Resolves a URL that the app itself chose — an update feed, a component
    /// manifest, a telemetry collector — and refuses it unless it is encrypted.
    ///
    /// Endpoints the *user* typed are not routed through here: pointing Locus
    /// at a local model server is the entire reason the ATS opt-out exists.
    /// Everything else has no business speaking cleartext, and with ATS off
    /// this is the only thing that still says so.
    static func requireEncrypted(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), isEncrypted(url) else { return nil }
        return url
    }
}
