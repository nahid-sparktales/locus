import XCTest
@testable import Locus

/// App Transport Security permits cleartext to a private address and refuses
/// it to a public one, which is exactly what lets a self-hosted model server
/// work while the rest of the app keeps its HTTPS guarantee. The OS draws that
/// line for the network; these assertions draw it for everything the OS does
/// not speak to — which endpoints the app may choose for itself, and what the
/// account editor tells the user about the one they typed.
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

    /// The addresses a self-hosted model server actually lives on. Apple's
    /// `NSAllowsLocalNetworking` is documented as covering none of these, yet
    /// ATS lets them through unaided — see Tools/AuditTransportSecurity.py.
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

    /// An ATS refusal describes a policy, not an endpoint, and reads as if
    /// Locus were broken. It should never fire for a genuinely private address,
    /// so when it does the message has to point at the two things that could
    /// actually be wrong.
    func testATSRefusalIsTranslated() {
        let ats = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorAppTransportSecurityRequiresSecureConnection
        )
        let message = RemoteEndpointTester.connectionFailureMessage(ats)
        XCTAssertTrue(message.contains("not encrypted"), message)
        XCTAssertTrue(message.contains("https://"), message)
        XCTAssertTrue(message.contains("private"), message)
    }

    /// Every other failure keeps the system's own wording — a refused
    /// connection and a DNS miss say more than any rewrite of ours would.
    func testOtherFailuresKeepTheirOwnDescription() {
        for code in [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorSecureConnectionFailed] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertEqual(
                RemoteEndpointTester.connectionFailureMessage(error),
                error.localizedDescription,
                "code \(code)"
            )
        }
    }

    /// The component feed installs an executable, and ATS would not stop a
    /// cleartext one pointed at a LAN address. This is the check that does.
    #if !LOCUS_APP_STORE
    @MainActor
    func testComponentFeedURLIsEncryptedOrAbsent() {
        if let feed = CodexComponentInstaller.feedURL {
            XCTAssertTrue(TransportSecurity.isEncrypted(feed), feed.absoluteString)
        }
    }
    #endif
}
