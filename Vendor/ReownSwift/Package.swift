// swift-tools-version:5.10

import PackageDescription

// Audited narrow package for Reown Swift 2.3.2. Only the WalletConnect Sign
// product and its closed in-tree dependency graph are exposed to Locus.
let package = Package(
    name: "LocusReownSwift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WalletConnect", targets: ["WalletConnectSign"]),
    ],
    targets: [
        .target(
            name: "WalletConnectSign",
            dependencies: ["WalletConnectPairing", "WalletConnectVerify", "WalletConnectSigner", "Events"],
            path: "Sources/WalletConnectSign",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "WalletConnectPairing",
            dependencies: ["WalletConnectNetworking", "Events"],
            path: "Sources/WalletConnectPairing",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(name: "WalletConnectSigner", dependencies: ["WalletConnectNetworking"], path: "Sources/WalletConnectSigner"),
        .target(name: "WalletConnectJWT", dependencies: ["WalletConnectKMS"], path: "Sources/WalletConnectJWT"),
        .target(name: "WalletConnectKMS", dependencies: ["WalletConnectUtils"], path: "Sources/WalletConnectKMS"),
        .target(name: "WalletConnectUtils", dependencies: ["JSONRPC"], path: "Sources/WalletConnectUtils"),
        .target(name: "JSONRPC", dependencies: ["Commons"], path: "Sources/JSONRPC"),
        .target(name: "Commons", path: "Sources/Commons"),
        .target(name: "HTTPClient", path: "Sources/HTTPClient"),
        .target(
            name: "WalletConnectRelay",
            dependencies: ["WalletConnectJWT"],
            path: "Sources/WalletConnectRelay",
            resources: [.copy("PackageConfig.json"), .process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "WalletConnectNetworking",
            dependencies: ["HTTPClient", "WalletConnectRelay"],
            path: "Sources/WalletConnectNetworking"
        ),
        .target(
            name: "WalletConnectVerify",
            dependencies: ["WalletConnectUtils", "WalletConnectNetworking", "WalletConnectJWT"],
            path: "Sources/WalletConnectVerify",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "Events",
            dependencies: ["WalletConnectUtils", "WalletConnectNetworking"],
            path: "Sources/Events"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
