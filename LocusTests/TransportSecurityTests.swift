import XCTest
@testable import Locus

/// The app ships `NSAllowsArbitraryLoads`, so the operating system no longer
/// refuses a cleartext endpoint on anyone's behalf. These assertions are what
/// took over that job: the classification below is the only thing standing
/// between "a LAN model server works" and "an app-owned endpoint quietly stops
/// being encrypted".
final class TransportSecurityTests: XCTestCase {
    private func exposure(_ string: String) -> EndpointExposure? {
        URL(string: string).map(TransportSecurity.exposure(of:))
    }

    func testEncryptedSchemesAreEncrypted() {
        XCTAssertEqual(exposure("https://api.openai.com/v1"), .encrypted)
        XCTAssertEqual(exposure("wss://relay.walletconnect.org"), .encrypted)
        // Scheme comparison is case-insensitive, as URLs themselves are.
        XCTAssertEqual(exposure("HTTPS://api.openai.com"), .encrypted)
    }

    func testLoopbackIsPrivate() {
        for host in [
            "http://localhost:11434",
            "http://127.0.0.1:11434",
            "http://127.1.2.3:8791",
            "http://[::1]:11434",
        ] {
            XCTAssertEqual(exposure(host), .cleartextPrivate, host)
        }
    }

    /// The whole reason the ATS opt-out exists. `NSAllowsLocalNetworking` does
    /// not cover any of these, which is why the narrow key was not an option.
    func testPrivateLANAddressesArePrivate() {
        for host in [
            "http://192.168.1.50:11434",
            "http://10.0.0.7:11434",
            "http://172.16.4.2:11434",
            "http://172.31.255.254:11434",
            "http://169.254.10.1:11434",
        ] {
            XCTAssertEqual(exposure(host), .cleartextPrivate, host)
        }
    }

    /// Carrier-grade NAT is the range Tailscale hands out, and reaching a GPU
    /// box over Tailscale is a mainstream way to run a remote Ollama.
    func testTailscaleRangeIsPrivate() {
        XCTAssertEqual(exposure("http://100.101.102.103:11434"), .cleartextPrivate)
        XCTAssertEqual(exposure("http://100.64.0.1:11434"), .cleartextPrivate)
        XCTAssertEqual(exposure("http://100.127.255.254:11434"), .cleartextPrivate)
    }

    /// 100.0.0.0/10 outside 100.64–100.127 is ordinary public space and must
    /// not inherit the Tailscale exemption.
    func testAddressesAdjacentToPrivateRangesAreRoutable() {
        for host in [
            "http://100.63.0.1:11434",   // just below CGNAT
            "http://100.128.0.1:11434",  // just above CGNAT
            "http://172.15.0.1:11434",   // just below RFC1918
            "http://172.32.0.1:11434",   // just above RFC1918
            "http://192.169.1.1:11434",  // not 192.168/16
            "http://11.0.0.1:11434",     // not 10/8
        ] {
            XCTAssertEqual(exposure(host), .cleartextRoutable, host)
        }
    }

    func testMDNSAndUnqualifiedNamesArePrivate() {
        XCTAssertEqual(exposure("http://gpubox.local:11434"), .cleartextPrivate)
        XCTAssertEqual(exposure("http://gpubox:11434"), .cleartextPrivate)
        XCTAssertEqual(exposure("http://dev.localhost:3000"), .cleartextPrivate)
    }

    func testUniqueLocalAndLinkLocalIPv6ArePrivate() {
        XCTAssertEqual(exposure("http://[fd00::1]:11434"), .cleartextPrivate)
        XCTAssertEqual(exposure("http://[fe80::1]:11434"), .cleartextPrivate)
    }

    /// The case the UI warns about: cleartext that leaves the network.
    func testPublicCleartextIsRoutable() {
        for host in [
            "http://api.openai.com/v1",
            "http://203.0.113.10:11434",
            "http://[2001:db8::1]:11434",
        ] {
            XCTAssertEqual(exposure(host), .cleartextRoutable, host)
        }
    }

    /// A dotted-quad with a leading-zero octet is not read as decimal by every
    /// resolver, so it must not be granted a private classification on the
    /// strength of looking like one.
    func testAmbiguousOctetsAreNotTreatedAsPrivate() {
        XCTAssertEqual(exposure("http://010.0.0.1:11434"), .cleartextRoutable)
        XCTAssertEqual(exposure("http://127.0.0.01:11434"), .cleartextRoutable)
    }

    func testRequireEncryptedAcceptsOnlyTLS() {
        XCTAssertNotNil(TransportSecurity.requireEncrypted("https://example.com/feed.json"))
        XCTAssertNil(TransportSecurity.requireEncrypted("http://example.com/feed.json"))
        // Loopback gets no exemption here: this gate is for endpoints the app
        // chose, and none of those live on the user's machine.
        XCTAssertNil(TransportSecurity.requireEncrypted("http://127.0.0.1/feed.json"))
        XCTAssertNil(TransportSecurity.requireEncrypted(nil))
        XCTAssertNil(TransportSecurity.requireEncrypted(""))
    }

    /// The component feed installs an executable. If its URL ever resolves over
    /// cleartext, the ATS opt-out has cost something real.
    #if !LOCUS_APP_STORE
    @MainActor
    func testComponentFeedURLIsEncryptedOrAbsent() {
        if let feed = CodexComponentInstaller.feedURL {
            XCTAssertTrue(TransportSecurity.isEncrypted(feed), feed.absoluteString)
        }
    }
    #endif
}
