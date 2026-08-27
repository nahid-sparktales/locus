import XCTest
@testable import Locus

final class GitHubConnectionTests: XCTestCase {
    func testClientIDRejectsMissingAndBuildSettingPlaceholders() {
        XCTAssertNil(GitHubConnectionConfiguration.clientID(
            configured: " ",
            bundleValue: "$(LOCUS_GITHUB_OAUTH_CLIENT_ID)",
            environment: [:]
        ))
    }

    func testConfiguredClientIDPrecedesBundleAndEnvironment() {
        XCTAssertEqual(GitHubConnectionConfiguration.clientID(
            configured: "configured-id",
            bundleValue: "bundle-id",
            environment: ["LOCUS_GITHUB_OAUTH_CLIENT_ID": "environment-id"]
        ), "configured-id")
    }

    func testEnvironmentCanSupplyAClientIDWhenTheBundleIsUnresolved() {
        XCTAssertEqual(GitHubConnectionConfiguration.clientID(
            configured: nil,
            bundleValue: "$(LOCUS_GITHUB_OAUTH_CLIENT_ID)",
            environment: ["LOCUS_GITHUB_OAUTH_CLIENT_ID": "environment-id"]
        ), "environment-id")
    }

    func testCapabilityStatesHaveDeterministicPrecedence() {
        XCTAssertEqual(GitHubConnectionConfiguration.capability(
            bundleValue: nil,
            environment: [:]
        ), .tokenFallbackOnly)
        XCTAssertEqual(GitHubConnectionConfiguration.capability(
            bundleValue: "public-client-id",
            environment: [:]
        ), .deviceFlowAvailable)
        XCTAssertEqual(GitHubConnectionConfiguration.capability(
            bundleValue: nil,
            environment: [:],
            hasCredentials: true,
            authorizationError: "denied"
        ), .connected)
        XCTAssertEqual(GitHubConnectionConfiguration.capability(
            bundleValue: nil,
            environment: [:],
            authorizationError: "denied"
        ), .tokenFallbackOnly)
        XCTAssertEqual(GitHubConnectionConfiguration.capability(
            bundleValue: "public-client-id",
            environment: [:],
            authorizationError: "denied"
        ), .authorizationFailed)
    }
}
